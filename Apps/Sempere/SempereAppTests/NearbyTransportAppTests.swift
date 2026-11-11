import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// The nearby link's Network.framework code (`NWNearbyTransport`, docs/design/nearby-join.md) on loopback: a real
/// `NWListener` and `NWConnection` pair on 127.0.0.1, running the package's sessions (`NearbyApprover`, `NearbyJoiner`)
/// over TCP, so the sends, receives, the end of a stream and cancellation are the code a device uses. Only discovery
/// differs: Bonjour over peer-to-peer Wi-Fi needs two devices, which no test here has. The joins through the model over
/// the link are `NearbyJoinModelTests` in `SempereAppCoreTests`; the protocol and the vault checks `NearbyJoinTests`.
/// Not in the offline mode (`OfflineModeTests`), whose sandbox refuses every outbound connection, loopback too.
///
/// Every wait is bounded (`connected` gives up after a few seconds, the sessions run on `quick` timeouts, and the suite
/// has a time limit), so a host whose sandbox or privacy settings block the listener fails here instead of holding the
/// shared Mac.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .disabled(if: OfflineModeTests.offline))
struct NearbyTransportAppTests {
    static let quick = NearbyJoin.Timeouts(handshake: .seconds(3), session: .seconds(5))

    struct NotConnected: Error {}

    /// A fresh loopback transport's listener, a browser that sees it, and a connection to it, within `limit`: (home's
    /// end, the joining device's end, stop).
    static func connected(limit: Duration = .seconds(5)) async throws
        -> (home: any NearbyJoinConnection, joiner: any NearbyJoinConnection, stop: @Sendable () -> Void) {
        let transport = NWNearbyTransport(mode: .loopback)
        let incoming = AsyncStream<any NearbyJoinConnection>.makeStream()
        let ad = try transport.advertise(accept: { incoming.continuation.yield($0) }, onFailure: { incoming.continuation.finish() })
        let peers = AsyncStream<[NearbyPeer]>.makeStream()
        let browsing = transport.browse(found: { peers.continuation.yield($0) }, onFailure: { peers.continuation.finish() })
        let stop: @Sendable () -> Void = {
            browsing.stop()
            ad.stop()
            incoming.continuation.finish()
            peers.continuation.finish()
        }
        // Past the limit the streams end, so every wait below returns.
        let watchdog = Task {
            try await Task.sleep(for: limit)
            stop()
        }
        defer { watchdog.cancel() }
        var peer: NearbyPeer?
        for await list in peers.stream {
            if let p = list.first { peer = p; break }
        }
        guard let peer else { stop(); throw NotConnected() }
        let joiner = try await transport.open(peer)
        var home: (any NearbyJoinConnection)?
        for await c in incoming.stream { home = c; break }
        guard let home else { joiner.cancel(); stop(); throw NotConnected() }
        return (home, joiner, stop)
    }

    static func request() throws -> (keys: DeviceKeys, raw: Data, vaultId: UUID) {
        let keys = try MemoryDeviceKeyStore().generate()
        let vaultId = UUID()
        let raw = try JSONEncoder().encode(keys.joinRequest(vaultId: vaultId, name: "iPad", kind: "ipad"))
        return (keys, raw, vaultId)
    }

    /// The joining device's side of the handshake by hand: hello, home's proof, the request.
    static func handshake(_ joiner: any NearbyJoinConnection, raw: Data, reader: inout NearbyFrameReader) async throws {
        try await joiner.send(NearbyJoin.magic + NearbyJoinMessage.hello(nonce: Data(count: 32)).frame())
        while try reader.next().map({ if case .proof = $0 { return true } else { return false } }) != true {
            let bytes = try await joiner.receive(maximum: 1024)
            guard !bytes.isEmpty else { throw NotConnected() }
            try reader.push(bytes)
        }
        try await joiner.send(NearbyJoinMessage.request(raw).frame())
    }

    /// A whole session over TCP: the hello and the proof, the request, then a sealed reply of a few megabytes (many receives), which the joining
    /// device opens and checks against its nonce and commitment.
    @Test func aSessionRunsOverRealConnections() async throws {
        let (home, joiner, stop) = try await Self.connected()
        defer { stop() }
        let (keys, raw, vaultId) = try Self.request()
        let record = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let nonce = NearbyJoin.randomBytes(32)
        let approver = Task.detached { () -> NearbyApprover.Ending in
            try await NearbyApprover.run(on: home, vaultId: vaultId, timeouts: Self.quick, received: { request, _, sessionNonce in
                let reply = NearbyJoinReply(nonce: sessionNonce, commitment: request.commitment, manifest: Data("{}".utf8),
                                            recordName: "2-0123456789abcdef.epoch.age", record: record)
                return (try? reply.seal(to: request.key)).map { .reply($0) } ?? .refuse(.malformed)
            }, outcome: { .refuse(.closed) })
        }
        let outcome = try await NearbyJoiner.run(on: joiner, request: raw, nonce: nonce, identity: keys.nativeIdentity,
                                                 timeouts: Self.quick)
        #expect(try await approver.value == .replied)
        guard case .reply(let reply) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reply.nonce == nonce)
        #expect(reply.record == record)
    }

    /// A frame claiming 2 GiB is refused before its body.
    @Test func anOversizedFrameIsRefusedOverRealConnections() async throws {
        let (home, joiner, stop) = try await Self.connected()
        defer { stop() }
        try await joiner.send(NearbyJoin.magic + Data([0x7f, 0xff, 0xff, 0xff, 1]))
        await #expect(throws: NearbyJoinError.oversized(0x7fff_ffff)) {
            _ = try await NearbyApprover.run(on: home, vaultId: UUID(), timeouts: Self.quick, received: { _, _, _ in .wait },
                                             outcome: { .refuse(.closed) })
        }
        joiner.cancel()
    }

    /// A joining device that never reads: home's send of an 8 MiB reply is cut off (or, if the system buffers it all,
    /// done) within the session's time, never held.
    @Test func aPeerThatNeverReadsCannotHoldHome() async throws {
        let (home, joiner, stop) = try await Self.connected()
        defer { stop() }
        let (_, raw, vaultId) = try Self.request()
        let big = Data(count: 8 << 20)
        let start = ContinuousClock.now
        let homeSide = Task.detached {
            try await NearbyApprover.run(on: home, vaultId: vaultId, timeouts: Self.quick, received: { _, _, _ in .reply(big) },
                                         outcome: { .refuse(.closed) })
        }
        var reader = NearbyFrameReader(reading: .approver)
        try await Self.handshake(joiner, raw: raw, reader: &reader)
        // ... and reads nothing more.
        let ended = try await homeSide.value
        #expect(ended == .timedOut || ended == .replied)
        #expect(ContinuousClock.now - start < .seconds(10))
        joiner.cancel()
    }

    /// A joining device that hangs up while home waits for the user ends the wait (the end of a real TCP stream).
    @Test func aPeerHangingUpEndsTheWait() async throws {
        let (home, joiner, stop) = try await Self.connected()
        defer { stop() }
        let (_, raw, vaultId) = try Self.request()
        let waiting = Task.detached {
            try await NearbyApprover.run(on: home, vaultId: vaultId, timeouts: Self.quick, received: { _, _, _ in .wait }, outcome: {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                return .refuse(.closed)
            })
        }
        var reader = NearbyFrameReader(reading: .approver)
        try await Self.handshake(joiner, raw: raw, reader: &reader)
        while try reader.next() == nil {
            let bytes = try await joiner.receive(maximum: 1024)
            guard !bytes.isEmpty else { break }
            try reader.push(bytes)
        }
        joiner.cancel()
        // `peerLeft`, or `timedOut` within the quick session if the end of the stream were missed (a failure).
        #expect(try await waiting.value == .peerLeft)
    }

    /// The join screen's and Add Device's words for the link.
    @Test func theLinkIsWorded() {
        #expect(NearbyJoinStatus.off.text == nil)
        #expect(NearbyJoinStatus.connected.text?.contains("approve it there") == true)
        #expect(NearbyJoinStatus.declined.text?.contains("Ask to Join") == true)
        #expect(NearbyApproverStatus.advertising.text?.contains("nearby") == true)
        #expect(NearbyApproverStatus.unavailable.text == nil)
    }
}
