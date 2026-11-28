{{/* Labels on every resource. */}}
{{- define "sn.labels" -}}
app.kubernetes.io/part-of: shopnexus
shopnexus.id.vn/stack: {{ .Values.stack }}
{{- end }}

{{/* Pod labels. Call with (dict "root" $ "name" "server"). */}}
{{- define "sn.podLabels" -}}
app.kubernetes.io/name: {{ .name }}
{{ include "sn.labels" .root }}
{{- end }}

{{/*
The server's version: a hash of what makes the operator start a new one
(image, env, secrets). The API Services select it, so old versions only
finish their invocations.
*/}}
{{- define "sn.serverVersion" -}}
{{ printf "%s|%s|%s" (include "sn.image" .Values.images.server) (include "sn.serverEnvData" .) (include "sn.secretsSum" .) | sha256sum | trunc 16 }}
{{- end }}

{{/* repository:tag of one images.* entry; a tag that is a digest
     (sha256:…, as a release writes) gives repository@digest. */}}
{{- define "sn.image" -}}
{{- if hasPrefix "sha256:" (toString .tag) -}}
{{ .repository }}@{{ .tag }}
{{- else -}}
{{ .repository }}:{{ .tag }}
{{- end -}}
{{- end }}

{{/* (dict "root" $ "sub" "api") gives api.<domain>; an empty sub gives <domain>. */}}
{{- define "sn.host" -}}
{{- $d := required "domain is required" .root.Values.domain -}}
{{- if .sub }}{{ .sub }}.{{ $d }}{{ else }}{{ $d }}{{ end -}}
{{- end }}

{{/* Ingress rules for (dict "routes" (list (list sub service port) ...)
     "domain" d "bucket" b). The website's host also sends /_img to
     imgproxy's cache. The media host sends its /robots.txt and /<bucket>/
     to the cache too (imgproxy/nginx.conf), which hands the bucket to
     Garage, so its admin API and other buckets stay off the internet. */}}
{{- define "sn.ingressRules" -}}
{{- $d := .domain }}
{{- range .routes }}
- host: {{ if index . 0 }}{{ index . 0 }}.{{ end }}{{ $d }}
  http:
    paths:
      {{- if eq (index . 0) "" }}
      - path: /_img
        pathType: Prefix
        backend:
          service:
            name: imgproxy-cache
            port: { number: 80 }
      {{- end }}
      {{- if eq (index . 0) "media" }}
      - path: /robots.txt
        pathType: Exact
        backend:
          service:
            name: imgproxy-cache
            port: { number: 80 }
      {{- end }}
      - path: {{ if eq (index . 0) "media" }}/{{ required "bucket is required" $.bucket }}/{{ else }}/{{ end }}
        pathType: Prefix
        backend:
          service:
            name: {{ index . 1 }}
            port: { number: {{ index . 2 }} }
{{- end }}
{{- end }}

{{/* The media bucket, OBJECT_STORE_BUCKET in env/server.env. */}}
{{- define "sn.bucket" -}}
{{ (include "sn.envFile" (dict "root" . "file" "env/server.env") | fromJson).OBJECT_STORE_BUCKET }}
{{- end }}

{{/* Name and namespace of the stack's RestateCluster. */}}
{{- define "sn.restate" -}}
restate-{{ required "stack is required" .Values.stack }}
{{- end }}

{{/* Argo CD sync wave annotation. */}}
{{- define "sn.wave" -}}
argocd.argoproj.io/sync-wave: {{ . | quote }}
{{- end }}

{{/* Prefer nodes labelled role=<value>. Goes under affinity. */}}
{{- define "sn.preferRole" -}}
nodeAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
          - { key: role, operator: In, values: [{{ . }}] }
{{- end }}

{{/* Prefer one pod of app <value> per node. Goes under affinity. */}}
{{- define "sn.spread" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels: { app.kubernetes.io/name: {{ . }} }
{{- end }}

{{/* Pod label that lets the stack's Restate pods reach this pod. */}}
{{- define "sn.restateAllow" -}}
allow.restate.dev/{{ include "sn.restate" . }}: "true"
{{- end }}

{{/* Checksum of the stack's sealed secrets, for pod template annotations:
     a reseal changes it and so starts new pods. */}}
{{- define "sn.secretsSum" -}}
{{- $all := "" }}
{{- range $path, $_ := .Files.Glob (printf "%s/%s/*.yaml" .Values.secretsDir .Values.stack) }}{{ $all = print $all ($.Files.Get $path) }}{{ end }}
{{- $all | sha256sum | trunc 16 }}
{{- end }}

{{/* The operations dashboards of the stack as a JSON list of app, host,
     service, namespace (empty: the stack's) and port. Argo CD is one per
     cluster and sits behind the stack whose argocdDashboard is true. */}}
{{- define "sn.dashboards" -}}
{{- $l := list
  (dict "app" "grafana" "service" "lgtm" "port" 3000)
  (dict "app" "restate" "service" "restate" "namespace" (include "sn.restate" .) "port" 9070)
  (dict "app" "bifrost" "service" "bifrost" "port" 8080)
  (dict "app" "s3" "service" "garage-webui" "port" 3909)
  (dict "app" "db" "service" "pgweb" "port" 8081) }}
{{- if .Values.argocdDashboard }}
{{- $l = append $l (dict "app" "argocd" "service" "argocd-server" "namespace" "argocd" "port" 80) }}
{{- end }}
{{- $out := list }}
{{- range $l }}
{{- $out = append $out (merge (dict "host" (include "sn.host" (dict "root" $ "sub" .app))) .) }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{/* DASHBOARD_HOSTS: app=host pairs, comma-separated. */}}
{{- define "sn.dashboardHosts" -}}
{{- $pairs := list }}
{{- range include "sn.dashboards" . | fromJsonArray }}{{ $pairs = append $pairs (printf "%s=%s" .app .host) }}{{ end }}
{{- join "," $pairs }}
{{- end }}

{{/* An env file of env/ (KEY=value lines, # comments) as a JSON object.
     docker-compose.yml reads the same files with env_file. */}}
{{- define "sn.envFile" -}}
{{- $out := dict }}
{{- range splitList "\n" (.root.Files.Get .file) }}
{{- $line := trim . }}
{{- if and $line (not (hasPrefix "#" $line)) }}
{{- $kv := splitn "=" 2 $line }}
{{- if lt (len $kv) 2 }}{{ fail (printf "%s: %q is not KEY=value" $.file $line) }}{{ end }}
{{- $_ := set $out $kv._0 $kv._1 }}
{{- end }}
{{- end }}
{{- toJson $out }}
{{- end }}
