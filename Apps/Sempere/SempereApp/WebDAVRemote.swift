import Age
import CryptoKit
import Foundation
import Network
import Security
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV

/// `WebDAVRemote` over `URLSession` (`SempereWebDAV`): https only (http to
/// localhost), Basic auth, redirects never followed, the certificate either
/// trusted by the system or the one pinned for the location.
struct LiveWebDAVRemote: WebDAVRemote {
    /// The open vault's transport, reused by every operation with the same address, credentials and pin.
    let pool: WebDAVTransportPool

    init(pool: WebDAVTransportPool = WebDAVTransportPool(make: { e in
        URLSessionTransport(timeout: 30, serverTrust: PinnedServerTrust(pin: e.pinnedCertificate, recorder: nil))
    })) {
        self.pool = pool
    }

    func releaseConnections() { pool.release() }

    func syncRemote(_ endpoint: WebDAVEndpoint) throws -> any SyncRemote { WebDAVSyncRemote(try client(endpoint)) }

    /// A client on the pooled transport; `check` (Test Connection, which needs the recorder and runs once) is
    /// the only caller that builds a transport of its own.
    func client(_ e: WebDAVEndpoint, recorder: CertificateRecorder? = nil) throws -> WebDAVClient {
        let credentials = e.user.map { WebDAVCredentials(user: $0, password: e.password ?? "") }
        let transport: any WebDAVTransport = recorder == nil
            ? pool.transport(for: e)
            : URLSessionTransport(timeout: 30, serverTrust: PinnedServerTrust(pin: e.pinnedCertificate, recorder: recorder))
        return try WebDAVClient(baseURL: e.url, credentials: credentials, transport: transport)
    }

    /// `WebDAVConnection.probe` (the CLI's `webdav check` too), with the refused certificate for the trust sheet.
    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe {
        let recorder = CertificateRecorder()
        switch WebDAVConnection.probe({ try client(endpoint, recorder: recorder) }) {
        case .reachable(let result):
            return .reachable(result)
        case .failed(let problem, let message):
            return .failed(problem, message: message, certificate: problem.isCertificate ? recorder.certificate : nil)
        }
    }

    /// `WebDAVConnection.probeTarget` (the CLI's `store target add --webdav --check` too), as `check`.
    func checkTarget(_ endpoint: WebDAVEndpoint, vaultID: UUID) -> WebDAVTargetProbe {
        let recorder = CertificateRecorder()
        switch WebDAVConnection.probeTarget({ try client(endpoint, recorder: recorder) }, vaultId: vaultID) {
        case .checked(let folder):
            return .checked(folder)
        case .failed(let problem, let message):
            return .failed(problem, message: message, certificate: problem.isCertificate ? recorder.certificate : nil)
        }
    }

    func download(_ endpoint: WebDAVEndpoint, into copy: LocalCopy) throws -> SyncReport {
        try copy.download(client: try client(endpoint))
    }

    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: LocalCopy, options: SyncOptions) throws -> SyncReport {
        try copy.downloadMetadata(client: try client(endpoint), options: options)
    }

    func fetch(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, scope: FetchScope) throws -> SyncReport {
        try copy.fetch(client: try client(endpoint), vault: vault, scope: scope)
    }

    func push(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        try copy.push(client: try client(endpoint), vault: vault, options: options)
    }

    func sync(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        try copy.sync(client: try client(endpoint), vault: vault, options: options)
    }

    func redownload(_ endpoint: WebDAVEndpoint, copy: LocalCopy, identities: [any AgeIdentity],
                    partial: Bool, options: SyncOptions) throws -> (report: SyncReport, replaced: Bool) {
        try copy.redownload(client: try client(endpoint), identities: identities, partial: partial, options: options)
    }
}

/// The server certificate seen by the last refused handshake.
final class CertificateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: ServerCertificate?
    var certificate: ServerCertificate? { lock.lock(); defer { lock.unlock() }; return seen }
    func record(_ c: ServerCertificate) { lock.lock(); seen = c; lock.unlock() }
}

/// TLS server trust for one WebDAV location: the system decides, unless the
/// user pinned a certificate, which is then the only one accepted (its
/// SHA-256 must match the leaf's exactly). A refused certificate is recorded
/// so the connect sheet can show it.
struct PinnedServerTrust: WebDAVServerTrust {
    var pin: String?
    var recorder: CertificateRecorder?

    func evaluate(_ challenge: URLAuthenticationChallenge) -> WebDAVTrustDecision {
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return .reject(String(localized: "The server sent no certificate."))
        }
        let certificate = Self.describe(leaf)
        if let pin {
            if certificate.sha256 == pin.lowercased() { return .accept(URLCredential(trust: trust)) }
            recorder?.record(certificate)
            return .reject(String(localized: "The server's certificate changed since you trusted it."))
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return .systemDefault }
        recorder?.record(certificate)
        if let error, Self.isDateProblem(CFErrorGetCode(error)) { return .reject(CertificateDate.refusal) }
        let reason = error.map { CFErrorCopyDescription($0) as String } ?? String(localized: "The system does not trust it.")
        return .reject(reason)
    }

    /// The trust evaluation failed on the certificate's dates (expired, or not valid yet): with a clock far off,
    /// a good certificate fails this way (offline audit P14).
    static func isDateProblem(_ code: CFIndex) -> Bool {
        code == CFIndex(errSecCertificateExpired) || code == CFIndex(errSecCertificateNotValidYet)
    }

    static func describe(_ certificate: SecCertificate) -> ServerCertificate {
        let der = SecCertificateCopyData(certificate) as Data
        let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "?"
        return ServerCertificate(sha256: hash, subject: SyncReport.printable(String(subject.prefix(120))))
    }
}

// MARK: - Reachability

/// Tells the WebDAV targets when the network comes back (`SyncCoordinator.networkChanged`: a run soon, the
/// backoff forgotten; docs/design/device-first-sync.md §4). `NWPathMonitor` only watches the device's own
/// interfaces: it connects to nothing. Tests drive the coordinator directly.
@MainActor
final class WebDAVReachability {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.anthonytw.sempere.reachability", qos: .utility)

    /// Starts watching; `changed` gets every change (on the main actor), the first one at once.
    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let reachable = path.status == .satisfied
            Task { @MainActor in changed(reachable) }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
