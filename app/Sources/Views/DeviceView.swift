// Open Adaptive Switch - connected device screen.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

struct DeviceView: View {
    @EnvironmentObject var manager: SwitchManager
    @EnvironmentObject var store: SwitchStore

    @State private var nameDraft = ""
    @State private var nameNote: String?
    @State private var showFactoryConfirm = false
    @State private var releaseNote: String?
    @State private var showSaved = false
    @State private var sleepCustom = false
    @State private var sleepCustomText = ""
    @State private var defaultSaved = false
    @FocusState private var nameFocused: Bool
    @FocusState private var sleepFieldFocused: Bool
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

            // What the hardware reports, plus how the app draws it.
            Section {
                HStack(spacing: 16) {
                    BatteryCard(reading: manager.battery)
                    if let id = manager.connectedID {
                        DomeSwitch(color: manager.domeColor(for: id), size: 54)
                    }
                }
                if manager.isDemo {
                    Label("Demo switch. Settings work, but changes stay in the app and firmware tools are off.",
                          systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let id = manager.connectedID {
                    Text("Bluetooth ID \(id.uuidString)")
                }
            }

            Section {
                TextField("Switch name", text: $nameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { commitName() }
                    .onChange(of: nameDraft) {
                        let clean = sanitizedName(nameDraft)
                        if clean != nameDraft { nameDraft = clean }
                    }
                    .frame(maxWidth: .infinity)
                    // Make the whole row focus the field; taps on the row's
                    // edges used to go nowhere and the keyboard stayed away.
                    .contentShape(Rectangle())
                    .onTapGesture { nameFocused = true }
                if let id = manager.connectedID {
                    domeColorRow(id)
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
                Text("Name and color")
            } footer: {
                if let nameNote {
                    Text(nameNote)
                } else {
                    Text("Names can be up to 15 plain characters; renaming a paired switch means forgetting and re-pairing it in Switch Control settings. The dome color is just how the app draws this switch.")
                }
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
                if !store.profiles.isEmpty {
                    Menu {
                        ForEach(store.profiles) { p in
                            Button(p.name.isEmpty ? "Profile" : p.name) {
                                manager.apply(p.config)
                            }
                        }
                    } label: {
                        Label("Apply a profile", systemImage: "square.on.square")
                    }
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
                            .focused($sleepFieldFocused)
                            .accessibilityLabel("Sleep minutes")
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
                LabeledContent("Installed", value: manager.firmwareVersion ?? "unknown")
                if manager.isDemo {
                    // Nothing to flash on a pretend switch.
                } else {
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
                                    Label("Install update", systemImage: "arrow.up.circle")
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
                }
            } header: {
                Text("Firmware")
            } footer: {
                if manager.isDemo {
                    Text("Firmware tools are turned off for the demo switch.")
                } else {
                    Text(autoUpdate
                         ? "Updates are never installed on their own; the switch only changes when you tap Install."
                         : "Automatic checking is off (see App Settings). Use the button above to update, roll back, or choose a version.")
                }
            }

            Section {
                Button {
                    var preset = manager.config
                    preset.name = ""   // the name belongs to the switch, not the setup
                    store.defaultConfig = preset
                    defaultSaved = true
                } label: {
                    Label("Save these settings as the default", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Default configuration")
            } footer: {
                Text(defaultSaved
                     ? "Saved. A switch connecting for the first time will offer to take this configuration."
                     : "Makes this switch's mode, keys, sleep timer, and status light the configuration offered to new switches. Manage it under App Settings on the home screen.")
            }

            Section {
                Button {
                    // A rename still sitting in the keyboard would be
                    // lost once the restart arms the disconnect; flush
                    // it first so the switch reboots under the new name.
                    commitName()
                    nameFocused = false
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
                Text("Factory reset restores the default key (F13), mode, name, sleep timer, and light color, then restarts. Pairings with this iPhone or iPad are not removed.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
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
        .keyboardDoneButton()
        .safeAreaInset(edge: .top, spacing: 0) {
            if manager.offerDefaultSetup {
                defaultOfferBanner
            }
        }
        .onAppear {
            nameDraft = manager.config.name
            seedSleepFields()
            checkRelease()
        }
        .onChange(of: nameFocused) {
            // Typing ends by tapping Done, tapping away, or scrolling;
            // all of those save the draft.
            if !nameFocused { commitName() }
        }
        .onChange(of: sleepFieldFocused) {
            // An external change (profile, default configuration) that
            // arrived while typing is picked up once the keyboard goes.
            if !sleepFieldFocused { seedSleepFields() }
        }
        // initial: true because the flag is usually already set by the
        // time this screen exists; a plain onChange would never fire.
        .onChange(of: manager.offerDefaultSetup, initial: true) {
            if manager.offerDefaultSetup {
                UIAccessibility.post(notification: .announcement,
                                     argument: "First time connecting. A banner offers to apply your default configuration.")
            }
        }
        .onChange(of: manager.config.name) {
            if !nameFocused { nameDraft = manager.config.name }
        }
        .onChange(of: manager.config.sleepMinutes) {
            // Applying a profile or default can change the value from
            // outside the picker; don't fight the field while typing.
            if !sleepFieldFocused { seedSleepFields() }
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

    // Offer sits above the list without covering it, in the style of a
    // notification bar: dismissable, one tap to accept.
    private var defaultOfferBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("First time connecting")
                    .font(.subheadline.weight(.semibold))
                Text("Apply your default configuration to this switch?")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply") {
                if let preset = store.defaultConfig { manager.apply(preset) }
                withAnimation { manager.offerDefaultSetup = false }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                withAnimation { manager.offerDefaultSetup = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // A full-size target, well apart from Apply; a mishit
                    // here would configure the switch instead.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func commitName() {
        // Focus can also end because the screen is being left; don't
        // fire a write into a connection that's already closing. The
        // phase alone isn't enough - it stays .ready until the async
        // disconnect callback lands.
        guard manager.phase == .ready, !manager.expectedDisconnect else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != manager.config.name else { return }
        let stored = manager.save(name: trimmed)
        nameNote = stored == trimmed
            ? "Name sent. Restart the switch (below) to start using it."
            : "Shortened to \"\(stored)\" to fit. Restart the switch to apply."
    }

    // Keep the name to printable ASCII, which is safe in a Bluetooth name;
    // this strips emoji, accented letters, and control characters.
    private func sanitizedName(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }))
    }

    // Preset dome colors with the free-choice picker at the end of the
    // line; the wheel itself says what it does.
    @ViewBuilder
    private func domeColorRow(_ id: UUID) -> some View {
        let presets: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]
        let currentHex = manager.domeColor(for: id).hexString
        HStack(spacing: 8) {
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
                .accessibilityAddTraits(c.hexString == currentHex ? .isSelected : [])
            }
            Spacer(minLength: 4)
            ColorPicker("", selection: Binding(
                get: { manager.domeColor(for: id) },
                set: { manager.setDomeColor($0, for: id) }
            ))
            .labelsHidden()
            .accessibilityLabel("Custom color")
        }
        .padding(.vertical, 2)
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

    private func seedSleepFields() {
        let m = Int(manager.config.sleepMinutes)
        sleepCustom = m != 0 && !sleepPresets.contains(m)
        if sleepCustom { sleepCustomText = String(m) }
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
        guard autoUpdate, manager.latestRelease == nil, !manager.isDemo else { return }
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
