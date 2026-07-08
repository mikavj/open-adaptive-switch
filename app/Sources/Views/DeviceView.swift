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
    @State private var sleepCustom = false
    @State private var sleepCustomText = ""
    @AppStorage("autoUpdate") private var autoUpdate = true

    private let sleepPresets: [Int] = [5, 15, 30, 60, 120, 480]

    var body: some View {
        List {
            if let error = manager.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack(spacing: 16) {
                    BatteryCard(reading: manager.battery)
                    if let id = manager.connectedID {
                        DomeSwitch(color: manager.domeColor(for: id), size: 54)
                    }
                }
                if let id = manager.connectedID {
                    domeColorPicker(id)
                }
            } footer: {
                Text("Pick a color to match the switch you built. This is just how the app shows it.")
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
                    SlotEditor(slot: slot)
                }
            } header: {
                Text("Button behavior")
            } footer: {
                Text(manager.config.mode.detail)
            }

            Section {
                Picker("Sleep after", selection: sleepSelection) {
                    Text("Never").tag(UInt16(0))
                    ForEach(sleepPresets, id: \.self) { m in
                        Text("\(m) minutes").tag(UInt16(m))
                    }
                    Text("Custom...").tag(UInt16(0xFFFF))
                }
                if sleepCustom {
                    HStack {
                        Text("Minutes (0 to 1440)")
                        Spacer()
                        TextField("30", text: $sleepCustomText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 70, maxWidth: 110)
                            .onChange(of: sleepCustomText) {
                                if let v = Int(sleepCustomText), (0...1440).contains(v) {
                                    manager.save(sleepMinutes: UInt16(v))
                                }
                            }
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
                        .onChange(of: nameDraft) {
                            let clean = sanitizedName(nameDraft)
                            if clean != nameDraft { nameDraft = clean }
                        }
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

            Section {
                LabeledContent("Installed", value: manager.firmwareVersion ?? "unknown")
                if autoUpdate {
                    LabeledContent("Latest release") {
                        if let release = manager.latestRelease {
                            Text(release.version)
                        } else if let releaseNote {
                            Text(releaseNote).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    if let release = manager.latestRelease,
                       let installed = manager.firmwareVersion {
                        if ReleaseChecker.compare(release.version, installed) > 0 {
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
                }
                Button {
                    manager.updaterPresented = true
                } label: {
                    Label("Update, roll back, or pick a version...", systemImage: "arrow.triangle.2.circlepath")
                }
            } header: {
                Text("Firmware")
            } footer: {
                Text(autoUpdate
                     ? "Updates are never installed on their own; the switch only changes when you tap Install."
                     : "Automatic checking is off. Use the button above to update, roll back, or choose a version.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
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
            let m = Int(manager.config.sleepMinutes)
            sleepCustom = m != 0 && !sleepPresets.contains(m)
            if sleepCustom { sleepCustomText = String(m) }
            checkRelease()
        }
        .onChange(of: autoUpdate) {
            if autoUpdate { checkRelease() }
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

    // Keep the name to printable ASCII, which is safe in a Bluetooth name;
    // this strips emoji, accented letters, and control characters.
    private func sanitizedName(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }))
    }

    @ViewBuilder
    private func domeColorPicker(_ id: UUID) -> some View {
        let presets: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]
        let currentHex = manager.domeColor(for: id).hexString
        HStack(spacing: 10) {
            ForEach(presets, id: \.hexString) { c in
                Button {
                    manager.setDomeColor(c, for: id)
                } label: {
                    Circle()
                        .fill(c)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(
                            Color.primary.opacity(c.hexString == currentHex ? 0.9 : 0.2),
                            lineWidth: c.hexString == currentHex ? 3 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(colorName(c))
            }
        }
        ColorPicker("Custom color", selection: Binding(
            get: { manager.domeColor(for: id) },
            set: { manager.setDomeColor($0, for: id) }
        ))
    }

    private func colorName(_ c: Color) -> String {
        switch c.hexString {
        case Color.red.hexString: return "Red"
        case Color.orange.hexString: return "Orange"
        case Color.yellow.hexString: return "Yellow"
        case Color.green.hexString: return "Green"
        case Color.blue.hexString: return "Blue"
        case Color.purple.hexString: return "Purple"
        case Color.white.hexString: return "White"
        case Color.black.hexString: return "Black"
        default: return "Color"
        }
    }

    // Sleep picker selection: a preset value, or 0xFFFF meaning "custom",
    // which reveals the minutes field.
    private var sleepSelection: Binding<UInt16> {
        Binding(
            get: {
                if sleepCustom { return 0xFFFF }
                return manager.config.sleepMinutes
            },
            set: { value in
                if value == 0xFFFF {
                    sleepCustom = true
                    sleepCustomText = String(manager.config.sleepMinutes)
                } else {
                    sleepCustom = false
                    manager.save(sleepMinutes: value)
                }
            })
    }

    private func checkRelease() {
        guard autoUpdate, manager.latestRelease == nil else { return }
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
