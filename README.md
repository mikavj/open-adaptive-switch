# Open Adaptive Switch

DIY wireless switches for iOS Switch Control, built around the Seeed XIAO
nRF52840. Each unit is a single button in a box: press it and it sends a
keystroke over Bluetooth LE, which an iPhone or iPad treats as an
accessibility switch input. The parts cost roughly $12 per unit;
comparable commercial Bluetooth switches sell for around $200.

The project started as a way to give a child with a motor disability an
affordable button for cause-and-effect games. A family can set everything
up from a phone: which key the button sends, one action or three, how
long before it sleeps, its name, and firmware updates. No computer, no
reflashing.

This is a work in progress. The firmware and configuration tools work;
enclosure designs, photos, and wiring diagrams are still to come.

## Hardware

| Part | Notes |
|---|---|
| Seeed XIAO nRF52840 | the plain variant, about $10; the Sense variant works identically |
| Tactile momentary button | wired between D0 and GND, no resistor needed |
| 3.7V 250mAh LiPo | JST connector, charged at 50mA over USB-C |
| Enclosure | any box that fits; 3D-printable design planned |

Why this board: a BLE switch has to hold its connection all day on a
small battery. The nRF52840 does that at roughly 0.1mA, which means
months per charge; an ESP32 in its best buildable configuration draws
about twenty times more and would need charging every few days. The
whole wireless-keyboard community settled on this chip for the same
reason.

The switch works by advertising as a BLE HID keyboard. iOS pairs with it
through Settings, Accessibility, Switch Control, where any key from an
external keyboard can be assigned to a switch action. The firmware
defaults to F13, which nothing else on the system uses, so several
switches can be paired at once without colliding.

## Setting up a switch

Configuration happens over Bluetooth, from either of two clients:

**The config page**, at
[mikavj.github.io/open-adaptive-switch](https://mikavj.github.io/open-adaptive-switch/)
(source in [docs/](docs/)). Open it in Chrome or Edge on a computer or
Android device and tap Connect. On an iPhone or iPad, install the free
[Bluefy browser](https://apps.apple.com/app/id1492822055) first, then
open the page inside it - Safari does not support Web Bluetooth, and a
link into Bluefy does nothing until the app is installed. A QR code
pointing at the page is in [docs/qr](docs/qr), sized to print on the
bottom of an enclosure.

**The iOS app**, in [app/](app/). A native SwiftUI app with the same
controls plus built-in firmware updates. It is not on the App Store yet;
building it yourself takes Xcode and an Apple developer account (see
[app/README.md](app/README.md)).

Either client can change:

| Setting | Choices |
|---|---|
| Mode | single key; tap or hold (two actions); short, medium, long press (three actions) |
| Keys | any HID keycode plus modifiers, per action |
| Sleep timer | minutes of inactivity before deep sleep, 0 to disable |
| Name | how the switch appears in Bluetooth lists; up to 15 plain characters |
| Status light | red, green, or blue accent |

Both show battery percentage, voltage, and charging state live, and check
this repository for firmware releases. Settings live on the switch
itself and survive restarts and updates. The switch accepts two
connections at once, so it can stay paired to the iPad while a parent
adjusts settings from a phone.

The chooser in the config page and the app only lists Open Adaptive
Switch devices (they filter on the switch's service identity), so
headphones and other Bluetooth devices never appear.

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
  controls.

If you reflash or rename a switch that was already paired, make iOS
Forget Device first, then pair again.

## Firmware updates

Three ways, most convenient first:

1. **Wireless, from a phone.** The config page or app puts the switch
   into update mode; Nordic's free
   [nRF Device Firmware Update](https://apps.apple.com/app/id1624454660)
   app (or the iOS app in this repo, which has the updater built in)
   sends it the release .zip. Both walk you through it.
2. **Any computer, no software.** Download the release .uf2, double-tap
   the switch's reset button, and a USB drive appears. Drag the file
   onto it; the switch reboots updated. (The copy dialog may report an
   error at the end - that's the drive vanishing on reboot, and the
   update still succeeded.)
3. **Wired, with the toolchain.** `./flash.sh` - see
   [SETUP.md](SETUP.md). Needed once per new board, since boards ship
   without this firmware.

Settings survive all three. Releases carry the .zip and .uf2, built by
`./make_release.sh`.

## Battery

The hardware takes care of itself; the firmware's job is honest
reporting.

Charging is handled entirely by the XIAO's onboard BQ25101 charger IC:
50mA (a gentle 0.2C for the 250mAh cell), 4.20V termination, fixed in
hardware. A cell that measures 4.15 to 4.20V after charging is full and
healthy - 4.2V is the normal full-charge voltage for a LiPo cell.

The firmware samples the cell through the onboard divider, maps voltage
to percentage with a resting-voltage discharge table (the approach ZMK
and Meshtastic use), and reports it over the standard BLE Battery
Service - so it shows in the iOS Batteries widget - and in detail on the
config page and app. Charging state comes from the charger IC's status
pin, not guessed from voltage; while charging, the percentage is capped
at 99 because a charging cell's voltage says nothing reliable about fill
level. On battery, the reported number never bounces upward. The LED
warns too: solid red below 3.55V, blinking red below 3.35V.

There is no firmware low-voltage shutdown. An earlier version had one and
it false-triggered on Bluetooth transmit sag. The 3.5V reporting floor
leaves comfortable margin above the roughly 3.0V where LiPo damage
starts.

One note for anyone with a pre-v3 unit: firmware before v3 addressed the
battery pins by raw port number, which this Arduino core ignores, so its
battery readings were always 0V and its warnings meant nothing. v3 uses
the board's pin map correctly.

## Longevity

The durable part of this project is the documented Bluetooth protocol
([docs/ble-protocol.md](docs/ble-protocol.md)) and the standard services
around it. Every client is replaceable against it: the web page, the iOS
app, Nordic's DFU tools (built on open-source libraries), and the
UF2 file copy, which is just a file on a USB drive and cannot rot.

If Bluefy ever disappears from the App Store, the page still has a path
to iOS: [WebBLE](https://github.com/daphtdazz/WebBLE) is an Apache-2.0
open-source browser using the same technique, and a fork of it (or a
Capacitor wrapper around this same page) restores support. Apple has
formally declined to add Web Bluetooth to Safari, so plan around that
rather than waiting for it.

## Status and roadmap

Working today: consolidated firmware (v3), the config page (live, with
release v3.0.0 published), battery reporting, wireless and drag-and-drop
updates, and the iOS app source.

Open threads:

- Field-test v3 on hardware: battery numbers, sleep, all three modes.
- Test the config page in Bluefy and Android Chrome end to end.
- Get the iOS app onto TestFlight, then the App Store.
- Enclosure design, wiring photos, assembly guide, carrier PCB with an
  onboard button.
- Test against switch-adapted apps (e.g. Inclusive Technology).
- Android Switch Access has not been tried; reports welcome.

## Contributing

Issues and pull requests are welcome, and so are reports from anyone who
builds one. Useful contributions don't have to be code: testing with
different apps or devices, enclosure designs, clearer assembly docs, or
accessibility feedback from daily use all help. For bigger changes, open
an issue first to talk it through.

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

GPL-3.0-or-later. See [LICENSE](LICENSE). Firmware, page, app, scripts,
and docs are all covered; if you improve a unit, sharing the changes back
keeps the next build cheap for everyone.
