import Foundation

/// Errors from the WebDAV layer. Messages never contain credentials.
public enum WebDAVError: Error, Hashable, Sendable {
    /// Plain `http` to anything but localhost, or credentials in the URL.
    case insecureURL(String)
    /// The server answered with an unexpected status.
    case http(method: String, path: String, status: Int)
    /// The server redirected; follow-ups are refused so credentials stay put.
    case redirect(path: String, location: String)
    /// No response (connection, TLS, timeout).
    case transport(String)
    /// No response because the server cannot be reached from here right now
    /// (no network, host not found, connection refused or lost, timeout):
    /// worth trying again later, nothing is wrong with the vault or the settings.
    case offline(String)
    /// The TLS handshake failed because the server's certificate is not
    /// trusted (self-signed, unknown root, expired, wrong host, or not the
    /// certificate pinned for this server).
    case untrustedCertificate(String)
    /// The response could not be understood.
    case malformedResponse(String)
    /// The local vault and the remote one have different `vaultId`s.
    case vaultMismatch(local: String, remote: String)
    /// A local filesystem operation failed.
    case io(String)
    /// The response body exceeded the limit for this request; reading stopped there.
    case responseTooLarge(path: String, limit: Int)
    /// A bound of the whole run (`SyncLimits`) was reached; the run stopped
    /// there (security review 2026-10, W5).
    case limitExceeded(String)
}

extension WebDAVError {
    /// True for failures that say nothing about the server or the settings,
    /// only that it cannot be reached now (retry later).
    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }

    /// True when the server refused the user name or password (401) or
    /// access to the folder (403).
    public var isUnauthorized: Bool {
        if case .http(_, _, let status) = self { return status == 401 || status == 403 }
        return false
    }
}

extension WebDAVError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insecureURL(let m): return m
        case .http(let method, let path, let status):
            let hint = (status == 401 || status == 403) ? " (check --user and the password)" : ""
            return "\(method) /\(path) failed: HTTP \(status)\(hint)"
        case .redirect(let path, let location):
            return "/\(SyncReport.printable(path)) redirects to \(SyncReport.printable(location)); "
                + "use that URL instead (redirects are not followed)"
        case .transport(let m): return "network error: \(m)"
        case .offline(let m): return "server not reachable: \(m)"
        case .untrustedCertificate(let m): return "the server's certificate is not trusted: \(m)"
        case .malformedResponse(let m): return "malformed server response: \(SyncReport.printable(m))"
        case .vaultMismatch(let l, let r):
            return "the remote holds vault \(r) but the local vault is \(l); refusing to mix them"
        case .io(let m): return m
        case .responseTooLarge(let path, let limit):
            return "the response for \(SyncReport.printable(path)) is over \(limit) bytes; not read"
        case .limitExceeded(let m): return "sync run stopped: \(m)"
        }
    }
}
