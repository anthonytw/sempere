import Foundation
import Sempere

// The link a nearby join runs over (docs/design/nearby-join.md): advertising while Add Device shows, browsing while the
// join screen shows, and one connection per session. The app's is Network.framework with peer-to-peer Wi-Fi
// (`NWNearbyTransport`); tests and headless front ends use `MemoryNearbyTransport`.

/// Something advertising or browsing, until stopped.
public protocol NearbyActivity: AnyObject, Sendable {
    func stop()
}

/// A device seen nearby (an opaque handle: the transport's service, never a name or a vault).
public struct NearbyPeer: Hashable, Sendable {
    public var id: String

    public init(id: String) { self.id = id }
}

/// The nearby link (`AppModelServices.nearby`).
public protocol NearbyJoinTransport: AnyObject, Sendable {
    /// Advertises the service (`NearbyJoin.serviceType`) under a random instance name, handing every connection that
    /// arrives to `accept`, until the activity is stopped. `onFailure` runs once if the listener fails (the system
    /// suspended the app, the local network is not allowed); the activity is then dead.
    func advertise(accept: @escaping @Sendable (any NearbyJoinConnection) -> Void,
                   onFailure: @escaping @Sendable () -> Void) throws -> any NearbyActivity
    /// Browses for the service, calling `found` with every peer seen whenever the set changes, until stopped.
    /// `onFailure` runs once if the browser fails; the activity is then dead.
    func browse(found: @escaping @Sendable ([NearbyPeer]) -> Void,
                onFailure: @escaping @Sendable () -> Void) -> any NearbyActivity
    /// A connection to `peer`, once it is ready (bounded by the transport's connection timeout).
    func open(_ peer: NearbyPeer) async throws -> any NearbyJoinConnection
}

/// What `MemoryNearbyTransport.open` fails with.
public enum NearbyTransportError: Error, Equatable, Sendable {
    case notFound
}

/// Devices in one process, joined by `NearbyJoinPipe`s: every model given the same instance sees the others'
/// advertisements (tests, previews). `fail()` fails every running advertisement and browser, as the system does.
public final class MemoryNearbyTransport: NearbyJoinTransport, @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var advertisers: [String: @Sendable (any NearbyJoinConnection) -> Void] = [:]
    private var browsers: [UUID: @Sendable ([NearbyPeer]) -> Void] = [:]
    private var failures: [String: @Sendable () -> Void] = [:]
    private var openedConnections: [NearbyJoinPipe.Connection] = []

    public init() {}

    /// The joining ends of every connection made (tests look at what crossed the link).
    public var opened: [NearbyJoinPipe.Connection] {
        lock.lock()
        defer { lock.unlock() }
        return openedConnections
    }

    final class Activity: NearbyActivity, @unchecked Sendable {
        let onStop: @Sendable () -> Void
        init(_ onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
        func stop() { onStop() }
    }

    private func peers() -> [NearbyPeer] { advertisers.keys.sorted().map(NearbyPeer.init(id:)) }

    private func changed() {
        lock.lock()
        let list = peers(), all = Array(browsers.values)
        lock.unlock()
        for b in all { b(list) }
    }

    /// Fails every advertisement and browser running now (each `onFailure` runs once; they advertise and browse no
    /// more), as the system does when it suspends the app.
    public func fail() {
        lock.lock()
        let all = Array(failures.values)
        failures = [:]
        advertisers = [:]
        browsers = [:]
        lock.unlock()
        changed()
        for f in all { f() }
    }

    public func advertise(accept: @escaping @Sendable (any NearbyJoinConnection) -> Void,
                          onFailure: @escaping @Sendable () -> Void) throws -> any NearbyActivity {
        let name = NearbyJoin.instanceName()
        lock.lock()
        advertisers[name] = accept
        failures["ad-" + name] = onFailure
        lock.unlock()
        changed()
        return Activity { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.advertisers[name] = nil
            self.failures["ad-" + name] = nil
            self.lock.unlock()
            self.changed()
        }
    }

    public func browse(found: @escaping @Sendable ([NearbyPeer]) -> Void,
                       onFailure: @escaping @Sendable () -> Void) -> any NearbyActivity {
        let id = UUID()
        lock.lock()
        browsers[id] = found
        failures["browse-" + id.uuidString] = onFailure
        let list = peers()
        lock.unlock()
        found(list)
        return Activity { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.browsers[id] = nil
            self.failures["browse-" + id.uuidString] = nil
            self.lock.unlock()
        }
    }

    public func open(_ peer: NearbyPeer) async throws -> any NearbyJoinConnection {
        let (mine, theirs) = NearbyJoinPipe.make()
        guard let accept = take(peer, mine) else { throw NearbyTransportError.notFound }
        accept(theirs)
        return mine
    }

    private func take(_ peer: NearbyPeer, _ mine: NearbyJoinPipe.Connection) -> (@Sendable (any NearbyJoinConnection) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        openedConnections.append(mine)
        return advertisers[peer.id]
    }
}
