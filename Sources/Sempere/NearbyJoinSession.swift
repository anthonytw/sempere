import Age
import Foundation

// The two ends of a nearby join session (docs/design/nearby-join.md), over any byte stream: the app's
// Network.framework connection, or `NearbyJoinPipe` in memory. One session is one connection:
//
//   joining device                 approver (home)
//   magic, hello(nonce)      ->
//                            <-    magic, proof(homeNonce, HMAC(vault id, nonce ‖ homeNonce))
//   request(join file)       ->                                             (only after a good proof)
//                            <-    waiting, then reply | refused            (or reply | refused at once: busy, ...)
//
// Every read is bounded by what the other side may send at that point (`NearbyFrameReader.Stage`), and every read and
// every send is timed (`NearbyJoin.Timeouts`): a peer that stops reading or sending ends the session, never holds it.

/// A byte stream between two devices (untrusted). `receive` returns at least one byte, or none at the end of the
/// stream; `cancel` ends the stream both ways (bytes already sent still go out) and makes every pending `send` or
/// `receive` return or throw; `abort` ends it at once, dropping what is still unsent (a session torn down or timed out).
public protocol NearbyJoinConnection: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func receive(maximum: Int) async throws -> Data
    func cancel()
    func abort()
}

extension NearbyJoinConnection {
    public func abort() { cancel() }
}

/// The frames of one connection, read one after the other.
actor NearbyChannel {
    let connection: any NearbyJoinConnection
    private var reader: NearbyFrameReader
    /// The other side ended the stream (or broke it).
    private(set) var ended = false

    init(_ connection: any NearbyJoinConnection, at stage: NearbyFrameReader.Stage) {
        self.connection = connection
        reader = NearbyFrameReader(at: stage)
    }

    /// What may come next (`NearbyFrameReader.expect`).
    func expect(_ stage: NearbyFrameReader.Stage) { reader.expect(stage) }

    private func more() async throws {
        // Never more than the stage's one frame can hold: what the peer sends early (a request right behind its hello)
        // waits in the connection until the stage that reads it.
        let room = reader.room
        guard room > 0 else { throw NearbyJoinError.oversized(reader.capacity + 1) }
        let bytes = try await connection.receive(maximum: min(64 * 1024, room))
        guard !bytes.isEmpty else {
            ended = true
            throw NearbyJoinError.closed
        }
        try reader.push(bytes)
    }

    /// Returns once the next frame's header is here and checked (its length and type).
    func header() async throws {
        while try !reader.headerReady() { try await more() }
    }

    /// The next message.
    func next() async throws -> NearbyJoinMessage {
        while true {
            if let m = try reader.next() { return m }
            try await more()
        }
    }

    /// Returns once the other side ends the stream, breaks it, or sends anything (it may send nothing more): the
    /// approver watches a joining device that went away while the user types.
    func untilEnded() async {
        _ = try? await connection.receive(maximum: 1)
        ended = true
    }
}

enum NearbyDeadline {
    /// `op`, or `timedOut` after `limit`: then `onTimeout` runs (it aborts the connection, which ends `op`).
    static func within<T: Sendable>(_ limit: Duration, onTimeout: @escaping @Sendable () -> Void,
                                    _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            if let first = try await group.next(), let value = first { return value }
            onTimeout()
            throw NearbyJoinError.timedOut
        }
    }

    /// What is left of `total` since `start`, but at least `floor`.
    static func left(_ total: Duration, since start: ContinuousClock.Instant, floor: Duration = .zero) -> Duration {
        max(total - (ContinuousClock.now - start), floor)
    }
}

/// One connection's sends, each within its own limit; the magic goes with the first.
final class NearbyWriter: @unchecked Sendable {
    // Used by one task at a time (the session's), never concurrently.
    let connection: any NearbyJoinConnection
    private var sentMagic = false

    init(_ connection: any NearbyJoinConnection) { self.connection = connection }

    /// Sends `message`, or throws `timedOut` (the connection aborted) when the peer does not take it within `limit`.
    func send(_ message: NearbyJoinMessage, within limit: Duration) async throws {
        let bytes = (sentMagic ? Data() : NearbyJoin.magic) + message.frame()
        sentMagic = true
        let connection = self.connection
        try await NearbyDeadline.within(limit, onTimeout: connection.abort) { try await connection.send(bytes) }
    }
}

/// The joining device's end of a session.
public enum NearbyJoiner {
    /// How a session ended.
    public enum Outcome: Equatable, Sendable {
        /// The approval, opened and checked to answer this session's request (nonce and commitment). What it holds is
        /// checked against the copy by `Vault.takeNearbyReply`.
        case reply(NearbyJoinReply)
        case refused(NearbyJoinRefusal)
    }

    /// Says `hello` with a fresh `nonce`; checks the approver's `proof` against the vault `request` names (a device
    /// that does not know the vault's id gets nothing else: `notThisVault`); sends `request` (the bytes of this
    /// device's `joins/<id>.join.json`); then waits for the answer: `waiting` (then `onWaiting` runs and the approval is
    /// awaited, up to the session's timeout), the reply, or a refusal. Every header must arrive within the handshake
    /// timeout and every body within the session's. The connection is closed when it returns.
    ///
    /// - Throws: `NearbyJoinError` (the link, `notThisVault`, a reply not for this session), what `JoinRequest.parse`
    ///   throws.
    public static func run(on connection: any NearbyJoinConnection, request: Data, nonce: Data, identity: NativeIdentity,
                           timeouts: NearbyJoin.Timeouts = .standard,
                           onWaiting: @escaping @Sendable () async -> Void = {}) async throws -> Outcome {
        defer { connection.cancel() }
        let parsed = try JoinRequest.parse(request)
        guard nonce.count == NearbyJoin.nonceBytes else { throw NearbyJoinError.malformed("a nonce of the wrong size") }
        // Before the proof only a proof or a refusal may come, each a few bytes: anything else, or longer, ends the
        // session from its header, before its body is held.
        let channel = NearbyChannel(connection, at: .proof)
        let writer = NearbyWriter(connection)
        let started = ContinuousClock.now
        // An approver that refuses at once may close before the hello is through: its answer is read all the same, and
        // a stream with none ends as `closed`.
        try? await writer.send(.hello(nonce: nonce), within: timeouts.handshake)
        let first = try await answer(channel, connection, header: timeouts.handshake, body: timeouts.handshake)
        switch first {
        case .proof(let homeNonce, let tag):
            guard NearbyJoin.checkProof(tag, vaultId: parsed.vaultId, nonce: nonce, homeNonce: homeNonce) else {
                connection.abort()
                throw NearbyJoinError.notThisVault
            }
        case .refused(let why):
            return .refused(why)
        default:
            throw NearbyJoinError.unexpected("not a proof")
        }
        await channel.expect(.answer)
        try await writer.send(.request(request), within: timeouts.handshake)
        var message = try await answer(channel, connection, header: timeouts.handshake,
                                       body: NearbyDeadline.left(timeouts.session, since: started, floor: timeouts.handshake))
        if message == .waiting {
            await channel.expect(.final)
            await onWaiting()
            let left = NearbyDeadline.left(timeouts.session, since: started)
            guard left > .zero else { throw NearbyJoinError.timedOut }
            message = try await answer(channel, connection, header: left, body: left)
        }
        switch message {
        case .reply(let sealed):
            let reply = try NearbyJoinReply.open(sealed, identity: identity)
            guard reply.nonce == nonce, reply.commitment == parsed.commitment else { throw NearbyJoinError.replayed }
            return .reply(reply)
        case .refused(let why):
            return .refused(why)
        case .waiting:
            throw NearbyJoinError.unexpected("waiting twice")
        default:
            throw NearbyJoinError.unexpected("not an answer to the request")
        }
    }

    /// The next message, its header within `header` and then its body within `body` (a reply may be megabytes).
    private static func answer(_ channel: NearbyChannel, _ connection: any NearbyJoinConnection, header: Duration,
                               body: Duration) async throws -> NearbyJoinMessage {
        try await NearbyDeadline.within(header, onTimeout: connection.abort) { try await channel.header() }
        return try await NearbyDeadline.within(body, onTimeout: connection.abort) { try await channel.next() }
    }
}

/// The approving device's end of a session.
public enum NearbyApprover {
    /// The approver's first answer to a request.
    public enum Answer: Sendable {
        /// The device is listed already (approved by either route): its reply, sealed, at once.
        case reply(Data)
        case refuse(NearbyJoinRefusal)
        /// Listed in Add Device: `outcome` is awaited for the approval.
        case wait
    }

    /// What ends a session that waited.
    public enum Final: Sendable {
        case reply(Data)
        case refuse(NearbyJoinRefusal)
    }

    /// How a session ended (for the approver's status and tests).
    public enum Ending: Equatable, Sendable {
        case replied
        case refused(NearbyJoinRefusal)
        /// The joining device went away while the approval was awaited.
        case peerLeft
        /// The session's time ran out while the approval was awaited, or the joining device did not take what was sent.
        case timedOut
    }

    /// Reads the `hello` and answers with the `proof` of `vaultId` (over a fresh nonce of its own), reads the request
    /// (the two within one limit, `timeouts.request`, from the connection), asks `received` what to do with it (the
    /// caller takes its one session there, or refuses `busy`), and, for `wait`, sends `waiting` and awaits `outcome`
    /// until the session's timeout or the joining device leaves (it is then canceled: `outcome` must return when its
    /// task is canceled). Every send is timed: refusals, `proof` and `waiting` by the handshake timeout, the reply by
    /// what is left of the session (at least the handshake's). The connection is closed when it returns.
    ///
    /// - Throws: `NearbyJoinError` for a stream that is not a hello and a request (garbage, too large, too slow); the
    ///   joining device was sent `malformed` first when the stream at least started right.
    public static func run(on connection: any NearbyJoinConnection, vaultId: UUID, timeouts: NearbyJoin.Timeouts = .standard,
                           received: @escaping @Sendable (_ request: JoinRequest, _ raw: Data, _ nonce: Data) async -> Answer,
                           outcome: @escaping @Sendable () async -> Final) async throws -> Ending {
        defer { connection.cancel() }
        let writer = NearbyWriter(connection)
        let channel = NearbyChannel(connection, at: .hello)
        let started = ContinuousClock.now
        let handshake = timeouts.handshake
        // One limit for the hello and the request together: a connection that sends nothing, or trickles, is dropped
        // within it, whatever it sends.
        func read() async throws -> NearbyJoinMessage {
            let left = NearbyDeadline.left(timeouts.request, since: started)
            do {
                guard left > .zero else { connection.abort(); throw NearbyJoinError.timedOut }
                return try await NearbyDeadline.within(left, onTimeout: connection.abort) { try await channel.next() }
            } catch let error as NearbyJoinError {
                switch error {
                case .oversized, .malformed, .unexpected: try? await writer.send(.refused(.malformed), within: handshake)
                default: break
                }
                throw error
            }
        }
        guard case .hello(let nonce) = try await read() else {
            try? await writer.send(.refused(.malformed), within: handshake)
            throw NearbyJoinError.unexpected("not a hello")
        }
        let homeNonce = NearbyJoin.randomBytes(NearbyJoin.nonceBytes)
        try await writer.send(.proof(homeNonce: homeNonce, tag: NearbyJoin.proof(vaultId: vaultId, nonce: nonce, homeNonce: homeNonce)),
                              within: handshake)
        await channel.expect(.request)
        guard case .request(let raw) = try await read() else {
            try? await writer.send(.refused(.malformed), within: handshake)
            throw NearbyJoinError.unexpected("not a request")
        }
        let request: JoinRequest
        do { request = try JoinRequest.parse(raw) } catch {
            try? await writer.send(.refused(.malformed), within: handshake)
            throw NearbyJoinError.malformed("not a join request")
        }
        let replyLimit = { NearbyDeadline.left(timeouts.session, since: started, floor: handshake) }
        switch await received(request, raw, nonce) {
        case .refuse(let why):
            try? await writer.send(.refused(why), within: handshake)
            return .refused(why)
        case .reply(let sealed):
            do { try await writer.send(.reply(sealed), within: replyLimit()) } catch { return .timedOut }
            return .replied
        case .wait:
            break
        }
        try await writer.send(.waiting, within: handshake)
        let waiting = Task { await outcome() }
        let watcher = Task {
            await channel.untilEnded()
            waiting.cancel()
        }
        defer { watcher.cancel() }
        let final: Final
        do {
            final = try await NearbyDeadline.within(NearbyDeadline.left(timeouts.session, since: started),
                                                    onTimeout: { waiting.cancel() }) { await waiting.value }
        } catch {
            try? await writer.send(.refused(.closed), within: handshake)
            return .timedOut
        }
        if await channel.ended { return .peerLeft }
        switch final {
        case .reply(let sealed):
            do { try await writer.send(.reply(sealed), within: replyLimit()) } catch { return .timedOut }
            return .replied
        case .refuse(let why):
            try? await writer.send(.refused(why), within: handshake)
            return .refused(why)
        }
    }
}
