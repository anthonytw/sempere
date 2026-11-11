import Foundation
@preconcurrency import Network
import Sempere
import SempereAppCore

/// The nearby link of joining by approval (docs/design/nearby-join.md): Bonjour over peer-to-peer Wi-Fi (AWDL, as
/// AirDrop uses) and any shared network, with `includePeerToPeer`, so two devices on different Wi-Fi networks or behind
/// client isolation still find each other. Plain TCP: the link is untrusted transport, the reply is sealed to the
/// joining device's key, and every check is the one the sync target path makes. The service type is
/// `NearbyJoin.serviceType` (in `NSBonjourServices`), the instance name random, with no TXT record.
///
/// `.loopback` (tests) listens on 127.0.0.1 and finds its own listeners without Bonjour: the connections, sends and
/// receives are the same `NWConnection` code.
final class NWNearbyTransport: NearbyJoinTransport, @unchecked Sendable {
    enum Mode { case bonjour, loopback }

    let mode: Mode
    private let queue = DispatchQueue(label: "io.github.anthonytw.sempere.nearby")
    // Guarded by `lock`.
    private let lock = NSLock()
    private var endpoints: [String: NWEndpoint] = [:]
    private var loopbackBrowsers: [UUID: @Sendable ([NearbyPeer]) -> Void] = [:]

    init(mode: Mode = .bonjour) { self.mode = mode }

    static func parameters(peerToPeer: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        // A vanished peer is noticed within about 30 seconds (15 idle, then 3 probes 5 seconds apart).
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = peerToPeer
        return p
    }

    final class Activity: NearbyActivity, @unchecked Sendable {
        let onStop: @Sendable () -> Void
        init(_ onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
        func stop() { onStop() }
    }

    // MARK: - Advertising (home)

    func advertise(accept: @escaping @Sendable (any NearbyJoinConnection) -> Void,
                   onFailure: @escaping @Sendable () -> Void) throws -> any NearbyActivity {
        let params = Self.parameters(peerToPeer: mode == .bonjour)
        if mode == .loopback { params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
        let listener = try NWListener(using: params)
        if mode == .bonjour {
            listener.service = NWListener.Service(name: NearbyJoin.instanceName(), type: NearbyJoin.serviceType)
        }
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            let c = NWNearbyConnection(connection)
            c.startIncoming(on: queue)
            accept(c)
        }
        let id = UUID().uuidString
        let failed = NWNearbyConnection.Once()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if self?.mode == .loopback, let port = listener?.port { self?.registerLoopback(id, port: port) }
            case .failed:
                // The system suspended the app, or the local network is not allowed: the model starts it again.
                self?.unregisterLoopback(id)
                listener?.cancel()
                failed.run { onFailure() }
            case .cancelled:
                self?.unregisterLoopback(id)
            default:
                break
            }
        }
        listener.start(queue: queue)
        return Activity { [weak self] in
            listener.cancel()
            self?.unregisterLoopback(id)
        }
    }

    private func registerLoopback(_ id: String, port: NWEndpoint.Port) {
        lock.lock()
        endpoints[id] = .hostPort(host: .ipv4(.loopback), port: port)
        lock.unlock()
        loopbackChanged()
    }

    private func unregisterLoopback(_ id: String) {
        guard mode == .loopback else { return }
        lock.lock()
        let had = endpoints.removeValue(forKey: id) != nil
        lock.unlock()
        if had { loopbackChanged() }
    }

    private func loopbackChanged() {
        lock.lock()
        let peers = endpoints.keys.sorted().map(NearbyPeer.init(id:)), all = Array(loopbackBrowsers.values)
        lock.unlock()
        for b in all { b(peers) }
    }

    // MARK: - Browsing (the joining device)

    func browse(found: @escaping @Sendable ([NearbyPeer]) -> Void,
                onFailure: @escaping @Sendable () -> Void) -> any NearbyActivity {
        if mode == .loopback {
            let id = UUID()
            lock.lock()
            loopbackBrowsers[id] = found
            let peers = endpoints.keys.sorted().map(NearbyPeer.init(id:))
            lock.unlock()
            found(peers)
            return Activity { [weak self] in
                self?.lock.lock()
                self?.loopbackBrowsers[id] = nil
                self?.lock.unlock()
            }
        }
        let browser = NWBrowser(for: .bonjour(type: NearbyJoin.serviceType, domain: nil),
                                using: Self.parameters(peerToPeer: true))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var seen: [String: NWEndpoint] = [:]
            for r in results {
                if case .service(let name, let type, let domain, _) = r.endpoint { seen["\(name)\u{1f}\(type)\u{1f}\(domain)"] = r.endpoint }
            }
            self.lock.lock()
            self.endpoints = seen
            self.lock.unlock()
            found(seen.keys.sorted().map(NearbyPeer.init(id:)))
        }
        let failed = NWNearbyConnection.Once()
        browser.stateUpdateHandler = { [weak browser] state in
            if case .failed = state {
                browser?.cancel()
                failed.run { onFailure() }
            }
        }
        browser.start(queue: queue)
        return Activity { browser.cancel() }
    }

    func open(_ peer: NearbyPeer) async throws -> any NearbyJoinConnection {
        guard let endpoint = endpoint(of: peer) else { throw NearbyTransportError.notFound }
        let c = NWNearbyConnection(NWConnection(to: endpoint, using: Self.parameters(peerToPeer: mode == .bonjour)))
        try await c.startOutgoing(on: queue)
        return c
    }

    private func endpoint(of peer: NearbyPeer) -> NWEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[peer.id]
    }
}

/// One `NWConnection` as a `NearbyJoinConnection`.
final class NWNearbyConnection: NearbyJoinConnection, @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    /// An incoming connection: started, and canceled if it fails (a pending receive then ends).
    func startIncoming(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [connection] state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
    }

    /// An outgoing connection, once ready. One that waits for a path (no route to the peer) fails at once: the join
    /// screen tries again, rather than holding a connection that may never be.
    func startOutgoing(on queue: DispatchQueue) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    once.run { cont.resume() }
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    once.run { cont.resume(throwing: error) }
                case .cancelled:
                    once.run { cont.resume(throwing: NearbyJoinError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func receive(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    // The end of the stream (isComplete), or nothing at all: the session reads it as the end.
                    _ = isComplete
                    cont.resume(returning: Data())
                }
            }
        }
    }

    func cancel() { connection.cancel() }

    /// At once, dropping what is unsent (a session torn down, or a peer that stopped reading).
    func abort() { connection.forceCancel() }

    /// Runs its body once (state handlers may report more than one final state).
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}
