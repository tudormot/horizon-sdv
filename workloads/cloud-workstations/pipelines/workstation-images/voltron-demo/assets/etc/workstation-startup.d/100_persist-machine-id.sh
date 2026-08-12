#!/bin/bash
#
# Startup script to persist machine-id across workstation instances.
#

SAVE_PATH=/home/.workstation/machine-id

if [ ! -f "$SAVE_PATH" ]; then
  MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || true)
  if [ -n "$MACHINE_ID" ]; then
    echo "saving machine id $MACHINE_ID to $SAVE_PATH"
    mkdir -p "$(dirname "$SAVE_PATH")"
    printf '%s\n' "$MACHINE_ID" > "$SAVE_PATH"
  fi
fi
