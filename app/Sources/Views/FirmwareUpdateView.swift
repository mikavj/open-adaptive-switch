// Open Adaptive Switch - guided firmware update.
//
// Pick a version (latest, any published release, or a local file), or roll
// back to the version that was on the switch before the last update, then
// put the switch into update mode and stream the package. Settings on the
// switch survive.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI
import UniformTypeIdentifiers

struct FirmwareUpdateView: View {
    @EnvironmentObject var manager: SwitchManager
    @StateObject private var dfu = DFUManager()
    @Environment(\.dismiss) private var dismiss

    // The version the switch ran before its last update, for rollback.
    // The version this switch ran before its last update, for rollback.
    // Stored per device by the manager, so several switches don't share
    // one rollback target.
    private var previousVersion: String {
        guard let id = manager.connectedID else { return "" }
        return manager.previousVersion(for: id)
    }

    let latestRelease: FirmwareRelease?

    // Guided first flash of a blank board, reached from the home screen
    // with nothing connected: same machinery, wording for someone
    // holding a factory-fresh Seeed board instead of a working switch.
    var setupMode = false

    private static let fileTag = "\u{0000}file"

    @State private var releases: [FirmwareRelease] = []
    @State private var loadingReleases = false
    @State private var selectedTag = ""
    @State private var packageURL: URL?
    @State private var packageLabel = ""
    @State private var downloading = false
    @State private var showFilePicker = false
    @State private var errorText: String?
    // Which switch is being flashed and what's going onto it, captured
    // when the flash starts: the picker stays live during the transfer,
    // so its value at .done can't be trusted.
    @State private var targetID: UUID?
    @State private var flashedTag: String?

    var body: some View {
        NavigationStack {
            List {
                stepSource
                if packageURL != nil { stepInstall }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(setupMode ? "Set up a new board" : "Firmware update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dfu.phase == .done ? "Done" : "Close") {
                        dfu.cancel()
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [UTType.zip]) { handleFile($0) }
            .onAppear(perform: loadReleases)
            .onChange(of: dfu.phase) {
                // Record the new version so the home screen's update
                // arrow clears without another connection. A package
                // from a file has no version the app can trust, so the
                // remembered version becomes "unknown" in that case.
                if dfu.phase == .done, let targetID {
                    let tag = flashedTag
                    manager.store.setFirmwareVersion(
                        (tag == nil || tag == Self.fileTag) ? nil : tag, for: targetID)
                }
            }
        }
        .interactiveDismissDisabled(dfu.phase == .updating)
    }

    // MARK: step 1 - choose what to install

    private var installedVersion: String { manager.firmwareVersion ?? "" }
    private var canRollBack: Bool {
        !previousVersion.isEmpty && previousVersion != installedVersion
            && releases.contains { $0.version == previousVersion }
    }

    private var stepSource: some View {
        Section {
            Picker("Version", selection: $selectedTag) {
                if let latestRelease {
                    Text("Latest (v\(latestRelease.version))").tag(latestRelease.version)
                }
                ForEach(otherVersions, id: \.self) { v in
                    Text("v\(v)").tag(v)
                }
                Text("From a file...").tag(Self.fileTag)
            }
            .onChange(of: selectedTag) { choose(selectedTag) }
            // Changing the selection mid-flash wouldn't change what's
            // being written; don't invite it.
            .disabled(dfu.phase == .updating)

            if canRollBack {
                Button {
                    selectedTag = previousVersion
                } label: {
                    Label("Roll back to v\(previousVersion)", systemImage: "arrow.uturn.backward")
                }
            }

            if loadingReleases {
                HStack { ProgressView(); Text("Loading versions...") }
                    .foregroundStyle(.secondary)
            }
            if downloading {
                HStack { ProgressView(); Text("Downloading \(packageLabel)...") }
                    .foregroundStyle(.secondary)
            } else if packageURL != nil {
                Label(packageLabel, systemImage: "doc.zipper")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Version")
        } footer: {
            Text(setupMode
                 ? "New boards normally receive the latest release. A .zip you already have works as well."
                 : "Choose the latest release, an older version, or a .zip you already have. Rolling back reinstalls the version the switch ran before its last update.")
        }
    }

    // Versions other than the latest (latest is shown as its own row).
    private var otherVersions: [String] {
        releases.map(\.version).filter { $0 != latestRelease?.version }
    }

    // MARK: step 2 - install

    private var stepInstall: some View {
        Section {
            switch dfu.phase {
            case .idle:
                if manager.phase == .ready && !setupMode {
                    Button {
                        // Remember what this switch is replacing, for a later rollback.
                        if let id = manager.connectedID, !installedVersion.isEmpty {
                            manager.setPreviousVersion(installedVersion, for: id)
                        }
                        targetID = manager.connectedID
                        flashedTag = selectedTag
                        manager.send(.enterUpdateMode)
                        if let packageURL { dfu.start(firmwareURL: packageURL) }
                    } label: {
                        Label("Start the update", systemImage: "arrow.up.circle")
                    }
                    Text("The switch restarts into update mode and this connection drops; that's normal. Keep the switch close and plugged in or well charged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        flashedTag = selectedTag
                        if let packageURL { dfu.start(firmwareURL: packageURL) }
                    } label: {
                        Label(setupMode ? "Search for the board"
                                        : "Find a switch already in update mode",
                              systemImage: "magnifyingglass")
                    }
                    Text(setupMode
                         ? "Power the board over USB or battery, then double-tap the small reset button beside the USB-C port. That puts it in update mode - search within about half a minute."
                         : "Not connected to a switch. If one is already in update mode (for example after an earlier attempt), search for it here; otherwise close this, connect, and start again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .searching:
                HStack { ProgressView(); Text(dfu.statusText) }
                Text(setupMode
                     ? "This searches for about half a minute. If nothing turns up, double-tap the reset button again and retry."
                     : "This searches for about half a minute. To back out, press the switch's reset button once; it restarts with its old firmware.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .choosing:
                Text(dfu.statusText).font(.subheadline)
                ForEach(dfu.candidates) { c in
                    Button {
                        dfu.select(c)
                    } label: {
                        HStack {
                            Text(c.name)
                            Spacer()
                            SignalBars(rssi: c.rssi)
                        }
                    }
                }
                Text("The strongest signal is listed first; that is almost always the switch next to you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .updating:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(dfu.progress), total: 100)
                    HStack {
                        Text(dfu.statusText)
                        Spacer()
                        Text("\(dfu.progress)%").monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            case .done:
                Label(setupMode
                      ? "Firmware installed. The board restarts as a switch - press its button once and it will appear on the home screen."
                      : "Update installed. The switch is restarting with its settings kept.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label("Update failed: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try again") {
                    flashedTag = selectedTag
                    if let packageURL { dfu.start(firmwareURL: packageURL) }
                }
                Text("The switch stays in update mode when an update fails, so retrying is safe. To back out entirely, press its reset button.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Install")
        }
    }

    // MARK: actions

    private func loadReleases() {
        guard releases.isEmpty else { return }
        loadingReleases = true
        Task {
            do { releases = try await ReleaseChecker.all() }
            catch { /* the version list just stays limited; file import still works */ }
            loadingReleases = false
            // Default to the latest (or newest available) and fetch it, so
            // the common case needs no extra taps.
            if selectedTag.isEmpty {
                selectedTag = latestRelease?.version ?? releases.first?.version ?? Self.fileTag
            }
        }
    }

    private func choose(_ tag: String) {
        errorText = nil
        if tag == Self.fileTag {
            packageURL = nil
            showFilePicker = true
            return
        }
        let release = (tag == latestRelease?.version ? latestRelease : nil)
            ?? releases.first { $0.version == tag }
        guard let release else {
            errorText = "That version isn't available to download."
            return
        }
        download(release)
    }

    private func download(_ release: FirmwareRelease) {
        downloading = true
        packageURL = nil
        packageLabel = "v\(release.version)"
        errorText = nil
        Task {
            do {
                packageURL = try await ReleaseChecker.download(release)
            } catch {
                errorText = "Download failed: \(error.localizedDescription)"
            }
            downloading = false
        }
    }

    private func handleFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                packageURL = dest
                packageLabel = url.lastPathComponent
                errorText = nil
            } catch {
                errorText = "Couldn't read that file: \(error.localizedDescription)"
            }
        case .failure:
            break
        }
    }
}
