{{- define "omniroute.namespace" -}}
{{- required "namespace.name is required" .Values.namespace.name -}}
{{- end -}}

{{- define "omniroute.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "omniroute.labels" -}}
app.kubernetes.io/name: {{ include "omniroute.fullname" . }}
app.kubernetes.io/instance: {{ include "omniroute.fullname" . }}
app.kubernetes.io/managed-by: Helm
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "omniroute.selectorLabels" -}}
app.kubernetes.io/name: {{ include "omniroute.fullname" . }}
app.kubernetes.io/instance: {{ include "omniroute.fullname" . }}
{{- end -}}
