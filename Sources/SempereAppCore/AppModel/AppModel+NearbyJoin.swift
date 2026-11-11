import Foundation
import Sempere

// Joining nearby (docs/design/nearby-join.md, key-hierarchy design §6.2.1): while Add Device shows on home, home
// advertises the link's service; while the join screen waits on the new device, it browses, connects and sends its
// request. Home lists the request with the synced ones; once the user approves it (by the six words or the QR code, as
// always), home sends the approval back over the same connection, and the new device takes it into its copy as a join
// run would. The new device still confirms with home's reply words. Both routes run side by side: whichever brings the
// request or the approval first wins, and the other finds nothing left to do.

/// Add Device's side of the nearby link.
public enum NearbyApproverStatus: Equatable, Sendable {
    /// Add Device is not showing.
    case off
    /// No link on this device, or this device cannot approve now (locked, read-only, not home).
    case unavailable
    /// Advertising: a new device nearby can send its request.
    case advertising
    /// A device nearby is connected (one session at a time).
    case connected
}

/// The join screen's side of the nearby link.
public enum NearbyJoinStatus: Equatable, Sendable {
    /// The join screen is not waiting.
    case off
    /// No link on this device.
    case unavailable
    /// Looking for a device that manages devices nearby.
    case looking
    /// A device advertises nearby; connecting.
    case found
    /// The device that manages devices has the request and lists it.
    case connected
    /// Its approval arrived over the link: the reply words are next.
    case received
    /// It declined the request.
    case declined
}

/// What ends home's wait for the user in a nearby session.
enum NearbyDecision: Sendable {
    case approved, declined, closed
}

/// The nearby link's running parts (one per model).
@MainActor
final class NearbyJoinRuntime {
    // Home
    var advertisement: (any NearbyActivity)?
    var session: Task<Void, Never>?
    /// The session's request and nonce, once it waits for the approval.
    var pending: (request: JoinRequest, nonce: Data)?
    var decision: NearbyDecision?
    var waiter: CheckedContinuation<NearbyDecision, Never>?
    // The joining device
    var browsing: (any NearbyActivity)?
    var joinTask: Task<Void, Never>?
    var peers: [NearbyPeer] = []

    /// Ends the wait of the session going, once.
    func decide(_ d: NearbyDecision) {
        guard decision == nil else { return }
        decision = d
        let w = waiter
        waiter = nil
        w?.resume(returning: d)
    }

    /// The user's decision; `closed` when the waiting task is canceled (the joining device left, time ran out).
    func waitForDecision() async -> NearbyDecision {
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
            Task { @MainActor [weak self] in self?.decide(.closed) }
        }
    }

    func endSession() {
        session = nil
        pending = nil
        decide(.closed)
        decision = nil
    }
}

extension AppModelCore {
    // MARK: - Home: Add Device

    /// Starts advertising for Add Device (its sheet calls it when it shows): only on home, unlocked and writable, and
    /// only with a link. A connection that comes while a session goes is told `busy`.
    public func startNearbyApproving() {
        guard nearby.advertisement == nil else { return }
        guard let transport = nearbyTransport else { nearbyApproving = .off; return }
        guard phase == .unlocked, vault?.isHome == true, !isVaultReadOnly else { nearbyApproving = .unavailable; return }
        do {
            nearby.advertisement = try transport.advertise { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.acceptNearby(connection)
                }
            }
            nearbyApproving = .advertising
        } catch {
            nearbyApproving = .unavailable
        }
    }

    /// Stops advertising (Add Device closed, the vault closed): a session waiting for the approval is told `closed`.
    public func stopNearbyApproving() {
        nearby.advertisement?.stop()
        nearby.advertisement = nil
        nearby.decide(.closed)
        nearbyRequests = []
        nearbyApproving = .off
    }

    func acceptNearby(_ connection: any NearbyJoinConnection) {
        guard nearby.advertisement != nil else { connection.cancel(); return }
        guard nearby.session == nil else {
            Task.detached { await NearbyApprover.refuseBusy(connection) }
            return
        }
        let gen = generation, timeouts = nearbyTimeouts
        nearbyApproving = .connected
        nearby.decision = nil
        nearby.session = Task { [weak self] in
            _ = try? await NearbyApprover.run(on: connection, timeouts: timeouts, received: { [weak self] request, raw, nonce in
                await self?.nearbyReceived(request, raw: raw, nonce: nonce, generation: gen) ?? .refuse(.closed)
            }, outcome: { [weak self] in
                await self?.nearbyOutcome(generation: gen) ?? .refuse(.closed)
            })
            self?.nearbySessionEnded()
        }
    }

    /// Home's first answer to a request that came nearby: refused when it cannot be approved here, the reply at once
    /// when the device is listed already, else placed in the copy's `joins/` (as a sync places one) and listed.
    func nearbyReceived(_ request: JoinRequest, raw: Data, nonce: Data, generation gen: Int) async -> NearbyApprover.Answer {
        guard gen == generation, nearby.advertisement != nil, let current = vault, phase == .unlocked, current.isHome,
              !isVaultReadOnly else { return .refuse(.cannotApprove) }
        guard request.vaultId == current.vaultId else { return .refuse(.otherVault) }
        // Approved already (through a target, or in an earlier session): the reply at once.
        if let sealed = await nearbySealedReply(current, request, nonce) { return .reply(sealed) }
        guard gen == generation, nearby.advertisement != nil else { return .refuse(.closed) }
        // In the copy, for the vault's records: the runs take it to the targets, and it stays listed after the session.
        _ = try? await offMain { try current.placeNearbyJoinRequest(raw) }
        guard gen == generation, nearby.advertisement != nil else { return .refuse(.closed) }
        nearby.pending = (request, nonce)
        nearbyRequests = [request]
        nearbyArrivals += 1
        return .wait
    }

    /// Waits for the user's decision on the session's request, then the reply (built from `vault.json` on disk).
    func nearbyOutcome(generation gen: Int) async -> NearbyApprover.Final {
        guard let pending = nearby.pending else { return .refuse(.closed) }
        switch await nearby.waitForDecision() {
        case .declined: return .refuse(.declined)
        case .closed: return .refuse(.closed)
        case .approved:
            guard gen == generation, let current = vault,
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

    func nearbySessionEnded() {
        nearby.endSession()
        nearbyRequests = []
        nearbyApproving = nearby.advertisement != nil ? .advertising : .off
        // The request stays listed from the copy's `joins/`: Add Device reads its list again.
        nearbyArrivals += 1
    }

    /// `approveDevice` approved `request`: the session waiting for it sends the reply.
    func nearbyApproved(_ request: JoinRequest) {
        guard nearby.pending?.request.key == request.key else { return }
        nearby.decide(.approved)
    }

    /// `declineJoinRequest` declined `fileName`: the session waiting for it says so.
    func nearbyDeclined(_ fileName: String) {
        nearbyRequests.removeAll { $0.fileName == fileName }
        guard nearby.pending?.request.fileName == fileName else { return }
        nearby.decide(.declined)
    }

    // MARK: - The joining device: the join screen

    /// Starts looking for home nearby while the join screen waits for the approval (its view calls it): browses, and
    /// sends this device's request (the bytes of its `joins/` file) to each device found in turn, until one approves.
    public func startNearbyJoin() {
        guard nearby.joinTask == nil else { return }
        guard let transport = nearbyTransport else { nearbyJoining = .off; return }
        guard phase == .locked, joinIdentity != nil, let v = vault, joinRequestedFile(v.vaultId) != nil else {
            nearbyJoining = .unavailable
            return
        }
        nearbyJoining = .looking
        nearby.peers = []
        nearby.browsing = transport.browse { [weak self] peers in
            Task { @MainActor in self?.nearbyPeersChanged(peers) }
        }
        let gen = generation
        nearby.joinTask = Task { [weak self] in await self?.nearbyJoinLoop(transport, generation: gen) }
    }

    /// Stops looking (the join screen went, the join was confirmed or canceled, the vault closed).
    public func stopNearbyJoin() {
        nearby.browsing?.stop()
        nearby.browsing = nil
        nearby.joinTask?.cancel()
        nearby.joinTask = nil
        nearby.peers = []
        nearbyJoining = .off
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

    /// One session at a time, with each device found: a device that refused (another vault, not home) rests a minute,
    /// a busy one or a broken link a moment.
    func nearbyJoinLoop(_ transport: any NearbyJoinTransport, generation gen: Int) async {
        var resting: [NearbyPeer: ContinuousClock.Instant] = [:]
        while !Task.isCancelled, gen == generation, phase == .locked {
            let now = ContinuousClock.now
            guard let peer = nearby.peers.first(where: { (resting[$0] ?? now) <= now }), let identity = joinIdentity,
                  let v = vault, let url = vaultURL, let file = joinRequestedFile(v.vaultId) else {
                try? await Task.sleep(for: nearbyRetry)
                continue
            }
            let requestURL = url.appendingPathComponent("joins").appendingPathComponent(file)
            // The request as written: its bytes are what the targets hold, so both routes bring home one file.
            guard let raw = try? await offMain({ try BoundedRead.contents(of: requestURL, maxBytes: JoinRequest.maxBytes) }),
                  let commitment = try? JoinRequest.parse(raw).commitment else {
                try? await Task.sleep(for: nearbyRetry)
                continue
            }
            let nonce = NearbyJoin.randomBytes(NearbyJoin.nonceBytes), timeouts = nearbyTimeouts
            let outcome: NearbyJoiner.Outcome
            do {
                let connection = try await transport.open(peer)
                outcome = try await NearbyJoiner.run(on: connection, request: raw, nonce: nonce, identity: identity,
                                                     timeouts: timeouts) { [weak self] in
                    await self?.nearbyConnected(generation: gen)
                }
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                resting[peer] = .now + nearbyRetry
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
                    nearby.browsing?.stop()
                    nearby.browsing = nil
                    nearby.joinTask = nil
                    return
                }
                resting[peer] = .now + .seconds(60)
            case .refused(.declined):
                nearbyJoining = .declined
                nearby.browsing?.stop()
                nearby.browsing = nil
                nearby.joinTask = nil
                return
            case .refused(.busy):
                resting[peer] = .now + nearbyRetry
            case .refused:
                resting[peer] = .now + .seconds(60)
            }
            nearbyJoining = nearby.peers.isEmpty ? .looking : .found
        }
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
