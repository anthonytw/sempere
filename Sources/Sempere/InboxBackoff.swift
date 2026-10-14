import Foundation

/// This device's record of inbox files (format.md §11) that failed to read
/// (security review 2026-10, C5): a file that does not verify is kept in the
/// inbox (it may be a real capture this device cannot check yet), but it is
/// not decrypted again at every unlock. After its first failure it is
/// skipped for an hour, then twice as long after each further failure, up to
/// a week, unless its size or modification time changes. Keyed by vault id
/// and file name; kept outside the vault (CLI
/// `$XDG_STATE_HOME/sempere/inbox-backoff.json`, app Application Support),
/// never synced. Losing it only costs a re-read.
public final class InboxBackoff: @unchecked Sendable {
    /// What identifies one version of an inbox file.
    public struct FileMark: Codable, Hashable, Sendable {
        public var size: Int64
        public var modified: Date?

        public init(size: Int64, modified: Date?) { self.size = size; self.modified = modified }

        /// The mark of the file at `url`; nil when it cannot be read.
        public init?(_ url: URL) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (a[.size] as? NSNumber)?.int64Value else { return nil }
            self.size = size
            self.modified = a[.modificationDate] as? Date
        }
    }

    /// One failing file.
    public struct Entry: Codable, Hashable, Sendable {
        public var mark: FileMark
        public var failures: Int
        public var lastError: String
        public var retryAfter: Date
    }

    struct Stored: Codable {
        var format = "sempere-inbox-backoff/1"
        var entries: [String: Entry] = [:]
    }

    /// First wait after a failure, and the longest.
    public static let firstDelay: TimeInterval = 3600
    public static let maxDelay: TimeInterval = 7 * 24 * 3600
    /// Entries kept at most (the oldest retry dates go first).
    public static let maxEntries = 10_000
    static let maxFileBytes = 16 << 20

    private let lock = NSLock()
    private var stored = Stored()
    /// Where the record is saved; nil keeps it in memory only.
    public let fileURL: URL?

    /// Loads the record at `fileURL` (an unreadable one starts empty: the
    /// cost is only re-reading files).
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? BoundedRead.contents(of: fileURL, maxBytes: Self.maxFileBytes),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = s
        }
    }

    /// `$XDG_STATE_HOME/sempere/inbox-backoff.json`, next to `device.json`.
    public static func cliURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        DeviceState.defaultURL(environment: environment).deletingLastPathComponent()
            .appendingPathComponent("inbox-backoff.json")
    }

    static func key(_ vault: UUID, _ name: String) -> String { "\(vault.uuidString.lowercased())/\(name)" }

    /// The entry of a file still backed off at `now`: same version, retry
    /// date not reached. Nil when it should be read.
    public func pending(vault: UUID, name: String, mark: FileMark, now: Date) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = stored.entries[Self.key(vault, name)], e.mark == mark, now < e.retryAfter else { return nil }
        return e
    }

    /// Every entry of `vault`, by file name (for reports).
    public func entries(vault: UUID) -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        let prefix = vault.uuidString.lowercased() + "/"
        var out: [String: Entry] = [:]
        for (k, v) in stored.entries where k.hasPrefix(prefix) { out[String(k.dropFirst(prefix.count))] = v }
        return out
    }

    /// Records a failure of the file's version `mark`: its count grows (a
    /// changed file starts again at one) and its next read waits.
    public func recordFailure(vault: UUID, name: String, mark: FileMark, error: String, now: Date) {
        lock.lock()
        let k = Self.key(vault, name)
        let n = (stored.entries[k].map { $0.mark == mark ? $0.failures : 0 } ?? 0) + 1
        let delay = min(Self.firstDelay * pow(2, Double(min(n - 1, 20))), Self.maxDelay)
        stored.entries[k] = Entry(mark: mark, failures: n, lastError: String(error.prefix(500)),
                                  retryAfter: now.addingTimeInterval(delay))
        if stored.entries.count > Self.maxEntries {
            let oldest = stored.entries.sorted { $0.value.retryAfter < $1.value.retryAfter }
                .prefix(stored.entries.count - Self.maxEntries).map(\.key)
            for k in oldest { stored.entries[k] = nil }
        }
        lock.unlock()
        save()
    }

    /// Forgets a file (it verified, or it is gone).
    public func clear(vault: UUID, name: String) {
        lock.lock()
        let removed = stored.entries.removeValue(forKey: Self.key(vault, name)) != nil
        lock.unlock()
        if removed { save() }
    }

    private func save() {
        guard let fileURL else { return }
        lock.lock()
        let data = try? JSONEncoder().encode(stored)
        lock.unlock()
        guard let data else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
