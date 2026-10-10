import Foundation

/// When the app pushes a WebDAV vault's local copy (docs/io.md, "WebDAV
/// vaults in the app", "When it pushes"). Pure logic: the caller tells it
/// what happened and asks when the next run is due.
///
/// - after a write: `writeDelay` after the last one;
/// - on demand (unlock, the app becoming active, "Sync Now"): at once;
/// - otherwise every `interval` after the last attempt;
/// - after a failure: `firstRetry`, doubling up to `maxRetry` (a write or a
///   demand still runs sooner);
/// - never while a run is going: one that ends with writes or a demand
///   behind it is followed by another.
public struct WebDAVPushSchedule: Sendable, Equatable {
    public var writeDelay: TimeInterval = 10
    public var interval: TimeInterval = 300
    public var firstRetry: TimeInterval = 30
    public var maxRetry: TimeInterval = 900

    /// A run is going.
    public private(set) var running = false
    /// Consecutive failed runs.
    public private(set) var failures = 0
    /// When the last run started.
    public private(set) var lastAttempt: Date?
    /// When the last run that succeeded ended.
    public private(set) var lastSuccess: Date?
    /// The last write not yet covered by a run that started after it.
    public private(set) var pendingWrite: Date?
    /// A run was asked for and has not started yet.
    public private(set) var demanded = false

    public init() {}

    /// A write to the local copy happened.
    public mutating func noteWrite(at date: Date) { pendingWrite = date }

    /// Ask for a run as soon as possible.
    public mutating func demand() { demanded = true }

    /// A run starts now.
    public mutating func started(at date: Date) {
        running = true
        lastAttempt = date
        demanded = false
        // Writes up to here are in this run (a run lists the folder as it goes).
        if let w = pendingWrite, w <= date { pendingWrite = nil }
    }

    /// The run ended.
    public mutating func finished(at date: Date, success: Bool) {
        running = false
        if success {
            failures = 0
            lastSuccess = date
        } else {
            failures = min(failures + 1, 32)
        }
    }

    /// The wait before an automatic retry after `failures` failures.
    public var retryDelay: TimeInterval {
        guard failures > 0 else { return 0 }
        let factor = pow(2.0, Double(min(failures - 1, 20)))
        return min(firstRetry * factor, maxRetry)
    }

    /// When the next run is due; nil while one is running.
    public func nextRun(now: Date) -> Date? {
        guard !running else { return nil }
        if demanded || lastAttempt == nil { return now }
        var due: Date
        if failures > 0, let last = lastAttempt {
            due = last.addingTimeInterval(retryDelay)
        } else {
            due = (lastAttempt ?? now).addingTimeInterval(interval)
        }
        if let w = pendingWrite { due = min(due, w.addingTimeInterval(writeDelay)) }
        return max(due, now)
    }

    /// True when a run should start now.
    public func isDue(now: Date) -> Bool {
        guard let next = nextRun(now: now) else { return false }
        return next <= now
    }
}

/// What the user is told about a WebDAV vault's last push.
public enum WebDAVSyncProblem: Hashable, Sendable {
    /// The server cannot be reached; changes stay in the local copy.
    case offline
    /// The server refused the user name or password.
    case unauthorized
    /// The server's certificate is not trusted (or not the pinned one).
    case certificate(String)
    /// The server folder holds another vault.
    case otherVault
    /// The server folder is gone (404), or holds no vault any more.
    case notFound
    /// The server redirects; the URL must be changed.
    case redirect(String)
    /// The server's `vault.json` (or rewrap journal) was changed elsewhere and kept.
    case serverChangedManifest
    /// Some files could not be uploaded or removed (first messages).
    case failures([String])
    /// Anything else that stopped the run.
    case failed(String)

    /// A stable identifier (`sempere webdav check --json` "problem").
    public var code: String {
        switch self {
        case .offline: return "offline"
        case .unauthorized: return "unauthorized"
        case .certificate: return "certificate"
        case .otherVault: return "other-vault"
        case .notFound: return "not-found"
        case .redirect: return "redirect"
        case .serverChangedManifest: return "server-changed-manifest"
        case .failures: return "failures"
        case .failed: return "failed"
        }
    }

    /// True when only time can fix it (the run is retried by itself).
    public var isTransient: Bool {
        if case .offline = self { return true }
        return false
    }

    /// The problem for a run that threw.
    public static func from(error: Error) -> WebDAVSyncProblem {
        guard let e = error as? WebDAVError else { return .failed(WebDAVSync.describe(error)) }
        switch e {
        case .offline: return .offline
        case .untrustedCertificate(let m): return .certificate(SyncReport.printable(m))
        case .vaultMismatch: return .otherVault
        case .redirect(_, let location): return .redirect(SyncReport.printable(location))
        case .http(_, _, let status) where status == 401 || status == 403: return .unauthorized
        case .http(_, _, let status) where status == 404: return .notFound
        default: return .failed(WebDAVSync.describe(e))
        }
    }

    /// The problems a finished push reports (empty: all is well).
    public static func from(report: SyncReport) -> [WebDAVSyncProblem] {
        var out: [WebDAVSyncProblem] = []
        if !report.conflicts.isEmpty { out.append(.serverChangedManifest) }
        if !report.errors.isEmpty {
            out.append(.failures(report.errors.prefix(3).map { "\($0.path): \($0.message)" }))
        }
        return out
    }
}
