// Open Adaptive Switch - app-wide settings.
//
// Settings for the app itself, as opposed to any one switch: the default
// setup offered to new switches, reusable profiles, backup and restore,
// and clearing stored data.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: SwitchStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoUpdate") private var autoUpdate = true

    @State private var showExporter = false
    @State private var exportDocument: SettingsBackupDocument?
    @State private var showImporter = false
    @State private var noticeText: String?
    @State private var showForgetAllConfirm = false
    @State private var showEraseConfirm = false

    var body: some View {
        List {
            Section {
                if store.defaultConfig != nil {
                    NavigationLink("Default configuration") {
                        ConfigEditorView(title: "Default configuration",
                                         config: defaultConfigBinding)
                    }
                    Button("Remove the default configuration", role: .destructive) {
                        store.defaultConfig = nil
                    }
                } else {
                    Button("Set up a default configuration") {
                        store.defaultConfig = .factoryDefault
                    }
                }
            } header: {
                Text("New switches")
            } footer: {
                Text("With a default configuration set, a switch connecting to this app for the first time shows an offer to take those settings. A connected switch's screen also has a button to save its current settings as the default.")
            }

            Section {
                ForEach(store.profiles) { profile in
                    NavigationLink(profile.name.isEmpty ? "Profile" : profile.name) {
                        ProfileEditorView(profileID: profile.id)
                    }
                }
                .onDelete { store.profiles.remove(atOffsets: $0) }
                Button {
                    store.profiles.append(
                        SwitchProfile(name: "Profile \(store.profiles.count + 1)",
                                      config: .factoryDefault))
                } label: {
                    Label("Add a profile", systemImage: "plus")
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Configurations prepared ahead of time. Apply one to a connected switch from its screen. Swipe left on a profile to delete it.")
            }

            Section {
                Toggle("Check for firmware updates automatically", isOn: $autoUpdate)
            } footer: {
                Text("Checking only reads the list of published releases. Nothing installs until you tap Install on a switch.")
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label("Export settings", systemImage: "square.and.arrow.up")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import settings", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("The backup file holds remembered switches, profiles, and the default configuration - for moving to a new device or sharing a setup with someone else.")
            }

            Section {
                Button(role: .destructive) {
                    showForgetAllConfirm = true
                } label: {
                    Label("Forget all remembered switches", systemImage: "trash")
                }
                Button(role: .destructive) {
                    showEraseConfirm = true
                } label: {
                    Label("Delete all app data", systemImage: "trash.fill")
                }
            } header: {
                Text("Stored data")
            } footer: {
                Text("Deleting app data clears remembered switches, profiles, the default configuration, and preferences from this device. Settings stored on the switches themselves are not touched.")
            }

            Section {
                Link(destination: URL(string: "https://openadaptiveswitch.com/")!) {
                    Label("About Open Adaptive Switch", systemImage: "globe")
                }
                LabeledContent("App version", value: appVersion)
            }
        }
        .navigationTitle("App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: "open-adaptive-switch-settings") { result in
            if case .failure(let error) = result {
                noticeText = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { handleImport($0) }
        .alert("Settings", isPresented: Binding(
            get: { noticeText != nil },
            set: { if !$0 { noticeText = nil } }
        )) {
            Button("OK") { noticeText = nil }
        } message: {
            Text(noticeText ?? "")
        }
        .confirmationDialog("Forget all remembered switches?",
                            isPresented: $showForgetAllConfirm, titleVisibility: .visible) {
            Button("Forget all", role: .destructive) { store.forgetAll() }
        } message: {
            Text("Their saved settings and colors are removed from this device.")
        }
        .confirmationDialog("Delete all app data?",
                            isPresented: $showEraseConfirm, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                store.eraseAllData()
                dismiss()
            }
        } message: {
            Text("Remembered switches, profiles, the default configuration, and preferences are all removed. This can't be undone.")
        }
    }

    private var defaultConfigBinding: Binding<SwitchConfig> {
        Binding(
            get: { store.defaultConfig ?? SwitchConfig() },
            set: { store.defaultConfig = $0 })
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func prepareExport() {
        do {
            exportDocument = SettingsBackupDocument(data: try store.exportJSON())
            showExporter = true
        } catch {
            noticeText = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                noticeText = try store.importJSON(try Data(contentsOf: url))
            } catch {
                noticeText = "That file couldn't be read as a settings backup."
            }
        case .failure:
            break
        }
    }
}

// Plain JSON container for the settings backup.
struct SettingsBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - configuration editing (default setup and profiles)

// The same behavior/sleep/light rows the device screen has, editing a
// stored configuration instead of a live switch.
struct ConfigEditorSections: View {
    @Binding var config: SwitchConfig

    @State private var sleepCustom = false
    @State private var sleepCustomText = ""
    @FocusState private var sleepFieldFocused: Bool
    private let sleepPresets: [Int] = [5, 15, 30, 60, 120, 480]

    var body: some View {
        Section {
            Picker("Mode", selection: $config.mode) {
                ForEach(SwitchMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            ForEach(0..<config.mode.slotCount, id: \.self) { slot in
                BindingEditor(
                    label: SwitchMode.slotLabel(slot, mode: config.mode),
                    binding: $config.bindings[slot])
            }
        } header: {
            Text("Button behavior")
        } footer: {
            Text(config.mode.detail)
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
                                config.sleepMinutes = UInt16(v)
                            }
                        }
                }
            }
        } header: {
            Text("Sleep timer")
        }
        // Without seeding, a stored custom value (say 45 minutes) matches
        // no picker tag and the row renders blank. Don't reseed while the
        // field is being typed in - "30" would hide it mid-entry.
        .onAppear(perform: seedSleepFields)
        .onChange(of: config.sleepMinutes) {
            if !sleepFieldFocused { seedSleepFields() }
        }
        .onChange(of: sleepFieldFocused) {
            if !sleepFieldFocused { seedSleepFields() }
        }

        Section {
            Picker("Status light", selection: $config.accent) {
                ForEach(AccentColorSetting.allCases) { a in
                    Text(a.title).tag(a)
                }
            }
        } footer: {
            Text("The color of the switch's light when it's awake.")
        }
    }

    private func seedSleepFields() {
        let m = Int(config.sleepMinutes)
        sleepCustom = m != 0 && !sleepPresets.contains(m)
        if sleepCustom, sleepCustomText != String(m) { sleepCustomText = String(m) }
    }

    private var sleepSelection: Binding<UInt16> {
        Binding(
            get: {
                if sleepCustom { return 0xFFFF }
                return config.sleepMinutes
            },
            set: { value in
                if value == 0xFFFF {
                    sleepCustom = true
                    sleepCustomText = String(config.sleepMinutes)
                } else {
                    sleepCustom = false
                    config.sleepMinutes = value
                }
            })
    }
}

struct ConfigEditorView: View {
    let title: String
    @Binding var config: SwitchConfig

    var body: some View {
        List {
            ConfigEditorSections(config: $config)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject var store: SwitchStore
    let profileID: UUID

    var body: some View {
        if let i = store.profiles.firstIndex(where: { $0.id == profileID }) {
            List {
                Section("Profile name") {
                    TextField("Name", text: $store.profiles[i].name)
                        .submitLabel(.done)
                }
                ConfigEditorSections(config: $store.profiles[i].config)
            }
            .navigationTitle(store.profiles[i].name.isEmpty ? "Profile" : store.profiles[i].name)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
        }
    }
}
