import Age
import CryptoKit
import Foundation
import Security
import Sempere
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

/// The server operations the app makes, all blocking (call them off the
/// main actor). `LiveWebDAVRemote` is the network; tests use a fake.
protocol WebDAVRemote: Sendable {
    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe
    func download(_ endpoint: WebDAVEndpoint, into copy: WebDAVLocalCopy) throws -> SyncReport
    func push(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy, vault: Vault?, options: WebDAVSyncOptions) throws -> SyncReport
    func redownload(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy,
                    identities: [any AgeIdentity]) throws -> (report: SyncReport, replaced: Bool)
}

/// `WebDAVRemote` over `URLSession` (`SempereWebDAV`): https only (http to
/// localhost), Basic auth, redirects never followed, the certificate either
/// trusted by the system or the one pinned for the location.
struct LiveWebDAVRemote: WebDAVRemote {
    func client(_ e: WebDAVEndpoint, recorder: CertificateRecorder? = nil) throws -> WebDAVClient {
        let trust = PinnedServerTrust(pin: e.pinnedCertificate, recorder: recorder)
        let credentials = e.user.map { WebDAVCredentials(user: $0, password: e.password ?? "") }
        return try WebDAVClient(baseURL: e.url, credentials: credentials,
                                transport: URLSessionTransport(timeout: 30, serverTrust: trust))
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

    func download(_ endpoint: WebDAVEndpoint, into copy: WebDAVLocalCopy) throws -> SyncReport {
        try copy.download(client: try client(endpoint))
    }

    func push(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy, vault: Vault?, options: WebDAVSyncOptions) throws -> SyncReport {
        try copy.push(client: try client(endpoint), vault: vault, options: options)
    }

    func redownload(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy,
                    identities: [any AgeIdentity]) throws -> (report: SyncReport, replaced: Bool) {
        try copy.redownload(client: try client(endpoint), identities: identities)
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
        let reason = error.map { CFErrorCopyDescription($0) as String } ?? String(localized: "The system does not trust it.")
        return .reject(reason)
    }

    static func describe(_ certificate: SecCertificate) -> ServerCertificate {
        let der = SecCertificateCopyData(certificate) as Data
        let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "?"
        return ServerCertificate(sha256: hash, subject: SyncReport.printable(String(subject.prefix(120))))
    }
}

/// One line for a WebDAV failure, without credentials (the library's
/// messages never contain them).
enum WebDAVErrorText {
    static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return SyncReport.printable(text.split(whereSeparator: \.isNewline).joined(separator: " "))
    }
}
