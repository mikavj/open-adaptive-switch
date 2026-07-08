// Open Adaptive Switch - connected device screen.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

struct DeviceView: View {
    @EnvironmentObject var manager: SwitchManager

    @State private var nameDraft = ""
    @State private var nameNote: String?
    @State private var showFactoryConfirm = false
    @State private var releaseNote: String?
    @State private var showSaved = false

    var body: some View {
        List {
            if let error = manager.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                BatteryCard(reading: manager.battery)
            }

            Section {
                Picker("Mode", selection: Binding(
                    get: { manager.config.mode },
                    set: { manager.save(mode: $0) }
                )) {
                    ForEach(SwitchMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                ForEach(0..<manager.config.mode.slotCount, id: \.self) { slot in
                    NavigationLink {
                        KeyPickerView(slot: slot)
                    } label: {
                        LabeledContent(
                            SwitchMode.slotLabel(slot, mode: manager.config.mode),
                            value: manager.config.bindings[slot].display)
                    }
                }
            } header: {
                Text("Button behavior")
            } footer: {
                Text(manager.config.mode.detail)
            }

            Section {
                Picker("Sleep after", selection: Binding(
                    get: { manager.config.sleepMinutes },
                    set: { manager.save(sleepMinutes: $0) }
                )) {
                    Text("Never").tag(UInt16(0))
                    ForEach([5, 15, 30, 60, 120, 480], id: \.self) { m in
                        Text("\(m) minutes").tag(UInt16(m))
                    }
                    if ![0, 5, 15, 30, 60, 120, 480].contains(Int(manager.config.sleepMinutes)) {
                        Text("\(manager.config.sleepMinutes) minutes").tag(manager.config.sleepMinutes)
                    }
                }
            } header: {
                Text("Sleep timer")
            } footer: {
                Text("A sleeping switch wakes on the next press. It never sleeps while plugged in over USB.")
            }

            Section {
                HStack {
                    TextField("Switch name", text: $nameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        let stored = manager.save(name: nameDraft.trimmingCharacters(in: .whitespaces))
                        nameNote = stored == nameDraft.trimmingCharacters(in: .whitespaces)
                            ? "Name sent. Restart the switch (below) to start using it."
                            : "Shortened to \"\(stored)\" to fit. Restart the switch to apply."
                    }
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker("Status light", selection: Binding(
                    get: { manager.config.accent },
                    set: { manager.save(accent: $0) }
                )) {
                    ForEach(AccentColorSetting.allCases) { a in
                        Text(a.title).tag(a)
                    }
                }
            } header: {
                Text("Name and light")
            } footer: {
                if let nameNote {
                    Text(nameNote)
                } else {
                    Text("Up to 15 plain characters. If the switch was already paired, forget it in Switch Control settings and pair again after renaming.")
                }
            }

            Section("Firmware") {
                LabeledContent("Installed", value: manager.firmwareVersion ?? "unknown")
                LabeledContent("Latest release") {
                    if let release = manager.latestRelease {
                        Text(release.version)
                    } else if let releaseNote {
                        Text(releaseNote).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                if let release = manager.latestRelease {
                    if let installed = manager.firmwareVersion,
                       ReleaseChecker.compare(release.version, installed) > 0 {
                        Button {
                            manager.updaterPresented = true
                        } label: {
                            Label("Install update", systemImage: "arrow.down.circle")
                        }
                    } else {
                        Label("Up to date", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
                Button {
                    manager.updaterPresented = true
                } label: {
                    Label("Update from a file...", systemImage: "doc.zipper")
                }
            }

            Section {
                Button {
                    manager.send(.restart)
                } label: {
                    Label("Restart switch", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    showFactoryConfirm = true
                } label: {
                    Label("Reset to factory settings", systemImage: "trash")
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Factory reset restores the default key (F13), mode, name, sleep timer, and light color, then restarts. Pairings on the iPad are not removed.")
            }
        }
        .navigationTitle(manager.config.name.isEmpty ? "Switch" : manager.config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if showSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            nameDraft = manager.config.name
            checkRelease()
        }
        .onChange(of: manager.savedPulse) {
            withAnimation { showSaved = true }
            UIAccessibility.post(notification: .announcement, argument: "Saved")
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation { showSaved = false }
            }
        }
        .confirmationDialog("Reset the switch to factory settings?",
                            isPresented: $showFactoryConfirm, titleVisibility: .visible) {
            Button("Reset and restart", role: .destructive) {
                manager.send(.factoryReset)
            }
        }
    }

    private func checkRelease() {
        guard manager.latestRelease == nil else { return }
        Task {
            do {
                manager.latestRelease = try await ReleaseChecker.latest()
            } catch {
                releaseNote = (error as? ReleaseChecker.CheckError)?.errorDescription
                    ?? "Couldn't check (no internet connection?)"
            }
        }
    }
}
