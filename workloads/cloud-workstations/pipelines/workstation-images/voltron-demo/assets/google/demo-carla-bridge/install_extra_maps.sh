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

# --- CONFIGURATION ---
INSTALL_DIR="${INSTALL_DIR:-$HOME/Workspace/carla-installation}"
CARLA_VERSION="0.9.15"
MAPS_FILENAME="AdditionalMaps_${CARLA_VERSION}.tar.gz"
MAPS_URL="https://tiny.carla.org/additional-maps-0-9-15-linux"
# ---------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
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
            echo "Usage: $(basename "$0") [-d|--install-dir <path>]"
            echo "  -d, --install-dir <path>  Path to CARLA installation (default: ~/Workspace/carla-installation)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Expand tilde if present
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

echo "--- Starting CARLA Map Installation ---"
echo "Target CARLA Directory: $INSTALL_DIR"

# 1. Verify the CARLA directory exists
if [ ! -d "$INSTALL_DIR" ]; then
    echo "Error: Directory '$INSTALL_DIR' not found."
    echo "Please ensure CARLA is installed or specify the path with -d <path>."
    exit 1
fi

# 2. Check for the CARLA import utility
if [ ! -f "$INSTALL_DIR/ImportAssets.sh" ]; then
    echo "Error: ImportAssets.sh not found inside $INSTALL_DIR!"
    exit 1
fi

mkdir -p "$INSTALL_DIR/Import"

# 3. Download the archive directly into the installation folder
if [ ! -f "$INSTALL_DIR/Import/$MAPS_FILENAME" ]; then
    echo "--- Downloading maps to $INSTALL_DIR/Import ---"
    wget --trust-server-names -P "$INSTALL_DIR/Import" --show-progress "$MAPS_URL"
else
    echo "--- Archive already exists in $INSTALL_DIR/Import, skipping download ---"
fi

# 4. Run the import from within the CARLA directory
echo "--- Running CARLA Import Script ---"
(
    cd "$INSTALL_DIR" || exit
    tar -xvf "Import/$MAPS_FILENAME"
)

# 5. Success Check & Cleanup
if [ $? -eq 0 ]; then
    echo "-------------------------------------------------------"
    echo "SUCCESS: Additional maps imported to $INSTALL_DIR."
    echo "-------------------------------------------------------"
    echo "Cleaning up archive..."
    rm -f "$INSTALL_DIR/Import/$MAPS_FILENAME"
else
    echo "Error: The import process failed."
    exit 1
fi

echo "Done."
