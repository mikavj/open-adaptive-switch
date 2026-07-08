// Open Adaptive Switch - CoreBluetooth connection and configuration.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import CoreBluetooth
import SwiftUI

struct DiscoveredSwitch: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var id: UUID { peripheral.identifier }
}

@MainActor
final class SwitchManager: NSObject, ObservableObject {

    enum Phase: Equatable {
        case bluetoothOff
        case unauthorized
        case idle
        case scanning
        case connecting
        case loading      // connected, reading initial values
        case ready
    }

    @Published var phase: Phase = .idle
    @Published var discovered: [DiscoveredSwitch] = []
    @Published var config = SwitchConfig()
    @Published var battery: BatteryReading?
    @Published var firmwareVersion: String?
    @Published var lastError: String?
    @Published var savedPulse = 0   // increments on confirmed writes, for UI feedback

    // The firmware updater is presented from the root view, not the
    // device screen: entering update mode disconnects the switch, which
    // pops the device screen, and a sheet attached there would be torn
    // down mid-update.
    @Published var updaterPresented = false
    @Published var latestRelease: FirmwareRelease?

    // Set before an intentional disconnect (restart, factory reset,
    // update mode) so the UI doesn't treat it as a failure.
    private var expectedDisconnect = false
    private(set) var enteredUpdateMode = false

    // Created on the first scan, not at init: creating a CBCentralManager
    // is what triggers the system Bluetooth permission dialog, and the
    // first-launch screen should explain why before it appears.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    // Reads still outstanding before the device screen can show. Tracked
    // by UUID, not by count: the battery characteristic also notifies,
    // and a notification arriving during loading must not double-count.
    private var pendingReads: Set<CBUUID> = []
    private var connectTimeout: Task<Void, Never>?

    // MARK: scanning

    func startScan() {
        guard let central = ensureCentral() else { return }
        guard central.state == .poweredOn else { return }
        discovered = []
        phase = .scanning
        central.scanForPeripherals(
            withServices: [SwitchBLE.configService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central?.stopScan()
        if phase == .scanning { phase = .idle }
    }

    private func ensureCentral() -> CBCentralManager? {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        return central
    }

    // MARK: connection

    func connect(_ item: DiscoveredSwitch) {
        guard let central else { return }
        stopScan()
        phase = .connecting
        lastError = nil
        enteredUpdateMode = false
        expectedDisconnect = false
        pendingReads = []
        peripheral = item.peripheral
        item.peripheral.delegate = self
        central.connect(item.peripheral)
        // CoreBluetooth connect attempts never time out on their own; a
        // stale list entry (switch went to sleep) would hang here forever.
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            if self.phase == .connecting || self.phase == .loading {
                if let p = self.peripheral { central.cancelPeripheralConnection(p) }
                self.peripheral = nil
                self.lastError = "The switch didn't answer. Press its button to wake it, then try again."
                self.phase = .idle
                self.startScan()
            }
        }
    }

    // Called when the firmware-update sheet closes, whatever the outcome:
    // resume normal scanning so the (restarted) switch reappears.
    func updateFlowEnded() {
        enteredUpdateMode = false
        if phase == .idle { startScan() }
    }

    func disconnect() {
        expectedDisconnect = true
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
    }

    var connectedName: String {
        if let n = peripheral?.name, !n.isEmpty { return n }
        return config.name.isEmpty ? "Switch" : config.name
    }

    // MARK: writes

    func save(mode: SwitchMode) {
        config.mode = mode
        write(SwitchBLE.modeChar, Data([mode.rawValue]))
    }

    func save(binding: KeyBinding, slot: Int) {
        guard (0..<3).contains(slot) else { return }
        config.bindings[slot] = binding
        write(SwitchBLE.keymapChar, config.keymapData)
    }

    func save(sleepMinutes: UInt16) {
        config.sleepMinutes = sleepMinutes
        write(SwitchBLE.sleepChar, Data([UInt8(sleepMinutes & 0xFF), UInt8(sleepMinutes >> 8)]))
    }

    func save(accent: AccentColorSetting) {
        config.accent = accent
        write(SwitchBLE.accentChar, Data([accent.rawValue]))
    }

    // Returns the name as actually stored (possibly shortened to fit 15 bytes).
    @discardableResult
    func save(name: String) -> String {
        let data = encodeSwitchName(name)
        guard !data.isEmpty else { return config.name }
        write(SwitchBLE.nameChar, data)
        let stored = String(decoding: data, as: UTF8.self)
        config.name = stored
        return stored
    }

    func send(_ command: SwitchCommand) {
        if command != .enterUpdateMode {
            expectedDisconnect = true
        }
        if command == .enterUpdateMode {
            expectedDisconnect = true
            enteredUpdateMode = true
        }
        write(SwitchBLE.commandChar, Data([command.rawValue]))
    }

    private func write(_ uuid: CBUUID, _ data: Data) {
        guard let p = peripheral, let c = chars[uuid] else {
            lastError = "Not connected."
            return
        }
        p.writeValue(data, for: c, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension SwitchManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            switch state {
            case .poweredOn:
                if self.phase == .bluetoothOff || self.phase == .unauthorized {
                    self.phase = .idle
                }
                self.startScan()
            case .unauthorized:
                self.phase = .unauthorized
            case .poweredOff:
                self.phase = .bluetoothOff
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        Task { @MainActor in
            let name = advName ?? peripheral.name ?? "Switch"
            if let i = self.discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.discovered[i].rssi = rssi
                self.discovered[i].name = name
            } else {
                self.discovered.append(DiscoveredSwitch(peripheral: peripheral, name: name, rssi: rssi))
                self.discovered.sort { $0.rssi > $1.rssi }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.phase = .loading
            peripheral.discoverServices([SwitchBLE.configService, SwitchBLE.deviceInfoService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.connectTimeout?.cancel()
            self.lastError = message ?? "Connection failed. Wake the switch and try again."
            self.phase = .idle
            self.peripheral = nil
            self.startScan()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.connectTimeout?.cancel()
            let wasExpected = self.expectedDisconnect
            self.expectedDisconnect = false
            self.peripheral = nil
            self.chars = [:]
            self.pendingReads = []
            self.battery = nil
            self.firmwareVersion = nil
            self.phase = .idle
            if !wasExpected {
                self.lastError = message ?? "The switch disconnected."
            }
            if !self.enteredUpdateMode {
                self.startScan()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension SwitchManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil, let services = peripheral.services else {
                self.failLoad(error)
                return
            }
            for s in services {
                if s.uuid == SwitchBLE.configService {
                    peripheral.discoverCharacteristics([
                        SwitchBLE.modeChar, SwitchBLE.keymapChar, SwitchBLE.sleepChar,
                        SwitchBLE.nameChar, SwitchBLE.batteryChar, SwitchBLE.commandChar,
                        SwitchBLE.accentChar,
                    ], for: s)
                } else if s.uuid == SwitchBLE.deviceInfoService {
                    peripheral.discoverCharacteristics([SwitchBLE.firmwareRevChar], for: s)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil, let found = service.characteristics else {
                self.failLoad(error)
                return
            }
            for c in found {
                self.chars[c.uuid] = c
            }
            if service.uuid == SwitchBLE.configService {
                // Read everything once, subscribe to battery pushes.
                for uuid in [SwitchBLE.modeChar, SwitchBLE.keymapChar, SwitchBLE.sleepChar,
                             SwitchBLE.nameChar, SwitchBLE.batteryChar, SwitchBLE.accentChar] {
                    if let c = self.chars[uuid] {
                        self.pendingReads.insert(uuid)
                        peripheral.readValue(for: c)
                    }
                }
                if let c = self.chars[SwitchBLE.batteryChar] {
                    peripheral.setNotifyValue(true, for: c)
                }
            } else if service.uuid == SwitchBLE.deviceInfoService {
                if let c = self.chars[SwitchBLE.firmwareRevChar] {
                    peripheral.readValue(for: c)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let data = characteristic.value
        Task { @MainActor in
            // Even a failed read must clear its pending slot, or one
            // transient GATT error would strand the app in loading.
            if self.phase == .loading {
                self.pendingReads.remove(uuid)
                if self.pendingReads.isEmpty {
                    self.phase = .ready
                }
            }
            guard error == nil, let data else { return }
            self.apply(uuid: uuid, data: data)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message {
                self.lastError = "Saving failed: \(message)"
                // Re-read so the UI shows what the switch really has.
                // (Not the command characteristic - the firmware forbids
                // reading it.)
                if uuid != SwitchBLE.commandChar, let c = self.chars[uuid] {
                    self.peripheral?.readValue(for: c)
                }
            } else if uuid != SwitchBLE.commandChar {
                self.savedPulse += 1
            }
        }
    }

    private func apply(uuid: CBUUID, data: Data) {
        switch uuid {
        case SwitchBLE.modeChar:
            if let raw = data.first, let m = SwitchMode(rawValue: raw) { config.mode = m }
        case SwitchBLE.keymapChar:
            if let b = SwitchConfig.bindings(from: data) { config.bindings = b }
        case SwitchBLE.sleepChar:
            if data.count >= 2 {
                config.sleepMinutes = UInt16(data[0]) | (UInt16(data[1]) << 8)
            }
        case SwitchBLE.nameChar:
            config.name = String(decoding: data, as: UTF8.self)
        case SwitchBLE.batteryChar:
            battery = BatteryReading(data: data)
        case SwitchBLE.accentChar:
            if let raw = data.first, let a = AccentColorSetting(rawValue: raw) { config.accent = a }
        case SwitchBLE.firmwareRevChar:
            firmwareVersion = String(decoding: data, as: UTF8.self)
        default:
            break
        }
    }

    private func failLoad(_ error: Error?) {
        lastError = error?.localizedDescription ?? "Couldn't read the switch's settings."
        disconnect()
    }
}
