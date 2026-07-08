// Open Adaptive Switch - guided firmware update.
//
// Flow: pick a package (latest release or a local file), put the switch
// into update mode, find it advertising as a DFU target, stream the
// package, done. Settings on the switch survive.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI
import UniformTypeIdentifiers

struct FirmwareUpdateView: View {
    @EnvironmentObject var manager: SwitchManager
    @StateObject private var dfu = DFUManager()
    @Environment(\.dismiss) private var dismiss

    let latestRelease: FirmwareRelease?

    @State private var packageURL: URL?
    @State private var downloading = false
    @State private var showFilePicker = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                stepPackage
                if packageURL != nil { stepInstall }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Firmware update")
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
                          allowedContentTypes: [UTType.zip]) { result in
                switch result {
                case .success(let url):
                    // Copy out of the security-scoped location so the DFU
                    // library can read it later.
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        packageURL = dest
                        errorText = nil
                    } catch {
                        errorText = "Couldn't read that file: \(error.localizedDescription)"
                    }
                case .failure:
                    break
                }
            }
        }
        .interactiveDismissDisabled(dfu.phase == .updating)
    }

    private var stepPackage: some View {
        Section("1. Update package") {
            if let packageURL {
                Label(packageURL.lastPathComponent, systemImage: "doc.zipper")
                Button("Choose a different file") { showFilePicker = true }
            } else {
                if let latestRelease {
                    Button {
                        downloadRelease(latestRelease)
                    } label: {
                        if downloading {
                            HStack {
                                ProgressView()
                                Text("Downloading \(latestRelease.zipName)...")
                            }
                        } else {
                            Label("Download v\(latestRelease.version)", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(downloading)
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label("Choose a .zip from Files", systemImage: "folder")
                }
            }
        }
    }

    private var stepInstall: some View {
        Section("2. Install") {
            switch dfu.phase {
            case .idle:
                if manager.phase == .ready {
                    Button {
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
                        if let packageURL { dfu.start(firmwareURL: packageURL) }
                    } label: {
                        Label("Find a switch already in update mode", systemImage: "magnifyingglass")
                    }
                    Text("Not connected to a switch. If one is already in update mode (for example after an earlier attempt), search for it here; otherwise close this, connect, and start again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .searching:
                HStack {
                    ProgressView()
                    Text(dfu.statusText)
                }
                Text("This searches for about half a minute. To back out, press the switch's reset button once; it restarts with its old firmware.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .choosing:
                Text(dfu.statusText)
                    .font(.subheadline)
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
                        Text("\(dfu.progress)%")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            case .done:
                Label("Update installed. The switch is restarting with its settings kept.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label("Update failed: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try again") {
                    if let packageURL { dfu.start(firmwareURL: packageURL) }
                }
                Text("The switch stays in update mode when an update fails, so retrying is safe. To back out entirely, press its reset button.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadRelease(_ release: FirmwareRelease) {
        downloading = true
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
}
