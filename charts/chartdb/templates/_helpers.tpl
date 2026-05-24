{{/*
Expand the name of the chart.
*/}}
{{- define "chartdb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "chartdb.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "chartdb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "chartdb.labels" -}}
helm.sh/chart: {{ include "chartdb.chart" . }}
{{ include "chartdb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "chartdb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "chartdb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use.
*/}}
{{- define "chartdb.serviceAccountName" -}}
{{- if .Values.chartdb.serviceAccount.create }}
{{- default (include "chartdb.fullname" .) .Values.chartdb.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.chartdb.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Build the chartdb container image reference.
*/}}
{{- define "chartdb.image" -}}
{{- $tag := default .Chart.AppVersion .Values.chartdb.image.tag }}
{{- printf "%s:%s" .Values.chartdb.image.repository $tag }}
{{- end }}

{{/*
Return the OpenAI Secret name.
- If openai.existingSecret is set, use it directly.
- If openai.enabled is true but no existingSecret is set, fail. The
  chart never generates an OpenAI Secret (see INV-0001) — it must be
  provisioned out-of-band when AI features are enabled.
- If openai.enabled is false, return an empty string (not referenced).
*/}}
{{- define "chartdb.openaiSecretName" -}}
{{- if .Values.chartdb.openai.existingSecret }}
{{- .Values.chartdb.openai.existingSecret }}
{{- else if .Values.chartdb.openai.enabled }}
{{- fail "chartdb.openai.existingSecret is required when chartdb.openai.enabled is true. The chart does not generate an OpenAI Secret (see INV-0001). Provision the Secret out-of-band (External Secrets, 1Password Operator, sealed-secrets, or raw kubectl apply)." }}
{{- end }}
{{- end }}
