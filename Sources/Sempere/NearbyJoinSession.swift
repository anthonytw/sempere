import Age
import Foundation

// The two ends of a nearby join session (docs/design/nearby-join.md), over any byte stream: the app's
// Network.framework connection, or `NearbyJoinPipe` in memory. One session is one connection: the joining device sends
// the magic and its request; the approver answers with the magic and `waiting` (then, once approved, the sealed reply),
// or with a refusal; then the connection is closed. Every read is bounded (`NearbyFrameReader`) and every wait timed
// (`NearbyJoin.Timeouts`).

/// A byte stream between two devices (untrusted). `receive` returns at least one byte, or none at the end of the
/// stream; `cancel` ends the stream both ways and makes every pending `send` or `receive` return or throw at once.
public protocol NearbyJoinConnection: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func receive(maximum: Int) async throws -> Data
    func cancel()
}

/// The frames of one connection, read one after the other.
actor NearbyChannel {
    let connection: any NearbyJoinConnection
    private var reader: NearbyFrameReader
    /// The other side ended the stream (or broke it).
    private(set) var ended = false

    init(_ connection: any NearbyJoinConnection, reading sender: NearbyFrameReader.Sender) {
        self.connection = connection
        reader = NearbyFrameReader(reading: sender)
    }

    /// The next message.
    func next() async throws -> NearbyJoinMessage {
        while true {
            if let m = try reader.next() { return m }
            let bytes = try await connection.receive(maximum: 64 * 1024)
            guard !bytes.isEmpty else {
                ended = true
                throw NearbyJoinError.closed
            }
            try reader.push(bytes)
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
    /// `op`, or `timedOut` after `limit`: then `onTimeout` runs (it cancels the connection, which ends `op`).
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

    /// Sends `request` (the bytes of this device's `joins/<id>.join.json`) with a fresh `nonce`, and waits for the
    /// approver's answer: `waiting` (then `onWaiting` runs and the approval is awaited, up to the session's timeout),
    /// the reply, or a refusal. The connection is closed when it returns.
    ///
    /// - Throws: `NearbyJoinError` (the link, a reply not for this session), what `JoinRequest.parse` throws.
    public static func run(on connection: any NearbyJoinConnection, request: Data, nonce: Data, identity: NativeIdentity,
                           timeouts: NearbyJoin.Timeouts = .standard,
                           onWaiting: @escaping @Sendable () async -> Void = {}) async throws -> Outcome {
        defer { connection.cancel() }
        let commitment = try JoinRequest.parse(request).commitment
        guard nonce.count == NearbyJoin.nonceBytes else { throw NearbyJoinError.malformed("a nonce of the wrong size") }
        let channel = NearbyChannel(connection, reading: .approver)
        let started = ContinuousClock.now
        let first = try await NearbyDeadline.within(timeouts.handshake, onTimeout: connection.cancel) {
            // An approver that refuses at once (busy) may close before the request is through: its answer is read all
            // the same, and a stream with none ends as `closed`.
            try? await connection.send(NearbyJoin.magic + NearbyJoinMessage.request(nonce: nonce, request: request).frame())
            return try await channel.next()
        }
        var message = first
        if message == .waiting {
            await onWaiting()
            let left = timeouts.session - (ContinuousClock.now - started)
            guard left > .zero else { throw NearbyJoinError.timedOut }
            message = try await NearbyDeadline.within(left, onTimeout: connection.cancel) { try await channel.next() }
        }
        switch message {
        case .reply(let sealed):
            let reply = try NearbyJoinReply.open(sealed, identity: identity)
            guard reply.nonce == nonce, reply.commitment == commitment else { throw NearbyJoinError.replayed }
            return .reply(reply)
        case .refused(let why):
            return .refused(why)
        case .waiting:
            throw NearbyJoinError.unexpected("waiting twice")
        case .request:
            throw NearbyJoinError.unexpected("a request from the approver")
        }
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
        /// The session's time ran out while the approval was awaited.
        case timedOut
    }

    /// Reads the request (within the handshake timeout), asks `received` what to do with it, and, for `wait`, sends
    /// `waiting` and awaits `outcome` until the session's timeout or the joining device leaves (it is then canceled:
    /// `outcome` must return when its task is canceled). The connection is closed when it returns.
    ///
    /// - Throws: `NearbyJoinError` for a stream that is not a request (garbage, too large, too slow); the joining
    ///   device was sent `malformed` first when the stream at least started right.
    public static func run(on connection: any NearbyJoinConnection, timeouts: NearbyJoin.Timeouts = .standard,
                           received: @escaping @Sendable (_ request: JoinRequest, _ raw: Data, _ nonce: Data) async -> Answer,
                           outcome: @escaping @Sendable () async -> Final) async throws -> Ending {
        defer { connection.cancel() }
        let writer = Writer(connection)
        let channel = NearbyChannel(connection, reading: .joiner)
        let started = ContinuousClock.now
        let first: NearbyJoinMessage
        do {
            first = try await NearbyDeadline.within(timeouts.handshake, onTimeout: connection.cancel) { try await channel.next() }
        } catch let error as NearbyJoinError {
            switch error {
            case .oversized, .malformed, .unexpected: try? await writer.send(.refused(.malformed))
            default: break
            }
            throw error
        }
        guard case .request(let nonce, let raw) = first else { throw NearbyJoinError.unexpected("not a request") }
        let request: JoinRequest
        do { request = try JoinRequest.parse(raw) } catch {
            try? await writer.send(.refused(.malformed))
            throw NearbyJoinError.malformed("not a join request")
        }
        switch await received(request, raw, nonce) {
        case .refuse(let why):
            try? await writer.send(.refused(why))
            return .refused(why)
        case .reply(let sealed):
            try await writer.send(.reply(sealed))
            return .replied
        case .wait:
            break
        }
        try await writer.send(.waiting)
        let waiting = Task { await outcome() }
        let watcher = Task {
            await channel.untilEnded()
            waiting.cancel()
        }
        defer { watcher.cancel() }
        let left = timeouts.session - (ContinuousClock.now - started)
        let final: Final
        do {
            final = try await NearbyDeadline.within(max(left, .zero), onTimeout: { waiting.cancel() }) { await waiting.value }
        } catch {
            try? await writer.send(.refused(.closed))
            return .timedOut
        }
        if await channel.ended { return .peerLeft }
        switch final {
        case .reply(let sealed):
            try await writer.send(.reply(sealed))
            return .replied
        case .refuse(let why):
            try? await writer.send(.refused(why))
            return .refused(why)
        }
    }

    /// Ends a connection that came while another session is going: the magic and `busy`, then closed.
    public static func refuseBusy(_ connection: any NearbyJoinConnection) async {
        try? await Writer(connection).send(.refused(.busy))
        connection.cancel()
    }

    /// One connection's sends: the magic goes with the first.
    final class Writer: @unchecked Sendable {
        // Used by one task at a time (the session's), never concurrently.
        let connection: any NearbyJoinConnection
        private var sentMagic = false

        init(_ connection: any NearbyJoinConnection) { self.connection = connection }

        func send(_ message: NearbyJoinMessage) async throws {
            let bytes = (sentMagic ? Data() : NearbyJoin.magic) + message.frame()
            sentMagic = true
            try await connection.send(bytes)
        }
    }
}
