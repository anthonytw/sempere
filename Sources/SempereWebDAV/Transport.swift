import Foundation
import Sempere
import SempereSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request, independent of the networking stack.
public struct WebDAVRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Largest response body accepted; a transport stops reading past it and
    /// throws `WebDAVError.responseTooLarge`. Nil means no limit.
    public var maxResponseBytes: Int?
    /// When set, the request body is streamed from this file instead of
    /// `body` (uploads of large blobs never hold the file in memory).
    public var bodyFile: URL?
    /// When set, a 200 or 206 response body is streamed into this file
    /// instead of `body`: a 200 replaces the file's contents (it is created,
    /// mode 0600, if missing), a 206 is appended at its end. Any other
    /// response body is discarded. `maxResponseBytes` counts the bytes of
    /// this response only.
    public var responseFile: URL?
    /// Asked while the request is in flight (a few times a second): an error
    /// it returns cancels the request, and `send` throws that error. What a
    /// streamed response wrote to `responseFile` stays there. The sync passes
    /// its run bound and cancellation (`SyncLimits.maxDuration`,
    /// `WebDAVSyncOptions.isCancelled`), so a server that keeps a request
    /// alive with a trickle of bytes, never idle long enough for the idle
    /// timeout, cannot hold a run past them. Transports that answer at once
    /// may ignore it.
    public var interrupt: (@Sendable () -> (any Error)?)?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil,
                maxResponseBytes: Int? = nil, bodyFile: URL? = nil, responseFile: URL? = nil,
                interrupt: (@Sendable () -> (any Error)?)? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
        self.maxResponseBytes = maxResponseBytes
        self.bodyFile = bodyFile; self.responseFile = responseFile
        self.interrupt = interrupt
    }
}

/// Opening the file a streamed response body goes to (`WebDAVRequest.responseFile`).
enum ResponseFile {
    /// The handle to write a `status` response into: truncated for 200,
    /// positioned at the end for 206; nil for any other status.
    static func open(_ url: URL, status: Int) throws -> FileHandle? {
        guard status == 200 || status == 206 else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw WebDAVError.io("cannot create \(url.path)")
            }
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            if status == 200 { try h.truncate(atOffset: 0) } else { try h.seekToEnd() }
            return h
        } catch {
            throw WebDAVError.io("open \(url.path): \(error.localizedDescription)")
        }
    }
}

/// One HTTP response. Header names are lowercased.
public struct WebDAVResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

/// What a `WebDAVServerTrust` decided about a server's TLS certificate.
public enum WebDAVTrustDecision: Sendable {
    /// Let the system evaluate it (its trust store, host name, dates).
    case systemDefault
    /// Accept it with this credential (`URLCredential(trust:)`).
    case accept(URLCredential)
    /// Refuse it; the request fails with `WebDAVError.untrustedCertificate(reason)`.
    case reject(String)
}

/// Decides TLS server trust instead of the system (a certificate the user
/// pinned explicitly). Only Apple platforms deliver server-trust challenges;
/// on Linux the system (libcurl's trust store) always decides. Evaluating a
/// `SecTrust` needs the Security framework, so implementations live in the
/// app (`Apps/`), never in `Sources/`.
public protocol WebDAVServerTrust: Sendable {
    func evaluate(_ challenge: URLAuthenticationChallenge) -> WebDAVTrustDecision
}

/// Sends one request and returns the response, whatever its status. Throws
/// only when no response arrived (DNS, TLS, timeout, ...). Tests substitute
/// an in-memory server for this.
public protocol WebDAVTransport: Sendable {
    func send(_ request: WebDAVRequest) throws -> WebDAVResponse
}

/// The `URLSession` transport. Redirects are never followed: a redirect would
/// resend credentials and rewrite methods, so it surfaces as a 3xx response
/// that the client reports with the target. Bodies are read incrementally and
/// the request is canceled once one exceeds `maxResponseBytes`, so a server
/// cannot make the client buffer more than that.
public final class URLSessionTransport: WebDAVTransport, @unchecked Sendable {
    /// `NSURLAuthenticationMethodServerTrust`. swift-corelibs-foundation marks
    /// the constant unavailable (it has no Security framework and never sends
    /// the challenge), so its value is spelled out there.
    #if canImport(FoundationNetworking)
    static let serverTrustMethod = "NSURLAuthenticationMethodServerTrust"
    #else
    static let serverTrustMethod = NSURLAuthenticationMethodServerTrust
    #endif

    /// How a challenge is answered: TLS server trust goes to the system's
    /// default handling (Apple platforms deliver it to the task delegate);
    /// HTTP authentication is canceled, and the 401 itself is the answer.
    static func disposition(forAuthenticationMethod method: String) -> URLSession.AuthChallengeDisposition {
        method == serverTrustMethod ? .performDefaultHandling : .cancelAuthenticationChallenge
    }

    private let session: URLSession
    private let delegate: Delegate
    /// For requests streamed from or to a file (`bodyFile`, `responseFile`),
    /// with its own delegate since task identifiers are per session.
    private let streamSession: URLSession
    private let streamDelegate: Delegate

    /// - Parameters:
    ///   - timeout: the idle timeout: a request fails when no data moved for this long.
    ///   - resourceTimeout: the longest a request with an in-memory body may take in all.
    ///   - streamResourceTimeout: the same for a request streamed from or to
    ///     a file. A blob of up to about 1 GiB goes in one PUT that cannot
    ///     resume, so on a slow uplink it may take hours; it is bounded by the
    ///     idle timeout, not by its total time.
    ///   - serverTrust: decides TLS server trust in place of the
    ///     system (nil: the system decides, as for any HTTPS request).
    public init(timeout: TimeInterval = 60, resourceTimeout: TimeInterval = 600,
                streamResourceTimeout: TimeInterval = 7 * 24 * 3600,
                serverTrust: (any WebDAVServerTrust)? = nil) {
        func make(_ resource: TimeInterval, _ delegate: Delegate) -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = resource
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            // No HTTP cache: it would answer a GET of a mutable file from memory, and it adds
            // If-None-Match / If-Modified-Since from a cached GET to later requests for the URL,
            // a DELETE included, which a server then refuses with 412.
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            // One connection per transfer a run makes at once (`TransferPool`), kept alive
            // between requests; the default (6 on Apple platforms) queued `--jobs` above it.
            config.httpMaximumConnectionsPerHost = TransferPool.maxWidth
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
        delegate = Delegate(serverTrust: serverTrust)
        streamDelegate = Delegate(serverTrust: serverTrust)
        session = make(resourceTimeout, delegate)
        streamSession = make(streamResourceTimeout, streamDelegate)
    }

    deinit {
        // A session keeps its delegate (and itself) alive until invalidated.
        session.finishTasksAndInvalidate()
        streamSession.finishTasksAndInvalidate()
    }

    public func send(_ request: WebDAVRequest) throws -> WebDAVResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        if request.bodyFile == nil { r.httpBody = request.body }
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let streamed = request.bodyFile != nil || request.responseFile != nil
        let (session, delegate) = streamed ? (streamSession, streamDelegate) : (self.session, self.delegate)
        let task: URLSessionTask = request.bodyFile.map { session.uploadTask(with: r, fromFile: $0) }
            ?? session.dataTask(with: r)
        let pending = Pending(limit: request.maxResponseBytes, file: request.responseFile)
        delegate.register(task.taskIdentifier, pending)
        defer { delegate.unregister(task.taskIdentifier) }
        task.resume()
        if let interrupt = request.interrupt {
            while pending.done.wait(timeout: .now() + Self.interruptPoll) == .timedOut {
                guard let stop = interrupt() else { continue }
                task.cancel()
                pending.done.wait()
                if let failure = pending.fileFailure { throw failure }
                throw stop
            }
        } else {
            pending.done.wait()
        }
        var (data, response, error, tooLarge, challenged) = pending.result()
        if let failure = pending.fileFailure { throw failure }
        if let refused = pending.trustRefusal { throw WebDAVError.untrustedCertificate(refused) }
        if tooLarge, let limit = request.maxResponseBytes {
            throw WebDAVError.responseTooLarge(path: request.url.path, limit: limit)
        }
        if error != nil, let challenged { response = challenged; error = nil }
        if let error { throw Self.classify(error) }
        guard let http = (response ?? task.response) as? HTTPURLResponse else {
            throw WebDAVError.transport("not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        return WebDAVResponse(status: http.statusCode, headers: headers, body: data)
    }

    private static func describe(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }

    /// How often a request in flight asks its `interrupt`.
    static let interruptPoll: DispatchTimeInterval = .milliseconds(250)

    /// `URLError` codes that mean the server cannot be reached from here now.
    static let offlineCodes: Set<Int> = [
        -1009,  // notConnectedToInternet
        -1005,  // networkConnectionLost
        -1003,  // cannotFindHost
        -1004,  // cannotConnectToHost
        -1001,  // timedOut
        -1006,  // dnsLookupFailed
        -1018,  // internationalRoamingOff
        -1020,  // dataNotAllowed
    ]

    /// `URLError` codes for a certificate the system does not trust.
    static let certificateCodes: Set<Int> = [
        -1202,  // serverCertificateUntrusted
        -1203,  // serverCertificateHasUnknownRoot
        -1201,  // serverCertificateHasBadDate
        -1204,  // serverCertificateNotYetValid
    ]

    /// The `WebDAVError` for a request that got no response.
    static func classify(_ error: Error) -> WebDAVError {
        let ns = error as NSError
        let message = describe(error)
        guard ns.domain == NSURLErrorDomain else { return .transport(message) }
        if offlineCodes.contains(ns.code) { return .offline(message) }
        if certificateCodes.contains(ns.code) { return .untrustedCertificate(message) }
        return .transport(message)
    }

    /// One request in flight: its body so far and how it ended.
    private final class Pending: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        let limit: Int?
        /// Where a successful body goes instead of memory, if anywhere.
        let file: URL?
        private let lock = NSLock()
        private var data = Data()
        private var response: URLResponse?
        private var error: Error?
        private var tooLarge = false
        private var challenged: HTTPURLResponse?
        private var handle: FileHandle?
        /// True once the response is known and its body is not wanted.
        private var discarding = false
        private var received = 0
        private var fileError: WebDAVError?
        private var refusedTrust: String?

        init(limit: Int?, file: URL?) { self.limit = limit; self.file = file }

        /// Why a `WebDAVServerTrust` refused the server's certificate, if it did.
        var trustRefusal: String? { lock.lock(); defer { lock.unlock() }; return refusedTrust }
        func refuseTrust(_ reason: String) { lock.lock(); refusedTrust = reason; lock.unlock() }

        var fileFailure: WebDAVError? { lock.lock(); defer { lock.unlock() }; return fileError }

        /// Opens the response file for a streamed body; false (and the
        /// failure recorded) when it cannot be opened.
        func prepareFile(status: Int) -> Bool {
            guard let file else { return true }
            lock.lock(); defer { lock.unlock() }
            do {
                handle = try ResponseFile.open(file, status: status)
                discarding = handle == nil
                return true
            } catch {
                fileError = error as? WebDAVError ?? .io("\(error)")
                return false
            }
        }

        /// False (and marks the request too large) when the body would exceed the limit.
        func accept(expected: Int64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !discarding, let limit, expected > Int64(limit) else { return true }
            tooLarge = true
            return false
        }

        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if discarding { return true }
            if let limit, chunk.count > limit - received { tooLarge = true; return false }
            received += chunk.count
            guard handle != nil else { data.append(chunk); return true }
            // Small deliveries are gathered and written 1 MiB at a time.
            pendingWrite.append(chunk)
            return pendingWrite.count < Self.writeSize || flush()
        }

        static let writeSize = 1 << 20
        private var pendingWrite = Data()

        /// Writes what was gathered; false (with the failure recorded) on error. Lock held.
        private func flush() -> Bool {
            guard let handle, !pendingWrite.isEmpty else { return true }
            do { try autoreleasing { try handle.write(contentsOf: pendingWrite) } } catch {
                fileError = .io("write \(file?.path ?? "?"): \(error.localizedDescription)")
                return false
            }
            pendingWrite.removeAll(keepingCapacity: true)
            return true
        }

        func set(response r: URLResponse) { lock.lock(); response = r; lock.unlock() }
        func set(challenged r: HTTPURLResponse) { lock.lock(); challenged = r; lock.unlock() }
        func finish(_ e: Error?) {
            lock.lock()
            error = e
            if let handle {
                // A transfer cut midway keeps what arrived (a later request resumes from it).
                _ = flush()
                do { try handle.synchronize(); try handle.close() } catch {
                    if fileError == nil { fileError = .io("write \(file?.path ?? "?"): \(error.localizedDescription)") }
                }
                self.handle = nil
            }
            lock.unlock()
            done.signal()
        }

        func result() -> (Data, URLResponse?, Error?, Bool, HTTPURLResponse?) {
            lock.lock(); defer { lock.unlock() }
            return (data, response, error, tooLarge, challenged)
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]
        let serverTrust: (any WebDAVServerTrust)?

        init(serverTrust: (any WebDAVServerTrust)?) { self.serverTrust = serverTrust }

        func register(_ id: Int, _ p: Pending) { lock.lock(); pending[id] = p; lock.unlock() }
        func unregister(_ id: Int) { lock.lock(); pending[id] = nil; lock.unlock() }
        private func lookup(_ id: Int) -> Pending? { lock.lock(); defer { lock.unlock() }; return pending[id] }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        /// Credentials are sent preemptively in the header; a challenge is
        /// answered with the 401 itself, never with a stored credential.
        /// Server trust (TLS) is left to the system: Apple platforms deliver it
        /// here, and canceling it fails every HTTPS request.
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let serverTrust, challenge.protectionSpace.authenticationMethod == URLSessionTransport.serverTrustMethod {
                switch serverTrust.evaluate(challenge) {
                case .systemDefault: completionHandler(.performDefaultHandling, nil)
                case .accept(let credential): completionHandler(.useCredential, credential)
                case .reject(let reason):
                    lookup(task.taskIdentifier)?.refuseTrust(reason)
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
                return
            }
            let disposition = URLSessionTransport.disposition(forAuthenticationMethod: challenge.protectionSpace.authenticationMethod)
            if disposition == .cancelAuthenticationChallenge, let r = challenge.failureResponse as? HTTPURLResponse {
                lookup(task.taskIdentifier)?.set(challenged: r)
            }
            completionHandler(disposition, nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let p = lookup(dataTask.taskIdentifier) else { return completionHandler(.cancel) }
            p.set(response: response)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard p.prepareFile(status: status) else { return completionHandler(.cancel) }
            completionHandler(p.accept(expected: response.expectedContentLength) ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let p = lookup(dataTask.taskIdentifier), p.append(data) else { return dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lookup(task.taskIdentifier)?.finish(error)
        }
    }
}
