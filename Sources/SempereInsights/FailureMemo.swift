import Foundation
import Sempere

// MARK: - Failed generations, remembered per device (D16)

/// Notes whose generation failed on this device, so the scheduling policy backs off instead of asking the model again
/// on every run (D16: on a real library about one note in twenty was refused by the model's guardrail; each run asked
/// again, and with `--limit` the refusals came first and crowded out the notes behind them). Keyed by the note's
/// insight hash and the model's identity: a changed text, model or prompt is tried at once. Device-local state
/// (`$XDG_STATE_HOME/sempere/insights/<vault id>-failures.json` for the CLI), never in the vault.
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
    }

    /// A refusal is asked again after this long; any other failure after `failedFor`.
    public static let refusedFor: TimeInterval = 30 * 24 * 3600
    public static let failedFor: TimeInterval = 24 * 3600
    /// The file is bounded: at most this many notes are remembered (the oldest failures go first).
    public static let maxEntries = 10_000
    static let maxFileBytes = 4 << 20

    public var notes: [String: Entry] = [:]

    public init() {}

    public static func key(_ identity: GenerationIdentity) -> String { "\(identity.model) \(identity.os) \(identity.prompt)" }

    /// `$XDG_STATE_HOME/sempere/insights/<vault id>-failures.json`.
    public static func defaultURL(vaultId: UUID, environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("insights").appendingPathComponent("\(vaultId.uuidString.lowercased())-failures.json")
    }

    /// The memo at `url`; a missing, unreadable or malformed file is an empty memo (it only saves model time).
    public static func load(from url: URL) -> InsightsFailureMemo {
        guard let data = try? BoundedRead.contents(of: url, maxBytes: maxFileBytes),
              let memo = try? JSONDecoder().decode(InsightsFailureMemo.self, from: data) else { return InsightsFailureMemo() }
        return memo
    }

    /// Writes the memo atomically, creating its directory.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Remembers that generating `note` at `hash` with `identity` failed with `error` at `now`.
    public mutating func record(note: UUID, hash: String, identity: GenerationIdentity, error: Error, now: Date) {
        let id = note.uuidString.lowercased(), key = Self.key(identity)
        var refused = false
        if case InsightsProviderError.refused = error { refused = true }
        let previous = notes[id].flatMap { $0.hash == hash && $0.identity == key ? $0 : nil }
        notes[id] = Entry(hash: hash, identity: key, refused: refused, at: now.timeIntervalSince1970, count: (previous?.count ?? 0) + 1)
        if notes.count > Self.maxEntries, let oldest = notes.min(by: { ($0.value.at, $0.key) < ($1.value.at, $1.key) })?.key {
            notes[oldest] = nil
        }
    }

    /// Forgets `note` (it was generated).
    public mutating func clear(note: UUID) { notes[note.uuidString.lowercased()] = nil }

    /// The policy's back-off (`InsightsPolicy.plan(backoff:)`): until when each of `notes` (id and current hash) waits,
    /// for the failures of this same text with this same model.
    public func backoff(notes current: [(id: UUID, hash: String)], identity: GenerationIdentity) -> [UUID: Date] {
        let key = Self.key(identity)
        var out: [UUID: Date] = [:]
        for n in current {
            guard let e = notes[n.id.uuidString.lowercased()], e.hash == n.hash, e.identity == key else { continue }
            out[n.id] = Date(timeIntervalSince1970: e.at + (e.refused ? Self.refusedFor : Self.failedFor))
        }
        return out
    }
}
