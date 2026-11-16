import Foundation
import Sempere

// MARK: - Failed generations, remembered per device (D16)

/// Notes whose generation failed on this device, so the scheduling policy backs off instead of asking the model again
/// on every run (D16: on a real library about one note in twenty was refused by the model's guardrail; each run asked
/// again, and with `--limit` the refusals came first and crowded out the notes behind them). Keyed by the note's
/// insight hash and the model's identity: a changed text, model or prompt is tried at once. Device-local state
/// (`$XDG_STATE_HOME/sempere/insights/<vault id>-failures` for the CLI), never in the vault. The file is sealed under a
/// key derived from the vault key (`LocalCacheKey`, purpose `insights-failures`, format.md §10.1), so note ids, scope
/// names and text hashes are unreadable without it; it is private to the user (0600), excluded from backups, and
/// deleted when Note Insights is turned off on this device, or at the next pass after it is turned off elsewhere, and
/// when the vault leaves the device. A new epoch derives another key, and the
/// memo starts empty.
public struct InsightsFailureMemo: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var hash: String
        /// `GenerationIdentity` as `model os prompt`.
        public var identity: String
        /// The model refused (a guardrail): that answer does not change by asking again.
        public var refused: Bool
        /// Seconds since 1970 of the latest failure.
        public var at: Double
        public var count: Int
        /// Why it first failed (the error's words, at most `maxReason` UTF-8 bytes), so a later pass can say why the note
        /// waits ("Process Now"'s outcome); nil in an entry of an earlier build.
        public var reason: String?
    }

    /// A reason is at most this many UTF-8 bytes (cut at a character boundary).
    static let maxReason = 120

    static func capped(_ s: String) -> String {
        var out = ""
        var bytes = 0
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > maxReason { break }
            out.append(ch); bytes += n
        }
        return out
    }

    /// A refusal is asked again after this long; any other failure after `failedFor`.
    public static let refusedFor: TimeInterval = 30 * 24 * 3600
    public static let failedFor: TimeInterval = 24 * 3600
    /// The file is bounded: at most this many notes are remembered (the oldest failures go first).
    public static let maxEntries = 10_000
    static let maxFileBytes = 4 << 20

    public var notes: [String: Entry] = [:]
    /// Topic summaries that failed (the model threw, or nothing survived the fact check), by scope name
    /// (`TopicScopes.name`), keyed by the members' digest (`membersHash`) instead of a note's hash.
    public var topics: [String: Entry] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case notes, topics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = try c.decodeIfPresent([String: Entry].self, forKey: .notes) ?? [:]
        // A memo written before topic entries existed has none.
        topics = try c.decodeIfPresent([String: Entry].self, forKey: .topics) ?? [:]
    }

    public static func key(_ identity: GenerationIdentity) -> String { "\(identity.model) \(identity.os) \(identity.prompt)" }

    static let purpose = "insights-failures"
    static let magic: [UInt8] = Array("SMPF".utf8) + [0x01]

    /// The memo file of `vaultId` in `folder`.
    public static func fileURL(in folder: URL, vaultId: UUID) -> URL {
        folder.appendingPathComponent("\(vaultId.uuidString.lowercased())-failures")
    }

    /// `$XDG_STATE_HOME/sempere/insights/<vault id>-failures`.
    public static func defaultURL(vaultId: UUID, environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        fileURL(in: DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("insights"), vaultId: vaultId)
    }

    /// The memo at `url` for `vault`; a missing, unreadable, malformed or differently keyed file (another epoch), or a
    /// locked vault, is an empty memo (it only saves model time).
    public static func load(from url: URL, vault: Vault) -> InsightsFailureMemo {
        // A memo of an earlier build, in plain JSON: never read, deleted.
        try? FileManager.default.removeItem(at: legacyURL(url))
        guard let key = try? LocalCacheKey(vault: vault, purpose: purpose, magic: magic),
              let data = try? BoundedRead.contents(of: url, maxBytes: maxFileBytes),
              let plain = try? key.open(data, fileName: url.lastPathComponent),
              let memo = try? JSONDecoder().decode(InsightsFailureMemo.self, from: plain) else { return InsightsFailureMemo() }
        return memo
    }

    /// Writes the memo sealed for `vault`, atomically, private to the user and excluded from backups, creating its
    /// directory (0700).
    public func save(to url: URL, vault: Vault) throws {
        let key = try LocalCacheKey(vault: vault, purpose: Self.purpose, magic: Self.magic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sealed = try key.seal(try encoder.encode(self), fileName: url.lastPathComponent)
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.excludeFromBackup(folder)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Self.excludeFromBackup(url)
        // A memo of an earlier build, in plain JSON: never read, deleted.
        try? fm.removeItem(at: Self.legacyURL(url))
    }

    /// Deletes the memo at `url` (and an earlier build's plain one beside it); nothing when there is none.
    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: legacyURL(url))
    }

    static func legacyURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".json")
    }

    static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try? u.setResourceValues(values)
        #endif
    }

    /// Remembers that generating `note` at `hash` with `identity` failed with `error` at `now`.
    public mutating func record(note: UUID, hash: String, identity: GenerationIdentity, error: Error, now: Date) {
        let id = note.uuidString.lowercased(), key = Self.key(identity)
        var refused = false
        if case InsightsProviderError.refused = error { refused = true }
        let previous = notes[id].flatMap { $0.hash == hash && $0.identity == key ? $0 : nil }
        notes[id] = Entry(hash: hash, identity: key, refused: refused, at: now.timeIntervalSince1970, count: (previous?.count ?? 0) + 1,
                          reason: previous?.reason ?? Self.capped(String(describing: error)))
        if notes.count > Self.maxEntries, let oldest = notes.min(by: { ($0.value.at, $0.key) < ($1.value.at, $1.key) })?.key {
            notes[oldest] = nil
        }
    }

    /// Why `note` first failed, when the memo has it.
    public func reason(note: UUID) -> String? { notes[note.uuidString.lowercased()]?.reason }

    /// Forgets `note` (it was generated).
    public mutating func clear(note: UUID) { notes[note.uuidString.lowercased()] = nil }

    /// Remembers that the topic summary of `scope` (its `TopicScopes.name`) over members digest `membersHash` failed.
    /// A summary the fact check left empty counts as a failure of its own kind (`refused` false: asked again after a day).
    public mutating func recordTopic(_ scope: String, membersHash: String, identity: GenerationIdentity, error: Error?, now: Date) {
        let key = Self.key(identity)
        var refused = false
        if let error, case InsightsProviderError.refused = error { refused = true }
        let previous = topics[scope].flatMap { $0.hash == membersHash && $0.identity == key ? $0 : nil }
        let why = error.map { Self.capped(String(describing: $0)) } ?? "nothing survived the fact check"
        topics[scope] = Entry(hash: membersHash, identity: key, refused: refused, at: now.timeIntervalSince1970,
                              count: (previous?.count ?? 0) + 1, reason: previous?.reason ?? why)
        if topics.count > Self.maxEntries, let oldest = topics.min(by: { ($0.value.at, $0.key) < ($1.value.at, $1.key) })?.key {
            topics[oldest] = nil
        }
    }

    /// Forgets the topic `scope` (it was made).
    public mutating func clearTopic(_ scope: String) { topics[scope] = nil }

    /// Until when the topic `scope` waits, for a failure over these same members with this same model; nil: not backed off.
    /// A failure recorded before `ignoringBefore` does not count ("Process Now" asks again; what fails during its pass
    /// waits).
    public func topicBackoff(_ scope: String, membersHash: String, identity: GenerationIdentity, ignoringBefore: Date? = nil) -> Date? {
        guard let e = topics[scope], e.hash == membersHash, e.identity == Self.key(identity) else { return nil }
        if let floor = ignoringBefore, e.at < floor.timeIntervalSince1970 { return nil }
        return Date(timeIntervalSince1970: e.at + (e.refused ? Self.refusedFor : Self.failedFor))
    }

    /// The policy's back-off (`InsightsPolicy.plan(backoff:)`): until when each of `notes` (id and current hash) waits,
    /// for the failures of this same text with this same model. A failure recorded before `ignoringBefore` does not count.
    public func backoff(notes current: [(id: UUID, hash: String)], identity: GenerationIdentity,
                        ignoringBefore: Date? = nil) -> [UUID: Date] {
        let key = Self.key(identity)
        var out: [UUID: Date] = [:]
        for n in current {
            guard let e = notes[n.id.uuidString.lowercased()], e.hash == n.hash, e.identity == key else { continue }
            if let floor = ignoringBefore, e.at < floor.timeIntervalSince1970 { continue }
            out[n.id] = Date(timeIntervalSince1970: e.at + (e.refused ? Self.refusedFor : Self.failedFor))
        }
        return out
    }
}
