import Foundation
import Sempere

/// Bounds of one sync run (security review 2026-10, W5). Each request is
/// bounded on its own (`maxFileBytes`, `maxBlobBytes`, listing sizes); these
/// bound the run as a whole, so a server cannot make it list, download or
/// last without end. Reaching one stops the run with
/// `SyncError.limitExceeded` in `errors` and `stoppedEarly`; what was done
/// so far is kept and recorded, and the next run continues.
public struct SyncLimits: Sendable, Hashable {
    /// Note folders the server may list.
    public var maxNotes: Int
    /// Remote entries listed in all (root, notes, note folders, `att/`).
    public var maxEntries: Int
    /// Bytes downloaded in all (revisions, blobs, mutable files).
    public var maxDownloadBytes: Int64
    /// Wall-clock seconds; checked before each note and each download.
    public var maxDuration: TimeInterval

    public static let defaultMaxNotes = 100_000
    public static let defaultMaxEntries = 1_000_000
    /// 64 GiB.
    public static let defaultMaxDownloadBytes: Int64 = 64 << 30
    /// 12 hours.
    public static let defaultMaxDuration: TimeInterval = 12 * 3600

    public init(maxNotes: Int = SyncLimits.defaultMaxNotes, maxEntries: Int = SyncLimits.defaultMaxEntries,
                maxDownloadBytes: Int64 = SyncLimits.defaultMaxDownloadBytes,
                maxDuration: TimeInterval = SyncLimits.defaultMaxDuration) {
        self.maxNotes = maxNotes; self.maxEntries = maxEntries
        self.maxDownloadBytes = maxDownloadBytes; self.maxDuration = maxDuration
    }
}

/// What one run has used of its `SyncLimits`.
struct RunBudget {
    let limits: SyncLimits
    let deadline: Date
    var entries = 0
    var downloadedBytes: Int64 = 0
    /// Listed sizes of the downloads running now (`reserve`), so that
    /// concurrent downloads together stay within `maxDownloadBytes`.
    var reservedBytes: Int64 = 0

    init(_ limits: SyncLimits, start: Date = Date()) {
        self.limits = limits
        deadline = start.addingTimeInterval(limits.maxDuration)
    }

    func checkTime() throws {
        if Date() > deadline { throw Self.timeExceeded(limits) }
    }

    /// The error of a run past `limits.maxDuration`.
    static func timeExceeded(_ limits: SyncLimits) -> SyncError {
        .limitExceeded("it ran for more than \(Int(limits.maxDuration / 60)) minutes (--max-minutes)")
    }

    mutating func list(_ count: Int) throws {
        entries += count
        if entries > limits.maxEntries {
            throw SyncError.limitExceeded("the server listed more than \(limits.maxEntries) entries (--max-entries)")
        }
    }

    /// Before a download of `size` bytes (nil: unknown, checked after):
    /// reserves them until `downloaded(_:reserved:)` (the returned amount).
    mutating func willDownload(_ size: Int?) throws -> Int64 {
        try checkTime()
        let wanted = Int64(max(size ?? 0, 0))
        // Saturating: `size` is what the server claims.
        let (held, overflowHeld) = downloadedBytes.addingReportingOverflow(reservedBytes)
        let (total, overflow) = held.addingReportingOverflow(wanted)
        if overflowHeld || overflow || total > limits.maxDownloadBytes {
            throw SyncError.limitExceeded("more than \(limits.maxDownloadBytes >> 20) MiB would be downloaded (--max-download-mib)")
        }
        reservedBytes += wanted
        return wanted
    }

    /// Ends a reservation of `willDownload` whose download did not happen.
    mutating func release(_ reserved: Int64) {
        reservedBytes = max(reservedBytes - reserved, 0)
    }

    /// Counts `size` received bytes, ending the reservation made for them.
    mutating func downloaded(_ size: Int, reserved: Int64) throws {
        release(reserved)
        try downloaded(size)
    }

    mutating func downloaded(_ size: Int) throws {
        downloadedBytes += Int64(max(size, 0))
        if downloadedBytes > limits.maxDownloadBytes {
            throw SyncError.limitExceeded("more than \(limits.maxDownloadBytes >> 20) MiB were downloaded (--max-download-mib)")
        }
    }
}

/// Stops the run on a run limit; any other error is the file's own.
func rethrowRunLimit(_ error: Error) throws {
    if let e = error as? SyncError, e.isRunLimit { throw e }
}

// MARK: - Quarantine (format.md §9.1, security review 2026-10, W2)

extension SyncEngine {
    /// The clock that times how long a version tag stood for the same bytes (`stampSettleInterval`): the real one,
    /// never `SyncOptions.now`, which a caller may set (tests replay runs on a clock of their own). Only tests replace it.
    nonisolated(unsafe) static var stampClock: @Sendable () -> Date = { Date() }

    /// The machine's uptime for `settle` (`ProcessInfo.systemUptime`, which only moves forward within a boot and a
    /// step of the wall clock does not move). Only tests replace it.
    nonisolated(unsafe) static var stampUptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// How long after the first read under a version tag a later read must come before the tag is trusted to show a
    /// rewrite. Many servers make a file's tag from its modification time in whole seconds (wsgidav, nginx and
    /// lighttpd from inode, mtime and size; any server without ETags, whose stamp is `Last-Modified`), so a
    /// same-size rewrite within the second the copy was written keeps the tag. A read at least this long after the
    /// first comes after that second ended, for any tag whose clock ticks in steps under 5 s (FAT keeps 2 s; the
    /// stress runs' 4-second buckets needed 5 s). It only delays the read that settles the tag; it adds none.
    static let stampSettleInterval: TimeInterval = 5

    /// The timing of a version tag seen again for the same bytes (`previous`: when it was first seen so; nil, or
    /// another tag or other bytes: starts now). It settles once read again at least `stampSettleInterval` after it
    /// was first, by the wall clock and, within one boot, by the uptime too: a wall clock stepped forward is not time
    /// that passed. An uptime lower than the first one means a reboot in between, itself longer than the interval.
    /// A stamp that holds no time (`trusted` false: a size, or none) never settles.
    static func settle(_ previous: SyncState.StampTiming?, trusted: Bool = true, now: Date = stampClock(),
                       uptime: TimeInterval = stampUptime()) -> SyncState.StampTiming {
        let fresh = SyncState.StampTiming(since: now, settled: false, uptime: uptime)
        guard trusted, let previous, previous.since <= now else { return fresh }
        if previous.settled { return previous }
        guard let before = previous.uptime else { return fresh }
        let wall = now.timeIntervalSince(previous.since) >= stampSettleInterval
        let up = uptime < before || uptime - before >= stampSettleInterval
        return .init(since: previous.since, settled: wall && up, uptime: before)
    }

    /// True for a stamp that changes with the time (an ETag or `Last-Modified`), false for the size a remote with
    /// neither gives (`quarantineStamp`) or none: only the first can settle (`settle`). An ETag made of the size alone
    /// cannot be told apart; such a server keeps a same-size rewrite hidden (key-hierarchy design §16.13).
    static func stampCanSettle(_ stamp: String?) -> Bool {
        guard let stamp, !stamp.isEmpty else { return false }
        return !stamp.hasPrefix("size:")
    }

    /// Where quarantined files go: `quarantineDirectory`, else next to the
    /// sync state (`<state>.quarantine/`), outside the vault, so nothing
    /// there is ever read as part of it.
    var quarantineRoot: URL {
        options.quarantineDirectory
            ?? stateURL.deletingPathExtension().appendingPathExtension("quarantine")
    }

    /// The vault received files are checked against: the unlocked one, else
    /// the local folder opened locked (structure only), else none (a first
    /// pull that got no `vault.json`: the age magic only). Opened again
    /// after this run replaced `vault.json`, so a rotation that arrived with
    /// it is checked under the new secret.
    func checker() -> Vault? {
        locked { lockedChecker() }
    }

    private func lockedChecker() -> Vault? {
        let manifest = manifestHash()
        if let cached = checkerCache, cached.manifest == manifest { return cached.vault }
        var v: Vault?
        if let vault {
            v = manifest == checkerBaseManifest ? vault : ((try? vault.reopened()) ?? vault)
        } else if !options.firstPullIdentities.isEmpty,
                  let opened = try? Vault.open(at: root, identities: options.firstPullIdentities) {
            v = opened
        } else {
            v = try? Vault.open(at: root)
        }
        checkerCache = (manifest, v)
        return v
    }

    /// SHA-256 (hex) of the local `vault.json`, nil when absent or unreadable.
    func manifestHash() -> String? {
        guard let data = try? localMutable(Vault.manifestName) else { return nil }
        return FileDigest.sha256(data)
    }

    /// True when `key` was quarantined by an earlier run against the same
    /// remote version and the same local `vault.json` and lock state (so the
    /// result would be the same): it is not downloaded again, and is listed
    /// in `skipped`.
    func skipQuarantined(_ key: String, path: String, entry: RemoteEntry?) -> Bool {
        locked { lockedSkipQuarantined(key, path: path, entry: entry) }
    }

    private func lockedSkipQuarantined(_ key: String, path: String, entry: RemoteEntry?) -> Bool {
        guard !options.retryQuarantined, let record = state.quarantined?[key] else { return false }
        let checker = checker()
        guard record.stamp == Self.quarantineStamp(entry), record.manifest == manifestHash(),
              record.unlocked == (checker?.canRead ?? false), record.key == Self.checkerKeyID(checker) else {
            state.quarantined?[key] = nil
            return false
        }
        // An unchanged stamp shows unchanged bytes only once it settled (`QuarantineRecord.settled`): until then the
        // file is read again, and the refusal records the same bytes without reporting them twice (`lockedRepeatedRefusal`).
        guard record.settled || refusedThisRun.contains(key) else { return false }
        report.skipped.append(.init(path: path, message: Self.unchangedMessage(record)))
        return true
    }

    private static func unchangedMessage(_ record: SyncState.QuarantineRecord) -> String {
        record.setAside == true
            ? "set aside by an earlier run (from before a device change) and unchanged on the server; not downloaded again"
            : "quarantined by an earlier run and unchanged on the server; not downloaded again (--retry-quarantined)"
    }

    /// A refusal of `key` under the current checker: its record, timed from the first refusal of the same bytes
    /// under the same fields (`QuarantineRecord.settled`).
    func lockedRefusalRecord(_ key: String, entry: RemoteEntry?, checker: Vault?, sha256: String?,
                             setAside: Bool?) -> SyncState.QuarantineRecord {
        var record = SyncState.QuarantineRecord(stamp: Self.quarantineStamp(entry), manifest: manifestHash(),
                                                unlocked: checker?.canRead ?? false, key: Self.checkerKeyID(checker),
                                                setAside: setAside)
        record.sha256 = sha256
        var previous: SyncState.StampTiming?
        if let old = state.quarantined?[key], let sha256, old.sha256 == sha256, old.stamp == record.stamp,
           old.manifest == record.manifest, old.unlocked == record.unlocked, old.key == record.key,
           old.setAside == record.setAside {
            previous = old.timing
        }
        record.timing = Self.settle(previous, trusted: Self.stampCanSettle(record.stamp))
        return record
    }

    /// True when `key` was refused before with these very bytes under the same fields (read again because its record
    /// had not settled): the record is brought up to date and the file reported as skipped, not refused again.
    func lockedRepeatedRefusal(_ key: String, path: String, entry: RemoteEntry?, checker: Vault?, sha256: String?,
                               setAside: Bool?) -> Bool {
        // Asked to check quarantined files again (`--retry-quarantined`, Repair): a refusal is reported as one.
        // A record from before the bytes were kept (`sha256` nil) counts as the same bytes when every other field
        // matches, so the first read after an upgrade is not reported as a new refusal.
        guard !options.retryQuarantined, let sha256, let old = state.quarantined?[key], old.sha256 == sha256 || old.sha256 == nil,
              old.setAside == setAside else { return false }
        let record = lockedRefusalRecord(key, entry: entry, checker: checker, sha256: sha256, setAside: setAside)
        guard record.stamp == old.stamp, record.manifest == old.manifest, record.unlocked == old.unlocked,
              record.key == old.key else { return false }
        state.quarantined?[key] = record
        refusedThisRun.insert(key)
        report.skipped.append(.init(path: path, message: Self.unchangedMessage(record)))
        return true
    }

    /// SHA-256 (hex) of refused bytes (`data`, else the file), nil when the file cannot be read.
    static func refusedDigest(data: Data?, file: URL?) -> String? {
        if let data { return FileDigest.sha256(data) }
        return file.flatMap { try? FileDigest.sha256(of: $0).hex }
    }

    /// Names the key a file was checked under (the epoch key the checker holds, by its public `epochId`,
    /// format.md §15.2), so a quarantine record made under one key never keeps a file out of a run under
    /// another: 16 hex digits of a SHA-256 of a label and the epoch id. Nil when locked.
    static func checkerKeyID(_ checker: Vault?) -> String? {
        guard let checker, checker.canRead else { return nil }
        var data = Data("sempere/1 quarantine key id".utf8)
        data.append(0)
        data.append(checker.manifest.epochId)
        return String(FileDigest.sha256(data).prefix(16))
    }

    static func quarantineStamp(_ entry: RemoteEntry?) -> String? {
        entry?.stamp ?? entry?.size.map { "size:\($0)" }
    }

    /// Distinct copies of one vault path the quarantine keeps (the first under
    /// the path itself, the others beside it, `quarantineCopyName`). A further
    /// distinct copy is not kept, and reported so; the ones kept stay.
    static let maxQuarantinedCopies = 16

    /// The name of a further distinct copy of `name` in the quarantine:
    /// `<name>.copy-<first 16 hex digits of its SHA-256>`.
    static func quarantineCopyName(_ name: String, hash: String) -> String {
        "\(name).copy-\(hash.prefix(16))"
    }

    /// Records a refused download: moves `file` (or writes `data`) to the
    /// quarantine folder under its vault path and reports it.
    ///
    /// Nothing in the quarantine is ever replaced or removed (design §6, I6:
    /// a file leaves it only by Adopt or Export). The first copy of a path is
    /// kept under the path; a copy with other bytes, quarantined later, is
    /// kept beside it under a content-addressed name, and one with the same
    /// bytes as a kept copy is not kept twice. At most
    /// `maxQuarantinedCopies` distinct copies of a path are kept, so a
    /// server cannot fill the disk by changing one file again and again.
    func quarantine(_ key: String, path: String, entry: RemoteEntry?, reason: String,
                    data: Data? = nil, file: URL? = nil) {
        locked { lockedQuarantine(key, path: path, entry: entry, reason: reason, data: data, file: file) }
    }

    private func lockedQuarantine(_ key: String, path: String, entry: RemoteEntry?, reason: String, data: Data?, file: URL?) {
        let fm = FileManager.default
        let sha256 = Self.refusedDigest(data: data, file: file)
        if lockedRepeatedRefusal(key, path: path, entry: entry, checker: checker(), sha256: sha256, setAside: nil) {
            if let file { try? fm.removeItem(at: file) }
            return
        }
        let first = quarantineRoot.appendingPathComponent(path)
        var kept: String
        do {
            try fm.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantineRoot.path)
            kept = try keepQuarantined(first: first, data: data, file: file)
        } catch {
            kept = "not kept: \(Self.describe(error))"
        }
        if let file { try? fm.removeItem(at: file) }
        report.quarantined.append(.init(path: path, message: SyncReport.printable(reason) + " (\(kept))"))
        state.quarantined = state.quarantined ?? [:]
        let record = lockedRefusalRecord(key, entry: entry, checker: checker(), sha256: sha256, setAside: nil)
        state.quarantined?[key] = record
        refusedThisRun.insert(key)
    }

    /// Keeps one refused copy (`data`, or the file `file`) beside the copies of
    /// the same path kept already, never over one: the report's text says where.
    private func keepQuarantined(first: URL, data: Data?, file: URL?) throws -> String {
        let fm = FileManager.default
        let hash: String
        if let file { hash = try FileDigest.sha256(of: file).hex } else if let data { hash = FileDigest.sha256(data) } else {
            return "nothing to keep"
        }
        func place(_ target: URL) throws {
            // Never over an existing file: a move or a write that finds the name taken fails.
            if let file { try fm.moveItem(at: file, to: target) } else if let data { try data.write(to: target, options: .withoutOverwriting) }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        guard fm.fileExists(atPath: first.path) else {
            try place(first)
            return first.path
        }
        if (try? FileDigest.sha256(of: first).hex) == hash { return "the same copy is kept at \(first.path)" }
        let dir = first.deletingLastPathComponent(), name = first.lastPathComponent
        let copy = dir.appendingPathComponent(Self.quarantineCopyName(name, hash: hash))
        if fm.fileExists(atPath: copy.path) { return "the same copy is kept at \(copy.path)" }
        let others = try LocalFS.entries(dir).filter { $0.hasPrefix(name + ".copy-") }.count
        guard 1 + others < Self.maxQuarantinedCopies else {
            return "not kept: \(Self.maxQuarantinedCopies) other copies of it are kept already, in \(dir.path)"
        }
        try place(copy)
        return "another copy of this path was quarantined before; this one is kept at \(copy.path)"
    }
}
