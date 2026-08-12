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

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARLA_DIR="${CARLA_DIR:-$HOME/Workspace/carla-installation}"
CARLA_CONFIG_COMMAND="$SCRIPT_DIR/external_utils/config.py"
MANUAL_CONTROL_CLIENT_PATH="$SCRIPT_DIR/external_utils/manual_control.py"
CARLA_MAIN_PORT="2000"

# --- Argument Parsing ---
MODE="manual-wasd"
RUN_BRIDGE=true
QUALITY="Epic"
OPENGL=false
ASYNC=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode=*)
            MODE="${1#*=}"
            shift
            ;;
        --doNotRunBridge)
            RUN_BRIDGE=false
            shift
            ;;
        --quality=*)
            QUALITY="${1#*=}"
            shift
            ;;
        --opengl)
            OPENGL=true
            shift
            ;;
        --async)
            ASYNC=true
            shift
            ;;
        -d|--carla-dir|--install-dir)
            CARLA_DIR="$2"
            shift 2
            ;;
        --carla-dir=*|--install-dir=*)
            CARLA_DIR="${1#*=}"
            shift
            ;;
        -d=*)
            CARLA_DIR="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo "  -d, --carla-dir=DIR   CARLA installation path (default: ~/Workspace/carla-installation)"
            echo "  --quality=QUALITY     CARLA render quality (default: Epic, or Low)"
            echo "  --opengl              Use OpenGL renderer instead of Vulkan"
            echo "  --async               Run simulation in asynchronous mode"
            echo "  --doNotRunBridge      Launch CARLA simulator only without SOME/IP bridge"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Expand tilde if present
CARLA_DIR="${CARLA_DIR/#\~/$HOME}"
CARLA_PATH="$CARLA_DIR/CarlaUE4.sh"

if [ ! -f "$CARLA_PATH" ]; then
    echo "Error: CARLA executable '$CARLA_PATH' not found."
    echo "Please run '$SCRIPT_DIR/setup_carla.sh -d $CARLA_DIR' first or specify a valid CARLA directory using -d <path>."
    exit 1
fi

PYTHON_CMD="python3.7"
if ! command -v "$PYTHON_CMD" &>/dev/null; then
    PYTHON_CMD="/opt/python3.7/bin/python3.7"
fi

# --- Cleanup Logic ---
cleanup() {
    echo -e "\nShutting down simulation stack..."

    # Sweep for CARLA simulator and client processes
    pkill -9 -f "CarlaUE4-Linux-Shipping" 2>/dev/null
    pkill -9 -f "carla_someip_client.py" 2>/dev/null
    pkill -9 -f "manual_control.py" 2>/dev/null

    echo "Cleanup complete."
    exit 0
}

# Register the cleanup function for signals and exit
trap cleanup SIGINT SIGTERM SIGHUP EXIT

# --- Launch Sequence ---
RENDERER_FLAG=""
if [ "$OPENGL" = true ]; then
    RENDERER_FLAG="-opengl"
fi

echo "Starting CARLA Simulator from $CARLA_PATH (Quality: $QUALITY, Renderer: ${RENDERER_FLAG:-Vulkan})..."
"$CARLA_PATH" $RENDERER_FLAG -quality-level=$QUALITY -carla-rpc-port=$CARLA_MAIN_PORT -RenderOffScreen -nosound &
CARLA_PID=$!

echo "Waiting for simulator to warm up..."
sleep 10

# Load Barcelona (Town15) HD Map
echo "Loading Barcelona (Town15) map..."
BARCELONA_REAL_MAP="Town15"
"$PYTHON_CMD" "$CARLA_CONFIG_COMMAND" -p $CARLA_MAIN_PORT -m $BARCELONA_REAL_MAP 2>/dev/null || \
"$PYTHON_CMD" "$CARLA_DIR/PythonAPI/util/config.py" -p $CARLA_MAIN_PORT -m $BARCELONA_REAL_MAP 2>/dev/null || true

# Launch Manual WASD Keyboard Control Client
echo "Starting Manual WASD Control (+ spawning vehicle)..."
SYNC_FLAG="--sync"
if [ "$ASYNC" = true ]; then
    SYNC_FLAG=""
fi
"$PYTHON_CMD" "$MANUAL_CONTROL_CLIENT_PATH" -p $CARLA_MAIN_PORT --autopilot --filter="vehicle.mini*" $SYNC_FLAG &
MANUAL_CONTROL_PID=$!

echo "Waiting for vehicle to spawn..."
sleep 5

# Launch SOME/IP Bridge
if [ "$RUN_BRIDGE" = true ]; then
    echo "Starting CARLA-SOME/IP Bridge..."
    "$PYTHON_CMD" "$SCRIPT_DIR/carla_someip_client.py" --mode="$MODE" &
    BRIDGE_PID=$!

    # Wait for the bridge client to finish
    wait $BRIDGE_PID
else
    echo "Skipping CARLA-SOME/IP Bridge as requested."
    wait $CARLA_PID
fi

cleanup
