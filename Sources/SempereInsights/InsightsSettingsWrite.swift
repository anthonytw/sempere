import Foundation
import Sempere

// MARK: - Changing the vault's insights settings (docs/design/1.2-note-insights.md §3.7, §3.8, D12-D14)
//
// The one place that writes the five `insights.*` keys of `settings.age`, for Settings ▸ Note Insights and the CLI
// (`insights purge`, `insights work-device`, `insights map --pin`, `settings set`'s validation is the catalog's). Every
// write takes the vault's write lock (`updateSharedSettingsUnderWriteLock`), so the caller must not hold it.

public enum InsightsSettingsWrite {
    static func write(_ vault: Vault, _ key: String, _ value: JSONValue?, block: SettingsDeviceType? = nil, now: Date) throws {
        try vault.updateSharedSettingsUnderWriteLock { s in
            guard let spec = SharedSettingsCatalog.spec(named: key) else { return }
            try s.write(spec, value, block: block?.rawValue, type: nil, now: now)
        }
    }

    /// Turns Note Insights on or off for the vault (`insights.enabled`, vault-wide). Off writes the explicit `false`
    /// that makes every device delete `insights/` (format.md §16.6) and deletes this copy's files now; returns their
    /// names (none when turned on).
    @discardableResult
    public static func setEnabled(_ on: Bool, vault: Vault, now: Date = Date()) throws -> [String] {
        try write(vault, InsightsSettings.keys.enabled, .bool(on), now: now)
        return on ? [] : try InsightsStore(vault: vault).purge()
    }

    /// Designates the work device (D13), or clears it (nil: the first capable device claims it).
    public static func setWorkDevice(_ device: DeviceID?, vault: Vault, now: Date = Date()) throws {
        try write(vault, InsightsSettings.keys.workDevice, device.map { .string($0.rawValue) } ?? .null, now: now)
    }

    /// The voice-note title format (D14); nil or the default resets it. Refuses a format `VoiceNoteTitleFormat.check`
    /// rejects.
    public static func setVoiceNoteTitle(_ format: String?, vault: Vault, now: Date = Date()) throws {
        let f = format ?? VoiceNoteTitleFormat.defaultFormat
        if let why = VoiceNoteTitleFormat.check(f) { throw InsightsSettingsError.invalidFormat(why) }
        try write(vault, InsightsSettings.keys.voiceNoteTitle, .string(f), now: now)
    }

    /// `insights.compute` for devices of `type` (D13: `auto` lets a device that is not the work device process too).
    public static func setCompute(auto: Bool, type: SettingsDeviceType, vault: Vault, now: Date = Date()) throws {
        try write(vault, InsightsSettings.keys.compute, .string(auto ? "auto" : "never"), block: type, now: now)
    }

    /// What moving the pinned embedding revision would do (D12): the devices it leaves out (they become vector
    /// readers) and where the work device goes when it lacks the revision.
    public struct PinMove: Hashable, Sendable {
        public var language: String
        public var revision: Int
        public var leftOut: [DeviceID]
        public var workDevice: DeviceID?
        public var movesWorkDevice: Bool
    }

    /// The move of `language`'s pin to `revision` as things stand (no write).
    public static func planPinMove(to revision: Int, language: String, vault: Vault, snapshot: InsightsSnapshot,
                                   settings: InsightsSettings, now: Date = Date()) -> PinMove {
        let listed = Set(vault.manifest.devices.compactMap { $0.id.flatMap(DeviceID.init) })
        let recent = EmbeddingPin.recent(snapshot.devices, listed: listed, now: now)
        let leftOut = EmbeddingPin.leftOut(recent, language: language, revision: revision)
        var work = settings.workDevice
        if let w = settings.workDevice, let r = snapshot.devices[w], !(r.supported[language] ?? []).contains(revision) {
            work = recent.filter { ($0.value.supported[language] ?? []).contains(revision) }.map(\.key).sorted().first
        }
        return PinMove(language: language, revision: revision, leftOut: leftOut, workDevice: work,
                       movesWorkDevice: work != settings.workDevice)
    }

    /// Writes `move`: the pin, and the work device when it moves.
    public static func apply(_ move: PinMove, vault: Vault, now: Date = Date()) throws {
        try vault.updateSharedSettingsUnderWriteLock { s in
            guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.pin) else { return }
            var o: [String: JSONValue] = [:]
            if case .object(let cur) = s.resolve(spec, for: nil).value { o = cur }
            o[move.language] = .number(Double(move.revision))
            try s.write(spec, .object(o), block: nil, type: nil, now: now)
            if move.movesWorkDevice, let w = SharedSettingsCatalog.spec(named: InsightsSettings.keys.workDevice) {
                try s.write(w, move.workDevice.map { .string($0.rawValue) } ?? .null, block: nil, type: nil, now: now)
            }
        }
    }
}

public enum InsightsSettingsError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidFormat(String)
    public var description: String {
        switch self {
        case .invalidFormat(let why): return "not a voice-note title format: \(why)"
        }
    }
}
