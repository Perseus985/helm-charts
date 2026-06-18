{{/*
Expand the name of the chart.
*/}}
{{- define "observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "observability.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "observability.fullname" -}}
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
Common labels
*/}}
{{- define "observability.labels" -}}
helm.sh/chart: {{ include "observability.chart" . }}
{{ include "observability.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "observability.selectorLabels" -}}
app.kubernetes.io/name: {{ include "observability.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Prometheus remote write endpoint
*/}}
{{- define "observability.prometheusEndpoint" -}}
http://{{ .Release.Name }}-prometheus-server:80/api/v1/write
{{- end }}

{{/*
Render a container image reference from a split image dict.
Builds "registry/repository", then "@digest" when a digest is set (overrides tag),
otherwise ":tag". Lets the platform-mesh-operator inject the localized
registry/repository/tag/digest from the OCM resource status for air-gap.
Usage: {{ include "observability.image" .Values.path.to.image }}

TODO(tech-debt): extract as a parameterized "common.imageRef" helper in the common chart
and migrate infra/observability (+ other charts with nested sub-images) to it. Kept local
here to avoid coupling this PR to a common release + a new observability->common dependency.
*/}}
{{- define "observability.image" -}}
{{- printf "%s/%s" .registry .repository -}}
{{- if .digest -}}@{{ .digest }}{{- else -}}:{{ .tag }}{{- end -}}
{{- end -}}
