// Open Adaptive Switch - remembered switches, profiles, and the default
// setup, stored on the phone as JSON in UserDefaults.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import Foundation

// Snapshot of a switch the app has connected to, kept so the home screen
// can list it later and show what was configured, even when the switch
// is asleep or out of range.
struct SavedSwitch: Codable, Identifiable, Equatable {
    var id: UUID               // the identifier iOS assigns this peripheral
    var name: String
    var colorHex: String?      // dome color chosen in the app
    var lastConnected: Date
    var firmwareVersion: String?
    var config: SwitchConfig
    // True for entries restored from a backup that haven't connected on
    // this device yet. Their ids come from another phone and can never
    // match, so a first connection may adopt them by name. Optional so
    // files and stores from before the flag still decode.
    var imported: Bool?
    // The id this entry had in the backup it came from, kept after
    // adoption so importing the same file again doesn't resurrect it.
    var originalID: UUID?
}

// A named configuration prepared in the app's settings, to apply to any
// connected switch.
struct SwitchProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var config = SwitchConfig()
}

@MainActor
final class SwitchStore: ObservableObject {

    @Published private(set) var saved: [SavedSwitch]

    // Written through bindings by the profile editor, so the setter is
    // public and persistence hangs off didSet.
    @Published var profiles: [SwitchProfile] {
        didSet { persist(profiles, key: Self.profilesKey) }
    }

    // nil means the user hasn't set up a default; the first-connection
    // offer only appears once this exists.
    @Published var defaultConfig: SwitchConfig? {
        didSet { persist(defaultConfig, key: Self.defaultKey) }
    }

    private static let savedKey = "saved.switches"
    private static let profilesKey = "saved.profiles"
    private static let defaultKey = "saved.defaultConfig"

    private let defaults = UserDefaults.standard

    init() {
        saved = Self.load([SavedSwitch].self, key: Self.savedKey) ?? []
        profiles = Self.load([SwitchProfile].self, key: Self.profilesKey) ?? []
        defaultConfig = Self.load(SwitchConfig.self, key: Self.defaultKey)
    }

    // MARK: remembered switches

    func knows(_ id: UUID) -> Bool {
        saved.contains { $0.id == id }
    }

    func savedSwitch(for id: UUID) -> SavedSwitch? {
        saved.first { $0.id == id }
    }

    // Upsert the snapshot for a switch and mark it as connected now.
    // A nil colorHex keeps whatever color was already stored. Returns
    // true when the entry was adopted from a backup made on another
    // device, so the caller can skip first-connection treatment.
    @discardableResult
    func touch(id: UUID, name: String, firmwareVersion: String?, config: SwitchConfig,
               colorHex: String?) -> Bool {
        // A nameless snapshot of an unknown switch (its name read failed)
        // has nothing to show and creating it would burn the one-shot
        // adoption below; wait for a snapshot that knows the name.
        if !knows(id), name.isEmpty { return false }

        // iOS assigns each phone its own id for the same physical switch,
        // so an entry restored from another device's backup can never
        // match by id. Adopt it by name on first connection instead of
        // leaving a duplicate behind. Only imported entries qualify -
        // switches that connected on this phone keep separate histories.
        // Should several imports share the name, take the most recent:
        // the live values overwrite the snapshot right below, so a
        // mispick costs a dome color at worst, while refusing would
        // leave ghosts no later connection could clear.
        var adoptedFromBackup = false
        if !knows(id) {
            let matches = saved.filter { $0.imported == true && $0.name == name }
            if let orphan = matches.max(by: { $0.lastConnected < $1.lastConnected }) {
                saved.removeAll { $0.id == orphan.id }
                var adopted = orphan
                adopted.originalID = orphan.originalID ?? orphan.id
                adopted.id = id
                if adopted.colorHex != nil, colorHex == nil {
                    UserDefaults.standard.set(adopted.colorHex, forKey: "dome.\(id.uuidString)")
                }
                saved.append(adopted)
                adoptedFromBackup = true
            }
        }

        var entry = savedSwitch(for: id) ?? SavedSwitch(
            id: id, name: name, colorHex: colorHex, lastConnected: .now,
            firmwareVersion: firmwareVersion, config: config)
        entry.name = name.isEmpty ? entry.name : name
        entry.lastConnected = .now
        entry.config = config
        entry.imported = nil   // it has connected here now
        if let firmwareVersion { entry.firmwareVersion = firmwareVersion }
        if let colorHex { entry.colorHex = colorHex }
        saved.removeAll { $0.id == id }
        saved.append(entry)
        saved.sort { $0.lastConnected > $1.lastConnected }
        persist(saved, key: Self.savedKey)
        return adoptedFromBackup
    }

    func setColor(hex: String, for id: UUID) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].colorHex = hex
        persist(saved, key: Self.savedKey)
    }

    // Called when a firmware update finishes, so the home-screen badge
    // clears without needing another connection. nil means "unknown"
    // (a package from a file has no version the app can trust).
    func setFirmwareVersion(_ version: String?, for id: UUID) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].firmwareVersion = version
        persist(saved, key: Self.savedKey)
    }

    func forget(id: UUID) {
        saved.removeAll { $0.id == id }
        persist(saved, key: Self.savedKey)
        defaults.removeObject(forKey: "dome.\(id.uuidString)")
        defaults.removeObject(forKey: "prevfw.\(id.uuidString)")
    }

    func forgetAll() {
        // Sweep by prefix, not by the saved list: colors and rollback
        // versions written by app 1.0 exist for switches that never made
        // it into the store.
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("dome.") || key.hasPrefix("prevfw.") {
            defaults.removeObject(forKey: key)
        }
        saved = []
        persist(saved, key: Self.savedKey)
    }

    // Wipe everything the app has stored on this phone, including
    // preferences. Settings stored on switches themselves are untouched.
    func eraseAllData() {
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        saved = []
        profiles = []
        defaultConfig = nil
    }

    // MARK: export / import

    private struct Backup: Codable {
        var format = 1
        var exported: Date
        var switches: [SavedSwitch]
        var profiles: [SwitchProfile]
        var defaultConfig: SwitchConfig?
    }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Backup(
            exported: .now, switches: saved, profiles: profiles,
            defaultConfig: defaultConfig))
    }

    // Merges the file into what's already here: entries with the same id
    // are replaced, everything else is kept. Returns a short summary for
    // the confirmation alert.
    func importJSON(_ data: Data) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)

        for var entry in backup.switches {
            if let existing = savedSwitch(for: entry.id) {
                // Same device (or the same file twice): overwrite by id.
                // An entry that still hasn't connected here stays
                // adoptable; one that has stays settled.
                entry.imported = existing.imported == true ? true : nil
                entry.originalID = existing.originalID ?? entry.originalID
                saved.removeAll { $0.id == entry.id }
                saved.append(entry)
                if let hex = entry.colorHex {
                    defaults.set(hex, forKey: "dome.\(entry.id.uuidString)")
                }
            } else if saved.contains(where: { $0.originalID == entry.id }) {
                // Already adopted here under a local id; the live entry
                // is authoritative, so re-importing must not resurrect
                // the backup copy as a duplicate.
                continue
            } else if !entry.name.isEmpty,
                      case let locals = saved.indices.filter({
                          saved[$0].imported != true && saved[$0].name == entry.name
                              // A local that already absorbed a backup
                              // entry can't take a second one - that
                              // would silently discard another switch.
                              && (saved[$0].originalID == nil
                                  || saved[$0].originalID == entry.id)
                      }),
                      locals.count == 1, let i = locals.first {
                // The switch already connected on this phone before the
                // backup arrived: fold the backup entry into the live
                // one instead of adding a ghost. The live settings came
                // off the switch itself, so only the cosmetic color is
                // taken, and only when none was picked here yet.
                if saved[i].colorHex == nil, let hex = entry.colorHex {
                    saved[i].colorHex = hex
                    defaults.set(hex, forKey: "dome.\(saved[i].id.uuidString)")
                }
                saved[i].originalID = saved[i].originalID ?? entry.id
            } else {
                // Unknown here: keep it listed and flagged so the first
                // connection can adopt it by name.
                entry.imported = true
                saved.append(entry)
                if let hex = entry.colorHex {
                    defaults.set(hex, forKey: "dome.\(entry.id.uuidString)")
                }
            }
        }
        saved.sort { $0.lastConnected > $1.lastConnected }
        persist(saved, key: Self.savedKey)

        for profile in backup.profiles {
            profiles.removeAll { $0.id == profile.id }
            profiles.append(profile)
        }
        if let imported = backup.defaultConfig { defaultConfig = imported }

        var parts = ["\(backup.switches.count) switch\(backup.switches.count == 1 ? "" : "es")",
                     "\(backup.profiles.count) profile\(backup.profiles.count == 1 ? "" : "s")"]
        if backup.defaultConfig != nil { parts.append("the default configuration") }
        return "Imported " + parts.joined(separator: ", ") + "."
    }

    // MARK: persistence

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func persist<T: Encodable>(_ value: T?, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
