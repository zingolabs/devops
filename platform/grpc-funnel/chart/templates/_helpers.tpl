{{- define "grpc-funnel.name" -}}
{{- default "grpc-funnel" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "grpc-funnel.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "grpc-funnel.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "grpc-funnel.labels" -}}
app.kubernetes.io/name: {{ include "grpc-funnel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "grpc-funnel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "grpc-funnel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* FQDN of the public cert / funnel domain */}}
{{- define "grpc-funnel.certDomain" -}}
{{- printf "%s.%s" (required "grpc-funnel: .Values.hostname is required" .Values.hostname) (required "grpc-funnel: .Values.tailnet is required" .Values.tailnet) -}}
{{- end -}}

{{/* Name of the Secret that holds TS_AUTHKEY */}}
{{- define "grpc-funnel.authkeySecret" -}}
{{- if .Values.authkey.existingSecret -}}
{{- .Values.authkey.existingSecret -}}
{{- else -}}
{{- printf "%s-authkey" (include "grpc-funnel.fullname" .) -}}
{{- end -}}
{{- end -}}
