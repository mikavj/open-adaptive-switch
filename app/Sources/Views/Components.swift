// Open Adaptive Switch - shared view pieces.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

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

