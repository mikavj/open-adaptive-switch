#!/usr/bin/env bash
# Build an over-the-air update package for a GitHub release.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Open Adaptive Switch contributors
#
# Compiles switch-firmware with exported binaries. The Seeed core's build
# recipe already produces the Nordic DFU .zip (adafruit-nrfutil dfu genpkg
# --dev-type 0x0052 --sd-req 0x0123); this script just puts a versioned
# copy in release/ ready to attach to a GitHub release.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH="$PROJECT_DIR/switch-firmware"
FQBN="Seeeduino:nrf52:xiaonRF52840Sense"
BUILD="$SKETCH/build/Seeeduino.nrf52.xiaonRF52840Sense"

VERSION=$(grep -E '^#define\s+FW_VERSION' "$SKETCH/switch-firmware.ino" \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$VERSION" ]; then
  echo "ERROR: could not read FW_VERSION from the sketch." >&2
  exit 1
fi

echo "Building Open Adaptive Switch v$VERSION..."
arduino-cli compile --fqbn "$FQBN" --export-binaries "$SKETCH"

OTA_ZIP="$BUILD/switch-firmware.ino.zip"
if [ ! -f "$OTA_ZIP" ]; then
  echo "ERROR: build did not produce $OTA_ZIP" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/release"
OUT="$PROJECT_DIR/release/open-adaptive-switch-v$VERSION-ota.zip"
cp "$OTA_ZIP" "$OUT"
cp "$BUILD/switch-firmware.ino.hex" \
   "$PROJECT_DIR/release/open-adaptive-switch-v$VERSION.hex"

echo
echo "Release artifacts:"
echo "  $OUT                (attach to the GitHub release; used by the DFU app)"
echo "  release/open-adaptive-switch-v$VERSION.hex  (for wired flashing, optional)"
echo
echo "Publish: create release v$VERSION on GitHub and attach the .zip."
echo "The config page finds it through the GitHub releases API."
