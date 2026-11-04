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
{{- range $path, $_ := .Files.Glob (printf "secrets/%s/*.yaml" .Values.stack) }}{{ $all = print $all ($.Files.Get $path) }}{{ end }}
{{- $all | sha256sum | trunc 16 }}
{{- end }}
