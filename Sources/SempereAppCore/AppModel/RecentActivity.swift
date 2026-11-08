import Foundation
import Sempere

/// Queries searched recently, newest first (the search field's suggestions).
/// Pure, tested.
public struct RecentSearches: Codable, Equatable, Sendable {
    public static let limit = 10
    /// Longest query remembered.
    public static let maxLength = 200

    public private(set) var queries: [String] = []

    public init() {}

    /// Puts `query` (trimmed) first; one copy per query, ignoring case.
    public mutating func record(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= Self.maxLength else { return }
        queries.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        queries.insert(q, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
    }

    public mutating func remove(_ query: String) { queries.removeAll { $0 == query } }

    public mutating func clear() { queries = [] }

    /// The list as read from a file: trimmed, bounded, without duplicates.
    public func sanitized() -> RecentSearches {
        var clean = RecentSearches()
        for q in queries.prefix(Self.limit * 4).reversed() { clean.record(q) }
        return clean
    }
}

/// What this device remembers of a vault between launches: the recent
/// searches. Sealed with a key derived
/// from the vault secret (`LocalCacheKey`, purpose `activity`), in the app's
/// Application Support folder, never in the vault: searches can name what
/// notes hold, so they are as private as the notes. A vault whose secret
/// changes starts afresh.
public struct RecentActivity: Codable, Equatable, Sendable {
    public var searches = RecentSearches()

    public init(searches: RecentSearches = RecentSearches()) { self.searches = searches }

    /// `SMPA` then version 1.
    public static let magic: [UInt8] = [0x53, 0x4D, 0x50, 0x41, 0x01]
    public static let fileName = "activity"
    /// The largest file read.
    public static let maxFileBytes = 4 << 20

    /// The file of `vault` under `root` (the folder is named by the key).
    public static func location(root: URL, key: LocalCacheKey) -> URL {
        root.appendingPathComponent(key.name, isDirectory: true).appendingPathComponent(fileName)
    }

    /// What `root` holds for `vault`; empty when nothing (or nothing usable) is stored.
    public static func load(root: URL, vault: Vault, now: Date = Date()) -> RecentActivity {
        guard let key = try? LocalCacheKey(vault: vault, purpose: "activity", magic: magic) else { return RecentActivity() }
        let url = location(root: root, key: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let sealed = try? BoundedRead.contents(of: url, maxBytes: maxFileBytes),
              let plain = try? key.open(sealed, fileName: fileName),
              var activity = try? JSONDecoder().decode(RecentActivity.self, from: plain) else { return RecentActivity() }
        activity.searches = activity.searches.sanitized()
        return activity
    }

    /// Stores `self` for `vault` under `root` (errors are ignored: it is a convenience).
    public func save(root: URL, vault: Vault) {
        guard let key = try? LocalCacheKey(vault: vault, purpose: "activity", magic: Self.magic),
              let plain = try? JSONEncoder().encode(self),
              let sealed = try? key.seal(plain, fileName: Self.fileName) else { return }
        let url = Self.location(root: root, key: key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
