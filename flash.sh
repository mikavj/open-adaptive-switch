#!/usr/bin/env bash
# Open Adaptive Switch interactive flasher.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Open Adaptive Switch contributors
#
# Detects a connected XIAO nRF52840 (plain or Sense), shows the last flash
# on this host, lets you pick a firmware folder, compiles + uploads, then
# records what was flashed.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$PROJECT_DIR/.flash_state"
# Both XIAO nRF52840 variants work; the FQBN is picked to match whichever
# is detected (the compiled firmware is identical apart from USB naming).

cd "$PROJECT_DIR"

# The Seeed core's build recipe calls plain "python", which macOS doesn't
# provide. If it's missing, put a temporary python -> python3 shim on PATH
# so the build works without touching the system.
if ! command -v python >/dev/null 2>&1; then
  if command -v python3 >/dev/null 2>&1; then
    SHIM_DIR=$(mktemp -d)
    ln -s "$(command -v python3)" "$SHIM_DIR/python"
    export PATH="$SHIM_DIR:$PATH"
  else
    echo "ERROR: python3 not found; install it first (e.g. brew install python)." >&2
    exit 1
  fi
fi

echo "== Open Adaptive Switch flasher =="
echo

# --- 1. Linux only: group check (uucp/lock needed for /dev/ttyACM* on Arch) ---
if [ "$(uname)" = "Linux" ]; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx uucp; then
    echo "WARNING: \$USER is not in the 'uucp' group."
    echo "  Upload will likely fail with a permissions error."
    echo "  Fix: sudo usermod -aG uucp,lock \$USER  (then log out + back in)"
    echo "  One-off workaround: re-run this script as:  sg uucp -c \"./flash.sh\""
    echo
  fi
fi

# --- 2. Detect board (plain XIAO nRF52840 or the Sense variant) ---
BOARD_LINE=$(arduino-cli board list 2>/dev/null \
  | grep "Seeed XIAO nRF52840" | head -1)
PORT=$(echo "$BOARD_LINE" | awk '{print $1}')
if echo "$BOARD_LINE" | grep -q "Sense"; then
  FQBN="Seeeduino:nrf52:xiaonRF52840Sense"
  BOARD_NAME="Seeed XIAO nRF52840 Sense"
else
  FQBN="Seeeduino:nrf52:xiaonRF52840"
  BOARD_NAME="Seeed XIAO nRF52840"
fi

if [ -z "$PORT" ]; then
  echo "ERROR: no Seeed XIAO nRF52840 detected."
  echo
  echo "Visible serial ports:"
  ls /dev/ttyACM* /dev/cu.usbmodem* 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo
  echo "Tips:"
  echo "  - Plug the XIAO via USB-C"
  echo "  - If the sketch is sleeping, press reset once"
  echo "  - If still not detected, double-tap reset to force DFU mode"
  exit 1
fi
echo "Board detected: $BOARD_NAME on $PORT"
echo

# --- 3. Show last-flashed (from local state file) ---
if [ -f "$STATE_FILE" ]; then
  echo "Last flash recorded on this host:"
  sed 's/^/  /' "$STATE_FILE"
else
  echo "No prior flash recorded on this host (no $STATE_FILE)."
  echo "(The board itself may have firmware from a previous flash - the"
  echo " firmware doesn't report itself over USB serial. Pair via BLE to"
  echo " confirm its advertised name if you need ground truth.)"
fi
echo

# --- 4. List available firmware folders, parse identity from each .ino ---
# (plain while-read loop instead of mapfile: macOS ships bash 3.2)
UNITS=()
while IFS= read -r dir; do
  UNITS+=("$dir")
done < <(ls -d "$PROJECT_DIR"/*-firmware 2>/dev/null | sort)

if [ ${#UNITS[@]} -eq 0 ]; then
  echo "ERROR: no *-firmware folders found in $PROJECT_DIR"
  exit 1
fi

extract() {
  # extract() <ino_path> <regex> -> first quoted value, or "?"
  local file="$1" regex="$2"
  grep -E "$regex" "$file" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    || echo "?"
}

echo "Available firmware:"
for i in "${!UNITS[@]}"; do
  folder=$(basename "${UNITS[$i]}")
  ino="${UNITS[$i]}/$folder.ino"
  if [ -f "$ino" ]; then
    name=$(extract "$ino" '^\s*const char\*\s+DEFAULT_DEVICE_NAME')
    ver=$(extract  "$ino" '^\s*#define\s+FW_VERSION')
  else
    name="(no .ino)"
    ver="?"
  fi
  printf "  [%2d] %-22s  %-14s  v%s\n" $((i+1)) "$folder" "$name" "$ver"
done
echo

# --- 5. Prompt ---
read -r -p "Pick a firmware number to flash (or q to quit): " choice
case "$choice" in
  q|Q) echo "Cancelled."; exit 0 ;;
  ''|*[!0-9]*) echo "Invalid input."; exit 1 ;;
esac
idx=$((choice - 1))
if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#UNITS[@]} ]; then
  echo "Out of range."
  exit 1
fi

SELECTED="${UNITS[$idx]}"
SEL_NAME=$(basename "$SELECTED")
SEL_INO="$SELECTED/$SEL_NAME.ino"
SEL_DEVICE=$(extract "$SEL_INO" '^\s*const char\*\s+DEFAULT_DEVICE_NAME')
SEL_VER=$(extract    "$SEL_INO" '^\s*#define\s+FW_VERSION')

echo
echo "Selected: $SEL_NAME  ($SEL_DEVICE v$SEL_VER)"
read -r -p "Proceed with compile + upload to $PORT? [y/N] " confirm
[[ "$confirm" =~ ^[yY] ]] || { echo "Cancelled."; exit 0; }

# --- 6. Compile ---
echo
echo "--- Compiling ---"
if ! arduino-cli compile --fqbn "$FQBN" "$SELECTED"; then
  echo
  echo "ERROR: compile failed."
  exit 1
fi

# --- 7. Upload ---
echo
echo "--- Uploading to $PORT ---"
if ! arduino-cli upload -p "$PORT" --fqbn "$FQBN" "$SELECTED"; then
  echo
  echo "ERROR: upload failed."
  echo "If the board didn't enter DFU, double-tap reset and retry the script."
  exit 1
fi

# --- 8. Record state ---
{
  echo "folder=$SEL_NAME"
  echo "device_name=$SEL_DEVICE"
  echo "fw_version=$SEL_VER"
  echo "port=$PORT"
  echo "flashed_at=$(date +%Y-%m-%dT%H:%M:%S%z)"
} > "$STATE_FILE"

# --- 9. Confirm ---
echo
echo "============================================================"
echo " DONE."
echo "   Folder:  $SEL_NAME"
echo "   BLE:     $SEL_DEVICE (default; a saved rename overrides this)"
echo "   Version: $SEL_VER"
echo "   Port:    $PORT"
echo "   State:   $STATE_FILE"
echo "============================================================"
echo
echo "Next:"
echo "  - iOS: Settings > Accessibility > Switch Control > Switches >"
echo "         Add New Switch > External"
echo "  - If previously paired with the same BLE name, Forget Device"
echo "    on iOS before re-pairing (the BLE bond is reset on reflash)."
