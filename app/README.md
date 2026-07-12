# Open Adaptive Switch iOS app

Native companion app for Open Adaptive Switch: find a switch, change what
its button sends, set the sleep timer, rename it, pick the light color,
watch the battery, and install firmware updates - all in one place, no
extra apps.

(The app's display name on the home screen is "OA Switch" so it fits
under the icon; everywhere else it is "Open Adaptive Switch".)

Firmware updates use Nordic's open-source DFU library (BSD-3-Clause),
the same code their own update apps are built on, so the update path
stays available even if any single app disappears from the store.

## Building and running

Requirements: Xcode 16 or newer, an Apple Developer account for running
on a real device (Bluetooth does not work in the simulator).

1. Open `OpenAdaptiveSwitch.xcodeproj` in Xcode.
2. In the project settings, Signing and Capabilities tab: pick your team
   and, if Xcode complains the bundle identifier is taken, change
   `com.mikavj.openadaptiveswitch` to something under your own domain.
3. Select your iPhone as the run destination and press Run. The first
   time, Xcode asks the phone to trust your developer certificate
   (Settings, General, VPN and Device Management).

The Swift package dependency (NordicDFU) resolves automatically on first
open; give it a minute.

## Project layout

The Xcode project file is generated from `project.yml` by
[xcodegen](https://github.com/yonaskolb/XcodeGen) and committed, so you
don't need xcodegen to build. If you add or rename source files outside
Xcode, regenerate with `xcodegen generate` in this folder.

| Path | What |
|---|---|
| `Sources/Model/SwitchProtocol.swift` | BLE UUIDs, modes, key catalog - mirrors [docs/ble-protocol.md](../docs/ble-protocol.md) |
| `Sources/Model/SwitchManager.swift` | CoreBluetooth: scanning, connection, reads/writes, demo switch |
| `Sources/Model/SwitchStore.swift` | remembered switches, profiles, default setup, backup files |
| `Sources/Model/DFUManager.swift` | firmware updates via NordicDFU |
| `Sources/Model/ReleaseChecker.swift` | latest-release lookup on GitHub |
| `Sources/Views/` | SwiftUI screens |

## Distribution

Running your own build covers development. To put the app in families'
hands it needs the App Store (or TestFlight for betas): archive in Xcode
(Product, Archive), upload through the Organizer, and submit. App Review
usually asks hardware apps for a short demo video showing the app working
with the physical switch - have one ready in the review notes. TestFlight
builds expire after 90 days, so the store is the long-term home.

## License

GPL-3.0-or-later, like the rest of the project. The NordicDFU dependency
is BSD-3-Clause, which is compatible.
