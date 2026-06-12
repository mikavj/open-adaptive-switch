#!/usr/bin/env bash
# =========================================================================
# make_unit.sh — spin up a new switch firmware variant from unit-a.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Open Adaptive Switch contributors
#
# Usage:
#   ./make_unit.sh <letter> <hid_key> [accent_color]
#
#   letter        single character/word; goes in folder + BLE name
#                 (e.g. "d" → unit-d-firmware/ → "AdaptSwitch-D")
#   hid_key       full HID key macro name (e.g. HID_KEY_F18, HID_KEY_SPACE)
#   accent_color  optional: RED | GREEN | BLUE  (default RED)
#
# Example:
#   ./make_unit.sh d HID_KEY_F14 GREEN
#
# What it does:
#   1. Copies unit-a-firmware/ → unit-<letter>-firmware/
#   2. Renames the .ino file
#   3. Edits DEVICE_NAME, HID_KEY, UNIT_LED_COLOR_* — nothing else
#   4. Verifies it compiles (if arduino-cli available)
# =========================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <letter> <hid_key> [accent_color]" >&2
  echo "Example: $0 d HID_KEY_F14 GREEN" >&2
  exit 1
fi

LETTER=$(echo "$1" | tr '[:upper:]' '[:lower:]')
LETTER_U=$(echo "$1" | tr '[:lower:]' '[:upper:]')
HID_KEY="$2"
COLOR="${3:-RED}"
COLOR_U=$(echo "$COLOR" | tr '[:lower:]' '[:upper:]')

if [[ "$COLOR_U" != "RED" && "$COLOR_U" != "GREEN" && "$COLOR_U" != "BLUE" ]]; then
  echo "accent_color must be RED, GREEN, or BLUE" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$PROJECT_DIR/unit-a-firmware"
DEST_DIR="$PROJECT_DIR/unit-${LETTER}-firmware"
DEST_INO="$DEST_DIR/unit-${LETTER}-firmware.ino"

if [[ -e "$DEST_DIR" ]]; then
  echo "Refusing to overwrite existing $DEST_DIR" >&2
  exit 1
fi

cp -r "$SRC_DIR" "$DEST_DIR"
mv "$DEST_DIR/unit-a-firmware.ino" "$DEST_INO"

# Identity substitutions (only touch the three settings lines).
# sed -i.bak + rm keeps this portable across GNU sed (Linux) and BSD
# sed (macOS), which disagree about a bare -i.
sed -i.bak \
  -e "s/^const char\*   DEVICE_NAME = \"AdaptSwitch-A\";/const char*   DEVICE_NAME = \"AdaptSwitch-${LETTER_U}\";/" \
  -e "s/^const uint8_t HID_KEY     = HID_KEY_F13;/const uint8_t HID_KEY     = ${HID_KEY};/" \
  -e "s/^#define UNIT_LED_COLOR_RED.*$/#define UNIT_LED_COLOR_${COLOR_U}/" \
  "$DEST_INO"

# Header banner swap — identify the new unit.
sed -i.bak \
  -e "1,3 s|UNIT A  (canonical \"tap\" switch, F13)|UNIT ${LETTER_U} (generated from unit-a)|" \
  "$DEST_INO"

rm -f "$DEST_INO.bak"

echo "Created $DEST_DIR"
echo "  DEVICE_NAME = AdaptSwitch-${LETTER_U}"
echo "  HID_KEY     = ${HID_KEY}"
echo "  LED accent  = ${COLOR_U}"

if command -v arduino-cli >/dev/null 2>&1; then
  echo "Compiling..."
  arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840Sense "$DEST_DIR" \
    | tail -3
fi
