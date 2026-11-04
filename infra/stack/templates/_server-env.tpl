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

{{/* Non-secret server configuration: the data of ConfigMap server-env. */}}
{{- define "sn.serverEnvData" -}}
{{- $restate := include "sn.restate" . -}}
APP_ENV: {{ .Values.appEnv | quote }}
HTTP_ADDR: ":8080"
LOG_LEVEL: {{ .Values.server.logLevel | quote }}
LOG_FORMAT: json
OTEL_EXPORTER_OTLP_ENDPOINT: ""
SERVICE_NAME: server
# k3s's pod network; Traefik's X-Forwarded-For is believed.
TRUSTED_PROXIES: "10.42.0.0/16"
RESTATE_INGRESS_URL: http://restate.{{ $restate }}:8080
RESTATE_ADMIN_URL: http://restate.{{ $restate }}:9070
RESTATE_LISTEN_ADDR: "0.0.0.0:9080"
RESTATE_ENDPOINT_URL: ""
RESTATE_SERVICE_PREFIX: ""
RESTATE_REGISTER: "false"
JWT_ISSUER: shopnexus
JWT_AUDIENCE: shopnexus-app
JWT_PREVIOUS_KEY_ID: ""
JWT_PREVIOUS_PUBLIC_KEY: ""
STAFF_CONSOLE_ORIGIN: https://{{ include "sn.host" (dict "root" . "sub" "console") }}
OBJECT_STORE_ENDPOINT: http://rustfs:9000
OBJECT_STORE_PUBLIC_ENDPOINT: https://{{ include "sn.host" (dict "root" . "sub" "media") }}
OBJECT_STORE_REGION: us-east-1
OBJECT_STORE_BUCKET: shopnexus
MEDIA_PUBLIC_URL: https://{{ include "sn.host" (dict "root" . "sub" "media") }}/shopnexus
LLM_BASE_URL: http://litellm:4000/v1
LLM_MODEL: search
FIREBASE_PROJECT_ID: {{ .Values.server.firebaseProjectID | quote }}
FIREBASE_PROJECT_NUMBER: {{ .Values.server.firebaseProjectNumber | quote }}
FIREBASE_AUTH_JWKS_URL: https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com
PNV_JWKS_URL: https://fpnv.googleapis.com/v1beta/jwks
PNV_TEST_NUMBERS: {{ .Values.server.pnvTestNumbers | quote }}
{{- end }}
