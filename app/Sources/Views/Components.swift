// Open Adaptive Switch - shared view pieces.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

// Hex <-> Color for storing the per-switch dome color in UserDefaults.
extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

// A rendered arcade-style dome button, so the app icon can match the
// physical switch a family built.
struct DomeSwitch: View {
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.22))
                .frame(width: size, height: size)
            Circle()
                .fill(RadialGradient(
                    colors: [color, color.opacity(0.68)],
                    center: UnitPoint(x: 0.36, y: 0.3),
                    startRadius: size * 0.03,
                    endRadius: size * 0.62))
                .frame(width: size * 0.82, height: size * 0.82)
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: max(1, size * 0.03))
                        .frame(width: size * 0.82, height: size * 0.82))
            Ellipse()
                .fill(Color.white.opacity(0.55))
                .frame(width: size * 0.3, height: size * 0.16)
                .offset(x: -size * 0.13, y: -size * 0.19)
                .blur(radius: size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BatteryCard: View {
    let reading: BatteryReading?

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 42

    private var percent: Int { Int(reading?.percent ?? 0) }

    private var fillColor: Color {
        guard let reading else { return .gray }
        if reading.state == .charging || reading.state == .fullOnUSB { return .green }
        if reading.percent <= 15 { return .red }
        if reading.percent <= 30 { return .orange }
        return .green
    }

    private var symbolName: String {
        guard let reading else { return "battery.0percent" }
        if reading.state == .charging { return "battery.100percent.bolt" }
        switch reading.percent {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...65: return "battery.50percent"
        case 66...90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: iconSize))
                .foregroundStyle(fillColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let reading {
                    Text("\(percent)%")
                        .font(.title.weight(.semibold))
                        .contentTransition(.numericText())
                    Text("\(String(format: "%.2f", Double(reading.millivolts) / 1000)) V, \(reading.state.title.lowercased())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Battery")
                        .font(.title3.weight(.semibold))
                    Text("Waiting for the first reading...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reading.map { "Battery \($0.percent) percent, \($0.state.title)" } ?? "Battery reading pending")
    }
}

// Compact battery indicator for the scan list, fed by advertised data.
struct MiniBattery: View {
    let percent: UInt8
    let charging: Bool

    private var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...65: return "battery.50percent"
        case 66...90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var color: Color {
        if charging { return .green }
        if percent <= 15 { return .red }
        if percent <= 30 { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(percent)%").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Battery \(percent) percent\(charging ? ", charging" : "")")
    }
}

struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        switch rssi {
        case (-55)...: return 3
        case (-70)...: return 2
        case (-85)...: return 1
        default: return 0
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(6 + i * 4))
            }
        }
        .accessibilityLabel("Signal strength \(level) of 3")
    }
}

