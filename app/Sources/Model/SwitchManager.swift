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
    var battery: UInt8?        // percent, from advertised manufacturer data
    var charging: Bool = false
    var id: UUID { peripheral.identifier }
}

// Parse the switch's advertised manufacturer data: [0xFF, 0xFF, percent,
// state]. Returns nil for anything else.
private func parseAdvBattery(_ data: Data?) -> (percent: UInt8, charging: Bool)? {
    guard let data, data.count >= 4, data[0] == 0xFF, data[1] == 0xFF else { return nil }
    let pct = min(data[2], 100)
    let charging = data[3] == 1 || data[3] == 2
    return (pct, charging)
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

    // Shown as a banner on the device screen the first time a switch
    // connects, if the user has set up a default configuration.
    @Published var offerDefaultSetup = false

    // Set before an intentional disconnect (restart, factory reset,
    // update mode) so the UI doesn't treat it as a failure. Readable so
    // views can skip writes into a connection that's already closing.
    private(set) var expectedDisconnect = false
    private(set) var enteredUpdateMode = false

    // True while the pretend switch is "connected". Writes stay on the
    // phone and nothing is remembered in the store.
    private(set) var isDemo = false

    // Remembered switches, profiles, and the default setup. The manager
    // keeps snapshots in it as configuration changes arrive.
    let store: SwitchStore

    // True when the switch being connected isn't in the store yet;
    // decided at connect time, consumed when loading finishes.
    private var connectingToNewSwitch = false

    init(store: SwitchStore) {
        self.store = store
        super.init()
    }

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
        guard !isDemo else { return }
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
        offerDefaultSetup = false
        connectingToNewSwitch = !store.knows(item.id)
        // Start from a clean slate: if an initial read fails, the
        // snapshot must not inherit the previous switch's values.
        config = SwitchConfig()
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
        if isDemo {
            endDemo()
            return
        }
        expectedDisconnect = true
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
    }

    var connectedName: String {
        if let n = peripheral?.name, !n.isEmpty { return n }
        return config.name.isEmpty ? "Switch" : config.name
    }

    var connectedID: UUID? {
        if isDemo { return Self.demoID }
        return peripheral?.identifier
    }

    // MARK: demo switch

    // A fixed id so the demo keeps its dome color between visits and
    // never collides with a real peripheral.
    static let demoID = UUID(uuidString: "0000DEED-0000-0000-0000-000000000000")!

    // A pretend switch for people who don't have the hardware in hand
    // yet. Every control works; changes stay on the phone.
    func startDemo() {
        stopScan()
        isDemo = true
        lastError = nil
        offerDefaultSetup = false
        config = SwitchConfig(
            mode: .tapHold,
            bindings: [KeyBinding(keycode: 0x68), KeyBinding(keycode: 0x69), KeyBinding()],
            sleepMinutes: 30, name: "Demo Switch", accent: .blue)
        firmwareVersion = latestRelease?.version ?? "3.1.2"
        battery = BatteryReading(millivolts: 4010, percent: 84, state: .onBattery)
        phase = .ready
    }

    private func endDemo() {
        isDemo = false
        battery = nil
        firmwareVersion = nil
        config = SwitchConfig()
        // Land on whatever the radio actually allows; Bluetooth may have
        // been switched off while the demo (which needs none) was up.
        switch central?.state {
        case .poweredOff:
            phase = .bluetoothOff
        case .unauthorized:
            phase = .unauthorized
        default:
            phase = .idle
            startScan()
        }
    }

    // MARK: release lookup (shared by the home screen badges and the
    // device screen)

    func refreshLatestRelease() async {
        guard latestRelease == nil else { return }
        latestRelease = try? await ReleaseChecker.latest()
    }

    // True when a remembered switch was last seen on something older
    // than the newest published firmware.
    func updateAvailable(for entry: SavedSwitch) -> Bool {
        guard let latest = latestRelease, let fw = entry.firmwareVersion else { return false }
        return ReleaseChecker.compare(latest.version, fw) > 0
    }

    // MARK: store snapshots

    // Keep the remembered-switch entry in step with what's on the
    // switch. Called once loading finishes and again as values change.
    private func syncSnapshot() {
        guard !isDemo, phase == .ready, let id = peripheral?.identifier else { return }
        let adopted = store.touch(
            id: id, name: config.name, firmwareVersion: firmwareVersion,
            config: config,
            colorHex: UserDefaults.standard.string(forKey: "dome.\(id.uuidString)"))
        if adopted {
            // A backup entry adopted by name is this same switch restored
            // from another device, not a first-time connection - don't
            // offer to overwrite its restored settings with the default.
            connectingToNewSwitch = false
            offerDefaultSetup = false
        }
    }

    // MARK: dome color (per switch, cosmetic, stored on the phone)

    // Bumped when a color changes so views observing the manager refresh.
    @Published private var domeVersion = 0

    func domeColor(for id: UUID) -> Color {
        if let hex = UserDefaults.standard.string(forKey: "dome.\(id.uuidString)"),
           let c = Color(hex: hex) { return c }
        return .red
    }

    func setDomeColor(_ color: Color, for id: UUID) {
        UserDefaults.standard.set(color.hexString, forKey: "dome.\(id.uuidString)")
        store.setColor(hex: color.hexString, for: id)
        domeVersion += 1
    }

    // MARK: previous firmware version (per switch, for rollback)

    // Stored per device so rolling back one switch can't target the
    // version that was on a different switch.
    func previousVersion(for id: UUID) -> String {
        UserDefaults.standard.string(forKey: "prevfw.\(id.uuidString)") ?? ""
    }

    func setPreviousVersion(_ version: String, for id: UUID) {
        UserDefaults.standard.set(version, forKey: "prevfw.\(id.uuidString)")
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

    func save(bindings: [KeyBinding]) {
        config.bindings = Array((bindings + [KeyBinding(), KeyBinding(), KeyBinding()]).prefix(3))
        write(SwitchBLE.keymapChar, config.keymapData)
    }

    // Write a whole prepared configuration (default setup or profile) to
    // the connected switch. The name stays as it is; it identifies the
    // switch rather than being part of a setup.
    func apply(_ preset: SwitchConfig) {
        save(mode: preset.mode)
        save(bindings: preset.bindings)
        save(sleepMinutes: preset.sleepMinutes)
        save(accent: preset.accent)
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
        if isDemo {
            // Restart and factory reset drop the connection on real
            // hardware; the demo mirrors that by ending.
            endDemo()
            return
        }
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
        if isDemo {
            // The save methods already updated config; just confirm.
            savedPulse += 1
            return
        }
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
                // The demo needs no radio; don't let a state change pop
                // its screen (endDemo picks the right phase afterwards).
                if !self.isDemo { self.phase = .unauthorized }
            case .poweredOff:
                if !self.isDemo { self.phase = .bluetoothOff }
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
        let batt = parseAdvBattery(advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        Task { @MainActor in
            let name = advName ?? peripheral.name ?? "Switch"
            if let i = self.discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.discovered[i].rssi = rssi
                self.discovered[i].name = name
                if let batt {
                    self.discovered[i].battery = batt.percent
                    self.discovered[i].charging = batt.charging
                }
            } else {
                self.discovered.append(DiscoveredSwitch(
                    peripheral: peripheral, name: name, rssi: rssi,
                    battery: batt?.percent, charging: batt?.charging ?? false))
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
            // Stamp "last connected" as the moment the link ended.
            self.syncSnapshot()
            let wasExpected = self.expectedDisconnect
            self.expectedDisconnect = false
            self.offerDefaultSetup = false
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
                    self.finishLoading()
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
                self.syncSnapshot()
            }
        }
    }

    // Runs once per connection, when the initial reads are all in.
    private func finishLoading() {
        syncSnapshot()
        if connectingToNewSwitch, store.defaultConfig != nil, !isDemo {
            offerDefaultSetup = true
        }
        connectingToNewSwitch = false
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
        // Reads can land after loading finished (the device-info read
        // races the config reads); keep the remembered snapshot current.
        // Battery pushes arrive constantly and aren't part of it.
        if uuid != SwitchBLE.batteryChar {
            syncSnapshot()
        }
    }

    private func failLoad(_ error: Error?) {
        lastError = error?.localizedDescription ?? "Couldn't read the switch's settings."
        disconnect()
    }
}
