import Foundation
import Sempere

// MARK: - Changing the vault's insights settings (docs/design/1.2-note-insights.md §3.7, §3.8, D12-D14, D21)
//
// The one place that writes the `insights.*` keys of `settings.age`, for Settings ▸ Note Insights and the CLI
// (`insights purge`, `insights map --pin`, `settings set`'s validation is the catalog's). Every
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

    /// The voice-note title format (D14); nil or the default resets it. Refuses a format `VoiceNoteTitleFormat.check`
    /// rejects.
    public static func setVoiceNoteTitle(_ format: String?, vault: Vault, now: Date = Date()) throws {
        let f = format ?? VoiceNoteTitleFormat.defaultFormat
        if let why = VoiceNoteTitleFormat.check(f) { throw InsightsSettingsError.invalidFormat(why) }
        try write(vault, InsightsSettings.keys.voiceNoteTitle, .string(f), now: now)
    }

    /// The language of generated summaries and voice-note titles (`insights.language`): a BCP 47 tag, or nil for "same as the
    /// note" (the default; resets the key). Refuses a tag that is none. Changing it makes summaries and titles be made again,
    /// in the new language, a few at a time (every device reads the same setting, so they all write the same language).
    public static func setLanguage(_ tag: String?, vault: Vault, now: Date = Date()) throws {
        guard let tag else { return try write(vault, InsightsSettings.keys.language, nil, now: now) }
        guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.language), spec.validated(.string(tag)) != nil else {
            throw InsightsSettingsError.invalidLanguage(tag)
        }
        try write(vault, InsightsSettings.keys.language, .string(tag), now: now)
    }

    /// What moving the pinned embedding revision would do (D12): the devices it leaves out (they become vector
    /// readers).
    public struct PinMove: Hashable, Sendable {
        public var language: String
        public var revision: Int
        public var leftOut: [DeviceID]
    }

    /// The move of `language`'s pin to `revision` as things stand (no write).
    public static func planPinMove(to revision: Int, language: String, vault: Vault, snapshot: InsightsSnapshot,
                                   settings: InsightsSettings, now: Date = Date()) -> PinMove {
        let listed = Set(vault.manifest.devices.compactMap { $0.id.flatMap(DeviceID.init) })
        let recent = EmbeddingPin.recent(snapshot.devices, listed: listed, now: now)
        let leftOut = EmbeddingPin.leftOut(recent, language: language, revision: revision)
        return PinMove(language: language, revision: revision, leftOut: leftOut)
    }

    /// Writes `move`: the pin (a device that supports the new revision builds the map at it).
    public static func apply(_ move: PinMove, vault: Vault, now: Date = Date()) throws {
        try vault.updateSharedSettingsUnderWriteLock { s in
            guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.pin) else { return }
            var o: [String: JSONValue] = [:]
            if case .object(let cur) = s.resolve(spec, for: nil).value { o = cur }
            o[move.language] = .number(Double(move.revision))
            try s.write(spec, .object(o), block: nil, type: nil, now: now)
        }
    }
}

public enum InsightsSettingsError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidFormat(String)
    case invalidLanguage(String)
    public var description: String {
        switch self {
        case .invalidFormat(let why): return "not a voice-note title format: \(why)"
        case .invalidLanguage(let tag): return "not a language tag: \(tag) (use a BCP 47 tag such as es or pt-BR)"
        }
    }
}
