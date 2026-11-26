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

/// Why the nearby link cannot come up, as far as the system says (shown on both screens, with the way out).
public enum NearbyLinkProblem: Equatable, Sendable {
    /// The Local Network permission is refused, or not answered yet (Network.framework waits with a policy-denied error,
    /// `kDNSServiceErr_PolicyDenied`, -65570). The fix is in Settings.
    case localNetworkDenied
    /// No Wi-Fi or wired network is up (and no peer-to-peer link either).
    case wifiOff
    /// The system failed the listener or browser for another reason.
    case other

    /// `kDNSServiceErr_PolicyDenied`: what a refused (or still unanswered) Local Network permission reports.
    public static let policyDeniedCode: Int32 = -65570
}

/// The nearby link (`AppModelServices.nearby`).
public protocol NearbyJoinTransport: AnyObject, Sendable {
    /// Why the last listener failed or waited past its grace, nil when one came up or none failed (read by the model right after
    /// the listener's `onFailure`); and the same for the browser: each side keeps its own.
    var advertisingProblem: NearbyLinkProblem? { get }
    var browsingProblem: NearbyLinkProblem? { get }
    /// Advertises the service (`NearbyJoin.serviceType`) under a random instance name, handing every connection that
    /// arrives to `accept`, until the activity is stopped. `onReady` runs when the listener is up (the model then counts
    /// its failures from zero again); `onFailure` runs once if the listener fails (the system suspended the app, the
    /// local network is not allowed); the activity is then dead.
    func advertise(accept: @escaping @Sendable (any NearbyJoinConnection) -> Void, onReady: @escaping @Sendable () -> Void,
                   onFailure: @escaping @Sendable () -> Void) throws -> any NearbyActivity
    /// Browses for the service, calling `found` with every peer seen whenever the set changes, until stopped.
    /// `onReady` runs when the browser is up; `onFailure` runs once if the browser fails; the activity is then dead.
    func browse(found: @escaping @Sendable ([NearbyPeer]) -> Void, onReady: @escaping @Sendable () -> Void,
                onFailure: @escaping @Sendable () -> Void) -> any NearbyActivity
    /// A connection to `peer`, once it is ready (bounded by the transport's connection timeout).
    func open(_ peer: NearbyPeer) async throws -> any NearbyJoinConnection
}

extension NearbyJoinTransport {
    public var advertisingProblem: NearbyLinkProblem? { nil }
    public var browsingProblem: NearbyLinkProblem? { nil }

    /// `advertise(accept:onReady:onFailure:)` without a ready hook.
    public func advertise(accept: @escaping @Sendable (any NearbyJoinConnection) -> Void,
                          onFailure: @escaping @Sendable () -> Void) throws -> any NearbyActivity {
        try advertise(accept: accept, onReady: {}, onFailure: onFailure)
    }

    /// `browse(found:onReady:onFailure:)` without a ready hook.
    public func browse(found: @escaping @Sendable ([NearbyPeer]) -> Void,
                       onFailure: @escaping @Sendable () -> Void) -> any NearbyActivity {
        browse(found: found, onReady: {}, onFailure: onFailure)
    }
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

    private var _problem: NearbyLinkProblem?
    /// What both problems answer (tests set it before `fail()`).
    public var problem: NearbyLinkProblem? {
        get { lock.lock(); defer { lock.unlock() }; return _problem }
        set { lock.lock(); _problem = newValue; lock.unlock() }
    }
    public var advertisingProblem: NearbyLinkProblem? { problem }
    public var browsingProblem: NearbyLinkProblem? { problem }

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
        failAdvertisers()
        failBrowsers()
    }

    /// Fails every advertisement running now, and nothing else (a listener the system failed).
    public func failAdvertisers() {
        lock.lock()
        let keys = failures.keys.filter { $0.hasPrefix("ad-") }
        let all = keys.compactMap { failures[$0] }
        for k in keys { failures[k] = nil }
        advertisers = [:]
        lock.unlock()
        changed()
        for f in all { f() }
    }

    /// Fails every browser running now, and nothing else (a browser the system failed, or one refused the local
    /// network).
    public func failBrowsers() {
        lock.lock()
        let keys = failures.keys.filter { $0.hasPrefix("browse-") }
        let all = keys.compactMap { failures[$0] }
        for k in keys { failures[k] = nil }
        browsers = [:]
        lock.unlock()
        for f in all { f() }
    }

    public func advertise(accept: @escaping @Sendable (any NearbyJoinConnection) -> Void, onReady: @escaping @Sendable () -> Void,
                          onFailure: @escaping @Sendable () -> Void) throws -> any NearbyActivity {
        let name = NearbyJoin.instanceName()
        lock.lock()
        advertisers[name] = accept
        failures["ad-" + name] = onFailure
        lock.unlock()
        changed()
        onReady()
        return Activity { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.advertisers[name] = nil
            self.failures["ad-" + name] = nil
            self.lock.unlock()
            self.changed()
        }
    }

    public func browse(found: @escaping @Sendable ([NearbyPeer]) -> Void, onReady: @escaping @Sendable () -> Void,
                       onFailure: @escaping @Sendable () -> Void) -> any NearbyActivity {
        let id = UUID()
        lock.lock()
        browsers[id] = found
        failures["browse-" + id.uuidString] = onFailure
        let list = peers()
        lock.unlock()
        onReady()
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
        try await open(peer, from: nil)
    }

    /// `open`, as a device at `host`: the accepting end sees that address (`NearbyJoinConnection.remoteHost`).
    public func open(_ peer: NearbyPeer, from host: String?) async throws -> any NearbyJoinConnection {
        let (mine, theirs) = NearbyJoinPipe.make()
        theirs.remoteHost = host
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
