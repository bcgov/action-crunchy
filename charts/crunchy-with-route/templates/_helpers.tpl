{{/*
Expand the name of the chart.
*/}}
{{- define "crunchy-postgres.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "crunchy-postgres.fullname" -}}
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
{{- define "crunchy-postgres.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "crunchy-postgres.labels" -}}
helm.sh/chart: {{ include "crunchy-postgres.chart" . }}
{{ include "crunchy-postgres.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "crunchy-postgres.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crunchy-postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Generate S3 configuration for pgBackRest secret
This template creates the S3 configuration section used in the pgBackRest secret.
The S3 credentials (accessKeyId and accessKeySecret) are passed via --set during deployment.
Supports the following S3 configuration options:
- accessKeyId: S3 access key ID
- accessKeySecret: S3 secret access key
- encryptionPassphrase: Optional encryption passphrase for backups
*/}}
{{- define "crunchy.s3" }}
[global]
{{- if .s3 }}
  {{- if .s3.accessKeyId }}
repo{{ add .index 1 }}-s3-key={{ .s3.accessKeyId }}
  {{- end }}
  {{- if .s3.accessKeySecret }}
repo{{ add .index 1 }}-s3-key-secret={{ .s3.accessKeySecret }}
  {{- end }}
  {{- if .s3.encryptionPassphrase }}
repo{{ add .index 1 }}-cipher-pass={{ .s3.encryptionPassphrase }}
  {{- end }}
{{- end }}
{{ end }}