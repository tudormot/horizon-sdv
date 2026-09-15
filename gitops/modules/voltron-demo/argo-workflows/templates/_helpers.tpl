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
ASfP base image: consumed as a build-arg, never pushed by this module.

The registry host is configurable independently of `voltron-demo.registry`
because the base image is published by a different pipeline, which need not
target the same region (or even the same Artifact Registry repository) as this
module's own output image.
*/}}
{{- define "voltron-demo.asfpBaseImage" -}}
{{- $registry := .Values.spec.asfpImageRegistry | default (include "voltron-demo.registry" .) -}}
{{- printf "%s/%s/%s:%s" $registry .Values.gcpProjectId .Values.spec.asfpImageName .Values.spec.asfpImageTag -}}
{{- end -}}

{{/*
Image produced by this pipeline. Mirrors how common-docker-image-build composes
its destination: <region>-docker.pkg.dev/<project>/<dockerArtifactPathName>:<imageTag>.
*/}}
{{- define "voltron-demo.outputImage" -}}
{{- printf "%s/%s/%s:%s" (include "voltron-demo.registry" .) .Values.gcpProjectId .Values.spec.dockerArtifactPathName .Values.spec.imageTag -}}
{{- end -}}
