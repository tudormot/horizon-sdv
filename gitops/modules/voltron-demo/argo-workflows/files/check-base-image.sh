#!/bin/sh
# Copyright (c) 2026 Accenture, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Report whether the pinned cicd-foundation base image has already been built
# into this project's Artifact Registry.
#
# This is the cache check for the base-image chain. Only the final layer is
# probed: the five layers are built as one unit, so if the top of the chain is
# present at this ref, the layers below it were necessarily built to produce
# it. Probing each layer separately would only create the possibility of a
# half-built chain being treated as usable.
#
# Writes "true" or "false" to ${OUT_FILE}, which the workflow surfaces as an
# output parameter. A missing image is a normal outcome, not an error, so the
# script itself always exits 0 unless the lookup could not be performed at all.
#
# Inputs (environment):
#   PROJECT     GCP project id
#   REGION      GCP region (selects the Artifact Registry host)
#   IMAGE_PATH  repository-qualified image path, e.g.
#               horizon-sdv/cicd-foundation-android-studio-for-platform
#   REF         image tag to look for (the pinned cicd-foundation ref)
#   OUT_FILE    file to write the boolean result to

set -eu

: "${PROJECT:?PROJECT is required}"
: "${REGION:?REGION is required}"
: "${IMAGE_PATH:?IMAGE_PATH is required}"
: "${REF:?REF is required}"
OUT_FILE="${OUT_FILE:-/tmp/base_image_exists}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${IMAGE_PATH}:${REF}"

echo "Looking for ${IMAGE}..."
if gcloud artifacts docker images describe "${IMAGE}" >/dev/null 2>&1; then
  echo "Found it; the base-image chain build will be skipped."
  printf 'true' > "${OUT_FILE}"
else
  echo "Not found; the base-image chain will be built from cicd-foundation."
  printf 'false' > "${OUT_FILE}"
fi
