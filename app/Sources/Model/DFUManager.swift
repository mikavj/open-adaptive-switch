// Open Adaptive Switch - firmware updates over BLE.
//
// Wraps Nordic's open-source DFU library (BSD-3-Clause), which speaks the
// legacy DFU protocol the Adafruit bootloader implements. After the app
// sends the enter-update-mode command, the switch reboots into its
// bootloader and advertises the DFU service under a different address;
// this manager finds it and streams the release .zip.
//
// The bootloader's address differs from the switch's, so the target
// can't be matched by identity. Instead, discoveries are collected for a
// short window: exactly one device in update mode starts automatically,
// several (a classroom, a stale failed update nearby) make the user pick,
// so the wrong switch never gets flashed silently.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import CoreBluetooth
import NordicDFU
import SwiftUI

struct DFUCandidate: Identifiable {
    let identifier: UUID
    var name: String
    var rssi: Int
    var id: UUID { identifier }
}

@MainActor
final class DFUManager: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case searching        // scanning for a device in update mode
        case choosing         // more than one device in update mode nearby
        case updating
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var candidates: [DFUCandidate] = []
    @Published var progress: Int = 0          // 0-100
    @Published var speedKBps: Double = 0
    @Published var statusText = ""

    private var central: CBCentralManager?
    private var firmwareURL: URL?
    private var controller: DFUServiceController?
    private var settleTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private let settleSeconds: Double = 2.5   // wait for all nearby DFU devices to appear
    private let searchTimeoutSeconds: Double = 30

    // Scan for a switch in update mode, then stream the package to it.
    func start(firmwareURL: URL) {
        self.firmwareURL = firmwareURL
        candidates = []
        progress = 0
        phase = .searching
        statusText = "Looking for the switch in update mode..."
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: [SwitchBLE.dfuService])
        }
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.searchTimeoutSeconds ?? 30))
            guard let self, !Task.isCancelled else { return }
            if self.phase == .searching {
                self.central?.stopScan()
                self.phase = .failed("No switch in update mode was found nearby.")
            }
        }
    }

    // User picked one of several candidates.
    func select(_ candidate: DFUCandidate) {
        guard phase == .choosing else { return }
        central?.stopScan()
        beginDFU(to: candidate.identifier)
    }

    func cancel() {
        _ = controller?.abort()
        settleTask?.cancel()
        timeoutTask?.cancel()
        central?.stopScan()
        central = nil
        if phase == .searching || phase == .choosing || phase == .updating {
            phase = .idle
            statusText = ""
        }
    }

    // Called when the discovery window closes: one candidate proceeds,
    // several ask the user.
    private func settle() {
        guard phase == .searching else { return }
        if candidates.count == 1 {
            central?.stopScan()
            beginDFU(to: candidates[0].identifier)
        } else if candidates.count > 1 {
            phase = .choosing
            statusText = "More than one switch is in update mode. Pick the one to update."
        }
    }

    private func beginDFU(to identifier: UUID) {
        guard let firmwareURL else { return }
        timeoutTask?.cancel()
        let firmware: DFUFirmware
        do {
            firmware = try DFUFirmware(urlToZipFile: firmwareURL)
        } catch {
            phase = .failed("Couldn't read the update package: \(error.localizedDescription)")
            return
        }
        phase = .updating
        statusText = "Sending firmware..."
        let initiator = DFUServiceInitiator(queue: .main)
        initiator.delegate = self
        initiator.progressDelegate = self
        // iOS sends 20-byte packets to legacy bootloaders; keep receipt
        // notifications at 8 or the bootloader can run out of memory
        // (Adafruit bootloader guidance).
        initiator.packetReceiptNotificationParameter = 8
        controller = initiator.with(firmware: firmware).start(targetWithIdentifier: identifier)
    }
}

extension DFUManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            guard state == .poweredOn, self.phase == .searching else { return }
            central.scanForPeripherals(withServices: [SwitchBLE.dfuService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard self.phase == .searching || self.phase == .choosing else { return }
            let name = advName ?? peripheral.name ?? "Device in update mode"
            if let i = self.candidates.firstIndex(where: { $0.identifier == peripheral.identifier }) {
                self.candidates[i].rssi = rssi
                self.candidates[i].name = name
            } else {
                self.candidates.append(
                    DFUCandidate(identifier: peripheral.identifier, name: name, rssi: rssi))
                self.candidates.sort { $0.rssi > $1.rssi }
            }
            // First sighting opens the settle window.
            if self.settleTask == nil && self.phase == .searching {
                self.settleTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.settleSeconds ?? 2.5))
                    guard let self, !Task.isCancelled else { return }
                    self.settleTask = nil
                    self.settle()
                }
            }
        }
    }
}

extension DFUManager: DFUServiceDelegate, DFUProgressDelegate {

    nonisolated func dfuStateDidChange(to state: DFUState) {
        Task { @MainActor in
            switch state {
            case .completed:
                self.phase = .done
                self.statusText = "Update installed. The switch is restarting."
            case .aborted:
                self.phase = .idle
                self.statusText = ""
            case .connecting:
                self.statusText = "Connecting to the switch..."
            case .starting, .enablingDfuMode:
                self.statusText = "Starting the update..."
            case .uploading:
                self.statusText = "Sending firmware..."
            case .validating:
                self.statusText = "Checking the transfer..."
            case .disconnecting:
                self.statusText = "Finishing up..."
            }
        }
    }

    nonisolated func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        Task { @MainActor in
            // A late library error after success or after the user backed
            // out must not clobber the outcome the user already saw.
            guard self.phase == .updating || self.phase == .searching else { return }
            self.phase = .failed(message)
        }
    }

    nonisolated func dfuProgressDidChange(for part: Int, outOf totalParts: Int,
                                          to progress: Int,
                                          currentSpeedBytesPerSecond: Double,
                                          avgSpeedBytesPerSecond: Double) {
        Task { @MainActor in
            self.progress = progress
            self.speedKBps = avgSpeedBytesPerSecond / 1024.0
        }
    }
}
