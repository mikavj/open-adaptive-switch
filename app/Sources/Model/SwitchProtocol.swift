// Open Adaptive Switch - BLE protocol constants and value types.
// Mirrors docs/ble-protocol.md; the firmware is the source of truth.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import CoreBluetooth

enum SwitchBLE {
    static let configService   = CBUUID(string: "F6BA8E00-4094-4E31-B42A-5AAEF6FC5C7D")
    static let modeChar        = CBUUID(string: "F6BA8E01-4094-4E31-B42A-5AAEF6FC5C7D")
    static let keymapChar      = CBUUID(string: "F6BA8E02-4094-4E31-B42A-5AAEF6FC5C7D")
    static let sleepChar       = CBUUID(string: "F6BA8E03-4094-4E31-B42A-5AAEF6FC5C7D")
    static let nameChar        = CBUUID(string: "F6BA8E04-4094-4E31-B42A-5AAEF6FC5C7D")
    static let batteryChar     = CBUUID(string: "F6BA8E05-4094-4E31-B42A-5AAEF6FC5C7D")
    static let commandChar     = CBUUID(string: "F6BA8E06-4094-4E31-B42A-5AAEF6FC5C7D")
    static let accentChar      = CBUUID(string: "F6BA8E07-4094-4E31-B42A-5AAEF6FC5C7D")

    static let deviceInfoService = CBUUID(string: "180A")
    static let firmwareRevChar   = CBUUID(string: "2A26")

    // Nordic legacy DFU service, advertised by the bootloader in update mode.
    static let dfuService = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
}

enum SwitchCommand: UInt8 {
    case restart = 1
    case factoryReset = 2
    case enterUpdateMode = 3
}

enum SwitchMode: UInt8, CaseIterable, Identifiable, Codable {
    case singleKey = 0
    case tapHold = 1
    case zones = 2

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .singleKey: return "Single key"
        case .tapHold:   return "Tap or hold"
        case .zones:     return "Short, medium, long"
        }
    }

    var detail: String {
        switch self {
        case .singleKey: return "Every press sends one key."
        case .tapHold:   return "A quick tap and a half-second hold send different keys."
        case .zones:     return "Press length picks one of three keys. The light shows red, amber, then green while held."
        }
    }

    var slotCount: Int {
        switch self {
        case .singleKey: return 1
        case .tapHold:   return 2
        case .zones:     return 3
        }
    }

    static func slotLabel(_ slot: Int, mode: SwitchMode) -> String {
        switch mode {
        case .singleKey: return "Key"
        case .tapHold:   return slot == 0 ? "Tap key" : "Hold key"
        case .zones:     return ["Short press key", "Medium press key", "Long press key"][slot]
        }
    }
}

enum AccentColorSetting: UInt8, CaseIterable, Identifiable, Codable {
    case red = 0, green = 1, blue = 2
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

enum BatteryState: UInt8 {
    case onBattery = 0
    case charging = 1
    case fullOnUSB = 2

    var title: String {
        switch self {
        case .onBattery: return "On battery"
        case .charging:  return "Charging"
        case .fullOnUSB: return "Charged, on USB power"
        }
    }
}

struct BatteryReading: Equatable {
    var millivolts: UInt16
    var percent: UInt8
    var state: BatteryState

    // For the demo switch, which has no real hardware behind it.
    init(millivolts: UInt16, percent: UInt8, state: BatteryState) {
        self.millivolts = millivolts
        self.percent = percent
        self.state = state
    }

    init?(data: Data) {
        guard data.count >= 4 else { return nil }
        millivolts = UInt16(data[0]) | (UInt16(data[1]) << 8)
        percent = data[2]
        state = BatteryState(rawValue: data[3]) ?? .onBattery
    }
}

// One key binding: HID modifier bitmask plus keycode.
struct KeyBinding: Equatable, Codable {
    var modifier: UInt8 = 0
    var keycode: UInt8 = 0

    var isDisabled: Bool { modifier == 0 && keycode == 0 }

    var display: String {
        if isDisabled { return "Off" }
        var parts: [String] = []
        for m in HIDModifier.all where modifier & m.bit != 0 { parts.append(m.name) }
        parts.append(HIDKey.name(for: keycode))
        return parts.joined(separator: " + ")
    }
}

struct HIDModifier: Identifiable {
    let name: String
    let bit: UInt8
    var id: UInt8 { bit }
    static let all: [HIDModifier] = [
        HIDModifier(name: "Ctrl", bit: 0x01),
        HIDModifier(name: "Shift", bit: 0x02),
        HIDModifier(name: "Alt", bit: 0x04),
        HIDModifier(name: "Cmd", bit: 0x08),
    ]
}

struct HIDKeyGroup: Identifiable {
    let name: String
    let keys: [(name: String, code: UInt8)]
    var id: String { name }
}

enum HIDKey {
    // USB HID keyboard usage codes, grouped for the picker. Sentinel 255
    // ("Custom code") is handled separately by the editor.
    static let groups: [HIDKeyGroup] = [
        HIDKeyGroup(name: "Function keys", keys: [
            ("F13", 0x68), ("F14", 0x69), ("F15", 0x6A), ("F16", 0x6B),
            ("F17", 0x6C), ("F18", 0x6D), ("F19", 0x6E), ("F20", 0x6F),
            ("F21", 0x70), ("F22", 0x71), ("F23", 0x72), ("F24", 0x73),
        ]),
        HIDKeyGroup(name: "Keys", keys: [
            ("Space", 0x2C), ("Enter", 0x28), ("Tab", 0x2B),
            ("Escape", 0x29), ("Backspace", 0x2A),
            ("Arrow up", 0x52), ("Arrow down", 0x51),
            ("Arrow left", 0x50), ("Arrow right", 0x4F),
        ]),
        HIDKeyGroup(name: "Numbers", keys: [
            ("1", 0x1E), ("2", 0x1F), ("3", 0x20), ("4", 0x21), ("5", 0x22),
            ("6", 0x23), ("7", 0x24), ("8", 0x25), ("9", 0x26), ("0", 0x27),
        ]),
        HIDKeyGroup(name: "Letters", keys: (0..<26).map { i in
            (String(UnicodeScalar(UInt8(65 + i))), UInt8(0x04 + i))
        }),
    ]

    // Flat catalog for name lookups.
    static let all: [(name: String, code: UInt8)] = groups.flatMap { $0.keys }

    static func name(for code: UInt8) -> String {
        all.first(where: { $0.code == code })?.name ?? "Code \(code)"
    }

    static func isKnown(_ code: UInt8) -> Bool {
        all.contains(where: { $0.code == code })
    }
}

// The full editable configuration of a switch, as read over BLE.
// Codable so remembered switches, profiles, and the default setup can be
// stored and exported as JSON.
struct SwitchConfig: Equatable, Codable {
    var mode: SwitchMode = .singleKey
    var bindings: [KeyBinding] = [KeyBinding(), KeyBinding(), KeyBinding()]
    var sleepMinutes: UInt16 = 30
    var name: String = ""
    var accent: AccentColorSetting = .red

    init(mode: SwitchMode = .singleKey,
         bindings: [KeyBinding] = [KeyBinding(), KeyBinding(), KeyBinding()],
         sleepMinutes: UInt16 = 30, name: String = "",
         accent: AccentColorSetting = .red) {
        self.mode = mode
        self.bindings = bindings
        self.sleepMinutes = sleepMinutes
        self.name = name
        self.accent = accent
    }

    // What a switch ships with (mirrors the firmware's factory settings:
    // F13 for the single key, F14 and F15 for the hold/long slots). Used
    // to seed new profiles and the default configuration, so they open
    // showing real keys instead of "Custom code 0".
    static let factoryDefault = SwitchConfig(
        bindings: [KeyBinding(keycode: 0x68),
                   KeyBinding(keycode: 0x69),
                   KeyBinding(keycode: 0x6A)])

    // The rest of the app indexes bindings[0..<3]; a hand-edited or
    // truncated backup file must not be able to break that invariant.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(SwitchMode.self, forKey: .mode) ?? .singleKey
        let decoded = try c.decodeIfPresent([KeyBinding].self, forKey: .bindings) ?? []
        bindings = Array((decoded + [KeyBinding(), KeyBinding(), KeyBinding()]).prefix(3))
        sleepMinutes = try c.decodeIfPresent(UInt16.self, forKey: .sleepMinutes) ?? 30
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        accent = try c.decodeIfPresent(AccentColorSetting.self, forKey: .accent) ?? .red
    }

    var keymapData: Data {
        var bytes = [UInt8]()
        for b in bindings.prefix(3) {
            bytes.append(b.modifier)
            bytes.append(b.keycode)
        }
        return Data(bytes)
    }

    static func bindings(from data: Data) -> [KeyBinding]? {
        guard data.count >= 6 else { return nil }
        return (0..<3).map { i in
            KeyBinding(modifier: data[i * 2], keycode: data[i * 2 + 1])
        }
    }
}

// Encode a name to at most 15 UTF-8 bytes without splitting a character,
// matching the firmware's byte limit.
func encodeSwitchName(_ s: String) -> Data {
    let bytes = Array(s.utf8)
    if bytes.count <= 15 { return Data(bytes) }
    var cut = 15
    while cut > 0 && (bytes[cut] & 0xC0) == 0x80 { cut -= 1 }
    return Data(bytes[0..<cut])
}
