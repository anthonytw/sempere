import Age
import Crypto
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Joining nearby (docs/design/nearby-join.md): the framing, the sealed reply and both ends of a session over an
/// in-memory pipe, against real vaults, with hostile peers on either end.
final class NearbyJoinTests: VaultTestCase {
    let home = pqIdentity(), laptop = pqIdentity()
    let homeTrust = MemoryEpochTrustStore(), laptopTrust = MemoryEpochTrustStore()
    static let quick = NearbyJoin.Timeouts(handshake: .milliseconds(300), session: .milliseconds(800))

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    /// Home's vault, and the joining laptop's copy of it (made before the approval) holding the laptop's request.
    struct Pair {
        var home: Vault
        let copy: URL
        let laptop: DeviceKeys
        let request: JoinRequest
        let raw: Data
    }

    func pair() throws -> Pair {
        let vault = try TestVaults.create(at: vaultURL(), identities: [home], names: ["Home"], trust: homeTrust)
        let copy = tmp.appendingPathComponent("Copy.sempere")
        try FileManager.default.copyItem(at: vault.url, to: copy)
        let keys = TestVaults.device(laptop)
        let request = try Vault.writeJoinRequest(at: copy, device: keys, name: "Laptop", kind: "mac")
        let raw = try Data(contentsOf: copy.appendingPathComponent("joins").appendingPathComponent(request.fileName))
        return Pair(home: vault, copy: copy, laptop: keys, request: request, raw: raw)
    }

    func manifest(_ url: URL) throws -> Data { try Data(contentsOf: url.appendingPathComponent("vault.json")) }

    // MARK: - A whole session

    /// The request goes over the link (home places it in its `joins/`), home approves it, the reply for this session's
    /// nonce comes back and the copy takes it: the laptop then confirms with the reply words exactly as after a sync.
    func testTheApproverSealsTheReplyForThisSession() async throws {
        let p = try pair()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let homeURL = p.home.url, homeID = home, trust = homeTrust
        let session = Box<(JoinRequest, Data)>()
        let words = Box<[String]>()
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, timeouts: .standard, received: { request, raw, nonce in
                let v = try? TestVaults.open(at: homeURL, identity: homeID, trust: trust)
                guard (try? v?.placeNearbyJoinRequest(raw)) != nil else { return .refuse(.otherVault) }
                session.set((request, nonce))
                return .wait
            }, outcome: {
                guard let (request, nonce) = session.get(),
                      var v = try? TestVaults.open(at: homeURL, identity: homeID, trust: trust),
                      let typed = try? v.approveDevice(request),
                      let sealed = try? v.nearbyReply(for: request, nonce: nonce)?.seal(to: request.key) else {
                    return .refuse(.cannotApprove)
                }
                words.set(typed)
                return .reply(sealed)
            })
        }
        let nonce = NearbyJoin.randomBytes(32)
        let waited = Box<Bool>()
        let outcome = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: nonce, identity: laptop,
                                                 timeouts: .standard) { waited.set(true) }
        let ending = try await homeSide.value
        XCTAssertEqual(ending, .replied)
        XCTAssertEqual(waited.get(), true, "home said it was waiting for the approval first")
        guard case .reply(let reply) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(try Vault.takeNearbyReply(reply, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                identities: [laptop], unconfirmed: true))
        XCTAssertEqual(try manifest(p.copy), try manifest(p.home.url), "the copy holds home's vault.json")
        // Taken twice (the same reply, or the sync's copy of it): nothing changes.
        XCTAssertFalse(try Vault.takeNearbyReply(reply, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                 identities: [laptop], unconfirmed: true))
        var mine = try TestVaults.open(at: p.copy, identity: laptop, trust: laptopTrust)
        XCTAssertEqual(mine.listStatus.problem?.reason, .rootUnconfirmed, "nothing pinned before the reply words")
        try mine.confirmJoin(words: try XCTUnwrap(words.get()))
        XCTAssertNil(mine.listStatus.problem)
        // Home's records: the request reached its joins/ (and went with the approval).
        XCTAssertTrue(try TestVaults.open(at: homeURL, identity: home, trust: homeTrust).joinRequests().isEmpty)
        // Nothing of the vault's list crossed the link in the clear.
        let names = Data("Home".utf8)
        XCTAssertNil(homeEnd.sent.range(of: names), "home's sends name no device")
        XCTAssertNil(homeEnd.sent.range(of: Data(p.home.vaultId.uuidString.lowercased().utf8)))
    }

    /// A device home lists already (approved through the target first) gets its reply at once.
    func testAListedDeviceIsAnsweredAtOnce() async throws {
        var p = try pair()
        let words = try p.home.approveDevice(p.request)
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let v = p.home
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, timeouts: Self.quick, received: { request, _, nonce in
                guard let sealed = try? v.nearbyReply(for: request, nonce: nonce)?.seal(to: request.key) else { return .wait }
                return .reply(sealed)
            }, outcome: { .refuse(.closed) })
        }
        let nonce = NearbyJoin.randomBytes(32)
        let outcome = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: nonce, identity: laptop, timeouts: Self.quick)
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .replied)
        guard case .reply(let reply) = outcome else { return XCTFail("\(outcome)") }
        try Vault.takeNearbyReply(reply, at: p.copy, nonce: nonce, commitment: p.request.commitment, identities: [laptop],
                                  unconfirmed: true)
        var mine = try TestVaults.open(at: p.copy, identity: laptop, trust: laptopTrust)
        try mine.confirmJoin(words: words)
    }

    /// The copy was made before home started a new epoch (it removed a device): the reply carries the current record,
    /// which the copy takes (checked against the hash vault.json names) before vault.json.
    func testTheReplyBringsTheCurrentRecordToACopyBehindAnEpoch() throws {
        var p = try pair()
        let old = pqIdentity()
        try p.home.approveDevice(TestVaults.device(old).joinRequest(vaultId: p.home.vaultId, name: "Old", kind: "cli"))
        let oldID = try XCTUnwrap(p.home.manifest.devices.first { $0.key == old.recipient.string }?.id)
        p.home = try TestVaults.open(at: p.home.url, identity: home, trust: homeTrust)
        try p.home.removeDevices([oldID])
        XCTAssertEqual(p.home.manifest.epoch, 2)
        let words = try p.home.approveDevice(p.request)
        let nonce = NearbyJoin.randomBytes(32)
        let reply = try XCTUnwrap(try p.home.nearbyReply(for: p.request, nonce: nonce))
        XCTAssertNotNil(reply.record)

        // A record with other bytes under its name is refused, and nothing is taken.
        var forged = reply
        forged.record = reply.record.map { Data($0.reversed()) }
        XCTAssertThrowsError(try Vault.takeNearbyReply(forged, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                       identities: [laptop], unconfirmed: true)) {
            XCTAssertEqual($0 as? NearbyJoinError, .recordMismatch)
        }
        XCTAssertNotEqual(try manifest(p.copy), try manifest(p.home.url))
        // Without a record (one too large to send) and none in the copy: not taken; the sync brings both.
        var bare = reply
        bare.record = nil
        XCTAssertThrowsError(try Vault.takeNearbyReply(bare, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                       identities: [laptop], unconfirmed: true))

        try Vault.takeNearbyReply(reply, at: p.copy, nonce: nonce, commitment: p.request.commitment, identities: [laptop],
                                  unconfirmed: true)
        var mine = try TestVaults.open(at: p.copy, identity: laptop, trust: laptopTrust)
        try mine.confirmJoin(words: words)
        XCTAssertNil(mine.listStatus.problem)
        XCTAssertEqual(mine.manifest.epoch, 2)
    }

    // MARK: - Hostile peers

    /// A replayed reply (an earlier session's nonce) and one for another request are refused by the joiner.
    func testAReplayedReplyIsRefused() async throws {
        var p = try pair()
        try p.home.approveDevice(p.request)
        let earlier = NearbyJoin.randomBytes(32)
        let sealed = try XCTUnwrap(try p.home.nearbyReply(for: p.request, nonce: earlier)).seal(to: p.request.key)
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let replayer = Task {
            _ = try await homeEnd.receive(maximum: 1 << 20)
            try await homeEnd.send(NearbyJoin.magic + NearbyJoinMessage.reply(sealed).frame())
        }
        do {
            _ = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                           timeouts: Self.quick)
            XCTFail("a replayed reply was taken")
        } catch let e as NearbyJoinError {
            XCTAssertEqual(e, .replayed)
        }
        try await replayer.value
        // The same at the vault: another nonce or another commitment.
        let reply = try XCTUnwrap(try p.home.nearbyReply(for: p.request, nonce: earlier))
        XCTAssertThrowsError(try Vault.takeNearbyReply(reply, at: p.copy, nonce: NearbyJoin.randomBytes(32),
                                                       commitment: p.request.commitment, identities: [laptop], unconfirmed: true)) {
            XCTAssertEqual($0 as? NearbyJoinError, .replayed)
        }
        XCTAssertThrowsError(try Vault.takeNearbyReply(reply, at: p.copy, nonce: earlier, commitment: Data(count: 32),
                                                       identities: [laptop], unconfirmed: true)) {
            XCTAssertEqual($0 as? NearbyJoinError, .replayed)
        }
    }

    /// A reply sealed to another key does not open, and a reply whose vault.json is not an approval of this device (a
    /// device in the middle with a vault of its own) is not taken.
    func testARepliesOfAnotherVaultOrKeyAreRefused() throws {
        var p = try pair()
        try p.home.approveDevice(p.request)
        let nonce = NearbyJoin.randomBytes(32)
        let reply = try XCTUnwrap(try p.home.nearbyReply(for: p.request, nonce: nonce))
        XCTAssertThrowsError(try NearbyJoinReply.open(try reply.seal(to: pqIdentity().recipient.string), identity: laptop))

        // Another vault (same request keys, approved there): another vault id and root.
        var other = try TestVaults.create(at: vaultURL("Other"), identities: [pqIdentity()], trust: MemoryEpochTrustStore())
        let theirs = TestVaults.device(laptop).joinRequest(vaultId: other.vaultId, name: "Laptop", kind: "mac")
        try other.approveDevice(theirs)
        var foreign = try XCTUnwrap(try other.nearbyReply(for: theirs, nonce: nonce))
        foreign.commitment = p.request.commitment
        XCTAssertThrowsError(try Vault.takeNearbyReply(foreign, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                       identities: [laptop], unconfirmed: true)) {
            XCTAssertEqual($0 as? NearbyJoinError, .notAnApproval)
        }
        // Home's own vault.json before the approval (it does not list the laptop): no approval either.
        var unlisted = reply
        unlisted.manifest = try Data(contentsOf: vaultURL("Other").appendingPathComponent("vault.json"))
        XCTAssertThrowsError(try Vault.takeNearbyReply(unlisted, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                       identities: [laptop], unconfirmed: true))
    }

    /// Home refuses a request of another vault (another person's Add Device), and places nothing.
    func testARequestOfAnotherVaultIsRefused() async throws {
        let p = try pair()
        let stranger = try TestVaults.create(at: vaultURL("Stranger"), identities: [pqIdentity()], trust: MemoryEpochTrustStore())
        XCTAssertThrowsError(try stranger.placeNearbyJoinRequest(p.raw)) { XCTAssertEqual($0 as? NearbyJoinError, .otherVault) }
        XCTAssertTrue(stranger.joinRequests().isEmpty)
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, timeouts: Self.quick, received: { _, raw, _ in
                (try? stranger.placeNearbyJoinRequest(raw)) == nil ? .refuse(.otherVault) : .wait
            }, outcome: { .refuse(.closed) })
        }
        let outcome = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32),
                                                 identity: laptop, timeouts: Self.quick)
        XCTAssertEqual(outcome, .refused(.otherVault))
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .refused(.otherVault))
    }

    /// The approver reads no frame larger than a request: a peer claiming a huge one is refused before its body, and
    /// garbage (no magic) is refused at once.
    func testOversizedFramesAndGarbageAreRefused() async throws {
        for (input, expected) in [(NearbyJoin.magic + Data([0x7f, 0xff, 0xff, 0xff, 1]), NearbyJoinError.oversized(0x7fffffff)),
                                  (Data("GET / HTTP/1.1\r\n\r\n".utf8), .badMagic),
                                  (NearbyJoin.magic + NearbyJoinMessage.waiting.frame(), .unexpected("message type 2"))] {
            let (peer, homeEnd) = NearbyJoinPipe.make()
            try await peer.send(input)
            let called = Box<Bool>()
            do {
                _ = try await NearbyApprover.run(on: homeEnd, timeouts: Self.quick, received: { _, _, _ in
                    called.set(true)
                    return .wait
                }, outcome: { .refuse(.closed) })
                XCTFail("accepted \(input.prefix(32))")
            } catch let e as NearbyJoinError {
                XCTAssertEqual(e, expected)
            }
            XCTAssertNil(called.get(), "nothing reached the model")
        }
        // A request frame whose file is not a join request.
        let (peer, homeEnd) = NearbyJoinPipe.make()
        try await peer.send(NearbyJoin.magic + NearbyJoinMessage.request(nonce: Data(count: 32), request: Data("{}".utf8)).frame())
        do {
            _ = try await NearbyApprover.run(on: homeEnd, timeouts: Self.quick, received: { _, _, _ in .wait },
                                             outcome: { .refuse(.closed) })
            XCTFail("accepted a request that does not parse")
        } catch {}
        var reader = NearbyFrameReader(reading: .approver)
        try reader.push(peer.inbox.take(1 << 20) ?? Data())
        XCTAssertEqual(try reader.next(), .refused(.malformed), "told why")

        // The joining device reads no frame larger than a reply.
        var joiner = NearbyFrameReader(reading: .approver)
        try joiner.push(NearbyJoin.magic + Data([0x7f, 0, 0, 0]))
        XCTAssertThrowsError(try joiner.next()) { XCTAssertEqual($0 as? NearbyJoinError, .oversized(0x7f00_0000)) }
        var full = NearbyFrameReader(reading: .joiner)
        XCTAssertThrowsError(try full.push(Data(count: full.capacity + 1)))
    }

    /// A silent peer, and an approver that never answers after `waiting`, run out of time.
    func testSilentPeersTimeOut() async throws {
        let (silent, homeEnd) = NearbyJoinPipe.make()
        do {
            _ = try await NearbyApprover.run(on: homeEnd, timeouts: Self.quick, received: { _, _, _ in .wait },
                                             outcome: { .refuse(.closed) })
            XCTFail("a silent peer held the session")
        } catch let e as NearbyJoinError {
            XCTAssertEqual(e, .timedOut)
        }
        _ = silent

        let p = try pair()
        let (joinerEnd, stallingHome) = NearbyJoinPipe.make()
        let staller = Task {
            _ = try await stallingHome.receive(maximum: 1 << 20)
            try await stallingHome.send(NearbyJoin.magic + NearbyJoinMessage.waiting.frame())
        }
        let start = ContinuousClock.now
        do {
            _ = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                           timeouts: Self.quick)
            XCTFail("a stalling approver held the joiner")
        } catch let e as NearbyJoinError {
            XCTAssertTrue(e == .timedOut || e == .closed, "\(e)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        try await staller.value
    }

    /// The approver's wait ends when the joining device goes away (its outcome is canceled), and when the session's
    /// time runs out (the joining device is told).
    func testTheApproverStopsWaitingForAPeerThatLeft() async throws {
        let p = try pair()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let canceled = Box<Bool>()
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, timeouts: .standard, received: { _, _, _ in .wait }, outcome: {
                // Waits for an approval that never comes, until canceled.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                canceled.set(true)
                return .refuse(.closed)
            })
        }
        try await joinerEnd.send(NearbyJoin.magic + NearbyJoinMessage.request(nonce: Data(count: 32), request: p.raw).frame())
        var reader = NearbyFrameReader(reading: .approver)
        while try reader.next() == nil { try reader.push(try await joinerEnd.receive(maximum: 1024)) }
        joinerEnd.cancel()
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .peerLeft)
        XCTAssertEqual(canceled.get(), true)

        let (joiner2, home2) = NearbyJoinPipe.make()
        let timed = Task {
            try await NearbyApprover.run(on: home2, timeouts: Self.quick, received: { _, _, _ in .wait }, outcome: {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                return .refuse(.closed)
            })
        }
        let outcome = try await NearbyJoiner.run(on: joiner2, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                                 timeouts: .standard)
        XCTAssertEqual(outcome, .refused(.closed))
        let timedEnding = try await timed.value
        XCTAssertEqual(timedEnding, .timedOut)
    }

    /// A second device while a session is going is told `busy`.
    func testASecondSessionIsToldBusy() async throws {
        let p = try pair()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        Task { await NearbyApprover.refuseBusy(homeEnd) }
        let outcome = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32),
                                                 identity: laptop, timeouts: Self.quick)
        XCTAssertEqual(outcome, .refused(.busy))
    }

    // MARK: - Pieces

    func testFramesRoundTripInPieces() throws {
        let messages: [NearbyJoinMessage] = [.waiting, .reply(Data([1, 2, 3])), .refused(.declined)]
        let stream = NearbyJoin.magic + messages.map { $0.frame() }.reduce(Data(), +)
        var reader = NearbyFrameReader(reading: .approver)
        var out: [NearbyJoinMessage] = []
        for b in stream {
            try reader.push(Data([b]))
            while let m = try reader.next() { out.append(m) }
        }
        XCTAssertEqual(out, messages)
        let request = NearbyJoinMessage.request(nonce: Data(repeating: 7, count: 32), request: Data("{}".utf8))
        var home = NearbyFrameReader(reading: .joiner)
        try home.push(NearbyJoin.magic + request.frame())
        XCTAssertEqual(try home.next(), request)
        var partial = NearbyFrameReader(reading: .joiner)
        try partial.push(Data("semp".utf8))
        XCTAssertNil(try partial.next())
        try partial.push(Data("ERE".utf8))
        XCTAssertThrowsError(try partial.next()) { XCTAssertEqual($0 as? NearbyJoinError, .badMagic) }
    }

    func testReplyPlaintextRoundTripsAndRejectsTrailingBytes() throws {
        let r = NearbyJoinReply(nonce: Data(repeating: 1, count: 32), commitment: Data(repeating: 2, count: 32),
                                manifest: Data("{}".utf8), recordName: "1-0123456789abcdef.epoch.age", record: Data([9]))
        XCTAssertEqual(try NearbyJoinReply.parse(r.plaintext()), r)
        XCTAssertThrowsError(try NearbyJoinReply.parse(r.plaintext() + Data([0])))
        var bad = r
        bad.recordName = "../vault.json"
        XCTAssertThrowsError(try NearbyJoinReply.parse(bad.plaintext()))
        XCTAssertEqual(try NearbyJoinReply.open(try r.seal(to: laptop.recipient.string), identity: laptop), r)
    }

    func testInstanceNamesAreRandomAndNameNothing() {
        let a = NearbyJoin.instanceName(), b = NearbyJoin.instanceName()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("Sempere-"))
        XCTAssertEqual(a.count, "Sempere-".count + 12)
    }
}

/// A value set from a `@Sendable` closure and read by the test.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
