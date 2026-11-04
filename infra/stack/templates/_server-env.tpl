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
