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
# Assert that the cicd-foundation revision this module pins is the one
# sdv-demos actually declares.
#
# sdv-demos/docker/skaffold.yaml is the authority: it `requires:` the
# cicd-foundation Android Studio for Platform config at an immutable ref, and
# skaffold builds that dependency as the BASE_IMAGE for the demo layer. This
# module builds the same chain itself, so its pinned ref must agree. If the two
# drift, the demo layer is built on a base its own Dockerfile was never tested
# against -- silently, which is precisely the failure this check exists to make
# loud.
#
# The repository URL is checked too, so that upstream moving to a different
# source is caught rather than silently ignored.
#
# Inputs (environment):
#   EXPECTED_REF    cicd-foundation ref pinned by this module
#   EXPECTED_REPO   cicd-foundation repository URL pinned by this module
#   SKAFFOLD_FILE   path to the sdv-demos skaffold config (default:
#                   /workspace/docker/skaffold.yaml)
#
# Runs in alpine/git, which is BusyBox: POSIX sh only, no bashisms.

set -eu

: "${EXPECTED_REF:?EXPECTED_REF is required}"
: "${EXPECTED_REPO:?EXPECTED_REPO is required}"
SKAFFOLD_FILE="${SKAFFOLD_FILE:-/workspace/docker/skaffold.yaml}"

if [ ! -f "${SKAFFOLD_FILE}" ]; then
  echo "ERROR: ${SKAFFOLD_FILE} not found." >&2
  echo "sdv-demos is expected to declare its base image in docker/skaffold.yaml." >&2
  exit 1
fi

# The file is small and the shape is fixed, so a targeted sed beats adding a
# YAML parser to a BusyBox image. Quotes are stripped because skaffold accepts
# the value both quoted and bare.
extract() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)[[:space:]]*$/\1/p" "${SKAFFOLD_FILE}" \
    | head -n 1 | tr -d '"'\''' | tr -d '[:space:]'
}

DECLARED_REF=$(extract ref)
DECLARED_REPO=$(extract repo)

echo "sdv-demos declares: repo=${DECLARED_REPO} ref=${DECLARED_REF}"
echo "this module pins:   repo=${EXPECTED_REPO} ref=${EXPECTED_REF}"

if [ -z "${DECLARED_REF}" ]; then
  echo "ERROR: no 'ref:' found in ${SKAFFOLD_FILE}." >&2
  echo "Either the file moved or upstream stopped pinning its base image." >&2
  exit 1
fi

FAILED=false

if [ "${DECLARED_REPO}" != "${EXPECTED_REPO}" ]; then
  echo "ERROR: sdv-demos now builds its base from a different repository." >&2
  FAILED=true
fi

if [ "${DECLARED_REF}" != "${EXPECTED_REF}" ]; then
  echo "ERROR: sdv-demos has moved its pinned cicd-foundation ref." >&2
  FAILED=true
fi

if [ "${FAILED}" = "true" ]; then
  echo >&2
  echo "Set spec.cicdFoundation.ref (and .repo) in this module's" >&2
  echo "argo-workflows/values.yaml to match, after reviewing the upstream" >&2
  echo "changes between the two refs as described in sdv-demos/docker/README.md." >&2
  exit 1
fi

echo "OK: the pinned cicd-foundation revision matches what sdv-demos declares."
