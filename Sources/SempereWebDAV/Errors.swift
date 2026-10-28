import Foundation
import SempereSync

/// Errors from the WebDAV transport (`WebDAVClient`, `URLSessionTransport`).
/// The sync engine's own errors are `SyncError`. Messages never contain credentials.
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
    /// As `offline`, but no connection was made at all (no network, no route, the host not found, the connection
    /// refused): nothing of the request was sent (`sentNothing`). `isOffline` covers both.
    case notConnected(String)
    /// The TLS handshake failed because the server's certificate is not
    /// trusted (self-signed, unknown root, expired, wrong host, or not the
    /// certificate pinned for this server).
    case untrustedCertificate(String)
    /// The response could not be understood.
    case malformedResponse(String)
    /// A local filesystem operation failed (a streamed body or response file).
    case io(String)
    /// The response body exceeded the limit for this request; reading stopped there.
    case responseTooLarge(path: String, limit: Int)
}

extension WebDAVError {
    /// True for failures that say nothing about the server or the settings,
    /// only that it cannot be reached now (retry later).
    public var isOffline: Bool {
        switch self {
        case .offline, .notConnected: return true
        default: return false
        }
    }

    /// True when the server refused the user name or password (401) or
    /// access to the folder (403).
    public var isUnauthorized: Bool {
        if case .http(_, _, let status) = self { return status == 401 || status == 403 }
        return false
    }
}

extension WebDAVError: TransientRemoteError {
    /// Only `.offline` (`Transport.offlineCodes`: no network, host not found or not reachable, a timeout, a lost
    /// connection). `.transport` (TLS failures, a bad server response, anything else) is not: a lasting failure to
    /// show (review of #90, M1).
    public var isUnreachable: Bool { isOffline }

    /// A dropped connection or a timeout: the sync keeps a partial download for the next run.
    public var isTransient: Bool {
        switch self {
        case .transport, .offline, .notConnected: return true
        default: return false
        }
    }

    /// No connection was made: nothing of the request reached the server.
    public var sentNothing: Bool { if case .notConnected = self { return true } else { return false } }
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
        case .offline(let m), .notConnected(let m): return "server not reachable: \(m)"
        case .untrustedCertificate(let m): return "the server's certificate is not trusted: \(m)"
        case .malformedResponse(let m): return "malformed server response: \(SyncReport.printable(m))"
        case .io(let m): return m
        case .responseTooLarge(let path, let limit):
            return "the response for \(SyncReport.printable(path)) is over \(limit) bytes; not read"
        }
    }
}
