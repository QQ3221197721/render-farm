{{/*
Expand the name of the chart.
*/}}
{{- define "render-farm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "render-farm.fullname" -}}
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
{{- define "render-farm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "render-farm.labels" -}}
helm.sh/chart: {{ include "render-farm.chart" . }}
{{ include "render-farm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: render-worker
{{- end }}

{{/*
Selector labels
*/}}
{{- define "render-farm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "render-farm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
job-id: {{ .Values.global.jobId }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "render-farm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "render-farm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Cloud provider specific settings
*/}}
{{- define "render-farm.cloudConfig" -}}
{{- if eq .Values.global.cloudProvider "aliyun" }}
OSS_ENDPOINT: {{ .Values.aliyun.ossEndpoint | quote }}
OSS_REGION: {{ .Values.aliyun.ossRegion | quote }}
{{- else }}
AWS_REGION: {{ .Values.aws.region | quote }}
{{- if .Values.aws.s3Endpoint }}
S3_ENDPOINT: {{ .Values.aws.s3Endpoint | quote }}
{{- end }}
{{- end }}
{{- end }}
