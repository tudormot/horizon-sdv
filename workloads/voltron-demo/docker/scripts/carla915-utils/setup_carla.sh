#!/usr/bin/env bash
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

# Configuration
CARLA_VERSION="0.9.15"
CARLA_URL="https://tiny.carla.org/carla-${CARLA_VERSION//./-}-linux"
MAPS_URL="https://tiny.carla.org/additional-maps-${CARLA_VERSION//./-}-linux"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Workspace/carla-installation}"
ARCHIVE_NAME="CARLA_${CARLA_VERSION}.tar.gz"
MAPS_FILENAME="AdditionalMaps_${CARLA_VERSION}.tar.gz"
ASSUME_YES=false

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y | --yes)
      ASSUME_YES=true
      shift
      ;;
    --install-dir=*)
      INSTALL_DIR="${1#*=}"
      shift
      ;;
    -h | --help)
      echo "Usage: $(basename "$0") [-y|--yes] [--install-dir=<path>]"
      echo "  --install-dir=<path>  Target directory for CARLA binaries (default: ~/Workspace/carla-installation)"
      echo "  -y, --yes             Non-interactive mode (assume yes to prompts)"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

## 1. User Confirmation Prompt
echo -e "${YELLOW}--- CARLA & Extra Maps Installation Plan ---${NC}"
echo -e "CARLA Version   : ${CARLA_VERSION}"
echo -e "Target Directory: ${INSTALL_DIR}"
echo ""

if [ "$ASSUME_YES" != true ]; then
  read -p "Do you want to proceed with this installation? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Installation aborted by user."
    exit 0
  fi
fi

## 2. CARLA Binary Installation
if [ ! -d "$INSTALL_DIR" ]; then
  log "Downloading CARLA ${CARLA_VERSION} (16GB+)..."
  mkdir -p "$INSTALL_DIR"
  curl -L "$CARLA_URL" -o "$ARCHIVE_NAME"

  log "Extracting CARLA to ${INSTALL_DIR}..."
  tar -xzf "$ARCHIVE_NAME" -C "$INSTALL_DIR"
  rm -f "$ARCHIVE_NAME"
  log "CARLA ${CARLA_VERSION} binaries installed successfully to ${INSTALL_DIR}."
else
  warn "CARLA directory already exists at ${INSTALL_DIR}. Skipping base download."
fi

## 3. Additional Maps Installation (Town15, etc.)
if [ ! -d "$INSTALL_DIR/CarlaUE4/Content/Carla/Maps/Town15" ]; then
  mkdir -p "$INSTALL_DIR/Import"
  MAPS_ARCHIVE_PATH="$INSTALL_DIR/Import/$MAPS_FILENAME"

  if [ ! -f "$MAPS_ARCHIVE_PATH" ]; then
    log "Downloading additional maps (Town15)..."
    curl -L "$MAPS_URL" -o "$MAPS_ARCHIVE_PATH"
  fi

  log "Extracting additional maps to ${INSTALL_DIR}..."
  tar -xzf "$MAPS_ARCHIVE_PATH" -C "$INSTALL_DIR"
  rm -f "$MAPS_ARCHIVE_PATH"
  log "Additional maps installed successfully."
else
  log "Additional maps (Town15) already exist in ${INSTALL_DIR}. Skipping maps download."
fi

## 4. Install Real-World UAB Campus Aligned OpenDRIVE Map
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMPUS_MAP_SOURCE="$SCRIPT_DIR/maps/Town15_Campus.xodr"
TARGET_MAP_DIR="$INSTALL_DIR/CarlaUE4/Content/Carla/Maps/Town15"

if [ -f "$CAMPUS_MAP_SOURCE" ] && [ -d "$TARGET_MAP_DIR/OpenDrive" ]; then
  log "Applying Real-World UAB Campus OpenDRIVE map to Town15..."
  if [ ! -f "$TARGET_MAP_DIR/OpenDrive/Town15.xodr.orig" ]; then
    cp "$TARGET_MAP_DIR/OpenDrive/Town15.xodr" "$TARGET_MAP_DIR/OpenDrive/Town15.xodr.orig" 2>/dev/null || true
  fi
  cp "$CAMPUS_MAP_SOURCE" "$TARGET_MAP_DIR/OpenDrive/Town15.xodr"
  rm -f "$TARGET_MAP_DIR/TM/Town15.bin"
  log "Town15 Real-World Campus map successfully installed."
else
  log "Campus OpenDRIVE map not found on disk; skipping optional map patch."
fi

log "Success! CARLA and real-world campus aligned maps installation is complete."
echo -e "Next steps:"
echo -e "1. Set up SOME/IP bridge : ${GREEN}cd ../someip-bridge && ./setup_someip_bridge.sh${NC}"
echo -e "2. Run simulation         : ${GREEN}cd ../someip-bridge && ./run_carla_and_bridge.sh --mode=manual-wasd${NC}"
