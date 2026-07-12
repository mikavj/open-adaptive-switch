// Open Adaptive Switch - device finder screen.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

struct ScanView: View {
    @EnvironmentObject var manager: SwitchManager
    @EnvironmentObject var store: SwitchStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @AppStorage("autoUpdate") private var autoUpdate = true

    var body: some View {
        NavigationStack {
            Group {
                if !hasSeenIntro {
                    intro
                } else {
                    switch manager.phase {
                    case .bluetoothOff:
                        ContentUnavailableView(
                            "Bluetooth is off",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("Turn on Bluetooth in Settings or Control Center, then come back."))
                    case .unauthorized:
                        ContentUnavailableView {
                            Label("Bluetooth permission needed", systemImage: "hand.raised")
                        } description: {
                            Text("This app talks to the switch over Bluetooth and can't work without it.")
                        } actions: {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                Link("Open Settings", destination: url)
                            }
                        }
                    case .connecting, .loading:
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(manager.phase == .connecting ? "Connecting..." : "Reading settings...")
                                .foregroundStyle(.secondary)
                        }
                    default:
                        deviceList
                    }
                }
            }
            .navigationTitle("Open Adaptive Switch")
            .toolbar {
                if hasSeenIntro {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("App settings")
                    }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { manager.phase == .ready },
                set: { if !$0 { manager.disconnect() } }
            )) {
                DeviceView()
            }
            .navigationDestination(for: UUID.self) { id in
                RememberedSwitchView(switchID: id)
            }
            // The updater lives here at the root, not on the device
            // screen: entering update mode disconnects the switch and
            // pops the device screen, and the sheet must outlive that.
            .sheet(isPresented: $manager.updaterPresented,
                   onDismiss: { manager.updateFlowEnded() }) {
                FirmwareUpdateView(latestRelease: manager.latestRelease)
                    .environmentObject(manager)
            }
            .onAppear { if hasSeenIntro { manager.startScan() } }
            // Fetched here as well as on the device screen, so remembered
            // switches can show their update arrows without connecting.
            // Keyed to the scene phase: a launch without internet gets
            // another chance every time the app comes to the front.
            .task(id: scenePhase) {
                if scenePhase == .active, autoUpdate {
                    await manager.refreshLatestRelease()
                }
            }
        }
    }

    // Shown once, before the system Bluetooth permission dialog, so the
    // dialog arrives with context instead of out of nowhere.
    private var intro: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "button.programmable")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Set up your switch")
                .font(.title.weight(.semibold))
            Text("This app connects to your Open Adaptive Switch over Bluetooth to configure the button, monitor the battery, and install firmware updates. iOS will request Bluetooth access first.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Spacer()
            Button {
                hasSeenIntro = true
                manager.startScan()
            } label: {
                Text("Find my switch")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private var deviceList: some View {
        List {
            if manager.discovered.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for switches")
                            .font(.headline)
                        Text("Press the switch's button once to wake it. Only Open Adaptive Switch devices will be displayed.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("No switch yet? Try a demo") {
                            manager.startDemo()
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section("Switches nearby") {
                    ForEach(manager.discovered) { item in
                        Button {
                            manager.connect(item)
                        } label: {
                            HStack(spacing: 10) {
                                DomeSwitch(color: manager.domeColor(for: item.id), size: 30)
                                Text(item.name)
                                    .font(.body.weight(.medium))
                                Spacer()
                                if let entry = store.savedSwitch(for: item.id),
                                   manager.updateAvailable(for: entry) {
                                    UpdateBadge()
                                }
                                if let pct = item.battery {
                                    MiniBattery(percent: pct, charging: item.charging)
                                }
                                SignalBars(rssi: item.rssi)
                            }
                            .padding(.vertical, 4)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            if !rememberedAway.isEmpty {
                Section {
                    ForEach(rememberedAway) { entry in
                        NavigationLink(value: entry.id) {
                            HStack(spacing: 10) {
                                DomeSwitch(color: savedColor(entry), size: 30)
                                    .opacity(0.45)
                                VStack(alignment: .leading, spacing: 2) {
                                    // The name stays readable; the dimmed
                                    // dome and the caption carry the
                                    // "not in reach" look.
                                    Text(entry.name.isEmpty ? "Switch" : entry.name)
                                        .font(.body.weight(.medium))
                                    Text("Last connected \(lastConnectedText(entry.lastConnected))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if manager.updateAvailable(for: entry) {
                                    UpdateBadge()
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Previously connected")
                } footer: {
                    Text("Not in reach right now. Tap one to see the settings it had last time.")
                }
            }

            if let error = manager.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Link(destination: URL(string: "https://openadaptiveswitch.com/")!) {
                    Label("About Open Adaptive Switch", systemImage: "globe")
                }
            } footer: {
                Text("An open-source Bluetooth switch for iOS Switch Control. This app changes what the button sends, its sleep timer, name, and light, and installs firmware updates.")
            }
        }
    }

    // Remembered switches that aren't currently advertising nearby; the
    // ones in reach are already in the live list above.
    private var rememberedAway: [SavedSwitch] {
        let nearby = Set(manager.discovered.map(\.id))
        return store.saved.filter { !nearby.contains($0.id) }
    }

    private func savedColor(_ entry: SavedSwitch) -> Color {
        entry.colorHex.flatMap { Color(hex: $0) } ?? .red
    }
}
