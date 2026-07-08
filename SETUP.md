# Setup and flashing

How to set up a machine to build and flash Open Adaptive Switch firmware,
and how releases are made. For what the project is and how to use the
switches, start with [README.md](README.md). Day-to-day configuration
(key bindings, sleep, name) does not need any of this - that happens on
the config page over Bluetooth.

---

## Hardware per unit

- MCU board: Seeed XIAO nRF52840, the **plain** variant (about $10; the
  Sense variant also works and only adds an IMU and microphone the
  switch never uses - the battery circuit and pin map are identical,
  verified against the schematic and the core's variant files).
  FQBN: `Seeeduino:nrf52:xiaonRF52840` (plain) or
  `Seeeduino:nrf52:xiaonRF52840Sense` (Sense).
  A binary built for either variant runs on both; releases are built
  with the plain FQBN. `flash.sh` picks the FQBN to match the board it
  detects.
- Button: tactile momentary, between **D0** and **GND**. Internal
  pull-up enabled in firmware (`INPUT_PULLUP`), so no external resistor.
- Battery: 3.7V 250mAh LiPo, JST connector. Charged at 50mA by the
  onboard BQ25101 (its 4.20V termination is fixed in hardware). The
  firmware leaves the charge-current pin high-Z for 50mA; a
  `CHARGE_AT_100MA` define exists for cells of 300mAh or more.
- Status LED: onboard RGB. Common anode, so `LOW = ON`. All firmware
  uses `ledRedOn()` / `ledRedOff()` helpers so the inversion is hidden.
- Optional: external bi-color charge LED on D9/D10. Wiring is documented
  in the settings block of `switch-firmware.ino`.

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

Verify: `adafruit-nrfutil version` reports `0.5.3.post16` or newer.

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

## Firmware layout

One firmware for all units since v3:

| Folder | Version | Notes |
|---|---|---|
| `switch-firmware/` | 3.0.0 | HID switch + BLE config service + battery reporting + OTA DFU |

The old per-unit builds (A = single key on F13, B = Space with hold
action, C = three press-duration zones) became runtime modes; their
sources are preserved outside the repo in the maintainer's archive, and
in git history before v3. Default identity is `AdaptSwitch` sending F13;
everything user-visible is set over BLE afterward
([docs/ble-protocol.md](docs/ble-protocol.md)).

---

## Wired flash

For the first flash of a new board, or recovery:

```
./flash.sh
```

It detects the connected XIAO, shows the last flash recorded in
`.flash_state` (a local, git-ignored file the script writes), compiles,
uploads, and records the result.

Manual steps, if you prefer them (run from the project root; substitute
your port):

```
arduino-cli board list
arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840Sense switch-firmware
arduino-cli upload -p /dev/ttyACM1 \
  --fqbn Seeeduino:nrf52:xiaonRF52840Sense switch-firmware
```

If the board doesn't enter DFU automatically, double-tap the reset button
(tiny button next to USB-C) and retry the upload. After flashing, a brief
accent flash then 1 to 3 blinks (battery level) confirms the sketch is
running; a slow accent pulse means it is advertising.

---

## Over-the-air updates and releases

The stock bootloader supports Nordic legacy BLE DFU, so units in the
field update from a phone; nobody needs this toolchain except to produce
the release package.

```
./make_release.sh
```

builds `switch-firmware` and produces three artifacts in `release/`:

- `...-ota.zip` - the wireless update package (the core runs
  `adafruit-nrfutil dfu genpkg --dev-type 0x0052 --sd-req 0x0123` on
  every compile; the script copies the result).
- `....uf2` - a drag-and-drop file for the bootloader's USB drive. The
  core's own UF2 step is broken for this board (its wrapper script only
  converts for one Tracker board), so the script calls the core's
  `uf2conv.py` directly with family `0xADA52840`. The UF2 contains only
  the application region (0x27000 up), so saved settings survive.
- `....hex` - for wired flashing tools, optional.

Publishing an update:

1. Bump `FW_VERSION` in the sketch, commit, push.
2. Run `./make_release.sh`.
3. Create a GitHub release with tag `vX.Y.Z` (matching FW_VERSION) and
   attach the .zip and .uf2. The config page and the iOS app read the
   latest release through the GitHub API, compare against the version
   the switch reports, and link the download.

Installing an update from a phone is described on the config page and in
[docs/ble-protocol.md](docs/ble-protocol.md). In short: put the switch in
update mode from the page (or let the DFU app trigger it), then send the
.zip with Nordic's nRF Device Firmware Update app. On iOS, keep the
packets-per-notification setting at 8 or below and enable scanning for
legacy DFU devices.

Settings survive updates: they live in a LittleFS filesystem in internal
flash, outside the application area.

---

## The config page

`docs/index.html` is a static page; GitHub Pages serves it from the
`docs/` folder of the main branch at
https://mikavj.github.io/open-adaptive-switch/. It needs no build step -
edit, commit, push. Web Bluetooth requires HTTPS, which Pages provides.

To work on it locally: `python3 -m http.server` in `docs/` and open
`http://localhost:8000` in Chrome (localhost counts as a secure context).
The BLE protocol it speaks is in [docs/ble-protocol.md](docs/ble-protocol.md).

QR codes pointing at the page (for printing on enclosures) are in
`docs/qr/`; regenerate them if the page URL ever changes.

---

## iOS pairing

See [README.md](README.md) for the pairing walkthrough and per-app
recipes. Short version: always pair via Settings, Accessibility, Switch
Control, Switches, Add New Switch, External - not the main Bluetooth
menu.

If a board was previously paired under the same BLE name, Forget Device
on iOS before re-pairing. Reflashing resets the BLE bond, and iOS will
silently fail to reconnect to a bond it remembers.

---

## Known issues / open threads

- The v3 consolidated firmware needs field testing against the v2 units
  it replaced (the LED-only battery warning approach came from units B
  and C; v2.0's low-voltage shutdown false-triggered on BLE TX sag and
  was dropped).
- Pre-v3 firmware addressed the battery pins by raw nRF port number
  (46/31/13), which this core's pin map does not accept: the divider
  enable write was a no-op and analogRead landed on the NFC pin, so
  every battery reading was 0V. Anything battery-related observed on
  v1/v2 units (readout blink counts, low-battery warnings, v2.0's
  shutdown behavior) was based on that phantom 0V and should be
  disregarded. v3 uses the variant's named pins (VBAT_ENABLE, PIN_VBAT,
  PIN_CHARGING_CURRENT).
- Config page tested paths: still to verify on Bluefy (iOS) and Android
  Chrome; protocol testing has been desktop Chrome so far.
- Multi-position selector switch: the v2 firmware carried a placeholder
  for a hardware mode selector; v3 dropped it since modes are now set
  over BLE. If a use case surfaces for a hardware selector, it can come
  back as a config option.
- Inclusive Technology compatibility: unknown until there's a paid app
  to test against. Their apps often expect Space or Enter from a
  switch-interface keyboard; both are now a config-page change instead
  of a reflash.
- v1/v2 firmware history: preserved in git history and in the
  maintainer's offline archive, not in the working tree.
