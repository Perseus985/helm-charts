{{/*
Render a container image reference from a split image dict.
Builds "registry/repository", then "@digest" when a digest is set (overrides tag),
otherwise ":tag". Mirrors the common.image helper so the platform-mesh-operator can
inject the localized registry/repository/tag/digest from the OCM resource status.
Usage: {{ include "infra.image" .Values.path.to.image }}

TODO(tech-debt): extract as a parameterized "common.imageRef" helper in the common chart
and migrate infra/observability (+ other charts with nested sub-images) to it. Kept local
here to avoid coupling this PR to a common release + a new observability->common dependency.
*/}}
{{- define "infra.image" -}}
{{- printf "%s/%s" .registry .repository -}}
{{- if .digest -}}@{{ .digest }}{{- else -}}:{{ .tag }}{{- end -}}
{{- end -}}
