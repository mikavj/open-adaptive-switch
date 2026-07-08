# BLE configuration protocol

How the config page (or any other client) talks to the switch. The
firmware side lives in `switch-firmware/switch-firmware.ino`; the
reference client is [index.html](index.html) in this folder.

All multi-byte values are little-endian. All characteristics are open
(no bonding required) - see the security note at the bottom.

## Services on the device

| Service | UUID | Purpose |
|---|---|---|
| HID | 0x1812 | the switch itself (keyboard reports) |
| Battery | 0x180F | standard percentage, shows in the iOS Batteries widget |
| Device Information | 0x180A | firmware revision (0x2A26), model, manufacturer |
| Nordic DFU | 00001530-1212-EFDE-1523-785FEABCD123 | reboot into the OTA bootloader |
| Config | F6BA8E00-4094-4E31-B42A-5AAEF6FC5C7D | everything below |

The config service UUID is advertised in the scan response, so Web
Bluetooth clients can filter on it: only Open Adaptive Switch devices
appear in the chooser.

The switch accepts two simultaneous connections: the tablet using it as
a switch, and one configuration client.

## Config service characteristics

Base UUID `F6BA8Exx-4094-4E31-B42A-5AAEF6FC5C7D`; the `xx` byte below.

| xx | Name | Size | Access | Contents |
|---|---|---|---|---|
| 01 | Mode | 1 | read, write | 0 = single key, 1 = tap/hold, 2 = short/medium/long |
| 02 | Key map | 6 | read, write | three [modifier, keycode] pairs: slot 0 (tap/short), slot 1 (hold/medium), slot 2 (long) |
| 03 | Sleep timeout | 2 | read, write | minutes of inactivity before deep sleep; 0 = never |
| 04 | Name | 1-15 | read, write | UTF-8 device name, 15 byte limit (clients must truncate on a UTF-8 character boundary); applied at next restart |
| 05 | Battery | 4 | read, notify | uint16 millivolts, uint8 percent, uint8 state (0 = on battery, 1 = charging, 2 = charged on USB) |
| 06 | Command | 1 | write | 1 = restart, 2 = factory reset, 3 = enter firmware update mode |
| 07 | Status light color | 1 | read, write | 0 = red, 1 = green, 2 = blue |

Writes outside the valid ranges are ignored; read the characteristic
back to confirm what the switch accepted. Every accepted write is saved
to internal flash immediately and survives restarts and firmware
updates.

Keycodes are USB HID keyboard usage codes (F13 = 0x68 through
F24 = 0x73, Space = 0x2C, Enter = 0x28). The modifier byte is the HID
modifier bitmask: bit 0 = left Ctrl, bit 1 = left Shift, bit 2 =
left Alt, bit 3 = left Cmd/GUI. A slot with modifier 0 and keycode 0 is
disabled and sends nothing.

Press timing: a hold is 500 ms or longer. In three-action mode the
boundary between medium and long is 2000 ms.

## Battery reporting rules

The percentage comes from an 11-point resting-voltage table
(4.20 V = 100%, 3.50 V = 0%) with linear interpolation, sampled every
30 seconds with burst averaging. Two rules keep the number honest:

- On battery, the reported percent never increases. Radio bursts sag the
  cell voltage briefly and it rebounds afterward; without this ratchet
  the percentage would wobble upward.
- While charging, the terminal voltage reads near 4.2 V regardless of
  actual charge, so no percentage derived from it is trustworthy. The
  value is capped at 99 until the charger IC terminates (detected on the
  charger status pin), then 100 is reported while USB stays connected.

The same percent goes to the standard Battery Service (0x2A19,
notify-on-change), which is what iOS reads.

## Firmware update flow

1. Client writes command 3 (or the user uses Nordic's app directly
   against the DFU service). The switch saves nothing extra - settings
   are already on flash - and reboots into the Adafruit bootloader.
2. The bootloader advertises as a DFU target under a different address.
3. Nordic's "nRF Device Firmware Update" app (iOS/Android) or nRF
   Connect sends the release .zip (built by `make_release.sh`, attached
   to GitHub releases).
4. The bootloader verifies the package CRC and SoftDevice requirement
   (S140 7.3.0, `--sd-req 0x0123`), flashes, and reboots into the new
   firmware. Settings in internal flash are untouched.

## Security note

The config characteristics and the stock bootloader's DFU are open: any
BLE client in radio range can reconfigure the switch or, while it is in
update mode, flash it. For a bedside accessibility switch this is a
deliberate trade against setup friction for families, and the window for
DFU only opens when someone with physical access requests it. If a
deployment needs more, the Adafruit bootloader supports signed updates
(rebuild with `SIGNED_FW=1`), and the config service could require
bonding - contributions welcome.
