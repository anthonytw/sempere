import Foundation
import SempereWebDAV

/// What identifies one vault connection: operations with an equal key may share a transport (and so its
/// TCP/TLS connections). The certificate pin is part of it, so a transport built for one pin is never used
/// under another, and a changed address or credential starts over.
struct WebDAVConnectionKey: Hashable, Sendable {
    var url: URL
    var user: String?
    var password: String?
    var pinnedCertificate: String?

    init(_ e: WebDAVEndpoint) {
        url = e.url
        user = e.user
        password = e.password
        pinnedCertificate = e.pinnedCertificate?.lowercased()
    }
}

/// Keeps one transport for the open vault's connection, so consecutive pushes and fetches reuse its
/// connections instead of opening new TCP/TLS ones each time.
///
/// One slot: asking for another key (credentials, URL or pin changed) replaces the transport, and
/// `release()` (the vault closed) empties it. A dropped transport is not torn down by force: operations still
/// holding it finish on it, and `URLSessionTransport` invalidates its sessions (`finishTasksAndInvalidate`) when
/// the last reference goes, so no session leaks and no request in flight is cut off. Trust is decided per
/// connection by the transport's own `PinnedServerTrust`, built from the key's pin; nothing is cached across pins.
final class WebDAVTransportPool: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (key: WebDAVConnectionKey, transport: any WebDAVTransport)?
    private let make: @Sendable (WebDAVEndpoint) -> any WebDAVTransport
    /// How many transports this pool has built (for tests).
    private(set) var created = 0

    init(make: @escaping @Sendable (WebDAVEndpoint) -> any WebDAVTransport) { self.make = make }

    /// The pooled transport for `endpoint`, built on first use or when the key changed.
    func transport(for endpoint: WebDAVEndpoint) -> any WebDAVTransport {
        let key = WebDAVConnectionKey(endpoint)
        lock.lock(); defer { lock.unlock() }
        if let current, current.key == key { return current.transport }
        let transport = make(endpoint)
        created += 1
        current = (key, transport)
        return transport
    }

    /// Drops the pooled transport (the vault closed); its sessions invalidate once nothing uses them.
    func release() {
        lock.lock(); let old = current; current = nil; lock.unlock()
        _ = old
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return current == nil }
}
