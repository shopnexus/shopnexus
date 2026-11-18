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
     cluster and sits behind the stack whose argocdDashboard is true. */}}
{{- define "sn.dashboards" -}}
{{- $l := list
  (dict "app" "grafana" "service" "lgtm" "port" 3000)
  (dict "app" "restate" "service" "restate" "namespace" (include "sn.restate" .) "port" 9070)
  (dict "app" "litellm" "service" "litellm" "port" 4000)
  (dict "app" "s3" "service" "rustfs" "port" 9001)
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

{{/* litellm/config.yaml parsed. */}}
{{- define "sn.litellmConfig" -}}
{{- .Files.Get "litellm/config.yaml" | fromYaml | toJson }}
{{- end }}

{{/* Every alias of litellm/config.yaml with its cost, as a JSON object of
     name to cost. A key's budget counts in one unit only when every alias
     it calls costs the same. */}}
{{- define "sn.litellmCosts" -}}
{{- $cfg := include "sn.litellmConfig" . | fromJson }}
{{- $out := dict }}
{{- range $m := $cfg.model_list }}
{{- $i := $m.model_info | default dict }}
{{- $_ := set $out $m.model_name (printf "token %v/%v second %v" ($i.input_cost_per_token | default 0) ($i.output_cost_per_token | default 0) ($i.input_cost_per_second | default 0)) }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{/* The secrets LiteLLM reads from the environment: each os.environ/NAME
     api_key of litellm/config.yaml, sorted, once. */}}
{{- define "sn.litellmSecretEnv" -}}
{{- $cfg := include "sn.litellmConfig" . | fromJson }}
{{- $names := dict }}
{{- range $m := $cfg.model_list }}
{{- $k := toString $m.litellm_params.api_key }}
{{- if hasPrefix "os.environ/" $k }}{{ $_ := set $names (trimPrefix "os.environ/" $k) true }}{{ end }}
{{- end }}
{{- keys $names | sortAlpha | toJson }}
{{- end }}

{{/* The keys of litellm/keys.txt as a JSON list of {alias, secret, var,
     allows}. */}}
{{- define "sn.litellmKeys" -}}
{{- $out := list }}
{{- range splitList "\n" (.Files.Get "litellm/keys.txt") }}
{{- $line := trim . }}
{{- if and $line (not (hasPrefix "#" $line)) }}
{{- $f := regexSplit "\\s+" $line -1 }}
{{- if ne (len $f) 4 }}{{ fail (printf "litellm/keys.txt: %q is not alias secret var allows" $line) }}{{ end }}
{{- $out = append $out (dict "alias" (index $f 0) "secret" (index $f 1) "var" (index $f 2) "allows" (splitList "," (index $f 3))) }}
{{- end }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{/* The env var of the key Job that holds one key's limits: server-llm
     gives LIMITS_SERVER_LLM. */}}
{{- define "sn.litellmLimitsEnv" -}}
LIMITS_{{ . | upper | replace "-" "_" }}
{{- end }}

{{/* A key's budget and rate limit as JSON members, the LIMITS_ value
     keys.sh adds to the body of /key/update and /key/generate. Call with
     (dict "alias" "server-llm" "k" .Values.litellm.keys.server-llm). */}}
{{- define "sn.litellmLimits" -}}
{{- $k := .k | default dict -}}
{{- $units := required (printf "litellm.keys.%s.dailyUnits is required" .alias) $k.dailyUnits -}}
{{- $b := dict "max_budget" (divf $units 1000000) -}}
{{- with $k.tpmLimit }}{{ $_ := set $b "tpm_limit" (int .) }}{{ end -}}
{{- with $k.rpmLimit }}{{ $_ := set $b "rpm_limit" (int .) }}{{ end -}}
{{- if not (or $k.tpmLimit $k.rpmLimit) }}{{ fail (printf "litellm.keys.%s needs tpmLimit or rpmLimit" .alias) }}{{ end -}}
{{- toJson $b | trimPrefix "{" | trimSuffix "}" -}}
{{- end }}
