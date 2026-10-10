import Foundation

/// One device's settings sync with one vault (docs/settings-sync.md §4): kept on
/// the device, never in the vault. The app stores it per vault and feeds it its
/// current values; this type decides what to apply and what to write, so the
/// rules are tested on Linux.
///
/// Local values are the device's *effective* values (defaults filled in) of the
/// settings it uses (`SharedSettingsCatalog.specs(for:)`), by key, in their
/// stored form (`SharedSettingSpec.validated`).
public struct SettingsSyncState: Hashable, Sendable, Codable {
    /// Sync is on for this vault on this device.
    public var enabled = false
    /// Keys the user chose "Only on This Device" for: neither applied nor written.
    public var overrides: Set<String> = []
    /// This device's merged copy of the shared settings (docs/settings-sync.md §3):
    /// written back when the file falls behind it.
    public var known = SharedSettings()
    /// The local value of each synced key after the last pass: a value that
    /// differs from it at the next pass is the user's edit.
    public var applied: [String: JSONValue] = [:]

    public init() {}

    /// Whether `key` is overridden on this device.
    public func isOverridden(_ key: String) -> Bool { overrides.contains(key) }

    /// How a row shows a setting (docs/settings-sync.md §4.3).
    public enum RowState: Hashable, Sendable {
        /// Follows the top level (or the default).
        case synced
        /// This device's type has its own value (its block).
        case typeSpecific
        /// Only on this device.
        case overridden
    }

    /// The row state of `key` on a device of `type`.
    public func rowState(_ key: String, type: SettingsDeviceType) -> RowState {
        if isOverridden(key) { return .overridden }
        guard let spec = SharedSettingsCatalog.spec(named: key) else { return .synced }
        return known.resolve(spec, for: type).source == .block ? .typeSpecific : .synced
    }

    /// What a pass decided.
    public struct Pass: Hashable, Sendable {
        /// Values to set on this device, by key.
        public var apply: [String: JSONValue] = [:]
        /// The settings to write to the vault's file; nil when the file is current.
        public var write: SharedSettings?
        /// Invalid values skipped while resolving (to log).
        public var warnings: [String] = []

        public init(apply: [String: JSONValue] = [:], write: SharedSettings? = nil, warnings: [String] = []) {
            self.apply = apply; self.write = write; self.warnings = warnings
        }
    }

    /// A setting whose vault value differs from this device's.
    public struct Difference: Hashable, Sendable {
        public var key: String
        public var vault: JSONValue
        public var device: JSONValue
    }

    /// What turning sync on finds (docs/settings-sync.md §4.2).
    public enum Discovery: Hashable, Sendable {
        /// The file has no slot of a setting this device uses: this device's values become the shared set.
        case empty
        /// The vault's values equal this device's (for every setting the vault has).
        case agrees
        /// These settings differ: ask the user.
        case differs([Difference])
    }

    /// How the user answered (or did not need to).
    public enum EnableChoice: Hashable, Sendable {
        /// Take the vault's values (also the answer for `.empty` and `.agrees`:
        /// settings the vault lacks are seeded from this device either way).
        case useVault
        /// Write every setting this device uses with its value.
        case replaceVault
    }

    /// Compares the vault's settings with this device's before sync is turned on.
    public static func discover(local: [String: JSONValue], file: SharedSettings?,
                                type: SettingsDeviceType) -> Discovery {
        let file = file ?? SharedSettings()
        let specs = SharedSettingsCatalog.specs(for: type)
        guard specs.contains(where: { file.hasSlot($0, block: nil) || file.hasSlot($0, block: type.rawValue) }) else { return .empty }
        var diffs: [Difference] = []
        for spec in specs {
            let r = file.resolve(spec, for: type)
            guard r.source != .default || file.hasSlot(spec, block: nil), let mine = local[spec.name] else { continue }
            if r.value != mine { diffs.append(Difference(key: spec.name, vault: r.value, device: mine)) }
        }
        return diffs.isEmpty ? .agrees : .differs(diffs)
    }

    /// Turns sync on: forgets overrides, takes `file` as the shared copy, and
    /// with `.replaceVault` (or an empty file) writes every setting this device
    /// uses with its value, where it resolves from; then runs a pass.
    public mutating func enable(_ choice: EnableChoice, local: [String: JSONValue], file: SharedSettings?,
                                type: SettingsDeviceType, now: Date) throws -> Pass {
        let replace = choice == .replaceVault || Self.discover(local: local, file: file, type: type) == .empty
        enabled = true
        overrides = []
        known = file ?? SharedSettings()
        applied = [:]
        for spec in SharedSettingsCatalog.specs(for: type) {
            guard let value = local[spec.name] else { continue }
            applied[spec.name] = value
            if replace { try known.write(spec, value, block: writeBlock(spec, type: type), type: type, now: now) }
        }
        return try reconcile(local: local, file: file, type: type, now: now)
    }

    /// Turns sync off: this device keeps its values; overrides and the shared copy are forgotten.
    public mutating func disable() {
        self = SettingsSyncState()
    }

    /// "Only on This Device": the setting keeps its value and leaves sync.
    public mutating func override(_ key: String) {
        overrides.insert(key)
        applied.removeValue(forKey: key)
    }

    /// "Use Synced Value": the setting rejoins sync; the pass applies the shared
    /// value, or seeds it from this device when the vault has none. The device's
    /// current value is not taken as an edit.
    public mutating func useSynced(_ key: String, local: [String: JSONValue], file: SharedSettings?,
                                   type: SettingsDeviceType, now: Date) throws -> Pass {
        overrides.remove(key)
        if let value = local[key] { applied[key] = value }
        return try reconcile(local: local, file: file, type: type, now: now)
    }

    /// "Only on iPads" (this device's type): the current value goes into the
    /// type's block. Ends an override of the key too.
    public mutating func onlyOnThisType(_ key: String, local: [String: JSONValue], file: SharedSettings?,
                                        type: SettingsDeviceType, now: Date) throws -> Pass {
        overrides.remove(key)
        if let file { known = known.merging(file) }
        if let value = local[key], let spec = SharedSettingsCatalog.spec(named: key) {
            applied[key] = value
            try known.write(spec, value, block: type.rawValue, type: type, now: now)
        }
        return try reconcile(local: local, file: file, type: type, now: now)
    }

    /// "Use on All Devices": resets the key in this type's block, so the top level applies.
    public mutating func useOnAllDevices(_ key: String, local: [String: JSONValue], file: SharedSettings?,
                                         type: SettingsDeviceType, now: Date) throws -> Pass {
        if let value = local[key] { applied[key] = value }
        if let file { known = known.merging(file) }
        if let spec = SharedSettingsCatalog.spec(named: key), known.latestSlot(spec, block: type.rawValue)?.1.value != nil {
            try known.write(spec, nil, block: type.rawValue, type: type, now: now)
        }
        return try reconcile(local: local, file: file, type: type, now: now)
    }

    /// The block an edit of `spec` on a device of `type` writes: its type's when
    /// the setting resolves from there, else the top level (nil).
    func writeBlock(_ spec: SharedSettingSpec, type: SettingsDeviceType) -> String? {
        known.resolve(spec, for: type).source == .block ? type.rawValue : nil
    }

    /// One sync pass (docs/settings-sync.md §4.4): merges `file` (nil when the
    /// vault has none, or it could not be read and is to be replaced) into the
    /// shared copy, turns local edits of synced settings into shared values (in
    /// the slot they resolve from), seeds settings the vault lacks at the top
    /// level, and says which values to apply here and whether the file must be
    /// written. Does nothing while sync is off. `file` is compared after
    /// migration: a migration alone never causes a write.
    public mutating func reconcile(local: [String: JSONValue], file: SharedSettings?,
                                   type: SettingsDeviceType, now: Date) throws -> Pass {
        guard enabled else { return Pass() }
        if let file { known = known.merging(file) }
        let synced = SharedSettingsCatalog.specs(for: type).filter { !isOverridden($0.name) }
        for spec in synced {
            guard let mine = local[spec.name] else { continue }
            if let last = applied[spec.name], last != mine {
                try known.write(spec, mine, block: writeBlock(spec, type: type), type: type, now: now)   // edited here
            } else if !known.hasSlot(spec, block: nil), !known.hasSlot(spec, block: type.rawValue) {
                try known.write(spec, mine, block: nil, type: type, now: now)    // the vault has none yet
            }
        }
        var pass = Pass()
        applied = [:]
        for spec in synced {
            let r = known.resolve(spec, for: type)
            pass.warnings += r.warnings
            if local[spec.name] != r.value { pass.apply[spec.name] = r.value }
            applied[spec.name] = r.value
        }
        if file != known { pass.write = known }
        return pass
    }
}
