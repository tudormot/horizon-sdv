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
# Builds a candidate persistent-disk snapshot for the voltron-demo workstation
# image.
#
# A workstation is created from the builder config and started once, which is
# what materialises and populates its regional persistent disk (the CARLA
# installation and the AAOS tree live on that disk, not in the container
# image). The workstation is then stopped so the disk is quiesced, snapshotted,
# and the workstation torn down again.
#
# Why gcloud and not Config Connector (KCC): the cluster runs the GKE
# Config Connector add-on at v1.126.0, which ships WorkstationCluster but
# neither WorkstationConfig nor Workstation, so there is no CRD to express any
# of this. Even where a CRD does exist (ComputeSnapshot), the source disk name
# is only discoverable at runtime and the create/start/stop/snapshot/delete
# sequence is one-shot and imperative, which a reconciling controller models
# poorly. See the module README for the full rationale.
#
# Inputs (environment):
#   PROJECT       GCP project id
#   REGION        GCP region
#   CLUSTER       Cloud Workstations cluster name
#   CONFIG        Cloud Workstations *builder* config name
#   WORKFLOW_UID  Argo workflow UID, used to name per-run resources
#
# Output:
#   Writes the created snapshot name to /tmp/candidate_snapshot_name.

set -eu

: "${PROJECT:?PROJECT is required}"
: "${REGION:?REGION is required}"
: "${CLUSTER:?CLUSTER is required}"
: "${CONFIG:?CONFIG is required}"
: "${WORKFLOW_UID:?WORKFLOW_UID is required}"

BUILD_WS="voltron-builder-${WORKFLOW_UID}"
CANDIDATE_SNAP="voltron-pd-snap-${WORKFLOW_UID}"

# Always try to remove the temporary builder workstation, including on failure,
# so a failed run does not leave a billable workstation behind.
cleanup() {
  echo "Cleaning up temporary builder workstation ${BUILD_WS}..."
  gcloud workstations delete "${BUILD_WS}" \
      --project="${PROJECT}" --region="${REGION}" --cluster="${CLUSTER}" \
      --config="${CONFIG}" --quiet || true
}
trap cleanup EXIT

echo "Creating temporary builder workstation: ${BUILD_WS}..."
gcloud workstations create "${BUILD_WS}" \
    --project="${PROJECT}" --region="${REGION}" --cluster="${CLUSTER}" \
    --config="${CONFIG}"

echo "Starting builder workstation..."
gcloud workstations start "${BUILD_WS}" \
    --project="${PROJECT}" --region="${REGION}" --cluster="${CLUSTER}" \
    --config="${CONFIG}"

echo "Stopping builder to quiesce its persistent disk before snapshotting..."
gcloud workstations stop "${BUILD_WS}" \
    --project="${PROJECT}" --region="${REGION}" --cluster="${CLUSTER}" \
    --config="${CONFIG}" --quiet

echo "Looking up persistent disk for ${BUILD_WS}..."
SHORT_DISK_NAME=$(gcloud compute disks list \
    --project="${PROJECT}" \
    --filter="labels.workstation_id=${BUILD_WS}" \
    --format="value(name)" | head -n 1)

if [ -z "${SHORT_DISK_NAME}" ]; then
  echo "ERROR: could not find a persistent disk for workstation ${BUILD_WS}." >&2
  exit 1
fi
echo "Found persistent disk: ${SHORT_DISK_NAME}"

echo "Creating snapshot ${CANDIDATE_SNAP} from regional disk ${SHORT_DISK_NAME}..."
gcloud compute snapshots create "${CANDIDATE_SNAP}" \
    --source-disk="${SHORT_DISK_NAME}" \
    --source-disk-region="${REGION}" \
    --project="${PROJECT}"

printf '%s' "${CANDIDATE_SNAP}" > /tmp/candidate_snapshot_name
echo "Candidate snapshot ready: ${CANDIDATE_SNAP}"
