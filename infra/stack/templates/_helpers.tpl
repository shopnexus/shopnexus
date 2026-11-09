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

{{/* repository:tag of one images.* entry. */}}
{{- define "sn.image" -}}
{{ .repository }}:{{ .tag }}
{{- end }}

{{/* (dict "root" $ "sub" "api") gives api.<domain>; an empty sub gives <domain>. */}}
{{- define "sn.host" -}}
{{- $d := required "domain is required" .root.Values.domain -}}
{{- if .sub }}{{ .sub }}.{{ $d }}{{ else }}{{ $d }}{{ end -}}
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
     cluster and sits behind the prod stack. */}}
{{- define "sn.dashboards" -}}
{{- $l := list
  (dict "app" "grafana" "service" "lgtm" "port" 3000)
  (dict "app" "restate" "service" "restate" "namespace" (include "sn.restate" .) "port" 9070)
  (dict "app" "litellm" "service" "litellm" "port" 4000)
  (dict "app" "s3" "service" "rustfs" "port" 9001) }}
{{- if eq .Values.stack "prod" }}
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
{{/* The env var of the key Job that holds one key's value: server-llm gives
     KEY_SERVER_LLM. */}}
{{- define "sn.keyEnv" -}}
KEY_{{ . | upper | replace "-" "_" }}
{{- end }}

{{/* The JSON body of /key/update and /key/generate for one key, without the
     key's value, which the Job adds at run time. Call with
     (dict "alias" "server-llm" "k" .Values.litellm.keys.server-llm). */}}
{{- define "sn.keyBody" -}}
{{- $k := .k -}}
{{- $units := required (printf "litellm.keys.%s.dailyUnits is required" .alias) $k.dailyUnits -}}
{{- $b := dict "key_alias" .alias "models" $k.models "budget_duration" "1d" "max_budget" (divf $units 1000000) -}}
{{- if hasKey $k "tpmLimit" }}{{ $_ := set $b "tpm_limit" (int $k.tpmLimit) }}{{ end -}}
{{- if hasKey $k "rpmLimit" }}{{ $_ := set $b "rpm_limit" (int $k.rpmLimit) }}{{ end -}}
{{- if not (or (hasKey $k "tpmLimit") (hasKey $k "rpmLimit")) }}{{ fail (printf "litellm.keys.%s needs tpmLimit or rpmLimit" .alias) }}{{ end -}}
{{- toJson $b -}}
{{- end }}
