import Age
import Crypto
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Joining nearby (docs/design/nearby-join.md): the framing, the handshake, the sealed reply and both ends of a session
/// over an in-memory pipe, against real vaults, with hostile peers on either end. Every session runs on short timeouts,
/// so a regression fails within seconds instead of hanging.
final class NearbyJoinTests: VaultTestCase {
    let home = pqIdentity(), laptop = pqIdentity()
    let homeTrust = MemoryEpochTrustStore(), laptopTrust = MemoryEpochTrustStore()
    /// For sessions expected to time out.
    static let quick = NearbyJoin.Timeouts(handshake: .milliseconds(300), session: .milliseconds(800))
    /// For sessions expected to finish (room for a slow runner, still bounded).
    static let bounded = NearbyJoin.Timeouts(handshake: .seconds(5), session: .seconds(20))

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

    /// Reads frames from `connection` (sent by `sender`) until one arrives.
    static func nextFrame(_ connection: NearbyJoinPipe.Connection, _ reader: inout NearbyFrameReader) async throws -> NearbyJoinMessage {
        while true {
            if let m = try reader.next() { return m }
            let bytes = try await connection.receive(maximum: 1 << 20)
            guard !bytes.isEmpty else { throw NearbyJoinError.closed }
            try reader.push(bytes)
        }
    }

    // MARK: - A whole session

    /// The request goes over the link after home's proof, home approves it (holding it in memory only: nothing is
    /// written to its `joins/`), the reply for this session's nonce comes back and the copy takes it: the laptop then
    /// confirms with the reply words exactly as after a sync.
    func testTheApproverSealsTheReplyForThisSession() async throws {
        let p = try pair()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let homeURL = p.home.url, homeID = home, trust = homeTrust, vaultId = p.home.vaultId
        let session = Box<(JoinRequest, Data)>()
        let words = Box<[String]>()
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, vaultId: vaultId, timeouts: Self.bounded, received: { request, _, nonce in
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
                                                 timeouts: Self.bounded) { waited.set(true) }
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .replied)
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
        // Home wrote nothing of the link's into its vault.
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeURL.appendingPathComponent("joins").path))
        // Nothing of the vault's list crossed the link in the clear.
        XCTAssertNil(homeEnd.sent.range(of: Data("Home".utf8)), "home's sends name no device")
        XCTAssertNil(homeEnd.sent.range(of: Data(p.home.vaultId.uuidString.lowercased().utf8)))
    }

    /// A device home lists already (approved through the target first) gets its reply at once.
    func testAListedDeviceIsAnsweredAtOnce() async throws {
        var p = try pair()
        let words = try p.home.approveDevice(p.request)
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let v = p.home
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, vaultId: v.vaultId, timeouts: Self.bounded, received: { request, _, nonce in
                guard let sealed = try? v.nearbyReply(for: request, nonce: nonce)?.seal(to: request.key) else { return .wait }
                return .reply(sealed)
            }, outcome: { .refuse(.closed) })
        }
        let nonce = NearbyJoin.randomBytes(32)
        let outcome = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: nonce, identity: laptop, timeouts: Self.bounded)
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
                                                       identities: [laptop], unconfirmed: true)) {
            XCTAssertEqual($0 as? NearbyJoinError, .recordMismatch)
        }

        try Vault.takeNearbyReply(reply, at: p.copy, nonce: nonce, commitment: p.request.commitment, identities: [laptop],
                                  unconfirmed: true)
        var mine = try TestVaults.open(at: p.copy, identity: laptop, trust: laptopTrust)
        try mine.confirmJoin(words: words)
        XCTAssertNil(mine.listStatus.problem)
        XCTAssertEqual(mine.manifest.epoch, 2)
    }

    // MARK: - The handshake (design N13)

    /// An advertiser that does not know the vault's id (another vault's Add Device, a harvester) gets the hello and
    /// nothing else: no request, no device name, no keys, no vault id.
    func testAnAdvertiserWithoutTheVaultIdGetsNoRequest() async throws {
        let p = try pair()
        for other in [UUID(), nil] as [UUID?] {
            let (joinerEnd, rogue) = NearbyJoinPipe.make()
            let answering = Task {
                var reader = NearbyFrameReader(reading: .joiner)
                guard case .hello(let nonce) = try await Self.nextFrame(rogue, &reader) else { return }
                // Another vault's proof, or 32 random bytes.
                let homeNonce = NearbyJoin.randomBytes(32)
                let tag = other.map { NearbyJoin.proof(vaultId: $0, nonce: nonce, homeNonce: homeNonce) } ?? NearbyJoin.randomBytes(32)
                try await rogue.send(NearbyJoin.magic + NearbyJoinMessage.proof(homeNonce: homeNonce, tag: tag).frame())
            }
            do {
                _ = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                               timeouts: Self.bounded)
                XCTFail("the request went to a device without the vault's id")
            } catch let e as NearbyJoinError {
                XCTAssertEqual(e, .notThisVault)
            }
            try await answering.value
            let sent = joinerEnd.sent
            XCTAssertEqual(sent.count, NearbyJoin.magic.count + 4 + 1 + 32, "the magic and the hello, nothing more")
            XCTAssertNil(sent.range(of: Data("Laptop".utf8)))
            XCTAssertNil(sent.range(of: Data(p.request.vaultId.uuidString.lowercased().utf8)))
        }
    }

    func testTheProofIsKeyedByTheVaultIdAndBothNonces() {
        let id = UUID(), nonce = NearbyJoin.randomBytes(32), homeNonce = NearbyJoin.randomBytes(32)
        let tag = NearbyJoin.proof(vaultId: id, nonce: nonce, homeNonce: homeNonce)
        XCTAssertEqual(tag.count, 32)
        XCTAssertTrue(NearbyJoin.checkProof(tag, vaultId: id, nonce: nonce, homeNonce: homeNonce))
        XCTAssertFalse(NearbyJoin.checkProof(tag, vaultId: UUID(), nonce: nonce, homeNonce: homeNonce))
        XCTAssertFalse(NearbyJoin.checkProof(tag, vaultId: id, nonce: NearbyJoin.randomBytes(32), homeNonce: homeNonce))
        XCTAssertFalse(NearbyJoin.checkProof(tag, vaultId: id, nonce: nonce, homeNonce: NearbyJoin.randomBytes(32)))
        XCTAssertFalse(NearbyJoin.checkProof(tag, vaultId: id, nonce: nonce, homeNonce: Data(count: 31)))
        // HMAC-SHA256 with the id's 16 bytes as the key, over the label and the two nonces.
        var u = id.uuid
        let key = SymmetricKey(data: withUnsafeBytes(of: &u) { Data($0) })
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data("sempere-nearby/1 home".utf8) + nonce + homeNonce, using: key))
        XCTAssertEqual(tag, expected)
    }

    /// Home's proof carries a fresh nonce of its own: two sessions answering the same joiner nonce never send the same
    /// proof, so a recorded one is neither replayed nor linked to another session.
    func testHomesProofNeverRepeatsForARepeatedNonce() async throws {
        let p = try pair()
        let nonce = NearbyJoin.randomBytes(32)
        var proofs: [Data] = []
        for _ in 0..<2 {
            let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
            let approver = Task {
                try? await NearbyApprover.run(on: homeEnd, vaultId: p.request.vaultId, timeouts: Self.quick,
                                              received: { _, _, _ in .refuse(.busy) }, outcome: { .refuse(.closed) })
            }
            try await joinerEnd.send(NearbyJoin.magic + NearbyJoinMessage.hello(nonce: nonce).frame())
            var reader = NearbyFrameReader(at: .proof)
            guard case .proof(let homeNonce, let tag) = try await Self.nextFrame(joinerEnd, &reader) else { return XCTFail("no proof") }
            XCTAssertTrue(NearbyJoin.checkProof(tag, vaultId: p.request.vaultId, nonce: nonce, homeNonce: homeNonce))
            proofs.append(homeNonce + tag)
            joinerEnd.cancel()
            _ = await approver.value
        }
        XCTAssertNotEqual(proofs[0], proofs[1])
    }

    // MARK: - Hostile peers

    /// A replayed reply (an earlier session's nonce) and one for another request are refused by the joiner.
    func testAReplayedReplyIsRefused() async throws {
        var p = try pair()
        try p.home.approveDevice(p.request)
        let earlier = NearbyJoin.randomBytes(32)
        let sealed = try XCTUnwrap(try p.home.nearbyReply(for: p.request, nonce: earlier)).seal(to: p.request.key)
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let vaultId = p.home.vaultId
        let replayer = Task {
            var reader = NearbyFrameReader(reading: .joiner)
            guard case .hello(let nonce) = try await Self.nextFrame(homeEnd, &reader) else { return }
            let homeNonce = NearbyJoin.randomBytes(32)
            try await homeEnd.send(NearbyJoin.magic + NearbyJoinMessage.proof(
                homeNonce: homeNonce, tag: NearbyJoin.proof(vaultId: vaultId, nonce: nonce, homeNonce: homeNonce)).frame())
            _ = try await Self.nextFrame(homeEnd, &reader)
            try await homeEnd.send(NearbyJoinMessage.reply(sealed).frame())
        }
        do {
            _ = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                           timeouts: Self.bounded)
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
    /// device in the middle with a vault of its own, or home's list before the approval) is not taken.
    func testRepliesOfAnotherVaultOrKeyAreRefused() throws {
        var p = try pair()
        let unlisted = try manifest(p.copy)   // home's vault.json before the approval: it does not list the laptop
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
        // A list that does not name the laptop, made to differ from the copy's by a byte (a version home never signed
        // is no approval either way).
        var notListing = reply
        notListing.manifest = unlisted + Data("\n".utf8)
        XCTAssertThrowsError(try Vault.takeNearbyReply(notListing, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                       identities: [laptop], unconfirmed: true)) {
            XCTAssertEqual($0 as? NearbyJoinError, .notAnApproval)
        }
    }

    /// Home refuses a request of another vault, sent after a good proof (a device that knows the id).
    func testARequestOfAnotherVaultIsRefused() async throws {
        let p = try pair()
        let stranger = UUID()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, vaultId: p.request.vaultId, timeouts: Self.bounded, received: { request, _, _ in
                request.vaultId == stranger ? .wait : .refuse(.otherVault)
            }, outcome: { .refuse(.closed) })
        }
        let outcome = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32),
                                                 identity: laptop, timeouts: Self.bounded)
        XCTAssertEqual(outcome, .refused(.otherVault))
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .refused(.otherVault))
    }

    /// The approver reads no frame larger than a hello or a request: a peer claiming a huge one is refused before its
    /// body, garbage (no magic) at once, and a request before the hello as out of order.
    func testOversizedFramesAndGarbageAreRefused() async throws {
        let p = try pair()
        for (input, expected) in [(NearbyJoin.magic + Data([0x7f, 0xff, 0xff, 0xff, 1]), NearbyJoinError.oversized(0x7fffffff)),
                                  (Data("GET / HTTP/1.1\r\n\r\n".utf8), .badMagic),
                                  (NearbyJoin.magic + NearbyJoinMessage.waiting.frame(), .unexpected("message type 2"))] {
            let (peer, homeEnd) = NearbyJoinPipe.make()
            try await peer.send(input)
            let called = Box<Bool>()
            do {
                _ = try await NearbyApprover.run(on: homeEnd, vaultId: UUID(), timeouts: Self.quick, received: { _, _, _ in
                    called.set(true)
                    return .wait
                }, outcome: { .refuse(.closed) })
                XCTFail("accepted \(input.prefix(32))")
            } catch let e as NearbyJoinError {
                XCTAssertEqual(e, expected)
            }
            XCTAssertNil(called.get(), "nothing reached the model")
        }
        // A request with no hello first.
        let (early, homeEarly) = NearbyJoinPipe.make()
        try await early.send(NearbyJoin.magic + NearbyJoinMessage.request(p.raw).frame())
        do {
            _ = try await NearbyApprover.run(on: homeEarly, vaultId: p.request.vaultId, timeouts: Self.quick,
                                             received: { _, _, _ in .wait }, outcome: { .refuse(.closed) })
            XCTFail("a request before the hello was read")
        } catch {}
        // A request frame whose file is not a join request, after the hello: refused with `malformed`.
        let (peer, homeEnd) = NearbyJoinPipe.make()
        try await peer.send(NearbyJoin.magic + NearbyJoinMessage.hello(nonce: Data(count: 32)).frame()
            + NearbyJoinMessage.request(Data("{}".utf8)).frame())
        do {
            _ = try await NearbyApprover.run(on: homeEnd, vaultId: UUID(), timeouts: Self.quick, received: { _, _, _ in .wait },
                                             outcome: { .refuse(.closed) })
            XCTFail("accepted a request that does not parse")
        } catch {}
        var reader = NearbyFrameReader(reading: .approver)
        try reader.push(peer.inbox.take(1 << 20) ?? Data())
        guard case .proof? = try reader.next() else { return XCTFail("no proof first") }
        XCTAssertEqual(try reader.next(), .refused(.malformed), "told why")

        // The joining device reads no frame larger than a reply.
        var joiner = NearbyFrameReader(reading: .approver)
        try joiner.push(NearbyJoin.magic + Data([0x7f, 0, 0, 0]))
        XCTAssertThrowsError(try joiner.next()) { XCTAssertEqual($0 as? NearbyJoinError, .oversized(0x7f00_0000)) }
        var full = NearbyFrameReader(reading: .joiner)
        XCTAssertThrowsError(try full.push(Data(count: full.capacity + 1)))
        // A header is judged before its body: a reply's length within bounds, a type the approver may send.
        var header = NearbyFrameReader(reading: .approver)
        try header.push(NearbyJoin.magic + Data([0, 0, 0, 9, 3]))
        XCTAssertTrue(try header.headerReady())
        XCTAssertNil(try header.next())
        var badType = NearbyFrameReader(reading: .approver)
        try badType.push(NearbyJoin.magic + Data([0, 0, 0, 9, 1]))
        XCTAssertThrowsError(try badType.headerReady())
    }

    /// A silent peer, a peer that trickles one byte every 100 ms, and an approver that never answers after `waiting`,
    /// all run out of time.
    func testSilentAndTricklingPeersTimeOut() async throws {
        let (silent, homeEnd) = NearbyJoinPipe.make()
        do {
            _ = try await NearbyApprover.run(on: homeEnd, vaultId: UUID(), timeouts: Self.quick, received: { _, _, _ in .wait },
                                             outcome: { .refuse(.closed) })
            XCTFail("a silent peer held the session")
        } catch let e as NearbyJoinError {
            XCTAssertEqual(e, .timedOut)
        }
        _ = silent

        let (trickler, homeTrickled) = NearbyJoinPipe.make()
        let hello = NearbyJoin.magic + NearbyJoinMessage.hello(nonce: Data(count: 32)).frame()
        let trickling = Task {
            for b in hello {
                try? await Task.sleep(for: .milliseconds(100))
                guard (try? await trickler.send(Data([b]))) != nil else { return }
            }
        }
        let start = ContinuousClock.now
        do {
            _ = try await NearbyApprover.run(on: homeTrickled, vaultId: UUID(), timeouts: Self.quick,
                                             received: { _, _, _ in .wait }, outcome: { .refuse(.closed) })
            XCTFail("a trickle held the session")
        } catch let e as NearbyJoinError {
            XCTAssertEqual(e, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "within the handshake, not the session")
        trickling.cancel()

        let p = try pair()
        let (joinerEnd, stallingHome) = NearbyJoinPipe.make()
        let vaultId = p.home.vaultId
        let staller = Task {
            var reader = NearbyFrameReader(reading: .joiner)
            guard case .hello(let nonce) = try await Self.nextFrame(stallingHome, &reader) else { return }
            let homeNonce = NearbyJoin.randomBytes(32)
            try await stallingHome.send(NearbyJoin.magic + NearbyJoinMessage.proof(
                homeNonce: homeNonce, tag: NearbyJoin.proof(vaultId: vaultId, nonce: nonce, homeNonce: homeNonce)).frame())
            _ = try await Self.nextFrame(stallingHome, &reader)
            try await stallingHome.send(NearbyJoinMessage.waiting.frame())
        }
        let started = ContinuousClock.now
        do {
            _ = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                           timeouts: Self.quick)
            XCTFail("a stalling approver held the joiner")
        } catch let e as NearbyJoinError {
            XCTAssertTrue(e == .timedOut || e == .closed, "\(e)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        try await staller.value
    }

    /// A joining device that never reads (a zero window): home's send of a 4 MiB reply is cut off within the session's
    /// time, and the session ends.
    func testAPeerThatNeverReadsEndsHomesSession() async throws {
        let p = try pair()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make(capacity: 64 * 1024)
        let big = Data(count: 4 << 20)
        let start = ContinuousClock.now
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, vaultId: p.request.vaultId, timeouts: Self.quick,
                                         received: { _, _, _ in .reply(big) }, outcome: { .refuse(.closed) })
        }
        try await joinerEnd.send(NearbyJoin.magic + NearbyJoinMessage.hello(nonce: Data(count: 32)).frame())
        var reader = NearbyFrameReader(reading: .approver)
        guard case .proof = try await Self.nextFrame(joinerEnd, &reader) else { return XCTFail("no proof") }
        try await joinerEnd.send(NearbyJoinMessage.request(p.raw).frame())
        // ... and reads nothing more.
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .timedOut)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    /// The approver's wait ends when the joining device goes away (its outcome is canceled), and when the session's
    /// time runs out (the joining device is told).
    func testTheApproverStopsWaitingForAPeerThatLeft() async throws {
        let p = try pair()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let canceled = Box<Bool>()
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, vaultId: p.request.vaultId, timeouts: Self.bounded,
                                         received: { _, _, _ in .wait }, outcome: {
                // Waits for an approval that never comes, until canceled.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                canceled.set(true)
                return .refuse(.closed)
            })
        }
        try await joinerEnd.send(NearbyJoin.magic + NearbyJoinMessage.hello(nonce: Data(count: 32)).frame())
        var reader = NearbyFrameReader(reading: .approver)
        guard case .proof = try await Self.nextFrame(joinerEnd, &reader) else { return XCTFail("no proof") }
        try await joinerEnd.send(NearbyJoinMessage.request(p.raw).frame())
        let answer = try await Self.nextFrame(joinerEnd, &reader)
        XCTAssertEqual(answer, .waiting)
        joinerEnd.cancel()
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .peerLeft)
        XCTAssertEqual(canceled.get(), true)

        let (joiner2, home2) = NearbyJoinPipe.make()
        let timed = Task {
            try await NearbyApprover.run(on: home2, vaultId: p.request.vaultId, timeouts: Self.quick,
                                         received: { _, _, _ in .wait }, outcome: {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                return .refuse(.closed)
            })
        }
        let outcome = try await NearbyJoiner.run(on: joiner2, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                                 timeouts: Self.bounded)
        XCTAssertEqual(outcome, .refused(.closed))
        let timedEnding = try await timed.value
        XCTAssertEqual(timedEnding, .timedOut)
    }

    /// A device whose request arrives while another session is going is told `busy`: after its hello, home's proof and
    /// its parsed request (a connection holds no session before that), and it keeps its outcome as a refusal.
    func testARequestWhileAnotherSessionGoesIsToldBusy() async throws {
        let p = try pair()
        let (joinerEnd, homeEnd) = NearbyJoinPipe.make()
        let asked = Box<Bool>()
        let homeSide = Task {
            try await NearbyApprover.run(on: homeEnd, vaultId: p.request.vaultId, timeouts: Self.bounded, received: { _, _, _ in
                asked.set(true)
                return .refuse(.busy)
            }, outcome: { .refuse(.closed) })
        }
        let outcome = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32),
                                                 identity: laptop, timeouts: Self.bounded)
        XCTAssertEqual(outcome, .refused(.busy))
        XCTAssertEqual(asked.get(), true, "busy is decided once the request is parsed")
        let ended = try await homeSide.value
        XCTAssertEqual(ended, .refused(.busy))
    }

    // MARK: - Pieces

    func testFramesRoundTripInPieces() throws {
        let messages: [NearbyJoinMessage] = [.proof(homeNonce: Data(repeating: 5, count: 32), tag: Data(repeating: 4, count: 32)),
                                             .waiting, .reply(Data([1, 2, 3])),
                                             .refused(.declined)]
        let stream = NearbyJoin.magic + messages.map { $0.frame() }.reduce(Data(), +)
        var reader = NearbyFrameReader(reading: .approver)
        var out: [NearbyJoinMessage] = []
        for b in stream {
            try reader.push(Data([b]))
            while let m = try reader.next() { out.append(m) }
        }
        XCTAssertEqual(out, messages)
        let hello = NearbyJoinMessage.hello(nonce: Data(repeating: 7, count: 32))
        let request = NearbyJoinMessage.request(Data("{}".utf8))
        var home = NearbyFrameReader(reading: .joiner)
        try home.push(NearbyJoin.magic + hello.frame() + request.frame())
        XCTAssertEqual(try home.next(), hello)
        XCTAssertEqual(try home.next(), request)
        var partial = NearbyFrameReader(reading: .joiner)
        try partial.push(Data("semp".utf8))
        XCTAssertNil(try partial.next())
        try partial.push(Data("ERE".utf8))
        XCTAssertThrowsError(try partial.next()) { XCTAssertEqual($0 as? NearbyJoinError, .badMagic) }
        // A hello or a proof of the wrong size.
        var short = NearbyFrameReader(reading: .joiner)
        try short.push(NearbyJoin.magic + NearbyJoinMessage.hello(nonce: Data(count: 31)).frame())
        XCTAssertThrowsError(try short.next())
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

    // MARK: - Per-stage limits, one handshake limit, the copy's record, declining by commitment

    /// Before the proof the joining device reads only a proof or a refusal, each a few bytes: an advertiser's first
    /// frame that claims more, or of another type, ends the read from its header, before any of its body is held.
    func testTheFirstAnswerIsJudgedFromItsHeader() throws {
        func header(_ length: Int, _ type: UInt8) -> Data {
            NearbyJoin.magic + Data([UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff), type])
        }
        var large = NearbyFrameReader(at: .proof)
        try large.push(header(NearbyJoin.maxReplyBody, 6))
        XCTAssertThrowsError(try large.headerReady()) { XCTAssertEqual($0 as? NearbyJoinError, .oversized(NearbyJoin.maxReplyBody)) }
        var longProof = NearbyFrameReader(at: .proof)
        try longProof.push(header(1 + NearbyJoin.proofBytes + 1, 6))
        XCTAssertThrowsError(try longProof.next()) { XCTAssertEqual($0 as? NearbyJoinError, .oversized(1 + NearbyJoin.proofBytes + 1)) }
        for type: UInt8 in [2, 3] {
            var early = NearbyFrameReader(at: .proof)
            try early.push(header(9, type))
            XCTAssertThrowsError(try early.headerReady()) { XCTAssertEqual($0 as? NearbyJoinError, .unexpected("message type \(type)")) }
        }
        // The reader never holds more than one frame of its stage.
        var held = NearbyFrameReader(at: .proof)
        XCTAssertThrowsError(try held.push(Data(count: NearbyJoin.magic.count + 4 + 1 + NearbyJoin.proofBytes + 1)))
        // After the request: waiting, a reply of megabytes, or a refusal; after waiting, no second waiting.
        var answer = NearbyFrameReader(at: .answer)
        try answer.push(header(NearbyJoin.maxReplyBody, 3))
        XCTAssertTrue(try answer.headerReady())
        var final = NearbyFrameReader(at: .final)
        try final.push(header(1, 2))
        XCTAssertThrowsError(try final.headerReady()) { XCTAssertEqual($0 as? NearbyJoinError, .unexpected("message type 2")) }
        // Home: the hello only, then the request only.
        var hello = NearbyFrameReader(at: .hello)
        try hello.push(header(NearbyJoin.maxRequestBody, 1))
        XCTAssertThrowsError(try hello.headerReady()) { XCTAssertEqual($0 as? NearbyJoinError, .oversized(NearbyJoin.maxRequestBody)) }
        var request = NearbyFrameReader(at: .request)
        try request.push(header(33, 5))
        XCTAssertThrowsError(try request.headerReady()) { XCTAssertEqual($0 as? NearbyJoinError, .unexpected("message type 5")) }
    }

    /// An advertiser whose first frame claims a large "proof" is refused at once, its body never read.
    func testTheJoinerRefusesALargeFirstFrameAtOnce() async throws {
        let p = try pair()
        let (joinerEnd, rogue) = NearbyJoinPipe.make()
        let len = NearbyJoin.maxReplyBody
        try await rogue.send(NearbyJoin.magic + Data([UInt8(len >> 24), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff), 6]))
        let started = ContinuousClock.now
        do {
            _ = try await NearbyJoiner.run(on: joinerEnd, request: p.raw, nonce: NearbyJoin.randomBytes(32), identity: laptop,
                                           timeouts: Self.bounded)
            XCTFail("a large first frame was read")
        } catch let e as NearbyJoinError {
            XCTAssertEqual(e, .oversized(len))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "refused from the header, not after a wait")
    }

    /// Home gives the hello and the request one limit together: a peer that sends its hello at once and its request
    /// after the limit is dropped, though each frame alone came within it.
    func testHomesHelloAndRequestShareOneLimit() async throws {
        let p = try pair()
        let timeouts = NearbyJoin.Timeouts(handshake: .seconds(2), session: .seconds(4), request: .milliseconds(400))
        let (peer, homeEnd) = NearbyJoinPipe.make()
        let called = Box<Bool>()
        let approver = Task {
            try await NearbyApprover.run(on: homeEnd, vaultId: p.request.vaultId, timeouts: timeouts, received: { _, _, _ in
                called.set(true)
                return .wait
            }, outcome: { .refuse(.closed) })
        }
        try await peer.send(NearbyJoin.magic + NearbyJoinMessage.hello(nonce: NearbyJoin.randomBytes(32)).frame())
        try await Task.sleep(for: .milliseconds(250))
        try await peer.send(Data(NearbyJoinMessage.request(p.raw).frame().prefix(3)))
        try await Task.sleep(for: .milliseconds(300))
        try? await peer.send(Data(NearbyJoinMessage.request(p.raw).frame().dropFirst(3)))
        do {
            _ = try await approver.value
            XCTFail("a request after the limit was read")
        } catch let e as NearbyJoinError {
            XCTAssertEqual(e, .timedOut)
        }
        XCTAssertNil(called.get(), "nothing reached the model")
    }

    /// A reply whose `vault.json` names a record the copy holds with other bytes is refused before anything is taken.
    func testAReplyIsRefusedWhenTheCopysRecordIsNotTheOneItNames() throws {
        var p = try pair()
        try p.home.approveDevice(p.request)
        let nonce = NearbyJoin.randomBytes(32)
        let reply = try XCTUnwrap(try p.home.nearbyReply(for: p.request, nonce: nonce))
        let record = p.copy.appendingPathComponent("epochs").appendingPathComponent(reply.recordName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the copy holds the record")
        let before = try manifest(p.copy)
        try Data("not the record".utf8).write(to: record)
        XCTAssertThrowsError(try Vault.takeNearbyReply(reply, at: p.copy, nonce: nonce, commitment: p.request.commitment,
                                                       identities: [laptop], unconfirmed: true)) {
            XCTAssertEqual($0 as? NearbyJoinError, .recordMismatch)
        }
        XCTAssertEqual(try manifest(p.copy), before, "nothing taken")
    }

    /// Declining a request deletes the file under its name only when that file is the same request (its commitment):
    /// a request of the same 8-hex name but another commitment stays.
    func testDecliningMatchesByCommitment() throws {
        let p = try pair()
        let joins = p.home.url.appendingPathComponent("joins")
        try FileManager.default.createDirectory(at: joins, withIntermediateDirectories: true)
        let file = joins.appendingPathComponent(p.request.fileName)
        try p.raw.write(to: file)
        // The same keys under another kind: the same file name, another commitment.
        let other = try p.laptop.joinRequest(vaultId: p.home.vaultId, name: "Laptop", kind: "ipad")
        XCTAssertEqual(other.fileName, p.request.fileName)
        XCTAssertNotEqual(other.commitment, p.request.commitment)
        XCTAssertFalse(try p.home.declineJoinRequest(other))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "another request's decline leaves it")
        XCTAssertTrue(try p.home.declineJoinRequest(p.request))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

/// A value set from a `@Sendable` closure and read by the test.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
