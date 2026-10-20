import Age
import Crypto
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// A device of a test chain: a synthetic key string and a software signing pair.
struct ChainTestDevice {
    let name: String
    let key: String
    let signing: DeviceSigningKeys
    let sign: DeviceSigningPublicKeys

    init(_ name: String) throws {
        self.name = name
        key = "age1pq1test-\(name)"
        signing = DeviceSigningKeys.generate()
        sign = try signing.publicKeys()
    }

    var fingerprint: Data { KeyFingerprint.device(key: key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex) }
    var id: String { String(Hex.encode(fingerprint).prefix(8)) }
    var author: ChainAuthor { ChainAuthor(key: key, sign: sign) }
}

/// A recovery key of a test chain: a key string and its derived signing pair (design §5.6).
struct ChainTestRecovery {
    let key: String
    let signing: DeviceSigningKeys
    let sign: DeviceSigningPublicKeys

    /// A synthetic key string with the signing pair of a random seed.
    init(_ name: String) throws {
        key = "age1pq1test-\(name)"
        signing = try DeviceSigningKeys.recovery(seed: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        sign = try signing.publicKeys()
    }

    /// A real recovery identity.
    init(identity: MLKEM768X25519Identity) throws {
        key = identity.recipient.string
        signing = try DeviceSigningKeys.recovery(identity: identity)
        sign = try signing.publicKeys()
    }

    var fingerprint: Data { KeyFingerprint.recovery(key: key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex) }
    var author: ChainAuthor { ChainAuthor(key: key, sign: sign) }
}

/// Builds signed chains (design §5.2.1) for tests.
struct ChainTestBuilder {
    let vaultId: UUID
    var keys: [VaultEpochKey]
    var entries: [ChainEntry]
    let root: Data

    /// Epoch 1, created by `author` (its home), listing `founders` (fingerprints); the recovery key is the last.
    init(vaultId: UUID = UUID(), author: ChainTestDevice, founders: [Data]) throws {
        self.vaultId = vaultId
        let k1 = VaultEpochKey.random()
        keys = [k1]
        let link = try LinkPublicKeys(epochKey: k1)
        root = VaultRoot.fingerprint(vaultId: vaultId, epochOne: link)
        var e = ChainEntry(epoch: 1, epochId: k1.epochId, parent: nil, linkPublicKeys: link, link: nil, reason: "create",
                           list: founders, parentList: [], author: author.author,
                           epochSig: try XCTUnwrap(AuthorSignature(p256: Data(count: 64), mldsa65: Data(count: 3309))),
                           recovery: try XCTUnwrap(founders.last), home: author.fingerprint)
        e.epochSig = try author.signing.sign(e.epochMessage(vaultId: vaultId, root: root))
        entries = [e]
    }

    /// An addition during the last epoch, approved (signed) by `approver`.
    @discardableResult
    mutating func add(_ d: ChainTestDevice, by approver: ChainTestDevice, claimedBy: String? = nil,
                      epoch: Int? = nil) throws -> ChainAddition {
        let claim = EntryClaim(key: d.key, sign: d.sign, kind: "ipad", added: "2026-10-20T16:20:00Z",
                               addedEpoch: epoch ?? entries.count, addedBy: claimedBy ?? approver.id)
        let a = ChainAddition(claim: claim, addSig: try approver.signing.sign(AuthorMessage.entry(vaultId: vaultId, claim)))
        entries[entries.count - 1].additions.append(a)
        return a
    }

    /// The next epoch by `author`, with first list `list` and the parent list as the author saw it. `home`
    /// defaults to the parent's (a handoff names another); a takeover is also signed by `takeover`.
    mutating func next(author: ChainTestDevice, reason: String = "remove", list: [Data], parentList: [Data],
                       signer: ChainTestDevice? = nil, linkFrom: VaultEpochKey? = nil, recovery: Data? = nil,
                       home: Data? = nil, takeover: ChainTestRecovery? = nil) throws {
        let k = VaultEpochKey.random()
        let prev = entries[entries.count - 1]
        let epoch = entries.count + 1
        var e = ChainEntry(epoch: epoch, epochId: k.epochId, parent: prev.epochId, linkPublicKeys: try LinkPublicKeys(epochKey: k),
                           link: try EpochLinks.link(from: linkFrom ?? keys[keys.count - 1], to: k, epoch: epoch, vaultId: vaultId),
                           reason: reason, list: list, parentList: parentList, author: author.author,
                           epochSig: try XCTUnwrap(AuthorSignature(p256: Data(count: 64), mldsa65: Data(count: 3309))),
                           recovery: recovery ?? prev.recovery,
                           home: home ?? (reason == "takeover" ? author.fingerprint : prev.home))
        e.epochSig = try (signer ?? author).signing.sign(e.epochMessage(vaultId: vaultId, root: root))
        if let takeover {
            e.recoveryAuthor = takeover.author
            e.recoverySig = try takeover.signing.sign(e.epochMessage(vaultId: vaultId, root: root))
        }
        keys.append(k)
        entries.append(e)
    }

    func verify(root: Data? = nil) throws -> EpochChain.Verified {
        try EpochChain.verify(entries, vaultId: vaultId, root: root ?? self.root)
    }
}

/// The author signatures, the chain and its checks, join codes, epoch records, the journal, the
/// passphrase copy and the kit (docs/design/key-hierarchy.md §4.1, §4.3, §5.2.1, §6.2, §7.4, §8; KH1).
final class EpochChainTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    typealias V = EpochKeysTests.Vectors
    static func unhex(_ s: String) -> Data { SecretLinkTests.unhex(s) }

    // MARK: - Shared signature and join vectors

    func testAuthorSignaturesMatchTheVectors() throws {
        let v = try EpochKeysTests.loadVectors()
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        let signer = try XCTUnwrap(v.signer), sigs = try XCTUnwrap(v.signatures)
        let keys = try DeviceSigningKeys(p256Scalar: Self.unhex(signer.p256Scalar), mldsa65Seed: Self.unhex(signer.mldsa65Seed))
        let pub = try keys.publicKeys()
        XCTAssertEqual(pub.p256Hex, signer.p256)
        XCTAssertEqual(pub.mldsa65Hex, signer.mldsa65)
        XCTAssertEqual(Hex.encode(KeyFingerprint.device(key: signer.key, signP256: signer.p256, signMLDSA65: signer.mldsa65)),
                       signer.fingerprint)

        let c = sigs.entry.claim
        let claim = EntryClaim(key: c.key, sign: try XCTUnwrap(DeviceSigningPublicKeys(p256Hex: c.signP256, mldsa65Hex: c.signMLDSA65)),
                               kind: c.kind, added: c.added, addedEpoch: c.addedEpoch, addedBy: c.addedBy)
        let entryMessage = AuthorMessage.entry(vaultId: vaultId, claim)
        XCTAssertEqual(Hex.encode(entryMessage), sigs.entry.message)

        let f = sigs.epoch.fields
        let epochMessage = AuthorMessage.epoch(vaultId: vaultId, root: Self.unhex(f.root), epoch: f.epoch,
                                               epochId: Self.unhex(f.epochId), parent: Self.unhex(f.parent),
                                               reason: f.reason, recovery: Self.unhex(f.recovery), home: Self.unhex(f.home),
                                               list: f.list.map(Self.unhex), parentList: f.parentList.map(Self.unhex))
        XCTAssertEqual(Hex.encode(epochMessage), sigs.epoch.message)
        // Order of the lists does not matter: they are signed sorted.
        XCTAssertEqual(AuthorMessage.epoch(vaultId: vaultId, root: Self.unhex(f.root), epoch: f.epoch,
                                           epochId: Self.unhex(f.epochId), parent: Self.unhex(f.parent), reason: f.reason,
                                           recovery: Self.unhex(f.recovery), home: Self.unhex(f.home),
                                           list: f.list.reversed().map(Self.unhex),
                                           parentList: f.parentList.reversed().map(Self.unhex)), epochMessage)

        let m = sigs.manifest.fields
        let listMessage = Self.unhex(v.listTag.message)
        let manifestMessage = AuthorMessage.manifest(vaultId: vaultId, root: Self.unhex(m.root), epoch: m.epoch,
                                                     epochId: Self.unhex(m.epochId),
                                                     epochRecordHash: Self.unhex(m.epochRecordHash),
                                                     listMessage: listMessage, format: m.format, features: m.features)
        XCTAssertEqual(Hex.encode(manifestMessage), sigs.manifest.message)
        XCTAssertTrue(m.features.contains { $0.contains("/") && $0.unicodeScalars.contains { !$0.isASCII } })

        let all: [(String, Data, [V.AuthorSig])] = [("entry", entryMessage, sigs.entry.signatures),
                                                     ("epoch", epochMessage, sigs.epoch.signatures),
                                                     ("manifest", manifestMessage, sigs.manifest.signatures)]
        for (name, message, list) in all {
            XCTAssertEqual(Set(list.map(\.by)), ["noble", "swift-crypto"], name)
            for s in list {
                let sig = try XCTUnwrap(AuthorSignature(p256Hex: s.p256, mldsa65Hex: s.mldsa65), "\(name) \(s.by)")
                XCTAssertTrue(sig.verifies(message, keys: pub), "\(name) \(s.by)")
                XCTAssertFalse(sig.verifies(message + Data([0]), keys: pub), "\(name) \(s.by)")
                XCTAssertFalse(sig.verifies(message, keys: try DeviceSigningKeys.generate().publicKeys()), "\(name) \(s.by)")
                // Both must verify.
                let other = try DeviceSigningKeys.generate().sign(message)
                XCTAssertFalse(try XCTUnwrap(AuthorSignature(p256: sig.p256, mldsa65: other.mldsa65)).verifies(message, keys: pub))
                XCTAssertFalse(try XCTUnwrap(AuthorSignature(p256: other.p256, mldsa65: sig.mldsa65)).verifies(message, keys: pub))
            }
        }
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_EPOCH_VECTORS"] == "1" {
            let mine = try all.map { (_, message, _) in try keys.sign(message) }
            try EpochKeysTests.updateVectors {
                func put(_ list: inout [V.AuthorSig], _ s: AuthorSignature) {
                    list.removeAll { $0.by == "swift-crypto" }
                    list.append(.init(by: "swift-crypto", p256: s.p256Hex, mldsa65: s.mldsa65Hex))
                }
                put(&$0.signatures!.entry.signatures, mine[0])
                put(&$0.signatures!.epoch.signatures, mine[1])
                put(&$0.signatures!.manifest.signatures, mine[2])
            }
        }
    }

    /// Review L1: P-256 signatures are written low-S; a high-S form still verifies.
    func testSignaturesAreLowS() throws {
        let keys = DeviceSigningKeys.generate()
        let pub = try keys.publicKeys()
        let n = DeviceSigningKeys.p256Order
        var half = [UInt8](repeating: 0, count: 32), carry: UInt8 = 0
        for i in 0..<32 { half[i] = (n[i] >> 1) | carry; carry = (n[i] & 1) << 7 }
        for i in 0..<16 {
            let message = Data("message \(i)".utf8)
            let sig = try keys.sign(message)
            let s = [UInt8](sig.p256.suffix(32))
            XCTAssertFalse(half.lexicographicallyPrecedes(s), "s ≤ n/2")
            // n − s, the other valid signature.
            var high = [UInt8](repeating: 0, count: 32), borrow = 0
            for j in stride(from: 31, through: 0, by: -1) {
                var d = Int(n[j]) - Int(s[j]) - borrow
                borrow = d < 0 ? 1 : 0
                if d < 0 { d += 256 }
                high[j] = UInt8(d)
            }
            let highSig = try XCTUnwrap(AuthorSignature(p256: Data(sig.p256.prefix(32)) + Data(high), mldsa65: sig.mldsa65))
            XCTAssertTrue(highSig.verifies(message, keys: pub), "high-S accepted")
            XCTAssertEqual(DeviceSigningKeys.lowS(highSig.p256), sig.p256, "normalized back")
        }
    }

    func testJoinCodesMatchTheVectors() throws {
        let v = try EpochKeysTests.loadVectors()
        let j = try XCTUnwrap(v.join)
        let request = try JSONEncoder().encode(j.request)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        json["format"] = "sempere-join/1"
        let r = try JoinRequest.parse(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(Hex.encode(r.commitment), j.commitment)
        XCTAssertEqual(JoinCodes.words(r.commitment), j.words)
        XCTAssertTrue(JoinCodes.matches(j.words.map { " \($0.uppercased()) " }, r.commitment), "typed, any case")
        XCTAssertFalse(JoinCodes.matches(Array(j.words.dropLast()) + ["zoo"], r.commitment))
        XCTAssertFalse(JoinCodes.matches(Array(j.words.dropLast()) + ["notaword"], r.commitment))
        let qr = JoinCodes.commitmentQR(vaultId: r.vaultId, commitment: r.commitment)
        XCTAssertEqual(Hex.encode(qr), j.qr)
        XCTAssertEqual(qr.count, 48)
        let parsed = try XCTUnwrap(JoinCodes.parseCommitmentQR(qr))
        XCTAssertEqual(parsed.vaultId, r.vaultId)
        XCTAssertEqual(parsed.commitment, r.commitment)
        XCTAssertNil(JoinCodes.parseCommitmentQR(qr.dropLast()))
        let reply = JoinCodes.reply(vaultId: r.vaultId, commitment: r.commitment, root: Self.unhex(j.root),
                                    frontier: Self.unhex(j.frontier))
        XCTAssertNotEqual(JoinCodes.reply(vaultId: r.vaultId, commitment: r.commitment, root: Self.unhex(j.root),
                                          frontier: Data(repeating: 0, count: 32)), reply, "the frontier is covered")
        XCTAssertEqual(Hex.encode(reply), j.reply)
        XCTAssertEqual(JoinCodes.words(reply), j.replyWords)
        let replyQR = JoinCodes.replyQR(vaultId: r.vaultId, root: Self.unhex(j.root), frontier: Self.unhex(j.frontier))
        XCTAssertEqual(replyQR, j.replyQR)
        XCTAssertEqual(JoinCodes.parseReplyQR(replyQR)?.frontier, Self.unhex(j.frontier))
        XCTAssertNil(JoinCodes.parseReplyQR(KitRecovery.rootQR(vaultId: r.vaultId, root: Self.unhex(j.root))))
        // The commitment covers the key, both signing keys, the kind and the vault; not the name.
        var renamed = r; renamed.name = "Other"
        XCTAssertEqual(renamed.commitment, r.commitment)
        var kind = r; kind.kind = "ipad"
        XCTAssertNotEqual(kind.commitment, r.commitment)
        var other = r; other.vaultId = UUID()
        XCTAssertNotEqual(other.commitment, r.commitment)
        XCTAssertEqual(BIP39English.words.count, 2048)
        XCTAssertEqual(FileDigest.sha256(Data((BIP39English.words.joined(separator: "\n") + "\n").utf8)),
                       "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda", "the BIP-39 English list")
    }

    func testJoinRequestReaderIsStrict() throws {
        let d = try ChainTestDevice("N")
        let r = JoinRequest(vaultId: UUID(), key: d.key, sign: d.sign, name: "N's iPhone", kind: "iphone",
                            created: "2026-10-20T16:20:00Z")
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JoinRequest.parse(data), r)
        XCTAssertEqual(r.fileName, "\(d.id).join.json")
        XCTAssertThrowsError(try JoinRequest.parse(Data(repeating: 0x20, count: JoinRequest.maxBytes + 1)))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (k, bad) in [("format", "sempere-join/2"), ("key", "age1abc"), ("vaultId", "nope"), ("kind", "iPad"), ("kind", ""),
                         ("kind", "i pad"), ("kind", String(repeating: "a", count: 33))] as [(String, Any)] {
            var j = json; j[k] = bad
            XCTAssertThrowsError(try JoinRequest.parse(try JSONSerialization.data(withJSONObject: j)), k)
        }
        json["sign"] = ["p256": "04", "mldsa65": "00"]
        XCTAssertThrowsError(try JoinRequest.parse(try JSONSerialization.data(withJSONObject: json)))
    }

    // MARK: - Chains

    /// Design §4.1 and the scenario "an offline device verifies a removal whose first list carries a
    /// device added while it was away": N and K are added by the home A during epoch 1; epoch 2 (by A)
    /// removes K; the chain alone admits N and K from epoch 1's additions.
    func testChainWithCarriedAdditionVerifies() throws {
        let a = try ChainTestDevice("A"), n = try ChainTestDevice("N"), k = try ChainTestDevice("K")
        let r = try ChainTestRecovery("recovery").fingerprint
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        try b.add(n, by: a)
        try b.add(k, by: a)
        try b.next(author: a, list: [a.fingerprint, n.fingerprint, r],
                   parentList: [a.fingerprint, n.fingerprint, k.fingerprint, r])
        let v = try b.verify()
        XCTAssertEqual(v.lists[0].list, [a.fingerprint, r, n.fingerprint, k.fingerprint])
        XCTAssertEqual(v.lists[0].admitted.map(\.approver), [a.fingerprint, a.fingerprint])
        XCTAssertEqual(v.removals, [[], [k.fingerprint]])
        XCTAssertEqual(v.homes, [a.fingerprint, a.fingerprint])
        // Without the carried addition, the same removal introduces N: refused.
        var missing = b
        missing.entries[0].additions = []
        XCTAssertThrowsError(try missing.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 2)) }
        // N, listed but not home, cannot sign an epoch.
        var byN = b
        byN.entries.removeLast(); byN.keys.removeLast()
        try byN.next(author: n, list: [a.fingerprint, n.fingerprint, r], parentList: [a.fingerprint, n.fingerprint, k.fingerprint, r])
        XCTAssertThrowsError(try byN.verify()) { XCTAssertEqual($0 as? ChainError, .notHome(epoch: 2)) }
    }

    /// Design §5.6: handoff and takeover.
    func testHandoffAndTakeover() throws {
        let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B"), k = try ChainTestDevice("K")
        let recovery = try ChainTestRecovery("recovery"), other = try ChainTestRecovery("other")
        let r = recovery.fingerprint
        let good = try ChainTestBuilder(author: a, founders: [a.fingerprint, bDev.fingerprint, r])
        // A hands off to B; B then signs; A no longer can.
        var handoff = good
        try handoff.next(author: a, reason: "handoff", list: [a.fingerprint, bDev.fingerprint, r],
                         parentList: [a.fingerprint, bDev.fingerprint, r], home: bDev.fingerprint)
        XCTAssertEqual(try handoff.verify().homes, [a.fingerprint, bDev.fingerprint])
        var afterB = handoff
        try afterB.next(author: bDev, list: [bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertEqual(try afterB.verify().removals[2], [a.fingerprint])
        var oldHome = handoff
        try oldHome.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try oldHome.verify()) { XCTAssertEqual($0 as? ChainError, .notHome(epoch: 3)) }
        // A handoff to a device that is not listed, or to itself; a home change outside a handoff.
        var toUnlisted = good
        try toUnlisted.next(author: a, reason: "handoff", list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                            home: bDev.fingerprint)
        XCTAssertThrowsError(try toUnlisted.verify()) { XCTAssertEqual($0 as? ChainError, .badHome(epoch: 2)) }
        var toSelf = good
        try toSelf.next(author: a, reason: "handoff", list: [a.fingerprint, bDev.fingerprint, r],
                        parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try toSelf.verify()) { XCTAssertEqual($0 as? ChainError, .badHome(epoch: 2)) }
        var sneaky = good
        try sneaky.next(author: a, list: [a.fingerprint, bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                        home: bDev.fingerprint)
        XCTAssertThrowsError(try sneaky.verify()) { XCTAssertEqual($0 as? ChainError, .badHome(epoch: 2)) }
        // A takeover: by the recovery key and the new home, with the list the user picked.
        var takeover = good
        try takeover.next(author: bDev, reason: "takeover", list: [bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                          takeover: recovery)
        let v = try takeover.verify()
        XCTAssertEqual(v.homes, [a.fingerprint, bDev.fingerprint])
        XCTAssertEqual(v.removals[1], [a.fingerprint])
        // A kit join is a takeover: the new home K is a device the parent never listed.
        var kitJoin = good
        try kitJoin.next(author: k, reason: "takeover", list: [a.fingerprint, k.fingerprint, r],
                         parentList: [a.fingerprint, bDev.fingerprint, r], takeover: recovery)
        XCTAssertEqual(try kitJoin.verify().lists[1].list, [a.fingerprint, k.fingerprint, r])
        // Round 7, M2: it may re-admit a device of its ancestry that a (stolen) home removed.
        var readmit = good
        try readmit.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        try readmit.next(author: k, reason: "takeover", list: [k.fingerprint, bDev.fingerprint, r],
                         parentList: [a.fingerprint, r], takeover: recovery)
        XCTAssertEqual(try readmit.verify().lists[2].list, [k.fingerprint, bDev.fingerprint, r])
        // ... and never an earlier, retired recovery key as a device.
        var oldKit = good
        let r2 = try ChainTestRecovery("recovery-2")
        try oldKit.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, r2.fingerprint],
                        parentList: [a.fingerprint, bDev.fingerprint, r], recovery: r2.fingerprint)
        try oldKit.next(author: bDev, reason: "takeover", list: [bDev.fingerprint, r, r2.fingerprint],
                        parentList: [a.fingerprint, bDev.fingerprint, r2.fingerprint], takeover: r2)
        XCTAssertThrowsError(try oldKit.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 3)) }
        // Round 7, C1 (owner decision): a takeover is valid only under the kit current at the verifier's
        // pinned frontier. A kit replacement (here R-signed by the old kit too, which is optional and
        // verified when present) retires the old kit for every device that saw it.
        var replaced = good
        let kit2 = try ChainTestRecovery("new-kit")
        try replaced.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, kit2.fingerprint],
                          parentList: [a.fingerprint, bDev.fingerprint, r], recovery: kit2.fingerprint, takeover: recovery)
        XCTAssertNoThrow(try replaced.verify(), "the old kit's recoverySig on the replacement verifies")
        var badOldSig = good
        try badOldSig.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, kit2.fingerprint],
                           parentList: [a.fingerprint, bDev.fingerprint, r], recovery: kit2.fingerprint, takeover: other)
        XCTAssertThrowsError(try badOldSig.verify()) { XCTAssertEqual($0 as? ChainError, .badTakeover(epoch: 2)) }
        let pinnedAfter = replaced.entries.map { TakeoverRule.PinnedEpoch(epochId: $0.epochId, recovery: $0.recovery) }
        var oldKitTakeover = good
        try oldKitTakeover.next(author: k, reason: "takeover", list: [k.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                                takeover: recovery)
        XCTAssertThrowsError(try EpochChain.verify(oldKitTakeover.entries, vaultId: good.vaultId, root: good.root,
                                                   pinned: pinnedAfter)) {
            XCTAssertEqual($0 as? ChainError, .badTakeover(epoch: 2), "a device that saw the replacement refuses it")
        }
        XCTAssertNoThrow(try oldKitTakeover.verify(), "a device that saw nothing (residual)")
        var kit2Takeover = replaced
        try kit2Takeover.next(author: k, reason: "takeover", list: [k.fingerprint, bDev.fingerprint, kit2.fingerprint],
                                parentList: [a.fingerprint, bDev.fingerprint, kit2.fingerprint], takeover: kit2)
        XCTAssertNoThrow(try EpochChain.verify(kit2Takeover.entries, vaultId: good.vaultId, root: good.root, pinned: pinnedAfter))
        // Round 8, C1-b (probe testThiefKitBelowTheFrontierWinsTheRace): for a device pinned before the
        // replacement, the new kit's takeover waits until the replacement is pinned (not tampering).
        let pinnedBefore = good.entries.map { TakeoverRule.PinnedEpoch(epochId: $0.epochId, recovery: $0.recovery) }
        XCTAssertThrowsError(try EpochChain.verify(kit2Takeover.entries, vaultId: good.vaultId, root: good.root, pinned: pinnedBefore)) {
            XCTAssertEqual($0 as? ChainError, .kitNotPinned(epoch: 3))
        }
        XCTAssertNoThrow(try EpochChain.verify(replaced.entries, vaultId: good.vaultId, root: good.root, pinned: pinnedBefore),
                         "it follows and pins the replacement first")
        XCTAssertNoThrow(try kit2Takeover.verify(), "a joiner takes it at once")
        // ... but it introduces no device of no ancestor list.
        var intro = good
        try intro.next(author: k, reason: "takeover", list: [k.fingerprint, try ChainTestDevice("Z").fingerprint, r],
                       parentList: [a.fingerprint, bDev.fingerprint, r], takeover: recovery)
        XCTAssertThrowsError(try intro.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 2)) }
        // Without the recovery key's signature, by another recovery key, or with the new home not its author.
        var unsigned = good
        try unsigned.next(author: bDev, reason: "takeover", list: [bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try unsigned.verify()) { XCTAssertEqual($0 as? ChainError, .badTakeover(epoch: 2)) }
        var otherKey = good
        try otherKey.next(author: bDev, reason: "takeover", list: [bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                          takeover: other)
        XCTAssertThrowsError(try otherKey.verify()) { XCTAssertEqual($0 as? ChainError, .badTakeover(epoch: 2)) }
        var forgedSig = takeover
        forgedSig.entries[1].recoverySig = try other.signing.sign(forgedSig.entries[1].epochMessage(vaultId: forgedSig.vaultId,
                                                                                                    root: forgedSig.root))
        XCTAssertThrowsError(try forgedSig.verify()) { XCTAssertEqual($0 as? ChainError, .badTakeover(epoch: 2)) }
        var notAuthor = good
        try notAuthor.next(author: a, reason: "takeover", list: [a.fingerprint, bDev.fingerprint, r],
                           parentList: [a.fingerprint, bDev.fingerprint, r], home: bDev.fingerprint, takeover: recovery)
        XCTAssertThrowsError(try notAuthor.verify()) { XCTAssertEqual($0 as? ChainError, .notHome(epoch: 2)) }
        // A takeover keeps the recovery key; a recovery signature outside a takeover is refused.
        var newKit = good
        try newKit.next(author: bDev, reason: "takeover", list: [bDev.fingerprint, other.fingerprint],
                        parentList: [a.fingerprint, bDev.fingerprint, r], recovery: other.fingerprint, takeover: recovery)
        XCTAssertThrowsError(try newKit.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 2)) }
        var stray = good
        try stray.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r], takeover: recovery)
        XCTAssertThrowsError(try stray.verify()) { XCTAssertEqual($0 as? ChainError, .badTakeover(epoch: 2)) }
        // The takeover's new home approves additions from then on; the old home no longer does.
        var adds = takeover
        try adds.add(k, by: bDev)
        try adds.add(try ChainTestDevice("M"), by: a)
        XCTAssertEqual(try adds.verify().lists[1].rejected, [1])
    }

    /// The recovery key's signing pair is derived from its seed (design §5.6), deterministically, and
    /// differs from every other derivation of it.
    func testRecoverySigningKeysAreDerived() throws {
        let identity = try MLKEM768X25519Identity()
        let one = try DeviceSigningKeys.recovery(identity: identity).publicKeys()
        XCTAssertEqual(try DeviceSigningKeys.recovery(identity: identity).publicKeys(), one)
        XCTAssertEqual(try DeviceSigningKeys.recovery(seed: identity.seedBytes).publicKeys(), one)
        XCTAssertNotEqual(try DeviceSigningKeys.recovery(identity: try MLKEM768X25519Identity()).publicKeys(), one)
        XCTAssertThrowsError(try DeviceSigningKeys.recovery(seed: Data(count: 31)))
        XCTAssertEqual(try KeyFingerprint.recovery(identity: identity),
                       KeyFingerprint.recovery(key: identity.recipient.string, signP256: one.p256Hex, signMLDSA65: one.mldsa65Hex))
        // The shared vector (Swift and TypeScript).
        let v = try EpochKeysTests.loadVectors()
        let rv = try XCTUnwrap(v.recovery)
        let keys = try DeviceSigningKeys.recovery(identity: try MLKEM768X25519Identity(string: try XCTUnwrap(rv.identity)))
            .publicKeys()
        XCTAssertEqual(keys.p256Hex, rv.signP256)
        XCTAssertEqual(keys.mldsa65Hex, rv.signMLDSA65)
        XCTAssertEqual(Hex.encode(KeyFingerprint.recovery(key: rv.recipient, signP256: keys.p256Hex, signMLDSA65: keys.mldsa65Hex)),
                       rv.fingerprint)
    }

    /// The negative chain cases of design §12 KH1.
    func testChainNegativeCases() throws {
        let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B"), y = try ChainTestDevice("Y")
        let z = try ChainTestDevice("Z")
        let r = try ChainTestRecovery("recovery").fingerprint
        var base = try ChainTestBuilder(author: a, founders: [a.fingerprint, bDev.fingerprint, r])
        let good = base
        try base.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertNoThrow(try base.verify())

        // A broken link: signed by a key other than the parent's.
        var broken = good
        try broken.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                        linkFrom: .random())
        XCTAssertThrowsError(try broken.verify()) { XCTAssertEqual($0 as? ChainError, .brokenLink(epoch: 2)) }
        // A wrong root.
        XCTAssertThrowsError(try base.verify(root: Data(repeating: 1, count: 32))) { XCTAssertEqual($0 as? ChainError, .notRooted) }
        // An epoch signed by an unlisted key (Y is in no list), or by a listed device that is not home.
        var unlisted = good
        try unlisted.next(author: y, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try unlisted.verify()) { XCTAssertEqual($0 as? ChainError, .notHome(epoch: 2)) }
        var byB = good
        try byB.next(author: bDev, list: [bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try byB.verify()) { XCTAssertEqual($0 as? ChainError, .notHome(epoch: 2)) }
        // An epoch naming A as author but signed by Y.
        var forged = good
        try forged.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r], signer: y)
        XCTAssertThrowsError(try forged.verify()) { XCTAssertEqual($0 as? ChainError, .badEpochSig(epoch: 2)) }
        // An epoch introducing a device.
        var intro = good
        try intro.next(author: a, list: [a.fingerprint, bDev.fingerprint, z.fingerprint, r],
                       parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try intro.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 2)) }
        // ... even as the one new key of a recovery replacement, when it is a known device.
        var introRecovery = good
        try introRecovery.add(z, by: bDev)   // rejected (B is not home), but Z's keys are known
        try introRecovery.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, z.fingerprint],
                               parentList: [a.fingerprint, bDev.fingerprint, r], recovery: z.fingerprint)
        XCTAssertThrowsError(try introRecovery.verify()) { XCTAssertEqual($0 as? ChainError, .badRecovery(epoch: 2)) }
        // A recovery replacement may bring one new recovery key; a removal may not.
        let r2 = try ChainTestRecovery("recovery-2").fingerprint
        var replace = good
        try replace.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, r2],
                         parentList: [a.fingerprint, bDev.fingerprint, r], recovery: r2)
        XCTAssertEqual(try replace.verify().removals[1], [r])
        var replaceAsRemoval = good
        try replaceAsRemoval.next(author: a, list: [a.fingerprint, bDev.fingerprint, r2],
                                  parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try replaceAsRemoval.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 2)) }
        // Review M1: the chain names the recovery key; a replacement drops the old one; nothing else changes it.
        XCTAssertEqual(try replace.verify().recoveryKeys, [r, r2])
        var keepsOld = good
        try keepsOld.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, r, r2],
                          parentList: [a.fingerprint, bDev.fingerprint, r], recovery: r2)
        XCTAssertThrowsError(try keepsOld.verify()) { XCTAssertEqual($0 as? ChainError, .badRecovery(epoch: 2)) }
        var sameKit = good
        try sameKit.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, r],
                         parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try sameKit.verify()) { XCTAssertEqual($0 as? ChainError, .badRecovery(epoch: 2)) }
        var renamedKit = good
        try renamedKit.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                            recovery: bDev.fingerprint)
        XCTAssertThrowsError(try renamedKit.verify()) { XCTAssertEqual($0 as? ChainError, .badRecovery(epoch: 2)) }
        var deviceAsKit = good
        try deviceAsKit.next(author: a, list: [a.fingerprint, bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                             recovery: bDev.fingerprint)
        XCTAssertThrowsError(try deviceAsKit.verify()) { XCTAssertEqual($0 as? ChainError, .badRecovery(epoch: 2)) }
        // An addedBy that is not the signer: the addition is rejected, and an epoch carrying it introduces a device.
        var wrongApprover = good
        try wrongApprover.add(z, by: bDev, claimedBy: a.id)
        try wrongApprover.next(author: a, list: [a.fingerprint, z.fingerprint, r],
                               parentList: [a.fingerprint, bDev.fingerprint, z.fingerprint, r])
        XCTAssertThrowsError(try wrongApprover.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 2)) }
        // A self-signed entry (a kit join is a takeover now), and one approved by a device that is not
        // home (even one home added), are not admitted.
        var selfClaim = good
        try selfClaim.add(z, by: z, claimedBy: a.id)
        try selfClaim.add(y, by: y, claimedBy: EntryClaim.recovery)
        XCTAssertEqual(try selfClaim.verify().lists[0].rejected, [0, 1])
        let n = try ChainTestDevice("N"), m = try ChainTestDevice("M")
        var notHome = good
        try notHome.add(n, by: a)
        try notHome.add(m, by: n)
        try notHome.add(z, by: bDev)
        XCTAssertEqual(try notHome.verify().lists[0].rejected, [1, 2])
        // An addition for another epoch is rejected.
        var otherEpoch = good
        try otherEpoch.add(n, by: a, epoch: 2)
        XCTAssertEqual(try otherEpoch.verify().lists[0].rejected, [0])
        // At most 256 additions per epoch.
        var many = good
        let one = try many.add(n, by: a)
        many.entries[0].additions = Array(repeating: one, count: EpochChain.maxAdditions + 1)
        XCTAssertThrowsError(try many.verify()) { XCTAssertEqual($0 as? ChainError, .tooManyAdditions(epoch: 1)) }
        // Sequence: a parent that is not the previous epoch; a second "create".
        var seq = base
        seq.entries[1].parent = Data(repeating: 9, count: 32)
        XCTAssertThrowsError(try seq.verify()) { XCTAssertEqual($0 as? ChainError, .badSequence(epoch: 2)) }
        var create = good
        try create.next(author: a, reason: "create", list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try create.verify()) { XCTAssertEqual($0 as? ChainError, .badSequence(epoch: 2)) }
        var reason = good
        try reason.next(author: a, reason: "merge", list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try reason.verify()) { XCTAssertEqual($0 as? ChainError, .badReason(epoch: 2)) }
        XCTAssertThrowsError(try EpochChain.verify([], vaultId: UUID(), root: Data(count: 32))) {
            XCTAssertEqual($0 as? ChainError, .empty)
        }
    }

    /// Removals are computed, never read (design §4.1): a key the author omits from its signed parent
    /// list is not removed, and one it still lists cannot be.
    func testRemovalsAreComputed() throws {
        let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B"), c = try ChainTestDevice("C")
        let r = try ChainTestRecovery("recovery").fingerprint
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, bDev.fingerprint, c.fingerprint, r])
        try b.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, c.fingerprint, r])
        XCTAssertEqual(try b.verify().removals[1], [c.fingerprint], "B was left out of the signed parent list")
    }

    // MARK: - Shared chain vectors (positive and negative)

    struct ChainVectors: Codable {
        struct Case: Codable { var name: String; var root: String; var chain: [ChainEntry]; var expect: String }
        var description: String
        var vaultId: String
        var cases: [Case]
    }

    static func outcome(_ chain: [ChainEntry], vaultId: UUID, root: Data) -> String {
        do {
            let v = try EpochChain.verify(chain, vaultId: vaultId, root: root)
            return "ok removals=" + v.removals.map { $0.map(Hex.encode).sorted().joined(separator: ",") }.joined(separator: "|")
        } catch let e as ChainError {
            switch e {
            case .empty: return "empty"
            case .badSequence(let n): return "badSequence:\(n)"
            case .notRooted: return "notRooted"
            case .brokenLink(let n): return "brokenLink:\(n)"
            case .authorNotListed(let n): return "authorNotListed:\(n)"
            case .notHome(let n): return "notHome:\(n)"
            case .badHome(let n): return "badHome:\(n)"
            case .badTakeover(let n): return "badTakeover:\(n)"
            case .kitNotPinned(let n): return "kitNotPinned:\(n)"
            case .badEpochSig(let n): return "badEpochSig:\(n)"
            case .introducesDevice(let n): return "introducesDevice:\(n)"
            case .tooManyAdditions(let n): return "tooManyAdditions:\(n)"
            case .badReason(let n): return "badReason:\(n)"
            case .badRecovery(let n): return "badRecovery:\(n)"
            }
        } catch {
            return "\(error)"
        }
    }

    /// `Fixtures/epoch-chain-vectors.json` (design §12 KH1 negative vectors): a chain with carried
    /// additions, a handoff and a takeover, and chains broken seven ways. Written by this test with
    /// `SEMPERE_WRITE_EPOCH_VECTORS=1`; web/test/epoch.test.ts checks every signature and link in it.
    func testChainVectors() throws {
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_EPOCH_VECTORS"] == "1" {
            let vaultId = try XCTUnwrap(UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c"))
            let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B"), n = try ChainTestDevice("N")
            let k = try ChainTestDevice("K"), y = try ChainTestDevice("Y"), z = try ChainTestDevice("Z")
            let recovery = try ChainTestRecovery("recovery")
            let r = recovery.fingerprint
            var base = try ChainTestBuilder(vaultId: vaultId, author: a, founders: [a.fingerprint, bDev.fingerprint, r])
            try base.add(n, by: a)
            try base.add(k, by: a)
            let start = base
            var ok = start
            try ok.next(author: a, list: [a.fingerprint, n.fingerprint, r],
                        parentList: [a.fingerprint, bDev.fingerprint, n.fingerprint, k.fingerprint, r])
            try ok.next(author: a, reason: "handoff", list: [a.fingerprint, n.fingerprint, r],
                        parentList: [a.fingerprint, n.fingerprint, r], home: n.fingerprint)
            try ok.next(author: k, reason: "takeover", list: [n.fingerprint, k.fingerprint, r],
                        parentList: [a.fingerprint, n.fingerprint, r], takeover: recovery)
            var broken = start
            try broken.next(author: a, list: [a.fingerprint, n.fingerprint, r],
                            parentList: [a.fingerprint, bDev.fingerprint, n.fingerprint, k.fingerprint, r], linkFrom: .random())
            var notHome = start
            try notHome.next(author: n, list: [a.fingerprint, n.fingerprint, r],
                             parentList: [a.fingerprint, bDev.fingerprint, n.fingerprint, k.fingerprint, r])
            var wrongApprover = start
            try wrongApprover.add(z, by: bDev, claimedBy: a.id)
            try wrongApprover.next(author: a, list: [a.fingerprint, z.fingerprint, r],
                                   parentList: [a.fingerprint, bDev.fingerprint, z.fingerprint, r])
            var intro = start
            try intro.next(author: a, list: [a.fingerprint, bDev.fingerprint, y.fingerprint, r],
                           parentList: [a.fingerprint, bDev.fingerprint, r])
            var badTakeover = start
            try badTakeover.next(author: k, reason: "takeover", list: [k.fingerprint, r],
                                 parentList: [a.fingerprint, bDev.fingerprint, n.fingerprint, k.fingerprint, r],
                                 takeover: try ChainTestRecovery("other"))
            let root = Hex.encode(ok.root)
            func c(_ name: String, _ b: ChainTestBuilder, root: String) -> ChainVectors.Case {
                .init(name: name, root: root, chain: b.entries,
                      expect: Self.outcome(b.entries, vaultId: vaultId, root: Self.unhex(root)))
            }
            let out = ChainVectors(
                description: "key-hierarchy design §4.1, §4.3, §5.6, §12 KH1: chains of signed epochs (link, epochSig, "
                    + "carried additions with addSig, home, a takeover's recoverySig). The first verifies (N and K added by "
                    + "the home A during epoch 1; epoch 2 by A removes B and K; epoch 3 hands home to N; epoch 4 is a takeover "
                    + "by the recovery key with K as the new home); the others are the negative vectors: a broken link, a wrong "
                    + "root, an epoch signed by a device that is not home, an addedBy that is not the signer, an epoch "
                    + "introducing a device, a takeover signed by another recovery key. Device keys are the strings "
                    + "age1pq1test-<name>. Written by EpochChainTests.",
                vaultId: vaultId.uuidString.lowercased(),
                cases: [c("carried additions, handoff and takeover", ok, root: root), c("broken link", broken, root: root),
                        c("wrong root", ok, root: String(repeating: "11", count: 32)),
                        c("signature by a device that is not home", notHome, root: root),
                        c("addedBy that is not the signer", wrongApprover, root: root),
                        c("epoch introducing a device", intro, root: root),
                        c("takeover by another recovery key", badTakeover, root: root)])
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/epoch-chain-vectors.json")
            try (enc.encode(out) + Data("\n".utf8)).write(to: source)
        }
        let v = try JSONDecoder().decode(ChainVectors.self, from: Data(contentsOf: FixtureTests.bundled("epoch-chain-vectors.json")))
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        XCTAssertEqual(v.cases.map { $0.expect.split(separator: " ").first.map(String.init) ?? "" },
                       ["ok", "brokenLink:2", "notRooted", "notHome:2", "introducesDevice:2", "introducesDevice:2", "badTakeover:2"])
        for c in v.cases {
            XCTAssertEqual(Self.outcome(c.chain, vaultId: vaultId, root: Self.unhex(c.root)), c.expect, c.name)
        }
    }

    // MARK: - vault.json

    /// A signed `vault.json` for `b`'s last epoch: founder A (home), N and K approved by A at epoch 1,
    /// `extra` entries, and the recovery entry with its derived signing keys; written by `writer`.
    func manifest(_ b: ChainTestBuilder, a: ChainTestDevice, n: ChainTestDevice, k: ChainTestDevice,
                  recovery: MLKEM768X25519Identity, writer: ChainTestDevice? = nil,
                  extra: [EpochKeyEntry] = [], drop: Set<String> = []) throws -> EpochManifest {
        let e = b.entries[b.entries.count - 1]
        let key = b.keys[b.keys.count - 1]
        let rk = try ChainTestRecovery(identity: recovery)
        let entries = [try Self.entry(b.vaultId, a, by: a, addedBy: a.id, epoch: 1), try Self.entry(b.vaultId, n, by: a, addedBy: a.id, epoch: 1),
                       try Self.entry(b.vaultId, k, by: a, addedBy: a.id, epoch: 1)]
            .filter { !drop.contains($0.key) } + extra
            + [EpochKeyEntry(role: .recovery, key: recovery.recipient.string, sign: rk.sign, added: "2026-10-20T16:20:00Z",
                             name: "Recovery kit",
                             wrap: try EpochKeyWrap.seal(key, vaultId: b.vaultId, epoch: e.epoch,
                                                         to: .mlkem768x25519(recovery.recipient)))]
        let zero = try XCTUnwrap(AuthorSignature(p256: Data(count: 64), mldsa65: Data(count: 3309)))
        var m = EpochManifest(format: "sempere/1", vaultId: b.vaultId, created: "2026-10-20T16:20:00Z", root: b.root,
                              epoch: e.epoch, epochId: key.epochId, parent: e.parent,
                              epochRecord: "epochs/" + EpochRecord.fileName(epoch: e.epoch, epochId: key.epochId),
                              epochRecordHash: Data(repeating: 7, count: 32), keys: entries, listTag: "", epochLink: e.link,
                              epochAuthor: String(Hex.encode(e.author.fingerprint).prefix(8)), epochSig: e.epochSig,
                              markersTag: "", author: (writer ?? a).id, authorSig: zero, features: [], label: nil,
                              reencryptPending: nil, parentList: e.parentList, epochReason: e.reason, home: e.home,
                              recoverySig: e.recoverySig)
        return try Self.seal(m: &m, key: key, writer: writer ?? a)
    }

    static func entry(_ vaultId: UUID, _ d: ChainTestDevice, by signer: ChainTestDevice, addedBy: String,
                      epoch: Int) throws -> EpochKeyEntry {
        let claim = EntryClaim(key: d.key, sign: d.sign, kind: "ipad", added: "2026-10-20T16:20:00Z", addedEpoch: epoch,
                               addedBy: addedBy)
        return EpochKeyEntry(role: .device, key: d.key, id: d.id, sign: d.sign, kind: claim.kind, added: claim.added,
                             addedEpoch: epoch, addedBy: addedBy,
                             addSig: try signer.signing.sign(AuthorMessage.entry(vaultId: vaultId, claim)),
                             name: "\(d.name)'s iPad / ☕️", wrap: "wrap-\(d.name)")
    }

    /// Re-tags and re-signs `m` after a change.
    static func seal(m: inout EpochManifest, key: VaultEpochKey, writer: ChainTestDevice) throws -> EpochManifest {
        m.listTag = EpochListTag.tag(key: key, vaultId: m.vaultId, root: Hex.encode(m.root), epoch: m.epoch,
                                     epochId: Hex.encode(key.epochId), epochRecordHash: Hex.encode(m.epochRecordHash),
                                     entries: m.keys.map(\.listEntry))
        m.markersTag = try XCTUnwrap(EpochManifest.markersTag(key: key, vaultId: m.vaultId, format: m.format, features: m.features))
        m.authorSig = try writer.signing.sign(m.manifestMessage)
        return m
    }

    func testManifestReadsAndChecks() throws {
        let a = try ChainTestDevice("A"), n = try ChainTestDevice("N"), k = try ChainTestDevice("K"), x = try ChainTestDevice("X")
        let recovery = try MLKEM768X25519Identity()
        let r = try KeyFingerprint.recovery(identity: recovery)
        let b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        let key = b.keys[0]
        let m = try manifest(b, a: a, n: n, k: k, recovery: recovery)
        let data = try JSONEncoder().encode(m)
        let read = try EpochManifest.parse(data)
        XCTAssertEqual(read, m)
        XCTAssertEqual(Set(read.firstList), [a.fingerprint, r], "the creator and the recovery key")
        let verified: Set<Data> = [a.fingerprint, r]
        let admitted = try read.check(key: key, verifiedList: verified)
        XCTAssertEqual(admitted.map(\.key), [n.key, k.key], "both approved by the home")
        let wrap = try XCTUnwrap(read.keys.first { $0.role == .recovery }?.wrap)
        XCTAssertEqual(try EpochKeyWrap.open(wrap, with: [recovery], vaultId: b.vaultId, epoch: 1), key)

        func problem(_ m: EpochManifest, verified: Set<Data> = verified) -> EpochManifest.Problem? {
            do { _ = try m.check(key: key, verifiedList: verified); return nil } catch {
                return (error as? EpochManifest.ProblemError)?.problem
            }
        }
        XCTAssertThrowsError(try m.check(key: .random(), verifiedList: verified))
        // Storage renames a device: listTag (and authorSig) no longer verify.
        var renamed = m; renamed.keys[1].name = "Mallory"
        XCTAssertEqual(problem(renamed), .listTag)
        var markers = m; markers.markersTag = String(repeating: "0", count: 64)
        XCTAssertEqual(problem(markers), .markersTag)
        // authorSig by a device that is not listed (X), or not matching the author id.
        var unlisted = try manifest(b, a: a, n: n, k: k, recovery: recovery, writer: x)
        XCTAssertEqual(problem(unlisted), .authorSig)
        unlisted.author = a.id
        XCTAssertEqual(problem(unlisted), .authorSig)
        // epochSig (review H2): verified from this file alone; by the epoch's author only.
        var badEpochSig = m; badEpochSig.epochSig = try a.signing.sign(Data("other".utf8))
        XCTAssertEqual(problem(try Self.seal(m: &badEpochSig, key: key, writer: a)), .epochSig)
        var otherAuthor = m; otherAuthor.epochAuthor = n.id
        XCTAssertEqual(problem(try Self.seal(m: &otherAuthor, key: key, writer: a)), .epochSig)
        // addSig.
        func reSigned(_ index: Int, signer: ChainTestDevice, addedBy: String) throws -> EpochManifest {
            var y = m
            y.keys[index].addedBy = addedBy
            let claim = try XCTUnwrap(y.keys[index].claim)
            y.keys[index].addSig = try signer.signing.sign(AuthorMessage.entry(vaultId: b.vaultId, claim))
            return try Self.seal(m: &y, key: key, writer: a)
        }
        XCTAssertEqual(problem(try reSigned(2, signer: k, addedBy: a.id)), .addSig(key: k.key), "self-signed, claiming the home")
        XCTAssertEqual(problem(try reSigned(2, signer: k, addedBy: EntryClaim.recovery)), .addSig(key: k.key), "a kit join")
        XCTAssertEqual(problem(try reSigned(1, signer: x, addedBy: a.id)), .addSig(key: n.key), "signed by an unlisted device")
        XCTAssertEqual(problem(try reSigned(1, signer: a, addedBy: n.id)), .addSig(key: n.key), "addedBy not the signer")
        XCTAssertEqual(problem(try reSigned(1, signer: a, addedBy: EntryClaim.recovery)), .addSig(key: n.key))
        // Only home approves: M approved by N (itself approved by home) is refused.
        let mDev = try ChainTestDevice("M")
        var chained = try manifest(b, a: a, n: n, k: k, recovery: recovery,
                                   extra: [try Self.entry(b.vaultId, mDev, by: n, addedBy: n.id, epoch: 1)])
        XCTAssertEqual(problem(try Self.seal(m: &chained, key: key, writer: a)), .addSig(key: mDev.key))
        // Only home writes vault.json.
        XCTAssertEqual(problem(try manifest(b, a: a, n: n, k: k, recovery: recovery, writer: n)), .authorSig)

        // Structure.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func parse(_ change: (inout [String: Any]) -> Void) throws -> EpochManifest {
            var j = json; change(&j)
            return try EpochManifest.parse(try JSONSerialization.data(withJSONObject: j))
        }
        XCTAssertNoThrow(try parse { _ in })
        let bad: [(String, (inout [String: Any]) -> Void)] = [
            ("record name", { $0["epochRecord"] = "epochs/1-0000000000000000.epoch.age" }),
            ("epoch 1 with a parent", { $0["parent"] = String(repeating: "ab", count: 32) }),
            ("epoch 1 not create", { $0["epochReason"] = "remove" }),
            ("recoverySig outside a takeover", {
                $0["recoverySig"] = ["p256": String(repeating: "ab", count: 64), "mldsa65": String(repeating: "ab", count: 3309)]
            }),
            ("home not a listed device", { $0["home"] = String(repeating: "ab", count: 32) }),
            ("no home", { $0["home"] = nil }),
            ("epoch 1 with a parent list", { $0["parentList"] = [String(repeating: "ab", count: 32)] }),
            ("two recovery entries", {
                var keys = $0["keys"] as? [[String: Any]] ?? []
                keys.append(keys[3]); keys[4]["key"] = "age1pq1other"
                $0["keys"] = keys
            }),
            ("no device", { var keys = $0["keys"] as? [[String: Any]] ?? []; $0["keys"] = [keys.removeLast()] }),
            ("a classic key", { var keys = $0["keys"] as? [[String: Any]] ?? []; keys[1]["key"] = "age1abc"; $0["keys"] = keys }),
            ("an id that is not the fingerprint's", {
                var keys = $0["keys"] as? [[String: Any]] ?? []; keys[1]["id"] = "00000000"; $0["keys"] = keys
            }),
            ("a device without addSig", { var keys = $0["keys"] as? [[String: Any]] ?? []; keys[1]["addSig"] = nil; $0["keys"] = keys }),
            ("a recovery entry with device fields", {
                var keys = $0["keys"] as? [[String: Any]] ?? []; keys[3]["kind"] = "ipad"; $0["keys"] = keys
            }),
            ("a recovery entry without its signing keys", {
                var keys = $0["keys"] as? [[String: Any]] ?? []; keys[3]["sign"] = nil; $0["keys"] = keys
            }),
        ]
        for (name, change) in bad { XCTAssertThrowsError(try parse(change), name) }
        json["keys"] = nil
        XCTAssertThrowsError(try EpochManifest.parse(try JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try EpochManifest.parse(Data(repeating: 0x20, count: EpochManifest.maxBytes + 1)))
    }

    /// Review H1 (probe testMutualApprovalInsideOneManifest) and M3: entries that approve each other,
    /// or a removed founder re-listed with its old self-signed entry, have no path to the verified
    /// list and are refused.
    func testManifestAdmitsOnlyAgainstTheVerifiedList() throws {
        let a = try ChainTestDevice("A"), n = try ChainTestDevice("N"), k = try ChainTestDevice("K")
        let d1 = try ChainTestDevice("D1"), d2 = try ChainTestDevice("D2")
        let recovery = try MLKEM768X25519Identity()
        let r = try KeyFingerprint.recovery(identity: recovery)
        let b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        let key = b.keys[0]
        let mutual = try manifest(b, a: a, n: n, k: k, recovery: recovery, extra: [
            try Self.entry(b.vaultId, d1, by: d2, addedBy: d2.id, epoch: 1),
            try Self.entry(b.vaultId, d2, by: d1, addedBy: d1.id, epoch: 1),
        ])
        XCTAssertThrowsError(try mutual.check(key: key, verifiedList: [a.fingerprint, r])) {
            guard case .addSig(let k)? = ($0 as? EpochManifest.ProblemError)?.problem else { return XCTFail("\($0)") }
            XCTAssertTrue([d1.key, d2.key].contains(k))
        }
        // The founder, no longer in the verified list (removed), comes back with its old entry.
        let founderBack = try manifest(b, a: a, n: n, k: k, recovery: recovery, writer: n)
        XCTAssertThrowsError(try founderBack.check(key: key, verifiedList: [n.fingerprint, r])) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig, "A is no longer a signer either")
        }
        // An entry of an earlier epoch that the verified list does not hold is never admitted.
        var c = b
        try c.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, r])
        let epoch2 = try manifest(c, a: a, n: n, k: k, recovery: recovery)
        XCTAssertThrowsError(try epoch2.check(key: c.keys[1], verifiedList: [a.fingerprint, r])) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig, "the first list is signed")
        }
    }

    /// Review H2: a direct child of the pinned epoch verifies from `vault.json` alone, before its
    /// record arrives: `epochSig` over the first list (the entries of earlier epochs) and `parentList`.
    func testDirectChildVerifiesFromVaultJsonAlone() throws {
        let a = try ChainTestDevice("A"), n = try ChainTestDevice("N"), k = try ChainTestDevice("K")
        let recovery = try MLKEM768X25519Identity()
        let r = try KeyFingerprint.recovery(identity: recovery)
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        try b.add(n, by: a)
        try b.add(k, by: a)
        try b.next(author: a, list: [a.fingerprint, n.fingerprint, r],
                   parentList: [a.fingerprint, n.fingerprint, k.fingerprint, r])
        let m = try manifest(b, a: a, n: n, k: k, recovery: recovery, drop: [k.key])
        XCTAssertEqual(Set(m.firstList), [a.fingerprint, n.fingerprint, r])
        let pinned: Set<Data> = [a.fingerprint, n.fingerprint, k.fingerprint, r]
        let parent = EpochManifest.VerifiedParent(list: pinned, home: a.fingerprint, recovery: r)
        XCTAssertEqual(try m.check(key: b.keys[1], verifiedList: Set(m.firstList), parent: parent).count, 0)
        // A parent home other than the signer: refused.
        var otherHome = parent; otherHome.home = n.fingerprint
        XCTAssertThrowsError(try m.check(key: b.keys[1], verifiedList: Set(m.firstList), parent: otherHome)) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig)
        }
        // Round 7, M3: without the parent as verified, the file's own home never stands in.
        XCTAssertThrowsError(try m.check(key: b.keys[1], verifiedList: Set(m.firstList))) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig)
        }
        // ... so a listed device that is not home, naming itself home, is refused.
        var byN = b
        byN.entries.removeLast(); byN.keys.removeLast()
        try byN.next(author: n, list: [a.fingerprint, n.fingerprint, r], parentList: [a.fingerprint, n.fingerprint, k.fingerprint, r],
                     home: n.fingerprint)
        let mN = try manifest(byN, a: a, n: n, k: k, recovery: recovery, writer: n, drop: [k.key])
        XCTAssertThrowsError(try mN.check(key: byN.keys[1], verifiedList: Set(mN.firstList), parent: parent)) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig)
        }
        // A device that never saw N added cannot take the epoch from vault.json alone.
        XCTAssertThrowsError(try m.check(key: b.keys[1], verifiedList: Set(m.firstList),
                                         parent: .init(list: [a.fingerprint, k.fingerprint, r], home: a.fingerprint, recovery: r)))
        // A forged parentList is refused: epochSig covers it.
        var forged = m; forged.parentList = [a.fingerprint, n.fingerprint, r]
        XCTAssertThrowsError(try Self.seal(m: &forged, key: b.keys[1], writer: a)
            .check(key: b.keys[1], verifiedList: Set(m.firstList), parent: parent)) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig)
        }
        // A takeover's vault.json: by the new home N and the parent's recovery key (TakeoverRule).
        let rk = try ChainTestRecovery(identity: recovery)
        var tb = b
        tb.entries.removeLast(); tb.keys.removeLast()
        try tb.next(author: n, reason: "takeover", list: [n.fingerprint, r], parentList: [a.fingerprint, n.fingerprint, k.fingerprint, r],
                    takeover: rk)
        let mt = try manifest(tb, a: a, n: n, k: k, recovery: recovery, writer: n, drop: [a.key, k.key])
        XCTAssertEqual(try mt.check(key: tb.keys[1], verifiedList: Set(mt.firstList), parent: parent).count, 0)
        var wrongKit = parent; wrongKit.recovery = try ChainTestRecovery("other").fingerprint
        XCTAssertThrowsError(try mt.check(key: tb.keys[1], verifiedList: Set(mt.firstList), parent: wrongKit)) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig)
        }
    }

    // MARK: - Chain JSON

    func testChainEntryJSONRoundTripsAndIsStrict() throws {
        let a = try ChainTestDevice("A"), n = try ChainTestDevice("N")
        let r = try ChainTestRecovery("recovery").fingerprint
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        try b.add(n, by: a)
        try b.next(author: a, list: [a.fingerprint, n.fingerprint, r], parentList: [a.fingerprint, n.fingerprint, r])
        let data = try JSONEncoder().encode(b.entries)
        XCTAssertEqual(try JSONDecoder().decode([ChainEntry].self, from: data), b.entries)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertNil(json[0]["parent"]); XCTAssertNil(json[0]["link"]); XCTAssertNotNil(json[0]["additions"])
        XCTAssertNil(json[1]["additions"], "written only when not empty")
        for (name, change) in [("short epochId", { (e: inout [String: Any]) in e["epochId"] = "00" }),
                               ("uppercase list", { (e: inout [String: Any]) in e["list"] = [Hex.encode(r).uppercased()] }),
                               ("short signature", { (e: inout [String: Any]) in e["epochSig"] = ["p256": "00", "mldsa65": "00"] })] {
            var e = json[1]; change(&e)
            XCTAssertThrowsError(try JSONDecoder().decode(ChainEntry.self, from: try JSONSerialization.data(withJSONObject: e)), name)
        }
    }

    // MARK: - Epoch records and the journal

    func testEpochRecordRoundTripsAndChecks() throws {
        let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B")
        let r = try ChainTestRecovery("recovery").fingerprint
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, bDev.fingerprint, r])
        try b.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        let k1 = b.keys[0], k2 = b.keys[1]
        let record = EpochRecord(vaultId: b.vaultId, root: b.root, epoch: 2, epochId: k2.epochId,
                                 parent: EpochRecordParent(epoch: 1, epochId: k1.epochId, key: k1,
                                                           sealed: ["notes/x/y.delta.age": String(repeating: "ab", count: 32)]),
                                 chain: b.entries, created: "2026-10-20T16:20:00Z", by: a.id, reason: "remove",
                                 removed: [bDev.fingerprint])
        XCTAssertEqual(record.fileName, "2-\(Hex.encode(k2.epochId).prefix(16)).epoch.age")
        let file = try record.seal(key: k2)
        XCTAssertEqual(try AgeFile.parseHeader(file).header.stanzas.map(\.type), ["mlkem768x25519"])
        XCTAssertEqual(try EpochRecord.open(file, key: k2, vaultId: b.vaultId, epoch: 2), record)
        XCTAssertThrowsError(try EpochRecord.open(file, key: k1, vaultId: b.vaultId, epoch: 2))
        XCTAssertThrowsError(try EpochRecord.open(file, key: k2, vaultId: UUID(), epoch: 2))
        XCTAssertThrowsError(try EpochRecord.open(file, key: k2, vaultId: b.vaultId, epoch: 3), "the name is in the tag")
        XCTAssertThrowsError(try record.seal(key: k1))
        // The chain in a record verifies.
        XCTAssertNoThrow(try EpochChain.verify(record.chain, vaultId: b.vaultId, root: b.root))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try record.json()) as? [String: Any])
        func parse(_ change: (inout [String: Any]) -> Void) throws -> EpochRecord {
            var j = json; change(&j)
            return try EpochRecord.parse(try JSONSerialization.data(withJSONObject: j))
        }
        XCTAssertEqual(try parse { _ in }, record)
        let bad: [(String, (inout [String: Any]) -> Void)] = [
            ("format", { $0["format"] = "sempere-epoch/2" }),
            ("epoch", { $0["epoch"] = 3 }),
            ("chain end", { $0["epochId"] = Hex.encode(Data(repeating: 1, count: 32)) }),
            ("no parent", { $0["parent"] = nil }),
            ("identity not derived", {
                var p = $0["parent"] as? [String: Any] ?? [:]
                p["identity"] = try? VaultEpochKey.random().vaultIdentity().string
                $0["parent"] = p
            }),
            ("key of another epoch", {
                var p = $0["parent"] as? [String: Any] ?? [:]
                let k = VaultEpochKey.random()
                p["key"] = Hex.encode(k.bytes); p["identity"] = try? k.vaultIdentity().string
                $0["parent"] = p
            }),
            ("identity without key", {
                var p = $0["parent"] as? [String: Any] ?? [:]
                p["key"] = nil
                $0["parent"] = p
            }),
            ("sealed digest", {
                var p = $0["parent"] as? [String: Any] ?? [:]
                p["sealed"] = ["notes/x": "zz"]
                $0["parent"] = p
            }),
        ]
        for (name, change) in bad { XCTAssertThrowsError(try parse(change), name) }
        // A re-encryption epoch carries no parent key.
        XCTAssertThrowsError(try parse { $0["reason"] = "reencrypt" })
        var reencrypt = record
        reencrypt.reason = "reencrypt"
        reencrypt.chain[reencrypt.chain.count - 1].reason = "reencrypt"
        reencrypt.parent?.key = nil
        XCTAssertEqual(try EpochRecord.parse(try reencrypt.json()), reencrypt)
        XCTAssertThrowsError(try EpochRecord.parse(Data(repeating: 0x20, count: 10)))
    }

    func testJournalRoundTripsAndBinds() throws {
        let vaultId = UUID(), k1 = VaultEpochKey.random(), k2 = VaultEpochKey.random(), km = VaultEpochKey.random()
        let journal = ReencryptJournal(vaultId: vaultId, epoch: 3, epochId: km.epochId,
                                       keys: [.init(epoch: 1, key: k1), .init(epoch: 2, key: k2)],
                                       created: "2026-10-20T16:20:00Z", by: "a1b2c3d4")
        let file = try journal.seal(key: km)
        XCTAssertEqual(try ReencryptJournal.open(file, key: km, vaultId: vaultId), journal)
        XCTAssertThrowsError(try ReencryptJournal.open(file, key: k2, vaultId: vaultId))
        XCTAssertThrowsError(try ReencryptJournal.open(file, key: km, vaultId: UUID()))
        let binding = ReencryptJournal.binding(journalFile: file, vaultId: vaultId, currentKey: km)
        XCTAssertEqual(binding.count, 64)
        XCTAssertNotEqual(binding, ReencryptJournal.binding(journalFile: file + Data([0]), vaultId: vaultId, currentKey: km))
        XCTAssertNotEqual(binding, ReencryptJournal.binding(journalFile: file, vaultId: vaultId, currentKey: k2),
                          "re-computed under each later epoch's key")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try journal.json()) as? [String: Any])
        var keys = json["keys"] as? [[String: Any]] ?? []
        keys[0]["epochId"] = Hex.encode(k2.epochId)
        json["keys"] = keys
        XCTAssertThrowsError(try ReencryptJournal.parse(try JSONSerialization.data(withJSONObject: json)))
    }

    // MARK: - The passphrase copy and the kit

    func testPassphraseCopyRoundTripsAndIsStrict() throws {
        let identity = try MLKEM768X25519Identity()
        let vaultId = UUID(), root = Data(repeating: 0x5a, count: 32)
        let copy = RecoveryPassphraseCopy(created: "2026-10-20T16:20:00Z", vaultId: vaultId, root: root, identity: identity)
        XCTAssertEqual(try copy.path(), "keys/recovery-\(Hex.encode(try KeyFingerprint.recovery(identity: identity))).key.age")
        let lines = copy.plaintext.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["# created: 2026-10-20T16:20:00Z", "# sempere-vault: \(vaultId.uuidString.lowercased())",
                               "# sempere-root: \(Hex.encode(root))", "# public key: \(identity.recipient.string)",
                               identity.string])
        // `age -i` reads it as an identity file (comments and one key).
        XCTAssertEqual(try IdentityFile.parse(copy.plaintext).recipient.string, identity.recipient.string)
        let file = try copy.seal(passphrase: "correct horse battery staple", workFactor: 10)
        XCTAssertEqual(try AgeFile.parseHeader(file).header.stanzas.map(\.type), ["scrypt"])
        XCTAssertEqual(try RecoveryPassphraseCopy.open(file, passphrase: "correct horse battery staple"), copy)
        XCTAssertThrowsError(try RecoveryPassphraseCopy.open(file, passphrase: "wrong"))
        let other = try MLKEM768X25519Identity()
        for bad in [copy.plaintext.replacingOccurrences(of: identity.recipient.string, with: other.recipient.string),
                    copy.plaintext.replacingOccurrences(of: "# sempere-root: ", with: "# root: "),
                    copy.plaintext.replacingOccurrences(of: vaultId.uuidString.lowercased(), with: vaultId.uuidString),
                    String(copy.plaintext.dropLast()), copy.plaintext + "\n"] {
            XCTAssertThrowsError(try RecoveryPassphraseCopy.parse(Data(bad.utf8)))
        }
        XCTAssertEqual(RecoveryPassphraseCopy.workFactor, 20)
    }

    func testKitRootGroupsAndQR() throws {
        let root = Data((0..<32).map { UInt8($0) })
        let groups = KitRecovery.rootGroups(root)
        XCTAssertEqual(groups.count, 16)
        XCTAssertEqual(groups.map(\.group).joined(), Hex.encode(root))
        XCTAssertEqual(groups[0].group, "0001")
        XCTAssertEqual(groups[0].checksum, String(FileDigest.sha256(Data("0001".utf8)).prefix(4)))
        let id = UUID()
        let qr = KitRecovery.rootQR(vaultId: id, root: root)
        XCTAssertEqual(qr, "sempere-root:\(id.uuidString.lowercased()):\(Hex.encode(root))")
        XCTAssertEqual(KitRecovery.parseRootQR(qr)?.root, root)
        XCTAssertNil(KitRecovery.parseRootQR(qr.uppercased()))
        XCTAssertNil(KitRecovery.parseRootQR("sempere-root:\(id.uuidString.lowercased())"))
    }

    /// The script in the code is the one format.md §15.13 and the design (§8.1) print, byte for byte.
    func testRecoveryScriptMatchesTheDocuments() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for (doc, heading) in [("docs/format.md", "### 15.13"), ("docs/design/key-hierarchy.md", "### 8.1")] {
            let text = try String(contentsOf: repo.appendingPathComponent(doc), encoding: .utf8)
            let section = try XCTUnwrap(text.range(of: heading), doc)
            let start = try XCTUnwrap(text.range(of: "```sh\n", range: section.upperBound..<text.endIndex), doc)
            let end = try XCTUnwrap(text.range(of: "```\n", range: start.upperBound..<text.endIndex), doc)
            XCTAssertEqual(String(text[start.upperBound..<end.lowerBound]), KitRecovery.script, doc)
        }
    }

    /// The kit's script (design §8.1) on a hand-built vault: two removals, a re-encryption that is
    /// not finished (journal present), an orphan record and a record of a fork that lost. Stock
    /// `age` 1.3+, `jq`, `tail` and `gunzip` open a note of every epoch. The passphrase copy's
    /// plaintext serves as `recovery.txt` (step 0 itself needs a terminal: `age -d` reads
    /// passphrases from one only).
    func testFrozenRecoveryScriptOpensEveryEpoch() throws {
        let required = ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil
        guard let age = ExternalTool.find("age"), ExternalTool.find("jq") != nil else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age or jq is not on PATH") }
            throw XCTSkip("age or jq not on PATH")
        }
        let version = String(decoding: try ExternalTool.run(age, ["--version"]).out, as: UTF8.self)
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
            .split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3) else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is \(version)") }
            throw XCTSkip("age \(version) predates post-quantum recipients (needs 1.3)")
        }
        let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B"), c = try ChainTestDevice("C")
        let recovery = try MLKEM768X25519Identity()
        let r = try KeyFingerprint.recovery(identity: recovery)
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, bDev.fingerprint, c.fingerprint, r])
        try b.next(author: a, list: [a.fingerprint, bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, c.fingerprint, r])
        try b.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        // The re-encryption replaces the recovery key (format.md §15.7).
        let recovery2 = try MLKEM768X25519Identity()
        let r2 = try KeyFingerprint.recovery(identity: recovery2)
        try b.next(author: a, reason: "reencrypt", list: [a.fingerprint, r2], parentList: [a.fingerprint, r], recovery: r2)
        XCTAssertNoThrow(try b.verify())
        let k = b.keys
        let dir = tmp.appendingPathComponent("kit.sempere")
        let epochs = dir.appendingPathComponent("epochs")
        try FileManager.default.createDirectory(at: epochs, withIntermediateDirectories: true)
        // vault.json: only what the script reads (the recovery entry's wrap of the current key).
        let wrap = try EpochKeyWrap.seal(k[3], vaultId: b.vaultId, epoch: 4, to: .mlkem768x25519(recovery2.recipient))
        let manifest = try JSONSerialization.data(withJSONObject: ["keys": [["role": "recovery", "wrap": wrap]]])
        try manifest.write(to: dir.appendingPathComponent("vault.json"))
        // Records 1 to 4 (4: a re-encryption, no parent key), an orphan 5, and a record at 3 that the
        // precedence rule drops (a non-home epoch).
        for e in 1...4 {
            let parent = e == 1 ? nil : EpochRecordParent(epoch: e - 1, epochId: k[e - 2].epochId,
                                                          key: e == 4 ? nil : k[e - 2], sealed: [:])
            let rec = EpochRecord(vaultId: b.vaultId, root: b.root, epoch: e, epochId: k[e - 1].epochId, parent: parent,
                                  chain: Array(b.entries.prefix(e)), created: "2026-10-20T16:20:00Z", by: a.id,
                                  reason: b.entries[e - 1].reason)
            try rec.seal(key: k[e - 1]).write(to: epochs.appendingPathComponent(rec.fileName))
        }
        var orphanChain = b
        try orphanChain.next(author: a, list: [a.fingerprint, r2], parentList: [a.fingerprint, r2])
        let k5 = orphanChain.keys[4]
        try EpochRecord(vaultId: b.vaultId, root: b.root, epoch: 5, epochId: k5.epochId,
                        parent: EpochRecordParent(epoch: 4, epochId: k[3].epochId, key: k[3], sealed: [:]),
                        chain: orphanChain.entries, created: "2026-10-20T16:20:00Z", by: a.id, reason: "remove")
            .seal(key: k5).write(to: epochs.appendingPathComponent(EpochRecord.fileName(epoch: 5, epochId: k5.epochId)))
        var lost = b
        lost.entries.removeLast(2); lost.keys.removeLast(2)
        try lost.next(author: bDev, list: [a.fingerprint, bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        let k3b = lost.keys[2]
        try EpochRecord(vaultId: b.vaultId, root: b.root, epoch: 3, epochId: k3b.epochId,
                        parent: EpochRecordParent(epoch: 2, epochId: k[1].epochId, key: k[1], sealed: [:]),
                        chain: lost.entries, created: "2026-10-20T16:20:00Z", by: bDev.id, reason: "remove")
            .seal(key: k3b).write(to: epochs.appendingPathComponent(EpochRecord.fileName(epoch: 3, epochId: k3b.epochId)))
        // The unfinished re-encryption's journal holds K_1 to K_3.
        let journal = ReencryptJournal(vaultId: b.vaultId, epoch: 4, epochId: k[3].epochId,
                                       keys: (1...3).map { .init(epoch: $0, key: k[$0 - 1]) },
                                       created: "2026-10-20T16:20:00Z", by: a.id)
        try journal.seal(key: k[3]).write(to: dir.appendingPathComponent(ReencryptJournal.fileName))
        // One note per epoch, as revisions are framed (format.md §4) under that epoch's tag key.
        var expected: [String: String] = [:]
        for e in 1...4 {
            let note = "note-\(e)", name = "r\(e).delta.age"
            let folder = dir.appendingPathComponent("notes/\(note)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = Data(#"{"epoch":\#(e)}"#.utf8)
            let body = try BodyFraming.frame(json: json, noteId: note, filename: name, secret: VaultSecret(bytes: k[e - 1].tagKey))
            try AgeFile.encrypt(body, to: [try k[e - 1].vaultIdentity().recipient]).write(to: folder.appendingPathComponent(name))
            expected["notes/\(note)/\(name)"] = #"{"epoch":\#(e)}"#
        }
        // recovery.txt: the passphrase copy's plaintext.
        let copy = RecoveryPassphraseCopy(created: "2026-10-20T16:20:00Z", vaultId: b.vaultId, root: b.root, identity: recovery2)
        try copy.plaintext.write(to: dir.appendingPathComponent("recovery.txt"), atomically: true, encoding: .utf8)

        // Steps 1 and 2 exactly as printed; step 3 for each note.
        let script = KitRecovery.script
        let step3 = try XCTUnwrap(script.range(of: "# 3. Any note, as before."))
        let steps = String(script[..<step3.lowerBound])
        XCTAssertTrue(script.hasSuffix("age -d -i vault-keys.txt notes/ID/NAME.delta.age | tail -c +38 | gunzip | jq .\n"))
        var sh = "set -u\ncd \(ExternalTool.shellQuote(dir.path))\nPATH=\(ExternalTool.shellQuote(age.deletingLastPathComponent().path)):$PATH\n"
        sh += steps
        for path in expected.keys.sorted() {
            sh += "echo \"== \(path)\"\nage -d -i vault-keys.txt \(path) | tail -c +38 | gunzip | jq -c .\n"
        }
        let run = try ExternalTool.run(URL(fileURLWithPath: "/bin/sh"), ["-c", sh])
        let out = String(decoding: run.out, as: UTF8.self)
        for (path, json) in expected {
            XCTAssertTrue(out.contains("== \(path)\n\(json)\n"), "\(path) did not open:\n\(out)\n\(run.errText)")
        }
    }
}
