#!/usr/bin/env bash
# Build the release artifacts: an over-the-air DFU package (.zip) and a
# drag-and-drop bootloader file (.uf2), plus a .hex for wired tools.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Open Adaptive Switch contributors
#
# The build targets the plain XIAO nRF52840 by default; the same binary
# runs on the Sense variant (identical MCU, SoftDevice, and pin map).
# Override with: FQBN=Seeeduino:nrf52:xiaonRF52840Sense ./make_release.sh
#
# The Seeed core's own UF2 step is broken for this board (its wrapper
# script only converts for one Tracker board), so the UF2 is produced
# here by calling the core's uf2conv.py directly. Family 0xADA52840 is
# nRF52840 + Adafruit bootloader.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH="$PROJECT_DIR/switch-firmware"
FQBN="${FQBN:-Seeeduino:nrf52:xiaonRF52840}"

# The Seeed core's build recipe calls plain "python", which macOS doesn't
# provide. If it's missing, put a temporary python -> python3 shim on PATH.
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
BUILD="$SKETCH/build/$(echo "$FQBN" | tr ':' '.')"

VERSION=$(grep -E '^#define\s+FW_VERSION' "$SKETCH/switch-firmware.ino" \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$VERSION" ]; then
  echo "ERROR: could not read FW_VERSION from the sketch." >&2
  exit 1
fi

# Locate the installed Seeed core (for uf2conv.py). Linux and macOS paths.
CORE=""
for d in "$HOME/Library/Arduino15" "$HOME/.arduino15"; do
  hit=$(ls -d "$d/packages/Seeeduino/hardware/nrf52/"*/ 2>/dev/null | sort | tail -1)
  if [ -n "$hit" ]; then CORE="$hit"; break; fi
done
UF2CONV="$CORE/tools/uf2conv/uf2conv.py"

echo "Building Open Adaptive Switch v$VERSION ($FQBN)..."
arduino-cli compile --fqbn "$FQBN" --export-binaries "$SKETCH"

OTA_ZIP="$BUILD/switch-firmware.ino.zip"
HEX="$BUILD/switch-firmware.ino.hex"
if [ ! -f "$OTA_ZIP" ] || [ ! -f "$HEX" ]; then
  echo "ERROR: build did not produce $OTA_ZIP / $HEX" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/release"
OUT_ZIP="$PROJECT_DIR/release/open-adaptive-switch-v$VERSION-ota.zip"
OUT_UF2="$PROJECT_DIR/release/open-adaptive-switch-v$VERSION.uf2"
OUT_HEX="$PROJECT_DIR/release/open-adaptive-switch-v$VERSION.hex"
cp "$OTA_ZIP" "$OUT_ZIP"
cp "$HEX" "$OUT_HEX"

if [ -f "$UF2CONV" ]; then
  python3 "$UF2CONV" -f 0xADA52840 -c -o "$OUT_UF2" "$HEX" >/dev/null
  echo "UF2 written."
else
  echo "WARNING: uf2conv.py not found in the Seeed core; skipping the .uf2." >&2
  echo "  (Expected under \$HOME/Library/Arduino15 or \$HOME/.arduino15.)" >&2
fi

echo
echo "Release artifacts in release/:"
echo "  open-adaptive-switch-v$VERSION-ota.zip  wireless update via the DFU app"
echo "  open-adaptive-switch-v$VERSION.uf2      drag-and-drop update from any computer"
echo "  open-adaptive-switch-v$VERSION.hex      wired flashing tools (optional)"
echo
echo "Publish: create GitHub release v$VERSION and attach the .zip and .uf2."
echo "The config page and app find them through the GitHub releases API."
