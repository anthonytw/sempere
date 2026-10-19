import Foundation

/// Errors of the sync engine (`SyncEngine`, `LocalCopy`). A transport's own
/// failures (HTTP status, TLS, no network) are its own error type
/// (`SyncError` in SempereWebDAV) and pass through the engine unchanged.
/// Messages never contain credentials.
public enum SyncError: Error, Hashable, Sendable {
    /// The local vault and the remote one have different `vaultId`s.
    case vaultMismatch(local: String, remote: String)
    /// A local filesystem operation failed, or a run was refused before it started.
    case io(String)
    /// What the remote holds could not be understood (a `vault.json` that is
    /// not a manifest, a file whose size differs from its listing).
    case malformedResponse(String)
    /// A remote file exceeded the limit for it; it was not read.
    case responseTooLarge(path: String, limit: Int)
    /// A bound of the whole run (`SyncLimits`) was reached; the run stopped
    /// there (security review 2026-10, W5).
    case limitExceeded(String)
    /// The caller canceled the run (`SyncOptions.isCancelled`); it
    /// stopped like a run bound does, and the next run continues.
    case cancelled
}

extension SyncError {
    /// True for a bound of the whole run, or a cancellation: it stops the run, not one file.
    public var isRunLimit: Bool {
        switch self {
        case .limitExceeded, .cancelled: return true
        default: return false
        }
    }
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .vaultMismatch(let l, let r):
            return "the remote holds vault \(r) but the local vault is \(l); refusing to mix them"
        case .io(let m): return m
        case .malformedResponse(let m): return "malformed server response: \(SyncReport.printable(m))"
        case .responseTooLarge(let path, let limit):
            return "the response for \(SyncReport.printable(path)) is over \(limit) bytes; not read"
        case .limitExceeded(let m): return "sync run stopped: \(m)"
        case .cancelled: return "sync run canceled"
        }
    }
}
