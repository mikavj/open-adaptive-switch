// Open Adaptive Switch - read-only view of a remembered switch.
//
// Opened from the home screen for switches that aren't in reach: shows
// the settings they had at the last connection, the firmware they were
// running, and whether something newer is out.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

struct RememberedSwitchView: View {
    @EnvironmentObject var manager: SwitchManager
    @EnvironmentObject var store: SwitchStore
    @Environment(\.dismiss) private var dismiss

    let switchID: UUID
    @State private var showForgetConfirm = false

    var body: some View {
        if let entry = store.savedSwitch(for: switchID) {
            content(entry)
        } else {
            // The entry was just forgotten; nothing left to show.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func content(_ entry: SavedSwitch) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    DomeSwitch(color: entry.colorHex.flatMap { Color(hex: $0) } ?? .red,
                               size: 54)
                        .opacity(0.6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name.isEmpty ? "Switch" : entry.name)
                            .font(.title3.weight(.semibold))
                        Text("Last connected \(lastConnectedText(entry.lastConnected))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Bluetooth ID \(entry.id.uuidString). To change anything, wake the switch with a press and connect from the home screen.")
            }

            Section {
                LabeledContent("Mode", value: entry.config.mode.title)
                ForEach(0..<entry.config.mode.slotCount, id: \.self) { slot in
                    LabeledContent(
                        SwitchMode.slotLabel(slot, mode: entry.config.mode),
                        value: entry.config.bindings[slot].display)
                }
                LabeledContent("Sleep after", value: sleepText(entry.config.sleepMinutes))
                LabeledContent("Status light", value: entry.config.accent.title)
            } header: {
                Text("Settings at last connection")
            }

            Section {
                LabeledContent("Was running", value: entry.firmwareVersion ?? "unknown")
                LabeledContent("Latest release") {
                    if let release = manager.latestRelease {
                        Text(release.version)
                    } else {
                        Text("unknown").foregroundStyle(.secondary)
                    }
                }
                if manager.updateAvailable(for: entry) {
                    HStack(spacing: 8) {
                        // Decorative here - the text next to it already
                        // says it, and VoiceOver shouldn't hear it twice.
                        UpdateBadge()
                            .accessibilityHidden(true)
                        Text("Update available. Connect this switch to install it.")
                            .font(.subheadline)
                    }
                }
            } header: {
                Text("Firmware")
            }

            Section {
                Button(role: .destructive) {
                    showForgetConfirm = true
                } label: {
                    Label("Forget this switch", systemImage: "trash")
                }
            } footer: {
                Text("Removes it from this list along with its saved settings and color. The switch itself keeps working as configured.")
            }
        }
        .navigationTitle(entry.name.isEmpty ? "Switch" : entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget \(entry.name.isEmpty ? "this switch" : entry.name)?",
                            isPresented: $showForgetConfirm, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                store.forget(id: entry.id)
                dismiss()
            }
        }
    }

    private func sleepText(_ minutes: UInt16) -> String {
        minutes == 0 ? "Never" : "\(minutes) minutes"
    }
}
