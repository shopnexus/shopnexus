{{/* Environment of every container running the server image. */}}
{{- define "sn.serverEnv" -}}
envFrom:
  - configMapRef: { name: server-env }
  - secretRef: { name: server-secrets }
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef: { name: postgres-app, key: uri }
  {{- /* Bifrost's admin password, from the Secret Bifrost itself reads. */}}
  - name: GATEWAY_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef: { name: bifrost-secrets, key: BIFROST_ADMIN_PASSWORD }
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
MONITORING_METRICS_URL: http://lgtm:9090
MONITORING_LOGS_URL: http://lgtm:3100
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
{{- $docs := list (printf "https://%s" (include "sn.host" (dict "root" . "sub" "docs"))) }}
{{- range .Values.aliasDomains }}{{ $docs = append $docs (printf "https://docs.%s" .) }}{{ end }}
DOCS_ORIGINS: {{ printf "%s,%s" (join "," $docs) (ternary "https://shopnexus.github.io" "http://localhost:4321" (eq .Values.appEnv "prod")) | quote }}
# The website's pages PUT photos to presigned upload URLs from these origins.
# Dev adds the website dev server on a laptop.
{{- $web := list (printf "https://%s" (include "sn.host" (dict "root" . "sub" ""))) }}
{{- range .Values.aliasDomains }}{{ $web = append $web (printf "https://%s" .) }}{{ end }}
WEBSITE_ORIGINS: {{ printf "%s%s" (join "," $web) (ternary "" ",http://localhost:4321" (eq .Values.appEnv "prod")) | quote }}
OBJECT_STORE_PUBLIC_ENDPOINT: https://{{ include "sn.host" (dict "root" . "sub" "media") }}
MEDIA_PUBLIC_URL: https://{{ include "sn.host" (dict "root" . "sub" "media") }}/shopnexus
{{- /* The agent runtime, in-cluster only; AGENT_KEY is in server-secrets.
       With agent.enabled off the server answers a question with 503. */}}
AGENT_URL: http://agent:8080
{{- /* Each carrier's switch. A carrier live takes its URL from the values
       and its partner token and webhook secret from server-secrets; fake
       and off leave all its settings empty. */}}
{{- $ghtk := .Values.server.carriers.ghtk }}
{{- $ghn := .Values.server.carriers.ghn }}
{{- range $name, $mode := dict "ghtk" $ghtk.mode "ghn" $ghn.mode }}
{{- if not (has $mode (list "live" "fake" "off")) }}{{ fail (printf "server.carriers.%s.mode must be live, fake or off, in the stack's values file" $name) }}{{ end }}
{{- end }}
CARRIER_GHTK: {{ $ghtk.mode | quote }}
CARRIER_GHN: {{ $ghn.mode | quote }}
{{- if eq $ghtk.mode "live" }}
GHTK_API_URL: {{ required "server.carriers.ghtk.apiUrl is required with mode live" $ghtk.apiUrl | quote }}
GHTK_CLIENT_SOURCE: {{ required "server.carriers.ghtk.clientSource is required with mode live" $ghtk.clientSource | quote }}
{{- else }}
GHTK_API_URL: ""
GHTK_CLIENT_SOURCE: ""
GHTK_PARTNER_TOKEN: ""
GHTK_WEBHOOK_SECRET: ""
{{- end }}
{{- if eq $ghn.mode "live" }}
GHN_API_URL: {{ required "server.carriers.ghn.apiUrl is required with mode live" $ghn.apiUrl | quote }}
{{- else }}
GHN_API_URL: ""
GHN_PARTNER_TOKEN: ""
GHN_WEBHOOK_SECRET: ""
{{- end }}
{{- /* VNPay, which boosts are paid through: live with its terminal from the
       values and its hash secret from server-secrets, fake or off. */}}
{{- $pay := .Values.server.payment }}
{{- if not (has $pay.mode (list "live" "fake" "off")) }}{{ fail "server.payment.mode must be live, fake or off, in the stack's values file" }}{{ end }}
PAYMENT_VNPAY: {{ $pay.mode | quote }}
API_PUBLIC_URL: https://{{ include "sn.host" (dict "root" . "sub" "api") }}
{{- if eq $pay.mode "live" }}
VNPAY_TMN_CODE: {{ required "server.payment.tmnCode is required with mode live" $pay.tmnCode | quote }}
VNPAY_PAY_URL: {{ required "server.payment.payUrl is required with mode live" $pay.payUrl | quote }}
VNPAY_API_URL: {{ required "server.payment.apiUrl is required with mode live" $pay.apiUrl | quote }}
VNPAY_SERVER_IP: {{ required "server.payment.serverIp is required with mode live" $pay.serverIp | quote }}
{{- else }}
VNPAY_TMN_CODE: ""
VNPAY_HASH_SECRET: ""
VNPAY_PAY_URL: ""
VNPAY_API_URL: ""
VNPAY_SERVER_IP: ""
{{- end }}
{{- /* A kind turned off gets an empty model, and the server writes and
       reads no vectors of it. */}}
{{- $e := .Values.server.embed }}
EMBED_TEXT_MODEL: {{ ternary "embed-text" "" $e.text | quote }}
AI_EMBED_MODELS: {{ ternary "siglip2-so400m-patch16-384=/models/siglip2-so400m-patch16-384" "" $e.image | quote }}
{{- if not (has .Values.server.scamChecks (list "on" "off")) }}{{ fail "server.scamChecks must be on or off, in the stack's values file" }}{{ end }}
TRUST_SCAM_CHECKS: {{ .Values.server.scamChecks | quote }}
PNV_TEST_NUMBERS: {{ .Values.server.pnvTestNumbers | quote }}
EMAIL_SENDER: {{ .Values.server.emailSender | quote }}
{{- end }}
