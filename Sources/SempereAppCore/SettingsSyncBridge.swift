import Foundation
import Sempere

/// Why settings sync is not working (docs/settings-sync.md §4.5, §6.2 rule 4). Worded by the app (`text`).
public enum SettingsSyncProblem: Equatable, Sendable {
    /// The vault holds content of a newer format version: nothing is written.
    case readOnly
    /// The vault's device list did not check: nothing is encrypted to it.
    case untrustedRecipients
    /// The file's `$minReaderVersion` is newer than this app: paused, untouched.
    case needsNewerApp
    /// Reading or writing failed; the English detail follows.
    case failed(String)
}

/// The question turning sync on asks when the vault's settings differ from this device's.
public struct SettingsSyncPrompt: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var differences: [SettingsSyncState.Difference]

    init(differences: [SettingsSyncState.Difference]) { self.differences = differences }
}

/// Where a front end keeps the shared settings that are not the model's on this device (docs/settings-sync.md §5,
/// `SharedSettingsCatalog`): every key outside `SettingsSyncBridge.modelKeys`. The app's is `AppSettingsStorage`
/// (`UserDefaults` through the settings' own types, so every value is read with its default filled in and written
/// through the same clamping as the Settings screen); headless, `StoredSettingsSyncStorage`.
public protocol SettingsSyncStorage: Sendable {
    /// This device's value of `key` (not one of `modelKeys`) in `defaults`, with its default filled in; nil for a key
    /// it does not keep.
    func read(_ key: String, from defaults: any KeyValueStore) -> JSONValue?
    /// Writes `values` (validated, none of `modelKeys`) to `defaults`.
    func write(_ values: [String: JSONValue], to defaults: any KeyValueStore)
}

/// Maps the shared settings' keys to this device's values (docs/settings-sync.md §5): the model's own keys here
/// (`modelKeys`, which the model applies), every other one through the front end's `SettingsSyncStorage`. The logic
/// of sync is `SettingsSyncState` (Sempere); this only reads and writes values.
public enum SettingsSyncBridge {
    /// The kind of device this app runs on (the iPad app on a Mac is a Mac).
    static func deviceType(isMac: Bool, isPhone: Bool) -> SettingsDeviceType {
        isMac ? .mac : (isPhone ? .iphone : .ipad)
    }

    /// Values the bridge cannot read from the settings store alone, supplied by the model.
    public struct Extras: Equatable, Sendable {
        /// The quick-capture profile's notebook and transcription choice, when
        /// quick capture is on for the open vault (else those keys are not read).
        var quickCapture: (notebook: String, transcribe: Bool)?
        /// The open vault's backup reminder (`BackupRecord.reminderDays`).
        var backupReminderDays: Int?
        /// The home-screen icon (`PlatformServices.appIcon`), where the device can switch icons.
        var appIcon: String?

        public init(quickCapture: (notebook: String, transcribe: Bool)? = nil, backupReminderDays: Int? = nil,
                    appIcon: String? = nil) {
            self.quickCapture = quickCapture; self.backupReminderDays = backupReminderDays; self.appIcon = appIcon
        }

        public static func == (a: Extras, b: Extras) -> Bool {
            a.quickCapture?.notebook == b.quickCapture?.notebook && a.quickCapture?.transcribe == b.quickCapture?.transcribe
                && a.backupReminderDays == b.backupReminderDays && a.appIcon == b.appIcon
        }
    }

    /// Keys whose values live outside the settings store (or need the model to act):
    /// `apply` returns them for the model instead of writing them. The Note Insights keys are read from the vault's
    /// file by the insights code itself (docs/design/1.2-note-insights.md §3.7), never stored on the device.
    public static let modelKeys: Set<String> = ["quickCapture.notebook", "quickCapture.transcribe", "backup.reminderDays",
                                                "handwriting.recognize", "search.transcripts", "appearance.icon",
                                                "insights.enabled", "insights.compute", "insights.workDevice",
                                                "insights.embeddingRevision", "insights.voiceNoteTitle"]

    /// This device's effective value of every setting a device of `type` uses,
    /// in the stored form of `SharedSettingSpec.validated`. A setting that cannot
    /// be read now (quick capture off for this vault) is left out, so it is
    /// neither taken for an edit nor seeded.
    public static func values(for type: SettingsDeviceType, defaults: any KeyValueStore, extras: Extras,
                              storage: any SettingsSyncStorage) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for spec in SharedSettingsCatalog.specs(for: type) {
            guard let raw = read(spec.name, defaults: defaults, extras: extras, storage: storage),
                  let v = spec.validated(raw) else { continue }
            out[spec.name] = v
        }
        return out
    }

    /// One key's value: the model's keys here, the rest from `storage`.
    static func read(_ key: String, defaults d: any KeyValueStore, extras: Extras,
                            storage: any SettingsSyncStorage) -> JSONValue? {
        switch key {
        case "handwriting.recognize": return .bool(RecognitionPreference.isEnabled(d))
        case "search.transcripts": return .bool(TranscriptSearchPreference.isOn(d))
        case "backup.reminderDays": return extras.backupReminderDays.map { .number(Double($0)) }
        case "quickCapture.notebook": return extras.quickCapture.map { .string($0.notebook) }
        case "quickCapture.transcribe": return extras.quickCapture.map { .bool($0.transcribe) }
        case "appearance.icon": return extras.appIcon.map { .string($0) }
        default: return storage.read(key, from: d)
        }
    }

    /// Writes `values` (validated by the caller) through `storage`; returns the
    /// ones in `modelKeys`, for the model to apply.
    @discardableResult
    public static func apply(_ values: [String: JSONValue], defaults: any KeyValueStore,
                             storage: any SettingsSyncStorage) -> [String: JSONValue] {
        var forModel: [String: JSONValue] = [:]
        var rest: [String: JSONValue] = [:]
        for (key, value) in values {
            if modelKeys.contains(key) { forModel[key] = value } else { rest[key] = value }
        }
        if !rest.isEmpty { storage.write(rest, to: defaults) }
        return forModel
    }
}

/// A `SettingsSyncStorage` that keeps each key's value as JSON in the store (`key(for:)`), its catalog default when
/// unset: for tests and front ends with no settings screen of their own.
public struct StoredSettingsSyncStorage: SettingsSyncStorage {
    public init() {}

    /// The store key of setting `name`.
    static func key(for name: String) -> String { "Sempere.sharedSetting.\(name)" }

    public func read(_ key: String, from defaults: any KeyValueStore) -> JSONValue? {
        guard let spec = SharedSettingsCatalog.spec(named: key) else { return nil }
        guard let data = defaults.data(forKey: Self.key(for: key)),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return spec.defaultValue }
        return value
    }

    public func write(_ values: [String: JSONValue], to defaults: any KeyValueStore) {
        for (key, value) in values {
            guard let data = try? JSONEncoder().encode(value) else { continue }
            defaults.set(data, forKey: Self.key(for: key))
        }
    }
}
