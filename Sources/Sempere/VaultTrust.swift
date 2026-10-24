import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// How a device classifies `vault.json` (docs/design/key-hierarchy.md §4.3, format.md §15.3, §15.10)
// and where it keeps what it verified (trust records `sempere-trust/3`). Phase KH2: single-epoch vaults,
// so a device pins epoch 1 and the list it verified; epochs above it are KH3's.

/// How a reader classified `vault.json` (design §4.3).
public enum ListStatus: Hashable, Sendable {
    /// Not checked: the vault is locked.
    case notChecked
    /// Every check passed.
    case verified(Verification)
    /// A check failed, or this device cannot confirm the vault: it may read, never write.
    case refused(ListProblem)

    /// What changed since this device's trust record.
    public enum Verification: String, Hashable, Sendable, Codable {
        /// The list this device verified last.
        case unchanged
        /// No trust record yet: the creator, a device whose join was just confirmed, or a reader
        /// that keeps none.
        case firstUse
        /// Home approved devices since (and maybe renamed some).
        case added
        /// Home renamed devices since, and added none.
        case renamed
        /// A later epoch than the one this device pinned, whose chain it follows (design §4.3 step 2, §5.6):
        /// a removal, a handoff, a takeover or a kit replacement since. Files of this device's ledger that
        /// the change did not seal are caught up (`Vault.catchUp`).
        case newEpoch
        /// A later epoch that is a direct child of the pinned one, linked and signed from it, whose record has
        /// not arrived (design §4.3 step 2, KH4): followed (writes are under its key), not pinned; files under
        /// the older key are pending and catch-up waits until the record arrives.
        case newEpochRecordPending = "new-epoch-record-pending"
    }

    /// True unless refused.
    public var allowsWriting: Bool {
        if case .refused = self { return false }
        return true
    }

    /// The problem, when refused.
    public var problem: ListProblem? {
        if case .refused(let p) = self { return p }
        return nil
    }

    /// `verified`, `refused` or `not-checked`, for `--json` outputs.
    public var label: String {
        switch self {
        case .notChecked: return "not-checked"
        case .verified: return "verified"
        case .refused: return "refused"
        }
    }
}

/// Why a device refuses to write to a vault (design §4.3).
public struct ListProblem: Hashable, Sendable, CustomStringConvertible {
    public enum Reason: String, Hashable, Sendable, Codable {
        /// `listTag` does not verify: an entry (a name, a key, a wrap) was changed without the key.
        case listTag
        /// `markersTag` does not verify: `format` or `features` changed without the key.
        case markersTag
        /// The markers verify but are fewer than this device last verified: an older `vault.json` put back.
        case markersRolledBack
        /// `authorSig` is not home's.
        case authorSig
        /// `epochSig` is not by the epoch's author over its first list, or a takeover's `recoverySig` fails.
        case epochSig
        /// The epoch's first list introduces a device.
        case introducesDevice
        /// An entry that is not in the verified list and is not an addition approved by home.
        case addSig
        /// `root` is not this vault's: not derived from epoch 1's key, not the trust record's, or not the
        /// root the user gave (the kit, the reverse code, `--root`).
        case rootMismatch
        /// Another epoch than the one this device pinned (a rollback, or a later epoch: KH3).
        case otherEpoch
        /// Under the same epoch, an entry this device verified is gone or changed other than its name:
        /// a removal always starts a new epoch.
        case entriesChanged
        /// This device's trust record exists but cannot be read (fails closed, security review 2026-10, R5).
        case recordUnreadable
        /// No trust record and no root to check the vault against: a device that joined confirms the
        /// home's reply code first (design §6.2 step 4), a recovery reader passes the root.
        case rootUnconfirmed
        /// `vault.json` binds a re-encryption journal to a re-encryption this device saw finished: an older
        /// version put back (KH6).
        case reencryptRolledBack
    }

    public var reason: Reason
    /// One line for people.
    public var detail: String

    public init(_ reason: Reason, _ detail: String) { self.reason = reason; self.detail = detail }

    public var description: String { "\(reason.rawValue): \(detail)" }

    /// `age1pq1abcdefgh…` for messages (post-quantum keys are 1959 characters).
    public static func abbreviate(_ key: String) -> String { key.count > 80 ? "\(key.prefix(16))…\(key.suffix(8))" : key }
}

// MARK: - Stores

/// Where a device keeps its trust records (`sempere-trust/3`, format.md §15.10).
public protocol EpochTrustStore: Sendable {
    /// The record of `vaultId`, nil when there is none.
    ///
    /// - Throws: when a record exists but cannot be read or does not decode (or names another vault).
    ///   Never nil for that: a record that reads as absent would make the next open a first use
    ///   (security review 2026-10, R5).
    func record(for vaultId: UUID) throws -> EpochTrustRecord?
    /// Saves (replaces) the record of its vault.
    func save(_ record: EpochTrustRecord) throws
    /// The `vault.json` versions of later epochs this device saw on a sync target and did not take
    /// (key-hierarchy design §4.3 "unverified-pending", §5.5 unlisted; KH4), oldest first.
    ///
    /// - Throws: when they exist but cannot be read: a device that forgot a sighting would upload again.
    func sightings(for vaultId: UUID) throws -> [EpochSighting]
    /// Replaces the sightings of `vaultId` (empty: removes them).
    func saveSightings(_ sightings: [EpochSighting], for vaultId: UUID) throws
}

/// Trust records as files `<directory>/<vaultId>.json` (mode 0600 in a 0700 folder).
public struct FileEpochTrustStore: EpochTrustStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The largest record file read.
    static let maxFileBytes = 4 << 20

    /// `$XDG_STATE_HOME/sempere/trust`, else `~/.local/state/sempere/trust`.
    public static func cliDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("trust", isDirectory: true)
    }

    func fileURL(_ vaultId: UUID) -> URL {
        directory.appendingPathComponent("\(vaultId.uuidString.lowercased()).json")
    }

    public func record(for vaultId: UUID) throws -> EpochTrustRecord? {
        let url = fileURL(vaultId)
        // Absent only when nothing is there at all (not even a dangling link).
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return nil }
        let r: EpochTrustRecord
        do {
            let data = try BoundedRead.contents(of: url, maxBytes: Self.maxFileBytes)
            r = try JSONDecoder().decode(EpochTrustRecord.self, from: data)
        } catch {
            throw VaultError.io("trust record \(url.path) is unreadable: \(error)")
        }
        guard r.vaultId == vaultId else { throw VaultError.io("trust record \(url.path) names another vault") }
        return r
    }

    /// Writes the record atomically. It holds only public values; it stays private anyway: it names the
    /// vault and its devices.
    public func save(_ record: EpochTrustRecord) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(try enc.encode(record), to: fileURL(record.vaultId))
    }

    /// `<directory>/<vaultId>.seen.json` (format.md §15.10 "Sightings").
    func sightingsURL(_ vaultId: UUID) -> URL {
        directory.appendingPathComponent("\(vaultId.uuidString.lowercased()).seen.json")
    }

    public func sightings(for vaultId: UUID) throws -> [EpochSighting] {
        let url = sightingsURL(vaultId)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return [] }
        do {
            let data = try BoundedRead.contents(of: url, maxBytes: EpochSighting.maxFileBytes)
            return try EpochSighting.decodeFile(data, vaultId: vaultId)
        } catch {
            throw VaultError.io("sightings \(url.path) are unreadable: \(error)")
        }
    }

    public func saveSightings(_ sightings: [EpochSighting], for vaultId: UUID) throws {
        let url = sightingsURL(vaultId)
        guard !sightings.isEmpty else {
            if FileIO.exists(url) { try FileIO.remove(url) }
            return
        }
        try write(try EpochSighting.encodeFile(sightings, vaultId: vaultId), to: url)
    }

    /// Writes `data` at `url` atomically (mode 0600, the folder 0700).
    private func write(_ data: Data, to url: URL) throws {
        try FileIO.createDirectory(directory)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let tmp = FileIO.tempURL(in: directory)
        try FileIO.writeNewFile(tmp) { write in try write(data) }
        guard rename(tmp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw VaultError.io("rename to \(url.path): errno \(code)")
        }
    }
}

/// Trust records in memory (tests, and readers that keep none on disk).
public final class MemoryEpochTrustStore: EpochTrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: EpochTrustRecord] = [:]
    private var unreadable: [UUID: String] = [:]
    private var seen: [UUID: [EpochSighting]] = [:]

    public init() {}

    public func sightings(for vaultId: UUID) throws -> [EpochSighting] {
        lock.lock(); defer { lock.unlock() }
        return seen[vaultId] ?? []
    }

    public func saveSightings(_ sightings: [EpochSighting], for vaultId: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        seen[vaultId] = sightings.isEmpty ? nil : sightings
    }

    public func record(for vaultId: UUID) throws -> EpochTrustRecord? {
        lock.lock(); defer { lock.unlock() }
        if let why = unreadable[vaultId] { throw VaultError.io("trust record unreadable: \(why)") }
        return records[vaultId]
    }

    public func save(_ record: EpochTrustRecord) throws {
        lock.lock(); defer { lock.unlock() }
        unreadable[record.vaultId] = nil
        records[record.vaultId] = record
    }

    /// Makes the record of `vaultId` read as unreadable (`why`) until the next `save`.
    public func markUnreadable(_ vaultId: UUID, _ why: String) {
        lock.lock(); defer { lock.unlock() }
        records[vaultId] = nil
        unreadable[vaultId] = why
    }

    /// Forgets every record.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        records = [:]
        unreadable = [:]
        seen = [:]
    }
}

/// What a `Vault` and its copies last saved to the trust store.
final class TrustMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var record: EpochTrustRecord?

    var last: EpochTrustRecord? {
        get { lock.lock(); defer { lock.unlock() }; return record }
        set { lock.lock(); record = newValue; lock.unlock() }
    }
}

// MARK: - Constant-time compare, markers

/// Small helpers of the authenticated fields (format.md §2.1 "Version markers", §15).
public enum VaultAuth {
    /// Compares in time that depends only on the lengths.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// `features` as the tag covers them: each once, sorted by UTF-8 bytes.
    static func canonicalFeatures(_ features: [String]) -> [String] {
        var seen = Set<[UInt8]>()
        var out: [[UInt8]] = []
        for f in features where seen.insert(Array(f.utf8)).inserted { out.append(Array(f.utf8)) }
        out.sort { $0.lexicographicallyPrecedes($1) }
        return out.map { String(decoding: $0, as: UTF8.self) }
    }

    /// `"sempere/1" ‖ 0 ‖ "markers" ‖ 0 ‖ vaultId ‖ 0 ‖ format (‖ 0 ‖ feature)*`, features canonical;
    /// nil when a marker holds a NUL (never tagged).
    static func markersMessage(vaultId: UUID, format: String, features: [String]) -> Data? {
        guard !format.utf8.contains(0), !features.contains(where: { $0.utf8.contains(0) }) else { return nil }
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "markers".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        m.append(0); m.append(contentsOf: format.utf8)
        for f in canonicalFeatures(features) { m.append(0); m.append(contentsOf: f.utf8) }
        return m
    }
}

/// The version markers a device last verified (format.md §2.1 "Version markers", §15.10).
public struct VaultMarkers: Hashable, Sendable, Codable {
    public var format: String
    /// Canonical: each once, sorted by UTF-8 bytes.
    public var features: [String]

    public init(format: String, features: [String]) {
        self.format = format
        self.features = VaultAuth.canonicalFeatures(features)
    }

    /// The markers of `manifest`.
    public init(_ manifest: EpochManifest) { self.init(format: manifest.format, features: manifest.features) }

    /// True when `manifest` names at least this major and every one of these features. Markers only
    /// ever grow, so anything less is a rollback.
    public func isCovered(by manifest: EpochManifest) -> Bool {
        let mine = SempereFormat.major(of: format) ?? 0
        let theirs = SempereFormat.major(of: manifest.format) ?? 0
        return theirs >= mine && Set(features).isSubset(of: Set(manifest.features))
    }

    /// The larger of two: the higher major, and every feature of either.
    func merged(with other: VaultMarkers) -> VaultMarkers {
        let a = SempereFormat.major(of: format) ?? 0, b = SempereFormat.major(of: other.format) ?? 0
        return VaultMarkers(format: b > a ? other.format : format, features: features + other.features)
    }
}
