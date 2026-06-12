# Open Adaptive Switch

DIY wireless switches for iOS Switch Control, built around the Seeed XIAO
nRF52840 Sense. Each unit is a single button in a box: press it and it
sends a keystroke over Bluetooth LE, which an iPhone or iPad can treat as
an accessibility switch input. The parts cost roughly $15 per unit, while
comparable commercial Bluetooth switches sell for around $200.

The project started as a way to give a child with a motor disability an
affordable button for cause-and-effect games, and grew into a small family
of switch firmwares that can pair to the same device side by side.

This is a work in progress. The firmware works and is in daily testing,
but enclosure designs, photos, and wiring diagrams are still to come.

## How it works

The XIAO advertises as a BLE HID keyboard. iOS pairs with it through
Settings → Accessibility → Switch Control, where any keystroke from an
external keyboard can be assigned to a switch action (tap the screen, run
a recipe, move the scanner). The firmware sends F-keys (F13 and up)
because nothing else on the system uses them, so each unit registers as
its own switch even when several are paired at once.

A unit is:

| Part | Notes |
|---|---|
| Seeed XIAO nRF52840 Sense | the Sense variant, FQBN `Seeeduino:nrf52:xiaonRF52840Sense` |
| Tactile momentary button | wired between D0 and GND, no resistor needed |
| 3.7V 250mAh LiPo | JST connector, charged at 50mA over USB-C |
| Enclosure | any box that fits; 3D-printable design planned |

The firmware handles debouncing, pairing, battery monitoring with LED
status codes, and an inactivity deep sleep that a button press wakes
from. Battery thresholds and sleep timeouts are constants at the top of
each sketch, commented so they can be changed without reading the rest
of the code.

## The three units

Three firmware variants are in side-by-side testing. They share the same
chassis code and differ in what a press sends:

| Unit | BLE name | Sends | Good for |
|---|---|---|---|
| A | AdaptSwitch-A | F13 on press | the basic single switch; template for new units |
| B | AdaptSwitch-B | SPACE on tap, F14 on hold | play/pause in YouTube and Music without the on-screen overlay appearing |
| C | AdaptSwitch-C | F15, F16, or F17 by press duration | three actions from one button, with live LED feedback showing which zone you're in |

Unit A still includes a low-voltage auto-shutdown (UVLO). Units B and C
dropped it after false shutdowns (BLE transmit bursts can briefly sag the
battery rail on a healthy cell) and signal low battery by LED instead.
Which approach wins is an open question; both are being tested.

`make_unit.sh` generates additional units (D, E, F, ...) from Unit A with
a new name, key, and LED color, so a classroom or household can run up to
ten distinct switches at once.

## Building and flashing

Toolchain setup (arduino-cli, the Seeed board package, adafruit-nrfutil)
is covered in [SETUP.md](SETUP.md), with notes for Linux and macOS. Once
set up:

```
./flash.sh
```

detects the board, lists the available firmware folders, and compiles and
uploads the one you pick.

## Pairing with an iPhone or iPad

Always pair through the Switch Control flow, not the main Bluetooth menu:

Settings → Accessibility → Switch Control → Switches → Add New Switch →
External, then press the button and assign an action.

Each F-key registers as a separate switch input, so Unit C's three press
durations become three assignable switches from one physical button.

Two setups that work well in practice:

- Tap-anywhere games (tested with Peekaboo Barn): create a Switch Control
  Recipe with the action "Tap Middle of Screen" and timeout off, then
  launch the recipe. A press becomes a single screen tap with no scanner
  UI in the way.
- YouTube / Apple Music play-pause: leave Switch Control off entirely and
  pair Unit B as a plain Bluetooth keyboard. SPACE toggles playback
  without bringing up the player controls (a screen tap would).

If you reflash a board that was already paired, make iOS Forget Device
first. Reflashing resets the BLE bond and iOS won't reconnect to the old
one.

## Status and roadmap

Working today: all three units compile, pair, and run from battery with
LED battery reporting and deep sleep.

Open threads, roughly in order:

- Settle the Unit A vs B/C chassis question (UVLO or LED-only battery
  warnings) and port the winner everywhere.
- Wire up the multi-position selector switch the firmware already has a
  placeholder for (change sleep timeout or key map without reflashing).
- An Apple Shortcuts launcher recipe driven by Unit C.
- Test against switch-adapted apps (e.g. Inclusive Technology), which
  often expect Space/Enter from a keyboard rather than Switch Control.
- Enclosure design, wiring photos, and a proper assembly guide.
- Android Switch Access has not been tried; reports welcome.

## Contributing

Issues and pull requests are welcome, and so are reports from anyone who
builds one. Useful contributions don't have to be code: testing with
different apps or devices, enclosure designs, clearer assembly docs, or
accessibility feedback from daily use all help. If you're planning a
bigger change, open an issue first so we can talk it through.

## Safety notes

These are DIY devices without any certification, built around a bare LiPo
cell. Use a protected cell or handle the battery with the usual LiPo care
(no punctures, no charging unattended, replace if puffy). If you build
one for a child, make sure the enclosure is secure enough that the
battery and small parts can't be reached.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Firmware, scripts, and docs are
all covered; if you improve a unit, sharing the changes back keeps the
next build cheap for everyone.
