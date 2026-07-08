# Open Adaptive Switch

DIY wireless switches for iOS Switch Control, built around the Seeed XIAO
nRF52840 Sense. Each unit is a single button in a box: press it and it
sends a keystroke over Bluetooth LE, which an iPhone or iPad can treat as
an accessibility switch input. The parts cost roughly $15 per unit, while
comparable commercial Bluetooth switches sell for around $200.

The project started as a way to give a child with a motor disability an
affordable button for cause-and-effect games, and grew into a
configurable switch a family can set up from a phone: which key it sends,
one action or three, how long before it sleeps, its name, and firmware
updates, all without a computer or a reflash.

This is a work in progress. The firmware works and is in daily testing,
but enclosure designs, photos, and wiring diagrams are still to come.

## How it works

The XIAO advertises as a BLE HID keyboard. iOS pairs with it through
Settings, Accessibility, Switch Control, where any keystroke from an
external keyboard can be assigned to a switch action (tap the screen, run
a recipe, move the scanner). The firmware defaults to F13 because nothing
else on the system uses the high F-keys, so several switches can be
paired at once without colliding.

A unit is:

| Part | Notes |
|---|---|
| Seeed XIAO nRF52840 Sense | the Sense variant, FQBN `Seeeduino:nrf52:xiaonRF52840Sense` |
| Tactile momentary button | wired between D0 and GND, no resistor needed |
| 3.7V 250mAh LiPo | JST connector, charged at 50mA over USB-C |
| Enclosure | any box that fits; 3D-printable design planned |

There is one firmware for every unit: `switch-firmware/`. What used to be
three separate builds is now a runtime setting.

## Setting up a switch

Configuration happens on a web page that talks to the switch over
Bluetooth, straight from the browser: [the config page](https://mikavj.github.io/open-adaptive-switch/)
(source in [docs/](docs/)). No app to install, no account, and settings
are stored on the switch itself.

- On a computer or Android device, open the page in Chrome or Edge.
- On an iPhone or iPad, open it in the free
  [Bluefy browser](https://apps.apple.com/app/id1492822055); Safari does
  not support Web Bluetooth. The page detects this and offers a Bluefy
  handoff link.
- A QR code pointing at the page is in [docs/qr](docs/qr), sized to print
  on the bottom of an enclosure. Scan it with the camera, and on an
  iPhone an NFC sticker (NTAG213 programmed with the page URL) gives the
  same result with a tap.

What you can change there:

| Setting | Choices |
|---|---|
| Mode | single key; tap or hold (two actions); short, medium, long press (three actions) |
| Keys | any HID keycode plus modifiers, per action |
| Sleep timer | minutes of inactivity before deep sleep, 0 to disable |
| Name | how the switch appears in Bluetooth lists; up to 15 plain characters (accented characters count extra) |
| Status light | red, green, or blue accent |

The page also shows battery percentage, voltage, and charging state live,
and checks this repository for firmware releases.

The switch accepts two Bluetooth connections at once, so it can stay
paired to the iPad while a parent adjusts settings from their phone.

## Pairing with an iPhone or iPad

Always pair through the Switch Control flow, not the main Bluetooth menu:

Settings, Accessibility, Switch Control, Switches, Add New Switch,
External, then press the button and assign an action.

Each distinct key registers as a separate switch input, so three-action
mode becomes three assignable switches from one physical button.

Two setups that work well in practice:

- Tap-anywhere games (tested with Peekaboo Barn): create a Switch Control
  Recipe with the action "Tap Middle of Screen" and timeout off, then
  launch the recipe. A press becomes a single screen tap with no scanner
  UI in the way.
- YouTube / Apple Music play-pause: leave Switch Control off entirely,
  set the switch to send Space, and pair it as a plain Bluetooth
  keyboard. Space toggles playback without bringing up the player
  controls (a screen tap would).

If you reflash or rename a switch that was already paired, make iOS
Forget Device first, then pair again.

## Battery

Short version: the hardware takes care of itself, and the firmware's job
is honest reporting.

Charging is handled entirely by the XIAO's onboard BQ25101 charger IC.
It charges at 50mA (a gentle 0.2C for the 250mAh cell), regulates to the
LiPo-standard 4.20V, and terminates on its own; firmware cannot override
any of that. A cell that measures around 4.15 to 4.20V after charging is
full and healthy, not overcharged - 4.2V is the normal full-charge
voltage for a single LiPo cell, and the IC's regulation band is 4.16 to
4.23V.

What the firmware does:

- Reads the cell through the onboard divider every 30 seconds and maps
  voltage to percentage with a resting-voltage discharge table (the same
  approach ZMK and Meshtastic use, tuned for a lightly loaded cell).
- Reports the percentage over the standard BLE Battery Service, so it
  appears in the iOS Batteries widget, and in detail (voltage, percent,
  charging state) on the config page.
- Reads the charger's status pin, so "charging" and "charged" are facts
  from the IC, not guesses from voltage. While charging, the percentage
  is capped at 99 because a charging cell's voltage says nothing reliable
  about its fill level; when the charger terminates, it reports 100.
- On battery, the reported percentage never bounces upward; radio bursts
  dip the voltage briefly and it rebounds, so the firmware ratchets the
  number downward only.
- Warns by LED: solid red below 3.55V, blinking red below 3.35V, plus an
  optional external charge LED (wiring in the firmware settings block).

There is no firmware low-voltage shutdown. An earlier version had one and
it false-triggered when Bluetooth transmit bursts briefly sagged the rail
on a healthy cell. The reporting floor of 3.5V still leaves comfortable
margin above the roughly 3.0V where LiPo damage starts.

One note for anyone with a pre-v3 unit: firmware before v3 addressed the
battery pins by raw port number, which this Arduino core ignores, so its
battery readings were always 0V and its LED battery warnings never
reflected the real cell. v3 uses the board's pin map correctly.

## Firmware updates, no cable needed

The XIAO's stock bootloader supports Bluetooth over-the-air updates using
Nordic's DFU protocol. Releases on this repository carry a ready-made
update package; installing one from an iPhone takes Nordic's free
[nRF Device Firmware Update](https://apps.apple.com/app/id1624454660)
app and a couple of minutes. The config page walks through it, checks
your installed version against the latest release, and puts the switch
into update mode with one button. Settings survive updates.

Wired flashing (first install, or recovery) still works the usual way:
see [SETUP.md](SETUP.md) and `./flash.sh`.

## Building and flashing

Toolchain setup (arduino-cli, the Seeed board package, adafruit-nrfutil)
is covered in [SETUP.md](SETUP.md), with notes for Linux and macOS. Once
set up:

```
./flash.sh
```

detects the board, compiles `switch-firmware/`, and uploads it.
`./make_release.sh` builds the OTA package for a GitHub release.

## Status and roadmap

Working today: the consolidated firmware compiles, pairs, runs from
battery with sleep and battery reporting, and is configurable from the
web page.

Open threads, roughly in order:

- Field-test the v3 firmware against the three v2 units it replaces.
- Test the config page across Chrome, Android, and Bluefy on iOS.
- Print and verify the QR sticker flow; try an NTAG213 sticker.
- Test against switch-adapted apps (e.g. Inclusive Technology), which
  often expect Space or Enter from a keyboard.
- Enclosure design, wiring photos, and a proper assembly guide.
- Android Switch Access has not been tried; reports welcome.

## Contributing

Issues and pull requests are welcome, and so are reports from anyone who
builds one. Useful contributions don't have to be code: testing with
different apps or devices, enclosure designs, clearer assembly docs, or
accessibility feedback from daily use all help. The BLE protocol between
firmware and config page is documented in
[docs/ble-protocol.md](docs/ble-protocol.md). If you're planning a bigger
change, open an issue first to talk it through.

## Safety notes

These are DIY devices without any certification, built around a bare LiPo
cell. Use a protected cell or handle the battery with the usual LiPo care
(no punctures, no charging unattended, replace if puffy). If you build
one for a child, make sure the enclosure is secure enough that the
battery and small parts can't be reached. The Bluetooth configuration and
update paths are open by design (see the security note in
[docs/ble-protocol.md](docs/ble-protocol.md)); anyone within radio range
could change settings, so don't use this design where that matters.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Firmware, scripts, and docs are
all covered; if you improve a unit, sharing the changes back keeps the
next build cheap for everyone.
