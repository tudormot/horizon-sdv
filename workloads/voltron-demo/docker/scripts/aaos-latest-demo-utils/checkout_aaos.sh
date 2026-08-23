#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eo pipefail

# ==============================================================================
# Open-Source AAOS Checkout & Build Script
# Default Target: sdv_media_cf-trunk_staging-userdebug (Open-Source SDV Media image)
# Branch: android-latest-release
# ==============================================================================

OUTPUT_DIR="${HOME}/Workspace/aaos-26q2"
REPO_URL="https://android.googlesource.com/platform/manifest"
BRANCH="android-latest-release" # as of 2026-08-04, defaults to 27Q2
THREAD_COUNT=20                 # high values might lead to throttling when during repo sync

_log() {
  echo "[AAOS-BUILD] $*"
}

_print_usage() {
  cat << USAGE
Usage: $(basename "$0") [OPTIONS]
Options:
  -o, --output-dir   Directory for AOSP checkout (default: ${OUTPUT_DIR})
  -u, --repo-url     Manifest repo URL (default: ${REPO_URL})
  -b, --branch       Manifest branch/tag (default: ${BRANCH})
  -j, --threads      Sync thread count (default: ${THREAD_COUNT})
  -h, --help         Show this help message
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o | --output-dir)
      [[ $# -gt 1 ]] || {
        echo "Error: $1 requires an argument"
        exit 1
      }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -u | --repo-url)
      [[ $# -gt 1 ]] || {
        echo "Error: $1 requires an argument"
        exit 1
      }
      REPO_URL="$2"
      shift 2
      ;;
    -b | --branch)
      [[ $# -gt 1 ]] || {
        echo "Error: $1 requires an argument"
        exit 1
      }
      BRANCH="$2"
      shift 2
      ;;
    -j | --threads)
      [[ $# -gt 1 ]] || {
        echo "Error: $1 requires an argument"
        exit 1
      }
      THREAD_COUNT="$2"
      shift 2
      ;;
    -h | --help)
      _print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      _print_usage
      exit 1
      ;;
  esac
done

_log "======================================================"
_log "Starting Open-Source AAOS Sync & Build"
_log "Directory:    ${OUTPUT_DIR}"
_log "Manifest URL: ${REPO_URL}"
_log "Branch:       ${BRANCH}"
_log "Sync Threads: ${THREAD_COUNT}"
_log "======================================================"

mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

# 1. Ensure Git config is present locally or in environment
if [[ -z "$(git config user.email 2> /dev/null || :)" ]]; then
  if [[ -d .git ]] || git rev-parse --git-dir > /dev/null 2>&1; then
    git config --local user.email "user@workstation.local"
    git config --local user.name "SDV Developer"
  else
    export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-SDV Developer}"
    export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-user@workstation.local}"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-SDV Developer}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-user@workstation.local}"
  fi
fi

# 2. Repo Init with branch android-latest-release
_log "Initializing repo with branch: ${BRANCH}..."
repo init -u "${REPO_URL}" -b "${BRANCH}" -c --depth=1 <<< "y"

# 3. Resilient Repo Sync with THREAD_COUNT (14 connections, --force-sync -d)
_log "Syncing repositories with ${THREAD_COUNT} connections and retries..."
repo sync -c -j"${THREAD_COUNT}" --force-sync -d --no-tags --retry-fetches=5
