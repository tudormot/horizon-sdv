# shellcheck shell=bash
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
#
# Helper tools for building AAOS targets and launching CVD instances.
# Intended to be sourced from interactive bash shells or ~/.bashrc.

ANDROID_BUILD_TOP="${ANDROID_BUILD_TOP:-${HOME}/Workspace/aaos-26q2}"
SDV_MEDIA_LUNCH_TARGET="${SDV_MEDIA_LUNCH_TARGET:-sdv_media_har_cf-trunk_staging-userdebug}"
IVI_LUNCH_TARGET="${IVI_LUNCH_TARGET:-cluster_cf_x86_64_auto_ds-trunk_staging-userdebug}"

if ! declare -f _log > /dev/null 2>&1; then
  _log() {
    echo "[AAOS-BUILD] $*"
  }
fi

_ensure_envsetup() {
  if ! declare -f lunch > /dev/null 2>&1; then
    _log "Setting up build environment..."
    # shellcheck source=/dev/null
    source build/envsetup.sh
  fi
}

build_target() {
  local build_target="$1"
  local orig_dir
  orig_dir="$(pwd)"
  cd "$ANDROID_BUILD_TOP" || return 1

  _ensure_envsetup

  _log "Executing lunch for target: ${build_target}..."
  lunch "${build_target}"

  # Build Target
  _log "Starting build compilation (m -j$(nproc))."
  m -j"$(nproc)"
  m -j"$(nproc)" ds_toolkit # build also ds_toolkit unconditionally

  _log "Build completed successfully for ${build_target}!"
  cd "$orig_dir" || return 1
}

build() {
  build_target "$SDV_MEDIA_LUNCH_TARGET"
  build_target "$IVI_LUNCH_TARGET"
}

launch_2vm() {
  local orig_dir
  orig_dir="$(pwd)"
  cd "$ANDROID_BUILD_TOP" || return 1
  _ensure_envsetup
  lunch "$SDV_MEDIA_LUNCH_TARGET" # any of the 2 targets would work
  ds_toolkit launch
  cd "$orig_dir" || return 1
}

clear_2vm() {
  local orig_dir
  orig_dir="$(pwd)"
  cd "$ANDROID_BUILD_TOP" || return 1
  _ensure_envsetup
  lunch "$SDV_MEDIA_LUNCH_TARGET" # any of the 2 targets would work
  cvd clear
  cd "$orig_dir" || return 1
}
