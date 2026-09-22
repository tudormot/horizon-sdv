{{/*
Copyright (c) 2026 Accenture, All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Description:
Helm helpers for the voltron-demo Argo Workflows chart.
*/ -}}

{{- define "voltron-demo.workflowServiceAccountName" -}}
{{- if .Values.spec.useElevatedWorkflowIam -}}
workflow-executor-elevated
{{- else -}}
{{- .Values.spec.serviceAccountName | default "workflow-executor" -}}
{{- end -}}
{{- end -}}

{{/* Artifact Registry host for the deployment region. */}}
{{- define "voltron-demo.registry" -}}
{{- printf "%s-docker.pkg.dev" .Values.gcpRegion -}}
{{- end -}}

{{/*
Fully qualified name of one cicd-foundation layer built by this module.

Call with a dict: (dict "ctx" . "layer" "gnome"). Helm templates take a single
argument, and the layer names are needed both as build destinations and as the
BASE_IMAGE of the next layer up, so a dict keeps the two in lock-step instead
of repeating the path composition at every call site.
*/}}
{{- define "voltron-demo.cicdFoundationImage" -}}
{{- $ctx := .ctx -}}
{{- $cf := $ctx.Values.spec.cicdFoundation -}}
{{- printf "%s/%s/%s%s:%s" (include "voltron-demo.registry" $ctx) $ctx.Values.gcpProjectId $cf.imagePathPrefix .layer $cf.ref -}}
{{- end -}}

{{/* Artifact Registry path (no host, no tag) for one cicd-foundation layer. */}}
{{- define "voltron-demo.cicdFoundationImagePath" -}}
{{- printf "%s%s" .ctx.Values.spec.cicdFoundation.imagePathPrefix .layer -}}
{{- end -}}

{{/*
Image produced by this pipeline. Mirrors how common-docker-image-build composes
its destination: <region>-docker.pkg.dev/<project>/<dockerArtifactPathName>:<imageTag>.
*/}}
{{- define "voltron-demo.outputImage" -}}
{{- printf "%s/%s/%s:%s" (include "voltron-demo.registry" .) .Values.gcpProjectId .Values.spec.dockerArtifactPathName .Values.spec.imageTag -}}
{{- end -}}
