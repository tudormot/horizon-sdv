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
VENV_DIR="${SCRIPT_DIR}/.venv"
CARLA_DIR="${CARLA_DIR:-$HOME/Workspace/carla-installation}"
MANUAL_CONTROL_CLIENT_PATH="${SCRIPT_DIR}/external_utils/manual_control.py"
CAMERA_CLIENT_PATH="${SCRIPT_DIR}/external_utils/camera_display.py"

# --- Argument Parsing ---
# Accepted modes (--mode=MODE):
#   auto:         (Default) Bridge spawns a vehicle and enables CARLA autopilot.
#   manual-wasd:  Launches CARLA's manual_control.py for keyboard control.
#   manual-wheel: Bridge waits for an external "hero" vehicle (e.g., from a steering wheel client).
#   --doNotRunBridge: If set, the bridge script is not started.
#   --quality=QUALITY: Set CARLA quality level (Low, Epic).
#   --spawnCameraClient: Launches the camera display client locally.
#   -d, --carla-dir=DIR: Custom CARLA installation directory (default: ~/Workspace/carla-installation)
MODE=""
RUN_BRIDGE=true
SPAWN_CAMERA=false
QUALITY="Epic"
OPENGL=false
ASYNC=false
REMOTE_BRIDGE=""
REMOTE_PATH="$HOME/Workspace/sdv-demos/someip-bridge"

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
    --spawnCameraClient)
      SPAWN_CAMERA=true
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
    --remote-bridge=*)
      REMOTE_BRIDGE="${1#*=}"
      shift
      ;;
    --remote-path=*)
      REMOTE_PATH="${1#*=}"
      shift
      ;;
    -d | --carla-dir | --install-dir)
      CARLA_DIR="$2"
      shift 2
      ;;
    --carla-dir=* | --install-dir=*)
      CARLA_DIR="${1#*=}"
      shift
      ;;
    -d=*)
      CARLA_DIR="${1#*=}"
      shift
      ;;
    -h | --help)
      echo "Usage: $(basename "$0") [options]"
      echo "  --mode=MODE           Simulation mode: auto, manual-wasd, manual-wheel"
      echo "  -d, --carla-dir=DIR   CARLA installation path (default: ~/Workspace/carla-installation)"
      echo "  --quality=QUALITY     CARLA render quality (default: Epic, or Low)"
      echo "  --opengl              Use OpenGL renderer instead of Vulkan"
      echo "  --async               Run simulation in asynchronous mode"
      echo "  --spawnCameraClient   Launch external camera display window"
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
CARLA_MAIN_PORT="2000"

if [ ! -f "$CARLA_PATH" ]; then
  echo "Error: CARLA executable '$CARLA_PATH' not found."
  echo "Please specify a valid CARLA directory using -d <path> or --carla-dir=<path>."
  exit 1
fi

# --- Python Runtime & Virtual Environment Management ---
PYTHON_EXEC="python3"
if [ -d "$VENV_DIR" ]; then
  # shellcheck source=/dev/null
  source "$VENV_DIR/bin/activate"
elif command -v python3.7 > /dev/null 2>&1; then
  PYTHON_EXEC="$(command -v python3.7)"
elif [ -x "/opt/python3.7/bin/python3.7" ]; then
  PYTHON_EXEC="/opt/python3.7/bin/python3.7"
elif [ -x "/usr/local/bin/python3.7" ]; then
  PYTHON_EXEC="/usr/local/bin/python3.7"
else
  echo "Error: Neither virtual environment '$VENV_DIR' nor Python 3.7 was found."
  echo "Are you not using containerised demo? Run ./setup_someip_bridge.sh --with-pyenv to provision system."
  exit 1
fi

# --- Cleanup Logic ---
cleanup() {
  echo -e "\nShutting down simulation stack..."

  # Aggressive sweep for components (handles orphaning)
  pkill -9 -f "CarlaUE4-Linux-Shipping" 2> /dev/null

  # If we used a remote bridge, make sure the remote processes are cleaned up
  if [ -n "$REMOTE_BRIDGE" ]; then
    echo "Cleaning up remote processes on $REMOTE_BRIDGE..."
    ssh "$REMOTE_BRIDGE" "pkill -f carla_someip_client.py" 2> /dev/null || true
  fi

  pkill -9 -f "carla_someip_client.py" 2> /dev/null
  pkill -9 -f "manual_control.py" 2> /dev/null
  pkill -9 -f "camera_display.py" 2> /dev/null
  pkill -9 -f "steering_control.py" 2> /dev/null
  pkill -9 -f "spawn_roadblockers.py" 2> /dev/null

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
"$CARLA_PATH" $RENDERER_FLAG -quality-level="$QUALITY" -carla-rpc-port="$CARLA_MAIN_PORT" -RenderOffScreen -nosound &
CARLA_PID=$!

echo "Waiting for simulator to warm up..."
sleep 10

# Note: Extra maps (Town15) are installed by setup_carla.sh
echo "Loading up Barcelona..."
BARCELONA_REAL_MAP="Town15"
"$PYTHON_EXEC" "$CARLA_DIR/PythonAPI/util/config.py" -p "$CARLA_MAIN_PORT" -m "$BARCELONA_REAL_MAP" 2> /dev/null || true

# Wait for CARLA server to finish map transition and stabilize before client connections
echo "Waiting for map initialization to settle..."
sleep 6

# Deploy static roadblockers once (if present)
if [ -f "${SCRIPT_DIR}/external_utils/spawn_roadblockers.py" ]; then
  echo "Deploying real-world strict campus roadblockers..."
  "$PYTHON_EXEC" "${SCRIPT_DIR}/external_utils/spawn_roadblockers.py" -p "$CARLA_MAIN_PORT" || true
else
  echo "Roadblocker script not found on disk; skipping roadblocker deployment."
fi

if [ "$SPAWN_CAMERA" = true ]; then
  echo "Starting Camera Display Client..."
  "$PYTHON_EXEC" "$CAMERA_CLIENT_PATH" --host 127.0.0.1 --res 1280x720 &
  # shellcheck disable=SC2034
  CAMERA_CLIENT_PID=$!
fi

if [ "$MODE" == "manual-wasd" ]; then
  echo "Starting Manual Control (+ spawning car)..."
  SYNC_FLAG="--sync"
  if [ "$ASYNC" = true ]; then
    SYNC_FLAG=""
  fi
  "$PYTHON_EXEC" "$MANUAL_CONTROL_CLIENT_PATH" -p "$CARLA_MAIN_PORT" --autopilot --filter="vehicle.mini*" $SYNC_FLAG &
  # shellcheck disable=SC2034
  MANUAL_CONTROL_PID=$!

  echo "Waiting for car to spawn..."
  sleep 5
fi

if [ "$RUN_BRIDGE" = true ]; then
  if [ -n "$REMOTE_BRIDGE" ]; then
    # --- Remote Bridge Setup ---
    echo "Starting REMOTE CARLA-SOME/IP Bridge on $REMOTE_BRIDGE..."
    # Forward CARLA ports (2000, 2001, 2002) from A to B and run the bridge on B
    ssh -tt -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 \
      -R 2000:localhost:2000 -R 2001:localhost:2001 -R 2002:localhost:2002 "$REMOTE_BRIDGE" \
      "cd $REMOTE_PATH && ( [ -x .venv/bin/python ] && .venv/bin/python carla_someip_client.py --mode='$MODE' || ( command -v python3.7 > /dev/null 2>&1 && python3.7 carla_someip_client.py --mode='$MODE' || python3 carla_someip_client.py --mode='$MODE' ) )" &
    BRIDGE_PID=$!
  else
    # --- Local Bridge Setup ---
    echo "Starting local CARLA-SOME/IP Bridge with mode: $MODE"
    "$PYTHON_EXEC" "${SCRIPT_DIR}/carla_someip_client.py" --mode="$MODE" &
    BRIDGE_PID=$!
  fi

  # Wait for the bridge client to finish
  wait "$BRIDGE_PID"
else
  echo "Skipping CARLA-SOME/IP Bridge and SOME/IP setup as requested."
  # Wait for background processes (CARLA)
  wait "$CARLA_PID"
fi

# If the python script exits on its own, trigger cleanup
cleanup
