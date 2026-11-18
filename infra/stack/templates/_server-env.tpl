{{/* Environment of every container running the server image. */}}
{{- define "sn.serverEnv" -}}
envFrom:
  - configMapRef: { name: server-env }
  - secretRef: { name: server-secrets }
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef: { name: postgres-app, key: uri }
{{- end }}

{{/* Non-secret server configuration: the data of ConfigMap server-env,
     env/server.env and the settings below, which differ between stacks or
     from compose. A key in both fails the render. */}}
{{- define "sn.serverEnvData" -}}
{{- $shared := include "sn.envFile" (dict "root" . "file" "env/server.env") | fromJson }}
{{- $stack := include "sn.serverStackEnv" . | fromYaml }}
{{- range $k, $_ := $stack }}
{{- if hasKey $shared $k }}{{ fail (printf "%s is in env/server.env and in _server-env.tpl" $k) }}{{ end }}
{{- end }}
{{- toYaml (merge $stack $shared) }}
{{- end }}

{{- define "sn.serverStackEnv" -}}
{{- $restate := include "sn.restate" . -}}
APP_ENV: {{ .Values.appEnv | quote }}
LOG_LEVEL: {{ .Values.server.logLevel | quote }}
LOG_FORMAT: json
OTEL_EXPORTER_OTLP_ENDPOINT: http://lgtm:4318
# k3s's pod network; Traefik's X-Forwarded-For is believed.
TRUSTED_PROXIES: "10.42.0.0/16"
RESTATE_INGRESS_URL: http://restate.{{ $restate }}:8080
RESTATE_ADMIN_URL: http://restate.{{ $restate }}:9070
RESTATE_ENDPOINT_URL: ""
RESTATE_REGISTER: "false"
CONSOLE_ORIGIN: https://{{ include "sn.host" (dict "root" . "sub" "console") }}
DASHBOARD_HOSTS: {{ include "sn.dashboardHosts" . | quote }}
# The docs site's API playground calls the API from these origins. Prod adds
# the GitHub Pages copy; dev adds the docs dev server on a laptop.
DOCS_ORIGINS: {{ printf "https://%s,%s" (include "sn.host" (dict "root" . "sub" "docs")) (ternary "https://shopnexus.github.io" "http://localhost:4321" (eq .Values.appEnv "prod")) | quote }}
OBJECT_STORE_ENDPOINT: http://rustfs:9000
OBJECT_STORE_PUBLIC_ENDPOINT: https://{{ include "sn.host" (dict "root" . "sub" "media") }}
MEDIA_PUBLIC_URL: https://{{ include "sn.host" (dict "root" . "sub" "media") }}/shopnexus
{{- /* The console agent, in-cluster only; its two tokens are in server-secrets. */}}
AGENT_BASE_URL: http://agent:3000
CARRIER: {{ required "server.carrier is required: fake or none, in the stack's values file" .Values.server.carrier | quote }}
{{- /* A kind turned off gets an empty model, and the server writes and
       reads no vectors of it. */}}
{{- $e := .Values.server.embed }}
EMBED_TEXT_BASE_URL: {{ ternary "http://litellm:4000/v1" "" $e.text | quote }}
EMBED_IMAGE_BASE_URL: {{ ternary "http://litellm:4000/v1" "" $e.image | quote }}
EMBED_TEXT_MODEL: {{ ternary "embed-text" "" $e.text | quote }}
EMBED_IMAGE_MODEL: {{ ternary "embed-image" "" $e.image | quote }}
PNV_TEST_NUMBERS: {{ .Values.server.pnvTestNumbers | quote }}
EMAIL_SENDER: {{ .Values.server.emailSender | quote }}
{{- end }}
