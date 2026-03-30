{{/*
Expand the name of the chart.
*/}}
{{- define "fleetdm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fleetdm.fullname" -}}
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
{{- define "fleetdm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "fleetdm.labels" -}}
helm.sh/chart: {{ include "fleetdm.chart" . }}
{{ include "fleetdm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "fleetdm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fleetdm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use.
*/}}
{{- define "fleetdm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fleetdm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Build the Fleet container image reference.
*/}}
{{- define "fleetdm.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{/*
Return the MySQL secret name — existingSecret or chart-generated.
*/}}
{{- define "fleetdm.mysqlSecretName" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecret }}
{{- else }}
{{- printf "%s-mysql" (include "fleetdm.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Return the Redis/Valkey secret name — existingSecret or chart-generated.
*/}}
{{- define "fleetdm.redisSecretName" -}}
{{- if .Values.cache.existingSecret }}
{{- .Values.cache.existingSecret }}
{{- else }}
{{- printf "%s-redis" (include "fleetdm.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Return the MySQL address.
- If database.address is set, use it directly.
- If mysql.enabled, derive from embedded MySQL service.
- Otherwise, fail with an actionable error message.
*/}}
{{- define "fleetdm.mysqlAddress" -}}
{{- if .Values.database.address }}
{{- .Values.database.address }}
{{- else if .Values.mysql.enabled }}
{{- printf "%s-mysql.%s:%d" (include "fleetdm.fullname" .) .Release.Namespace (.Values.mysql.service.port | int) }}
{{- else }}
{{- fail "database.address is required when mysql.enabled is false" }}
{{- end }}
{{- end }}

{{/*
Return the Redis/cache address.
- If cache.address is set, use it directly.
- If valkey.enabled, derive from Valkey headless service.
- Otherwise, fail with an actionable error message.
*/}}
{{- define "fleetdm.redisAddress" -}}
{{- if .Values.cache.address }}
{{- .Values.cache.address }}
{{- else if .Values.valkey.enabled }}
{{- printf "%s-valkey.%s:%d" (include "fleetdm.fullname" .) .Release.Namespace (.Values.valkey.service.port | int) }}
{{- else }}
{{- fail "cache.address is required when valkey.enabled is false" }}
{{- end }}
{{- end }}
