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
CARLA_URL="https://tiny.carla.org/carla-0-9-15-linux"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Workspace/carla-installation}"
ARCHIVE_NAME="CARLA_${CARLA_VERSION}.tar.gz"
ASSUME_YES=false
WITH_EXTRA_MAPS=false

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -m|--with-extra-maps)
            WITH_EXTRA_MAPS=true
            shift
            ;;
        -d|--install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --install-dir=*)
            INSTALL_DIR="${1#*=}"
            shift
            ;;
        -d=*)
            INSTALL_DIR="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo "  -d, --install-dir <path>  Target directory for CARLA binaries (default: ~/Workspace/carla-installation)"
            echo "  -m, --with-extra-maps     Automatically download and install extra maps (Town11 - Town15)"
            echo "  -y, --yes                 Non-interactive mode (assume yes to prompts)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Expand tilde if present
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

## 1. User Confirmation Prompt
echo -e "${YELLOW}--- CARLA Setup Plan ---${NC}"
echo -e "CARLA Binaries Target: ${INSTALL_DIR}"
echo -e "Python 3.7 Runtime   : $(command -v python3.7 2>/dev/null || echo '/usr/local/bin/python3.7')"
echo -e "Install Extra Maps   : ${WITH_EXTRA_MAPS}"
echo ""

if [ "$ASSUME_YES" != true ]; then
    read -p "Do you want to proceed with downloading and extracting CARLA ${CARLA_VERSION}? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Installation aborted by user."
        exit 0
    fi
fi

## 2. CARLA Binary Installation
if [ ! -f "$INSTALL_DIR/CarlaUE4.sh" ]; then
    log "Preparing target directory: ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"
    
    log "Downloading CARLA ${CARLA_VERSION} (16GB+)..."
    curl -L "$CARLA_URL" -o "$INSTALL_DIR/$ARCHIVE_NAME"

    log "Extracting to ${INSTALL_DIR}..."
    tar -xzf "$INSTALL_DIR/$ARCHIVE_NAME" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/$ARCHIVE_NAME"
    log "CARLA ${CARLA_VERSION} extracted successfully."
else
    warn "CARLA binaries already exist at ${INSTALL_DIR}/CarlaUE4.sh. Skipping download."
fi

## 3. Extra Maps Installation
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$WITH_EXTRA_MAPS" = true ]; then
    log "Installing additional maps..."
    bash "$SCRIPT_DIR/install_extra_maps.sh" -d "$INSTALL_DIR"
elif [ "$ASSUME_YES" != true ]; then
    read -p "Do you want to install extra maps (Barcelona Town15, etc.) now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        bash "$SCRIPT_DIR/install_extra_maps.sh" -d "$INSTALL_DIR"
    fi
fi

log "Success! CARLA environment is ready."
echo -e "To run the simulation:"
echo -e "  ${GREEN}$SCRIPT_DIR/run_carla_and_bridge.sh --mode=manual-wasd -d ${INSTALL_DIR}${NC}"
