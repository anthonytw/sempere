import Age
import CryptoKit
import Foundation
import Network
import Security
import Sempere
import SempereSync
import SempereWebDAV

/// Where and as whom to reach a WebDAV vault.
struct WebDAVEndpoint: Sendable {
    var url: URL
    var user: String?
    /// From the Keychain; never logged.
    var password: String?
    /// The certificate pin of the location (`WebDAVLocation.pinnedCertificate`).
    var pinnedCertificate: String?
}

/// A server certificate the system did not trust, as the connect sheet shows it.
struct ServerCertificate: Hashable, Sendable {
    /// SHA-256 of the DER bytes, lowercase hex: what a pin stores.
    var sha256: String
    /// The certificate's subject summary (usually its common name).
    var subject: String

    /// The fingerprint grouped in pairs, as servers print it ("AB:CD:…").
    var fingerprint: String {
        stride(from: 0, to: sha256.count, by: 2).map { i -> String in
            let start = sha256.index(sha256.startIndex, offsetBy: i)
            return sha256[start..<sha256.index(start, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }
}

/// What "Test Connection" found.
enum WebDAVProbe: Sendable {
    case reachable(WebDAVCheckResult)
    /// `certificate` is set when the server's certificate was not trusted.
    case failed(WebDAVSyncProblem, message: String, certificate: ServerCertificate?)
}

extension WebDAVRemote {
    /// Fakes that do not model folders: an empty folder.
    func checkTarget(_ endpoint: WebDAVEndpoint, vaultID: UUID) -> WebDAVTargetProbe { .checked(.empty) }
}

/// The server operations the app makes, all blocking (call them off the
/// main actor). `LiveWebDAVRemote` is the network; tests use a fake.
protocol WebDAVRemote: Sendable {
    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe
    /// Add WebDAV Server…: what the folder holds (`WebDAVConnection.checkTargetFolder`).
    func checkTarget(_ endpoint: WebDAVEndpoint, vaultID: UUID) -> WebDAVTargetProbe
    func download(_ endpoint: WebDAVEndpoint, into copy: LocalCopy) throws -> SyncReport
    /// The root files, sealed summaries and note list into a partial copy (format.md §1.2). `options`
    /// carry the progress callback and the Cancel (`AppModel.withWebDAVDownload`).
    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: LocalCopy, options: SyncOptions) throws -> SyncReport
    /// Fetches what the partial copy lacks within `scope`; never uploads or deletes.
    func fetch(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, scope: FetchScope) throws -> SyncReport
    func push(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport
    /// A two-way run of the copy with the server (`LocalCopy.sync`): takes what other devices wrote, checked
    /// before it is placed, and uploads what this device wrote.
    func sync(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport
    /// With `partial`, the new copy is a partial copy filled by `fetch` afterwards.
    func redownload(_ endpoint: WebDAVEndpoint, copy: LocalCopy, identities: [any AgeIdentity],
                    partial: Bool, options: SyncOptions) throws -> (report: SyncReport, replaced: Bool)
    /// The open vault closed: drop any connections kept for it.
    func releaseConnections()
    /// The server as the sync engine's remote, for what a re-encryption does on a target itself (its claim, its
    /// confirmation: key-hierarchy KH6, `ReencryptCoordinator`).
    func syncRemote(_ endpoint: WebDAVEndpoint) throws -> any SyncRemote
}

extension WebDAVRemote {
    func releaseConnections() {}
    func syncRemote(_ endpoint: WebDAVEndpoint) throws -> any SyncRemote {
        throw WebDAVVaultError.noSuchLocation
    }
}

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

    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe {
        let recorder = CertificateRecorder()
        do {
            return .reachable(try WebDAVConnection.check(try client(endpoint, recorder: recorder)))
        } catch {
            let problem = WebDAVSyncProblem.from(error: error)
            var certificate: ServerCertificate?
            if case .certificate = problem { certificate = recorder.certificate }
            return .failed(problem, message: WebDAVErrorText.message(error), certificate: certificate)
        }
    }

    func checkTarget(_ endpoint: WebDAVEndpoint, vaultID: UUID) -> WebDAVTargetProbe {
        let recorder = CertificateRecorder()
        do {
            return .checked(try WebDAVConnection.checkTargetFolder(try client(endpoint, recorder: recorder), vaultId: vaultID))
        } catch {
            let problem = WebDAVSyncProblem.from(error: error)
            var certificate: ServerCertificate?
            if case .certificate = problem { certificate = recorder.certificate }
            return .failed(problem, message: WebDAVErrorText.message(error), certificate: certificate)
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

/// A server certificate refused for its dates: either it really expired, or this device's clock is far off (a device
/// back after a long time offline, a date set by hand). Recognized by type (review of #91, S6): the trust evaluation's
/// `OSStatus` (`PinnedServerTrust`) or a `URLError` code, never by the words of a message. The refusal carries a
/// fixed, unlocalized marker before its text, which only this app writes and the bar strips.
enum CertificateDate {
    /// Starts a refusal's reason that is a date problem.
    static let marker = "[sempere:certificate-date] "

    static var reason: String {
        String(localized: "The server's certificate is not valid at this device's date and time. Check this device's date and time.",
               comment: "WebDAV: a certificate expired or not yet valid by this device's clock")
    }

    /// The reason `PinnedServerTrust` refuses with.
    static var refusal: String { marker + reason }

    /// True when a refusal's reason is one of ours for the dates.
    static func matches(_ message: String) -> Bool { message.hasPrefix(marker) }

    /// The `URLError` codes of a certificate refused for its dates.
    static func isDateProblem(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return e.code == .serverCertificateHasBadDate || e.code == .serverCertificateNotYetValid
    }

    /// `message` without the marker, for display.
    static func displayed(_ message: String) -> String {
        message.hasPrefix(marker) ? String(message.dropFirst(marker.count)) : message
    }
}

/// One line for a WebDAV failure, without credentials (the library's
/// messages never contain them).
enum WebDAVErrorText {
    static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let line = SyncReport.printable(text.split(whereSeparator: \.isNewline).joined(separator: " "))
        return line.replacingOccurrences(of: CertificateDate.marker, with: "")
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
