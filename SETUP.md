# Setup and flashing

How to set up a machine to build and flash Open Adaptive Switch firmware,
and how the flash flow works. For what the project is and how to use the
switches, start with [README.md](README.md).

---

## Hardware per unit

- MCU board: Seeed XIAO nRF52840 **Sense** (variant matters — the Sense
  has the LSM6DS3 IMU and PDM mic onboard; non-Sense doesn't).
  FQBN: `Seeeduino:nrf52:xiaonRF52840Sense`
  USB VID:PID `2886:8045`
- Button: tactile momentary, between **D0** and **GND**. Internal
  pull-up enabled in firmware (`INPUT_PULLUP`), so no external resistor.
- Battery: 3.7V 250mAh LiPo, JST connector. Charged at 50mA
  (`PIN_CHARGE_SEL` HIGH). Don't lower the charge current threshold; the
  code assumes cells of 300mAh or less.
- Status LED: onboard RGB. Common anode, so `LOW = ON`. All firmware
  uses `ledRedOn()` / `ledRedOff()` helpers so the inversion is hidden.
- Unit C only (optional): external bi-color charge LED on D9/D10. Wiring
  is documented in the settings block of `unit-c-firmware.ino`.

---

## Toolchain (any OS)

You need `arduino-cli`, the Seeed nRF52 board package, and
`adafruit-nrfutil` (the DFU upload tool).

```
arduino-cli config init --overwrite
arduino-cli config add board_manager.additional_urls \
  https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
arduino-cli core update-index
arduino-cli core install Seeeduino:nrf52
```

This installs the GCC ARM toolchain, CMSIS, and `Seeeduino:nrf52@1.1.13`
(which is Adafruit's Bluefruit nRF52 BSP under the hood). The Arduino IDE
is optional; it's handy for serial monitoring but `arduino-cli` does
everything needed here.

### Linux (tested on CachyOS / Arch)

Install arduino-cli from the official repo:

```
sudo pacman -S arduino-cli
```

Serial port permissions: `/dev/ttyACM*` on Arch is owned by `root:uucp`
(not `dialout` like Debian). Add yourself to the `uucp` group (and `lock`
for related flock state):

```
sudo usermod -aG uucp,lock $USER
```

Then log out and back in for the new group to take effect. Until then,
wrap upload commands with `sg uucp -c "..."`.

adafruit-nrfutil: the Seeed core ships only Windows and macOS binaries,
so Linux needs it supplied separately. Arch's PEP-668 blocks system pip;
use a self-contained venv with a `~/.local/bin` symlink:

```
python -m venv ~/.arduino15-tools/nrfutil-venv
~/.arduino15-tools/nrfutil-venv/bin/pip install --upgrade pip adafruit-nrfutil
mkdir -p ~/.local/bin
ln -sf ~/.arduino15-tools/nrfutil-venv/bin/adafruit-nrfutil ~/.local/bin/adafruit-nrfutil
```

Verify: `adafruit-nrfutil version` → `0.5.3.post16` (or newer).

### macOS

```
brew install arduino-cli
```

Then run the common toolchain steps above. The Seeed core bundles a macOS
`adafruit-nrfutil` binary, so no extra install is needed. Boards show up
as `/dev/cu.usbmodem*` and there is no serial group setup.

If compiling fails with `exec: "python": executable file not found`, the
Seeed build recipe calls plain `python`, which macOS doesn't provide.
Homebrew's unversioned shims fix it:

```
brew install python
export PATH="$(brew --prefix python)/libexec/bin:$PATH"
```

---

## Quick flash (interactive)

For routine updates, use the helper:

```
./flash.sh
```

It detects the connected XIAO, shows the last flash recorded in
`.flash_state` (a local, git-ignored file the script writes), lists every
`unit-*-firmware/` folder with its parsed BLE name and `FW_VERSION`,
prompts for a selection, then compiles and uploads.

Caveat: the firmware doesn't print over USB serial, so the script can't
query the board for its current firmware. `.flash_state` reflects only
what this host flashed. For ground truth, pair via BLE and check the
advertised name.

## Per-board first-flash workflow (manual)

1. Plug the XIAO in via USB-C and verify it shows up:
   ```
   arduino-cli board list
   ```
   You should see `Seeed XIAO nRF52840 Sense` on a serial port
   (`/dev/ttyACM1` on Linux, `/dev/cu.usbmodem*` on macOS). A sibling
   `Unknown` port may appear too — that's the bootloader CDC, ignore it.

2. Compile any unit folder (run from the project root):
   ```
   arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840Sense unit-a-firmware
   ```
   Expect ~120 KB used (14% flash).

3. Upload (substitute your port):
   ```
   arduino-cli upload -p /dev/ttyACM1 \
     --fqbn Seeeduino:nrf52:xiaonRF52840Sense unit-a-firmware
   ```
   On Arch, wrap with `sg uucp -c "..."` if you haven't re-logged in
   since being added to the `uucp` group.

4. If the board doesn't enter DFU automatically: double-tap the reset
   button (tiny button next to USB-C). The bootloader CDC port appears,
   `adafruit-nrfutil` finds it, re-flashes. Then single-press reset to
   boot into the new sketch.

5. Confirming the running sketch: brief accent-color LED flash at boot,
   then a slow pulse in the accent color means BLE advertising, not yet
   paired. (Unit C instead plays a red → amber → green boot sequence to
   teach its three press-duration zones.)

---

## Firmware inventory

Folder name = unit identity; version lives in code (`FW_VERSION` inside
each `.ino`, also broadcast over the BLE Device Information Service).

| Folder | BLE name | HID key(s) | LED accent | Version | Notes |
|---|---|---|---|---|---|
| `unit-a-firmware/` | AdaptSwitch-A | F13 | red | 2.0.1 | canonical "tap" switch; template for derived units; still has UVLO |
| `unit-b-firmware/` | AdaptSwitch-B | SPACE (tap), F14 (hold) | blue | 2.3.1 | media remote — YouTube/Music play-pause without overlay |
| `unit-c-firmware/` | AdaptSwitch-C | F15 / F16 / F17 (by press duration) | varies (R/A/G live zone feedback) | 2.4.1 | multi-mode timing button — one switch, three actions; optional external charge LED |

All three are being tested side by side; see "Known issues" below for
how their chassis versions differ and why.

### Generating more units

```
./make_unit.sh <letter> <HID_KEY_macro> [RED|GREEN|BLUE]
```

Example:

```
./make_unit.sh d HID_KEY_F14 GREEN
```

It copies unit-a, renames the identity lines, and compiles to verify. It
won't overwrite an existing folder.

Suggested key map for future units, chosen so every unit can pair to the
same iOS device without colliding (iOS treats each distinct key as a
distinct switch input):

| Unit | D | E | F | G | H | I | J |
|---|---|---|---|---|---|---|---|
| Key | F14* | F18 | F19 | F20 | F21 | F22 | F23 |

*F14 is also Unit B's long-press key — skip it if Unit B is in use.
F24 stays in reserve. Beyond ten units you'd need keypad keys
(`HID_KEY_KEYPAD_0..9`) or other non-F-key codes.

---

## iOS pairing

See [README.md](README.md) for the pairing walkthrough and per-app
recipes. Short version: always pair via Settings → Accessibility →
Switch Control → Switches → Add New Switch → External, not the main
Bluetooth menu.

If a board was previously paired under the same BLE name, Forget Device
on iOS before re-pairing. Reflashing resets the BLE bond, and iOS will
silently fail to reconnect to a bond it remembers.

---

## Known issues / open threads

- Which chassis wins: Unit A still runs the v2.0 chassis with UVLO
  (emergency shutdown below 3.10V). Units B and C dropped UVLO after
  false shutdowns — BLE TX bursts can briefly sag the rail below the
  threshold on a healthy cell — and indicate low battery by LED only.
  All three are in side-by-side testing; once a winner emerges the
  others should be ported to that chassis.
- Multi-position selector switch: the code template is present but
  commented out in all units; the hardware switch hasn't been wired yet.
- Apple Shortcuts launcher menu: a design direction (Unit C drives a
  "Run Shortcut" recipe with a Choose-from-Menu picker), not built yet.
- Inclusive Technology compatibility: unknown until there's a paid app
  to test against. Their apps often expect Space/Enter from a
  switch-interface keyboard rather than iOS Switch Control. Unit B's
  firmware is the starting point, but an Enter variant may be needed.
- v1.0 firmware history: the original v1.0 sketches predate this repo
  and are kept in the maintainer's offline archive, not in git.
