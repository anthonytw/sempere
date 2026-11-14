import Foundation
import Sempere

// Joining nearby (docs/design/nearby-join.md, key-hierarchy design §6.2.1): while Add Device shows on home, home
// advertises the link's service; while the join screen waits on the new device, it browses, connects, and once home
// proves it knows the vault's id, sends its request. Home keeps the request in memory and lists it with the synced ones
// (it never writes it to the vault); once the user approves it (by the six words or the QR code, as always), home sends
// the approval back over the same connection, and the new device takes it into its copy as a join run would. The new
// device still confirms with home's reply words. Both routes run side by side: whichever brings the request or the
// approval first wins, and the other finds nothing left to do.
//
// Both sides stop in the background and start again in the foreground while their screen still shows, and each
// restarts on its own after the system fails its listener or browser, waiting longer after each failure until it comes
// up again.

/// Add Device's side of the nearby link.
public enum NearbyApproverStatus: Equatable, Sendable {
    /// Add Device is not showing (or the app is in the background).
    case off
    /// No link on this device, this device cannot approve now (locked, read-only, not home), or the link failed and is
    /// being started again.
    case unavailable
    /// Advertising: a new device nearby can send its request.
    case advertising
    /// A device nearby is connected (one session at a time).
    case connected
}

/// The join screen's side of the nearby link.
public enum NearbyJoinStatus: Equatable, Sendable {
    /// The join screen is not waiting (or the app is in the background).
    case off
    /// No link on this device, or the link failed and is being started again.
    case unavailable
    /// Looking for a device that manages devices nearby.
    case looking
    /// A device advertises nearby; connecting.
    case found
    /// A device nearby that knows the vault has the request (not proven to be home: design L1).
    case connected
    /// Its approval arrived over the link: the reply words are next.
    case received
    /// A device nearby said it declined the request; the join screen keeps looking (it may not have been home).
    case declined
}

/// What ends home's wait for the user in a nearby session.
enum NearbyDecision: Sendable {
    case approved, declined, closed
}

/// The nearby link's running parts (one per model).
@MainActor
final class NearbyJoinRuntime {
    /// The app is in the background: nothing advertises or browses until it is back.
    var suspended = false
    /// Each side's restart after a failure, and its failures since it last started (the wait doubles with each,
    /// `restartDelay`; a side that comes up, `onReady`, starts again from zero).
    var listenerRestart: Task<Void, Never>?
    var browserRestart: Task<Void, Never>?
    var listenerFailures = 0
    var browserFailures = 0

    // Home
    /// Add Device shows (it asked for the link, and has not let it go).
    var wantsApproving = false
    var advertisement: (any NearbyActivity)?
    /// Connections that have not sent a whole request yet, by their token: at most `handshakeLimit`, each within one
    /// short limit (`NearbyJoin.Timeouts.request`). None of them holds the session.
    var handshakes: [UUID: (task: Task<Void, Never>, connection: any NearbyJoinConnection, host: String?)] = [:]
    /// Their tokens, oldest first.
    var handshakeOrder: [UUID] = []
    /// The session going (one at a time, taken by a parsed request of this vault): its token, task and connection.
    var sessionToken: UUID?
    var session: Task<Void, Never>?
    var sessionConnection: (any NearbyJoinConnection)?
    /// The session's request and nonce, once it waits for the approval.
    var pending: (request: JoinRequest, nonce: Data)?
    var decision: NearbyDecision?
    var waiter: CheckedContinuation<NearbyDecision, Never>?

    // The joining device
    /// The join screen waits (it asked for the link, and has not let it go).
    var wantsJoining = false
    var browsing: (any NearbyActivity)?
    var joinTask: Task<Void, Never>?
    var peers: [NearbyPeer] = []

    /// At most this many requests that came nearby are kept for Add Device (the oldest goes first).
    static let requestLimit = 4
    /// At most this many connections in their handshake at once (a new one ends the oldest), and one per remote address:
    /// a new connection from an address that has one ends that address's oldest first and takes its slot.
    nonisolated static let handshakeLimit = 4
    /// At most this many devices never tried before are tried per minute by the join screen (design L5).
    nonisolated static let newPeersPerMinute = 6

    /// Ends the wait of the session `token`, once; nothing for another session's token (one torn down since).
    func decide(_ d: NearbyDecision, token: UUID?) {
        guard token == sessionToken, decision == nil else { return }
        decision = d
        let w = waiter
        waiter = nil
        w?.resume(returning: d)
    }

    /// The user's decision on the session `token`; `closed` when the waiting task is canceled (the joining device left,
    /// time ran out).
    func waitForDecision(token: UUID) async -> NearbyDecision {
        if let decision { return decision }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<NearbyDecision, Never>) in
                if let decision {
                    c.resume(returning: decision)
                } else {
                    waiter = c
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.decide(.closed, token: token) }
        }
    }

    /// Tears the session down: its wait ends, its task is canceled and its connection aborted; a new session may start
    /// at once (its token differs from this one's).
    func endSession() {
        decide(.closed, token: sessionToken)
        session?.cancel()
        sessionConnection?.abort()
        session = nil
        sessionConnection = nil
        sessionToken = nil
        pending = nil
        decision = nil
    }

    /// Ends every connection still in its handshake.
    func endHandshakes() {
        for h in handshakes.values {
            h.task.cancel()
            h.connection.abort()
        }
        handshakes = [:]
        handshakeOrder = []
    }

    /// Ends the handshake `token` (its place is freed at once).
    func endHandshake(_ token: UUID) {
        handshakeOrder.removeAll { $0 == token }
        guard let h = handshakes.removeValue(forKey: token) else { return }
        h.task.cancel()
        h.connection.abort()
    }

    /// The wait before a side starts again after its `failures`-th failure since it last came up: `base`, doubled with
    /// each failure after the first, at most a minute (or `base`, if longer).
    static func restartDelay(base: Duration, failures: Int) -> Duration {
        let doubled = base * (1 << min(max(failures - 1, 0), 10))
        return min(doubled, max(base, .seconds(60)))
    }
}

extension AppModelCore {
    // MARK: - Home: Add Device

    /// Starts advertising for Add Device (its sheet calls it when it shows): only on home, unlocked and writable, and
    /// only with a link. A connection that comes while a session goes is told `busy`.
    public func startNearbyApproving() {
        nearby.wantsApproving = true
        nearby.listenerFailures = 0
        startAdvertising()
    }

    /// Stops advertising (Add Device closed, the vault closed): the session going is torn down, and the requests that
    /// came nearby are forgotten.
    public func stopNearbyApproving() {
        nearby.wantsApproving = false
        nearby.listenerRestart?.cancel()
        nearby.listenerRestart = nil
        stopAdvertising()
        nearbyRequests = []
        nearbyApproving = .off
    }

    func startAdvertising() {
        guard nearby.wantsApproving, !nearby.suspended, nearby.advertisement == nil else { return }
        guard let transport = nearbyTransport else { nearbyApproving = .off; return }
        guard phase == .unlocked, vault?.isHome == true, !isVaultReadOnly else { nearbyApproving = .unavailable; return }
        do {
            nearby.advertisement = try transport.advertise(accept: { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.acceptNearby(connection)
                }
            }, onReady: { [weak self] in
                // Up: the failures counted toward the wait start from zero again.
                Task { @MainActor in self?.nearby.listenerFailures = 0 }
            }, onFailure: { [weak self] in
                Task { @MainActor in self?.nearbyListenerFailed() }
            })
            nearbyApproving = .advertising
        } catch {
            nearbyApproving = .unavailable
            nearby.listenerFailures += 1
            scheduleListenerRestart()
        }
    }

    func stopAdvertising() {
        nearby.advertisement?.stop()
        nearby.advertisement = nil
        nearby.endHandshakes()
        nearby.endSession()
    }

    /// A connection arrived: it gets one of a few handshake places (when all are taken, the oldest is ended: a real
    /// device's hello and request take a round trip, a silent one holds its place only until newer ones come), and holds
    /// the one session only once it sent a parsed request of this vault (`nearbyReceived`); a device that connects and
    /// stays silent, or sends anything else, is dropped within `NearbyJoin.Timeouts.request` and keeps nobody out.
    func acceptNearby(_ connection: any NearbyJoinConnection) {
        guard nearby.advertisement != nil, let current = vault, phase == .unlocked else { connection.abort(); return }
        // One place per remote address: an address that opens connections fast ends its own, never the others'. A
        // connection with no known address is its own group. Only when its address has none and every place is taken does
        // the oldest overall end. This is no defense against many addresses (nearby-join.md "Handshake places").
        let host = connection.remoteHost
        if let host, let same = nearby.handshakeOrder.first(where: { nearby.handshakes[$0]?.host == host }) {
            nearby.endHandshake(same)
        }
        while nearby.handshakes.count >= NearbyJoinRuntime.handshakeLimit, let oldest = nearby.handshakeOrder.first {
            nearby.endHandshake(oldest)
        }
        let token = UUID(), vaultId = current.vaultId, timeouts = nearbyTimeouts
        let task = Task { [weak self] in
            _ = try? await NearbyApprover.run(on: connection, vaultId: vaultId, timeouts: timeouts,
                                              received: { [weak self] request, _, nonce in
                await self?.nearbyReceived(request, nonce: nonce, token: token, connection: connection) ?? .refuse(.closed)
            }, outcome: { [weak self] in
                await self?.nearbyOutcome(token: token) ?? .refuse(.closed)
            })
            self?.nearbyConnectionEnded(token)
        }
        nearby.handshakes[token] = (task, connection, host)
        nearby.handshakeOrder.append(token)
    }

    /// Home's first answer to a request that came nearby: refused when it cannot be approved here, `busy` while
    /// another device's session goes, the reply at once when the device is listed already, else this connection takes
    /// the session, and the request is kept in memory (never written to the vault: design N5) and listed.
    func nearbyReceived(_ request: JoinRequest, nonce: Data, token: UUID,
                        connection: any NearbyJoinConnection) async -> NearbyApprover.Answer {
        guard nearby.handshakes[token] != nil || nearby.sessionToken == token, let current = vault, phase == .unlocked,
              current.isHome, !isVaultReadOnly else { return .refuse(.cannotApprove) }
        guard request.vaultId == current.vaultId else { return .refuse(.otherVault) }
        // Approved already (through a target, or in an earlier session): the reply at once.
        if let sealed = await nearbySealedReply(current, request, nonce) { return .reply(sealed) }
        guard let handshake = nearby.handshakes[token] else { return .refuse(.closed) }
        guard nearby.sessionToken == nil else { return .refuse(.busy) }
        nearby.handshakes[token] = nil
        nearby.handshakeOrder.removeAll { $0 == token }
        nearby.sessionToken = token
        nearby.session = handshake.task
        nearby.sessionConnection = connection
        nearby.decision = nil
        nearby.pending = (request, nonce)
        nearbyApproving = .connected
        keepNearbyRequest(request)
        nearbyArrivals += 1
        return .wait
    }

    /// Keeps `request` for Add Device while it shows: one per commitment, the newest last, at most `requestLimit`.
    func keepNearbyRequest(_ request: JoinRequest) {
        var kept = nearbyRequests.filter { $0.commitment != request.commitment }
        kept.append(request)
        nearbyRequests = Array(kept.suffix(NearbyJoinRuntime.requestLimit))
    }

    /// Waits for the user's decision on the session's request, then the reply (built from `vault.json` on disk).
    func nearbyOutcome(token: UUID) async -> NearbyApprover.Final {
        guard nearby.sessionToken == token, let pending = nearby.pending else { return .refuse(.closed) }
        switch await nearby.waitForDecision(token: token) {
        case .declined: return .refuse(.declined)
        case .closed: return .refuse(.closed)
        case .approved:
            guard nearby.sessionToken == token, let current = vault,
                  let sealed = await nearbySealedReply(current, pending.request, pending.nonce) else { return .refuse(.cannotApprove) }
            return .reply(sealed)
        }
    }

    /// The reply for `request` sealed to its key, when `current`'s `vault.json` lists it.
    private func nearbySealedReply(_ current: Vault, _ request: JoinRequest, _ nonce: Data) async -> Data? {
        let sealed = try? await offMain { () throws -> Data? in
            try current.nearbyReply(for: request, nonce: nonce).map { try $0.seal(to: request.key) }
        }
        return sealed ?? nil
    }

    /// A connection's run ended: in its handshake, its place is freed; the session's, the session ends.
    func nearbyConnectionEnded(_ token: UUID) {
        if nearby.handshakes.removeValue(forKey: token) != nil {
            nearby.handshakeOrder.removeAll { $0 == token }
            return
        }
        guard nearby.sessionToken == token else { return }   // torn down already; another may be going
        nearby.endSession()
        nearbyApproving = nearby.advertisement != nil ? .advertising : .off
        // The request stays listed while Add Device shows (`nearbyRequests`): it reads its list again.
        nearbyArrivals += 1
    }

    /// `approveDevice` approved `request`: the session waiting for it sends the reply.
    func nearbyApproved(_ request: JoinRequest) {
        guard nearby.pending?.request.commitment == request.commitment else { return }
        nearby.decide(.approved, token: nearby.sessionToken)
    }

    /// `declineJoinRequest` declined `request`: forgotten here, and the session waiting for it says so. By its
    /// commitment, never its file name (8 hex digits another key may share).
    func nearbyDeclined(_ request: JoinRequest) {
        nearbyRequests.removeAll { $0.commitment == request.commitment }
        guard nearby.pending?.request.commitment == request.commitment else { return }
        nearby.decide(.declined, token: nearby.sessionToken)
    }

    // MARK: - Failures and the background

    /// The listener failed (the system suspended the app, the local network is not allowed): it is dropped, Add Device
    /// says the link is unavailable, and it starts again after a wait that grows with each failure since it last came up
    /// (`restartDelay`) while Add Device shows. The browser, if any, is not touched.
    func nearbyListenerFailed() {
        guard nearby.advertisement != nil else { return }
        stopAdvertising()
        if nearby.wantsApproving { nearbyApproving = .unavailable }
        nearby.listenerFailures += 1
        scheduleListenerRestart()
    }

    /// The browser failed, or waits for a permission the user refused (the app's transport reports both): as
    /// `nearbyListenerFailed`, for the join screen.
    func nearbyBrowserFailed() {
        guard nearby.browsing != nil || nearby.joinTask != nil else { return }
        stopJoinLoop()
        if nearby.wantsJoining { nearbyJoining = .unavailable }
        nearby.browserFailures += 1
        scheduleBrowserRestart()
    }

    func scheduleListenerRestart() {
        nearby.listenerRestart?.cancel()
        let delay = NearbyJoinRuntime.restartDelay(base: nearbyRetry, failures: nearby.listenerFailures)
        nearby.listenerRestart = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.nearby.listenerRestart = nil
            self.startAdvertising()
        }
    }

    func scheduleBrowserRestart() {
        nearby.browserRestart?.cancel()
        let delay = NearbyJoinRuntime.restartDelay(base: nearbyRetry, failures: nearby.browserFailures)
        nearby.browserRestart = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.nearby.browserRestart = nil
            self.startJoinLoop()
        }
    }

    /// The app went to the background (`observeAppLifecycle`): both sides stop, and their screens' wishes are kept.
    public func nearbyEnteredBackground() {
        nearby.suspended = true
        nearby.listenerRestart?.cancel()
        nearby.listenerRestart = nil
        nearby.browserRestart?.cancel()
        nearby.browserRestart = nil
        if nearby.wantsApproving {
            stopAdvertising()
            nearbyApproving = .off
        }
        if nearby.wantsJoining {
            stopJoinLoop()
            nearbyJoining = .off
        }
    }

    /// The app is back in the foreground: each side starts again while its screen still shows.
    public func nearbyEnteredForeground() {
        guard nearby.suspended else { return }
        nearby.suspended = false
        nearby.listenerFailures = 0
        nearby.browserFailures = 0
        startAdvertising()
        startJoinLoop()
    }

    // MARK: - The joining device: the join screen

    /// Starts looking for home nearby while the join screen waits for the approval (its view calls it): browses, and
    /// tries each device found in turn (`nearbyJoinLoop`) until one approves.
    public func startNearbyJoin() {
        nearby.wantsJoining = true
        nearby.browserFailures = 0
        startJoinLoop()
    }

    /// Stops looking (the join screen went, the join was confirmed or canceled, the vault closed).
    public func stopNearbyJoin() {
        nearby.wantsJoining = false
        stopJoinLoop()
        nearby.browserRestart?.cancel()
        nearby.browserRestart = nil
        nearbyJoining = .off
    }

    func startJoinLoop() {
        guard nearby.wantsJoining, !nearby.suspended, nearby.joinTask == nil else { return }
        guard let transport = nearbyTransport else { nearbyJoining = .off; return }
        guard phase == .locked, joinIdentity != nil, let v = vault, joinRequestedFile(v.vaultId) != nil else {
            nearbyJoining = .unavailable
            return
        }
        nearbyJoining = .looking
        nearby.peers = []
        nearby.browsing = transport.browse(found: { [weak self] peers in
            Task { @MainActor in self?.nearbyPeersChanged(peers) }
        }, onReady: { [weak self] in
            Task { @MainActor in self?.nearby.browserFailures = 0 }
        }, onFailure: { [weak self] in
            Task { @MainActor in self?.nearbyBrowserFailed() }
        })
        let gen = generation
        nearby.joinTask = Task { [weak self] in await self?.nearbyJoinLoop(transport, generation: gen) }
    }

    func stopJoinLoop() {
        nearby.browsing?.stop()
        nearby.browsing = nil
        nearby.joinTask?.cancel()
        nearby.joinTask = nil
        nearby.peers = []
    }

    func nearbyPeersChanged(_ peers: [NearbyPeer]) {
        guard nearby.browsing != nil else { return }
        nearby.peers = peers
        if nearbyJoining == .looking, !peers.isEmpty {
            nearbyJoining = .found
        } else if nearbyJoining == .found, peers.isEmpty {
            nearbyJoining = .looking
        }
    }

    /// How long the join screen leaves a device alone after it refused (another vault, not home, a proof of another
    /// vault, "declined"), and after it held a session to the end of its time without answering (design L5).
    nonisolated static var nearbyRefusedRest: Duration { .seconds(60) }
    nonisolated static var nearbyStalledRest: Duration { .seconds(300) }

    /// One session at a time, with a device found chosen at random among those not resting, those never tried first
    /// but at most `newPeersPerMinute` of them a minute (names are the advertisers' to choose: none sorts its way
    /// ahead, and many fresh ones do not keep the screen from the others): a device that refused rests a minute, one
    /// that said `waiting` and then let the session run out five, a busy one, one whose session closed or a broken
    /// link a moment (`nearbyRetry`).
    func nearbyJoinLoop(_ transport: any NearbyJoinTransport, generation gen: Int) async {
        var resting: [NearbyPeer: ContinuousClock.Instant] = [:]
        var tried: Set<NearbyPeer> = []
        var firstTries: [ContinuousClock.Instant] = []
        while !Task.isCancelled, gen == generation, phase == .locked {
            let now = ContinuousClock.now
            let ready = nearby.peers.filter { (resting[$0] ?? now) <= now }
            firstTries.removeAll { now - $0 >= .seconds(60) }
            guard let peer = Self.nearbyPick(ready: ready, tried: tried, newThisMinute: firstTries.count), let identity = joinIdentity,
                  let v = vault, let url = vaultURL, let file = joinRequestedFile(v.vaultId) else {
                try? await Task.sleep(for: nearbyRetry)
                continue
            }
            if tried.insert(peer).inserted { firstTries.append(now) }
            let requestURL = url.appendingPathComponent("joins").appendingPathComponent(file)
            // The request as written: its bytes are what the targets hold.
            guard let raw = try? await offMain({ try BoundedRead.contents(of: requestURL, maxBytes: JoinRequest.maxBytes) }),
                  let commitment = try? JoinRequest.parse(raw).commitment else {
                try? await Task.sleep(for: nearbyRetry)
                continue
            }
            let nonce = NearbyJoin.randomBytes(NearbyJoin.nonceBytes), timeouts = nearbyTimeouts
            let waited = NearbyFlag()
            let outcome: NearbyJoiner.Outcome
            do {
                let connection = try await transport.open(peer)
                outcome = try await NearbyJoiner.run(on: connection, request: raw, nonce: nonce, identity: identity,
                                                     timeouts: timeouts) { [weak self] in
                    waited.set()
                    await self?.nearbyConnected(generation: gen)
                }
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                switch error {
                case NearbyJoinError.notThisVault: resting[peer] = .now + Self.nearbyRefusedRest
                case NearbyJoinError.timedOut where waited.isSet: resting[peer] = .now + Self.nearbyStalledRest
                default: resting[peer] = .now + nearbyRetry
                }
                nearbyJoining = nearby.peers.isEmpty ? .looking : .found
                continue
            }
            guard gen == generation, !Task.isCancelled else { return }
            switch outcome {
            case .reply(let reply):
                if (try? await takeNearbyReply(reply, nonce: nonce, commitment: commitment)) != nil {
                    guard gen == generation else { return }
                    nearbyJoining = .received
                    nearbyArrivals += 1
                    nearby.wantsJoining = false
                    nearby.browsing?.stop()
                    nearby.browsing = nil
                    nearby.joinTask = nil
                    return
                }
                resting[peer] = .now + Self.nearbyRefusedRest
            case .refused(.declined):
                // Unauthenticated (any device that knows the vault's id can say it): said, and the screen keeps looking.
                resting[peer] = .now + Self.nearbyRefusedRest
                nearbyJoining = .declined
                continue
            case .refused(.busy), .refused(.closed):
                // Another device's session, or home's session ran out: home is still the one to ask.
                resting[peer] = .now + nearbyRetry
            case .refused:
                resting[peer] = .now + Self.nearbyRefusedRest
            }
            nearbyJoining = nearby.peers.isEmpty ? .looking : .found
        }
    }

    /// The next device to try: one never tried, at random, while fewer than `newPeersPerMinute` were tried for the
    /// first time this minute; else one tried before, at random; nil when none is ready.
    nonisolated static func nearbyPick(ready: [NearbyPeer], tried: Set<NearbyPeer>, newThisMinute: Int) -> NearbyPeer? {
        let untried = ready.filter { !tried.contains($0) }
        if !untried.isEmpty, newThisMinute < NearbyJoinRuntime.newPeersPerMinute { return untried.randomElement() }
        return ready.filter { tried.contains($0) }.randomElement()
    }

    func nearbyConnected(generation gen: Int) {
        guard gen == generation, nearby.joinTask != nil else { return }
        nearbyJoining = .connected
    }

    /// Takes an approval that came nearby into the open, locked copy under its write lock (`Vault.takeNearbyReply`, the
    /// join run's own test), then reads `vault.json` again: the join screen moves on to the reply words.
    func takeNearbyReply(_ reply: NearbyJoinReply, nonce: Data, commitment: Data) async throws {
        guard phase == .locked, let url = vaultURL, let identity = joinIdentity, let id = vault?.vaultId else {
            throw ModelError.noVaultOpen
        }
        let lock = vaultWriteLock
        let unconfirmed = trust.map { ((try? $0.record(for: id)) ?? nil) == nil } ?? false
        _ = try await offMain {
            try Self.withWriteLock(lock) {
                try Vault.takeNearbyReply(reply, at: url, nonce: nonce, commitment: commitment, identities: [identity],
                                          unconfirmed: unconfirmed)
            }
        }
        await refreshLockedManifest()
    }
}

/// A flag set from a `@Sendable` closure (whether a session got as far as `waiting`).
final class NearbyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
