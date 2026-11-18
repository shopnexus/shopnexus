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

{{/* The aliases LiteLLM starts with, litellm/models/<alias>.json, as a JSON
     list of /model/new bodies. A file's model_name is its file name. */}}
{{- define "sn.litellmModels" -}}
{{- $out := list }}
{{- range $path, $_ := .Files.Glob "litellm/models/*.json" }}
{{- $m := $.Files.Get $path | fromJson }}
{{- $alias := base $path | trimSuffix ".json" }}
{{- if ne (toString $m.model_name) $alias }}{{ fail (printf "%s: model_name is %v, want %s" $path $m.model_name $alias) }}{{ end }}
{{- $out = append $out $m }}
{{- end }}
{{- if not $out }}{{ fail "litellm/models/ holds no aliases" }}{{ end }}
{{- toJson $out }}
{{- end }}

{{/* Every alias of litellm/models/ with its cost, as a JSON object of
     name to cost. A key's budget counts in one unit only when every alias
     it calls costs the same. The prices are in litellm_params: LiteLLM
     drops the ones in model_info of a deployment it stores, and prices its
     calls at 0. */}}
{{- define "sn.litellmCosts" -}}
{{- $out := dict }}
{{- range $m := include "sn.litellmModels" . | fromJsonArray }}
{{- $p := $m.litellm_params }}
{{- range $k, $_ := $m.model_info | default dict }}
{{- if contains "cost" $k }}{{ fail (printf "litellm/models/%s.json: %s is in model_info, where LiteLLM drops it; put it in litellm_params" $m.model_name $k) }}{{ end }}
{{- end }}
{{- if not (or $p.input_cost_per_token $p.input_cost_per_second) }}{{ fail (printf "litellm/models/%s.json: litellm_params has no input_cost_per_token or input_cost_per_second" $m.model_name) }}{{ end }}
{{- $_ := set $out $m.model_name (printf "token %v/%v second %v" ($p.input_cost_per_token | default 0) ($p.output_cost_per_token | default 0) ($p.input_cost_per_second | default 0)) }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{/* The secrets LiteLLM reads from the environment: each os.environ/NAME
     api_key of litellm/models/, sorted, once. */}}
{{- define "sn.litellmSecretEnv" -}}
{{- $names := dict }}
{{- range $m := include "sn.litellmModels" . | fromJsonArray }}
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
