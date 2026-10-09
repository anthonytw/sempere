import Foundation
import Sempere

/// Bounds of one sync run (security review 2026-10, W5). Each request is
/// bounded on its own (`maxFileBytes`, `maxBlobBytes`, listing sizes); these
/// bound the run as a whole, so a server cannot make it list, download or
/// last without end. Reaching one stops the run with
/// `WebDAVError.limitExceeded` in `errors` and `stoppedEarly`; what was done
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

    init(_ limits: SyncLimits, start: Date = Date()) {
        self.limits = limits
        deadline = start.addingTimeInterval(limits.maxDuration)
    }

    func checkTime() throws {
        if Date() > deadline {
            throw WebDAVError.limitExceeded("it ran for more than \(Int(limits.maxDuration)) seconds (--max-minutes)")
        }
    }

    mutating func list(_ count: Int) throws {
        entries += count
        if entries > limits.maxEntries {
            throw WebDAVError.limitExceeded("the server listed more than \(limits.maxEntries) entries (--max-entries)")
        }
    }

    /// Before a download of `size` bytes (nil: unknown, checked after).
    func willDownload(_ size: Int?) throws {
        try checkTime()
        if downloadedBytes + Int64(max(size ?? 0, 0)) > limits.maxDownloadBytes {
            throw WebDAVError.limitExceeded("more than \(limits.maxDownloadBytes) bytes would be downloaded (--max-download-mib)")
        }
    }

    mutating func downloaded(_ size: Int) throws {
        downloadedBytes += Int64(max(size, 0))
        if downloadedBytes > limits.maxDownloadBytes {
            throw WebDAVError.limitExceeded("more than \(limits.maxDownloadBytes) bytes were downloaded (--max-download-mib)")
        }
    }
}

extension WebDAVError {
    /// True for a bound of the whole run: it stops the run, not one file.
    var isRunLimit: Bool {
        if case .limitExceeded = self { return true }
        return false
    }
}

/// Stops the run on a run limit; any other error is the file's own.
func rethrowRunLimit(_ error: Error) throws {
    if let e = error as? WebDAVError, e.isRunLimit { throw e }
}

// MARK: - Quarantine (format.md §9.1, security review 2026-10, W2)

extension WebDAVSync {
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
        guard !options.retryQuarantined, let record = state.quarantined?[key] else { return false }
        let checker = checker()
        guard record.stamp == Self.quarantineStamp(entry), record.manifest == manifestHash(),
              record.unlocked == (checker?.canRead ?? false) else {
            state.quarantined?[key] = nil
            return false
        }
        report.skipped.append(.init(path: path, message: "quarantined by an earlier run and unchanged on the server; "
                                    + "not downloaded again (--retry-quarantined)"))
        return true
    }

    static func quarantineStamp(_ entry: RemoteEntry?) -> String? {
        entry?.stamp ?? entry?.size.map { "size:\($0)" }
    }

    /// Records a refused download: moves `file` (or writes `data`) to the
    /// quarantine folder under its vault path and reports it.
    func quarantine(_ key: String, path: String, entry: RemoteEntry?, reason: String,
                    data: Data? = nil, file: URL? = nil) {
        let target = quarantineRoot.appendingPathComponent(path)
        var kept = target.path
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantineRoot.path)
            try? fm.removeItem(at: target)
            if let file {
                try fm.moveItem(at: file, to: target)
            } else if let data {
                try data.write(to: target, options: .withoutOverwriting)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            if let file { try? FileManager.default.removeItem(at: file) }
            kept = "not kept: \(Self.describe(error))"
        }
        report.quarantined.append(.init(path: path, message: SyncReport.printable(reason) + " (\(kept))"))
        state.quarantined = state.quarantined ?? [:]
        state.quarantined?[key] = .init(stamp: Self.quarantineStamp(entry), manifest: manifestHash(),
                                        unlocked: checker()?.canRead ?? false)
    }
}
