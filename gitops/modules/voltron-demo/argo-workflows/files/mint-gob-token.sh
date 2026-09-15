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
# Mint a short lived Git-on-Borg credential for this pod's Workload Identity
# service account and write it to ${TOKEN_DIR} as a username/password pair.
#
# Why a service account and not a developer's gitcookies: the Git-on-Borg `sdv`
# host grants its human readers almost entirely through MDB `prod_group` and
# `prod_user` entries, and those resolve only over sso:// and rpc://. Neither is
# available from a GKE pod, and over HTTPS any credential resolves a GAIA
# identity instead, which the host rejects with PERMISSION_DENIED_BY_HOST_ACL.
# The host does authorise `robot` readers, and a service account is a GAIA
# identity, so a token minted here is the only credential this pipeline can use.
#
# The pair is consumed two ways: as HTTP basic auth (Argo's git artifact, which
# only accepts usernameSecret/passwordSecret) and as a Netscape cookie
# (git ls-remote). Both were verified against the live host.
#
# It is written to a shared emptyDir rather than an Argo output parameter so the
# token never lands in the Workflow object, where anyone able to read workflows
# in this namespace could see it. Argo has no masked-parameter support.
#
# Runs in google/cloud-sdk:alpine, which is BusyBox: POSIX sh only, no bashisms.

set -eu
umask 077

METADATA="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default"
HEADER="Metadata-Flavor: Google"
OUT="${TOKEN_DIR:-/token}"

SA_EMAIL=$(curl -sf -H "${HEADER}" "${METADATA}/email" || true)
if [ -z "${SA_EMAIL}" ]; then
  echo "ERROR: could not read the service account email from the metadata server."
  echo "Check that this pod's Kubernetes service account is annotated with"
  echo "iam.gke.io/gcp-service-account and that Workload Identity is enabled."
  exit 1
fi

# Git-on-Borg expects the account name prefixed with 'git-'.
printf 'git-%s' "${SA_EMAIL}" > "${OUT}/username"

# BusyBox has no jq; the metadata response is a flat JSON object, so a single
# sed extraction is sufficient and avoids pulling in another dependency.
ACCESS_TOKEN=$(curl -sf -H "${HEADER}" "${METADATA}/token" \
  | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "${ACCESS_TOKEN}" ]; then
  echo "ERROR: could not mint an access token from the metadata server."
  exit 1
fi

# printf, not echo, so no trailing newline ends up inside the credential.
printf '%s' "${ACCESS_TOKEN}" > "${OUT}/password"

# This container runs as root, but the containers that consume the credential do
# not all do so: the kubectl image runs as UID 1001. The umask above would leave
# these files 0600 root-owned and unreadable there, so widen them to read-only
# for everyone. The blast radius is a single pod: the volume is a memory-backed
# emptyDir, so "everyone" means only the containers of this pod, all of which are
# already entitled to the credential.
chmod 0444 "${OUT}/username" "${OUT}/password"

# Never print the token itself; the identity is enough to correlate a run.
echo "Minted a Git-on-Borg credential for ${SA_EMAIL}."
