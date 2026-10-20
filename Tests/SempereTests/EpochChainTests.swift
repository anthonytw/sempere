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

/// Builds signed chains (design §5.2.1) for tests.
struct ChainTestBuilder {
    let vaultId: UUID
    var keys: [VaultEpochKey]
    var entries: [ChainEntry]
    let root: Data

    /// Epoch 1, created by `author`, listing `founders` (fingerprints); the recovery key is the last.
    init(vaultId: UUID = UUID(), author: ChainTestDevice, founders: [Data]) throws {
        self.vaultId = vaultId
        let k1 = VaultEpochKey.random()
        keys = [k1]
        let link = try LinkPublicKeys(epochKey: k1)
        root = VaultRoot.fingerprint(vaultId: vaultId, epochOne: link)
        var e = ChainEntry(epoch: 1, epochId: k1.epochId, parent: nil, linkPublicKeys: link, link: nil, reason: "create",
                           list: founders, parentList: [], author: author.author,
                           epochSig: try XCTUnwrap(AuthorSignature(p256: Data(count: 64), mldsa65: Data(count: 3309))),
                           recovery: try XCTUnwrap(founders.last))
        e.epochSig = try author.signing.sign(e.epochMessage(vaultId: vaultId, root: root))
        entries = [e]
    }

    /// An addition during the last epoch: approved by `approver`, or a kit join (self-signed) when nil.
    @discardableResult
    mutating func add(_ d: ChainTestDevice, by approver: ChainTestDevice?, claimedBy: String? = nil,
                      epoch: Int? = nil) throws -> ChainAddition {
        let claim = EntryClaim(key: d.key, sign: d.sign, kind: "ipad", added: "2026-10-20T16:20:00Z",
                               addedEpoch: epoch ?? entries.count, addedBy: claimedBy ?? approver?.id ?? EntryClaim.recovery)
        let signer = approver ?? d
        let a = ChainAddition(claim: claim, addSig: try signer.signing.sign(AuthorMessage.entry(vaultId: vaultId, claim)))
        entries[entries.count - 1].additions.append(a)
        return a
    }

    /// The next epoch by `author`, with first list `list` and the parent list as the author saw it.
    mutating func next(author: ChainTestDevice, reason: String = "remove", list: [Data], parentList: [Data],
                       signer: ChainTestDevice? = nil, linkFrom: VaultEpochKey? = nil, recovery: Data? = nil,
                       rejected: Data? = nil) throws {
        let k = VaultEpochKey.random()
        let prev = entries[entries.count - 1]
        let epoch = entries.count + 1
        var e = ChainEntry(epoch: epoch, epochId: k.epochId, parent: prev.epochId, linkPublicKeys: try LinkPublicKeys(epochKey: k),
                           link: try EpochLinks.link(from: linkFrom ?? keys[keys.count - 1], to: k, epoch: epoch, vaultId: vaultId),
                           reason: reason, list: list, parentList: parentList, author: author.author,
                           epochSig: try XCTUnwrap(AuthorSignature(p256: Data(count: 64), mldsa65: Data(count: 3309))),
                           recovery: recovery ?? prev.recovery, rejected: rejected)
        e.epochSig = try (signer ?? author).signing.sign(e.epochMessage(vaultId: vaultId, root: root))
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
                                               reason: f.reason, recovery: Self.unhex(f.recovery),
                                               rejected: f.rejected.isEmpty ? nil : Self.unhex(f.rejected),
                                               list: f.list.map(Self.unhex), parentList: f.parentList.map(Self.unhex))
        XCTAssertEqual(Hex.encode(epochMessage), sigs.epoch.message)
        // Order of the lists does not matter: they are signed sorted.
        XCTAssertEqual(AuthorMessage.epoch(vaultId: vaultId, root: Self.unhex(f.root), epoch: f.epoch,
                                           epochId: Self.unhex(f.epochId), parent: Self.unhex(f.parent), reason: f.reason,
                                           recovery: Self.unhex(f.recovery), rejected: f.rejected.isEmpty ? nil : Self.unhex(f.rejected),
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
    /// device added while it was away": N is added by A during epoch 1 and K joins with the kit;
    /// epoch 2 (by N) removes K; the chain alone admits N and K from epoch 1's additions.
    func testChainWithCarriedAdditionAndKitJoinVerifies() throws {
        let a = try ChainTestDevice("A"), n = try ChainTestDevice("N"), k = try ChainTestDevice("K")
        let r = KeyFingerprint.recovery(key: "age1pq1test-recovery")
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        try b.add(n, by: a)
        try b.add(k, by: nil)
        try b.next(author: n, list: [a.fingerprint, n.fingerprint, r],
                   parentList: [a.fingerprint, n.fingerprint, k.fingerprint, r])
        let v = try b.verify()
        XCTAssertEqual(v.lists[0].list, [a.fingerprint, r, n.fingerprint, k.fingerprint])
        XCTAssertEqual(v.lists[0].admitted.map(\.approver), [a.fingerprint, nil])
        XCTAssertEqual(v.removals, [[], [k.fingerprint]])
        XCTAssertEqual(v.approverChain(of: n.fingerprint), [a.fingerprint])
        XCTAssertEqual(v.approverChain(of: k.fingerprint), [], "a kit join")
        XCTAssertEqual(v.approverChain(of: a.fingerprint), [], "a founder")
        // An addition approved by N (itself added by A): the chain goes through both.
        let m = try ChainTestDevice("M")
        try b.add(m, by: n)
        try b.next(author: a, list: [a.fingerprint, n.fingerprint, m.fingerprint, r],
                   parentList: [a.fingerprint, n.fingerprint, m.fingerprint, r])
        XCTAssertEqual(try b.verify().approverChain(of: m.fingerprint), [n.fingerprint, a.fingerprint])
        // Without the carried addition, the same removal introduces N: refused.
        var missing = b
        missing.entries[0].additions = []
        XCTAssertThrowsError(try missing.verify()) { XCTAssertEqual($0 as? ChainError, .authorNotListed(epoch: 2)) }
    }

    /// The negative chain cases of design §12 KH1.
    func testChainNegativeCases() throws {
        let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B"), y = try ChainTestDevice("Y")
        let z = try ChainTestDevice("Z")
        let r = KeyFingerprint.recovery(key: "age1pq1test-recovery")
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
        // An epoch signed by an unlisted key (Y is in no list), as its own author.
        var unlisted = good
        try unlisted.next(author: y, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertThrowsError(try unlisted.verify()) { XCTAssertEqual($0 as? ChainError, .authorNotListed(epoch: 2)) }
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
        try introRecovery.add(z, by: nil, claimedBy: bDev.id)   // rejected (self-signed, claims B), but Z's keys are known
        try introRecovery.next(author: a, reason: "recovery", list: [a.fingerprint, bDev.fingerprint, z.fingerprint],
                               parentList: [a.fingerprint, bDev.fingerprint, r], recovery: z.fingerprint)
        XCTAssertThrowsError(try introRecovery.verify()) { XCTAssertEqual($0 as? ChainError, .badRecovery(epoch: 2)) }
        // A recovery replacement may bring one new recovery key; a removal may not.
        let r2 = KeyFingerprint.recovery(key: "age1pq1test-recovery-2")
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
        // Review M2: `rejected` only in a resolve epoch (optional there: the simple fork rule); it is signed.
        var resolveWithout = good
        try resolveWithout.next(author: a, reason: "resolve", list: [a.fingerprint, bDev.fingerprint, r],
                                parentList: [a.fingerprint, bDev.fingerprint, r])
        XCTAssertNoThrow(try resolveWithout.verify(), "a resolve may reject nobody (it carries re-applied removals only)")
        var removeWith = good
        try removeWith.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r],
                            rejected: bDev.fingerprint)
        XCTAssertThrowsError(try removeWith.verify()) { XCTAssertEqual($0 as? ChainError, .badReason(epoch: 2)) }
        var resolve = good
        try resolve.next(author: a, reason: "resolve", list: [a.fingerprint, bDev.fingerprint, r],
                         parentList: [a.fingerprint, bDev.fingerprint, r], rejected: y.fingerprint)
        XCTAssertNoThrow(try resolve.verify())
        resolve.entries[1].rejected = z.fingerprint
        XCTAssertThrowsError(try resolve.verify()) { XCTAssertEqual($0 as? ChainError, .badEpochSig(epoch: 2)) }
        // An addedBy that is not the signer: the addition is rejected, and an epoch carrying it introduces a device.
        var wrongApprover = good
        try wrongApprover.add(z, by: bDev, claimedBy: a.id)
        try wrongApprover.next(author: a, list: [a.fingerprint, z.fingerprint, r],
                               parentList: [a.fingerprint, bDev.fingerprint, z.fingerprint, r])
        XCTAssertThrowsError(try wrongApprover.verify()) { XCTAssertEqual($0 as? ChainError, .introducesDevice(epoch: 2)) }
        // A self-signed entry that names an approver is not a kit join and not admitted.
        var selfClaim = good
        try selfClaim.add(z, by: nil, claimedBy: a.id)
        XCTAssertEqual(try selfClaim.verify().lists[0].rejected, [0])
        // An approver not yet admitted (listed after the entry it approved) is rejected; in order, admitted.
        let n = try ChainTestDevice("N"), m = try ChainTestDevice("M")
        var order = good
        try order.add(m, by: n)
        try order.add(n, by: a)
        XCTAssertEqual(try order.verify().lists[0].rejected, [0])
        var inOrder = good
        try inOrder.add(n, by: a)
        try inOrder.add(m, by: n)
        XCTAssertEqual(try inOrder.verify().lists[0].rejected, [])
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
        let r = KeyFingerprint.recovery(key: "age1pq1test-recovery")
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

    /// `Fixtures/epoch-chain-vectors.json` (design §12 KH1 negative vectors): a chain with a carried
    /// addition and a kit join, and the same chain broken five ways. Written by this test with
    /// `SEMPERE_WRITE_EPOCH_VECTORS=1`; web/test/epoch.test.ts checks every signature and link in it.
    func testChainVectors() throws {
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_EPOCH_VECTORS"] == "1" {
            let vaultId = try XCTUnwrap(UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c"))
            let a = try ChainTestDevice("A"), bDev = try ChainTestDevice("B"), n = try ChainTestDevice("N")
            let k = try ChainTestDevice("K"), y = try ChainTestDevice("Y"), z = try ChainTestDevice("Z")
            let r = KeyFingerprint.recovery(key: "age1pq1test-recovery")
            var base = try ChainTestBuilder(vaultId: vaultId, author: a, founders: [a.fingerprint, bDev.fingerprint, r])
            try base.add(n, by: a)
            try base.add(k, by: nil)
            let start = base
            var ok = start
            try ok.next(author: n, list: [a.fingerprint, n.fingerprint, r],
                        parentList: [a.fingerprint, bDev.fingerprint, n.fingerprint, k.fingerprint, r])
            var broken = start
            try broken.next(author: n, list: [a.fingerprint, n.fingerprint, r],
                            parentList: [a.fingerprint, bDev.fingerprint, n.fingerprint, k.fingerprint, r], linkFrom: .random())
            var unlisted = start
            try unlisted.next(author: y, list: [a.fingerprint, n.fingerprint, r],
                              parentList: [a.fingerprint, bDev.fingerprint, n.fingerprint, k.fingerprint, r])
            var wrongApprover = start
            try wrongApprover.add(z, by: bDev, claimedBy: a.id)
            try wrongApprover.next(author: a, list: [a.fingerprint, z.fingerprint, r],
                                   parentList: [a.fingerprint, bDev.fingerprint, z.fingerprint, r])
            var intro = start
            try intro.next(author: a, list: [a.fingerprint, bDev.fingerprint, y.fingerprint, r],
                           parentList: [a.fingerprint, bDev.fingerprint, r])
            let root = Hex.encode(ok.root)
            func c(_ name: String, _ b: ChainTestBuilder, root: String) -> ChainVectors.Case {
                .init(name: name, root: root, chain: b.entries,
                      expect: Self.outcome(b.entries, vaultId: vaultId, root: Self.unhex(root)))
            }
            let out = ChainVectors(
                description: "key-hierarchy design §4.1, §4.3, §12 KH1: chains of signed epochs (link, epochSig, carried "
                    + "additions with addSig). The first verifies (N added by A and K joined with the kit during epoch 1; "
                    + "epoch 2 by N removes B and K); the others are the negative vectors: a broken link, a wrong root, an "
                    + "epoch signed by an unlisted key, an addedBy that is not the signer, an epoch introducing a device. "
                    + "Device keys are the strings age1pq1test-<name>. Written by EpochChainTests.",
                vaultId: vaultId.uuidString.lowercased(),
                cases: [c("carried addition and kit join", ok, root: root), c("broken link", broken, root: root),
                        c("wrong root", ok, root: String(repeating: "11", count: 32)),
                        c("signature by an unlisted key", unlisted, root: root),
                        c("addedBy that is not the signer", wrongApprover, root: root),
                        c("epoch introducing a device", intro, root: root)])
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/epoch-chain-vectors.json")
            try (enc.encode(out) + Data("\n".utf8)).write(to: source)
        }
        let v = try JSONDecoder().decode(ChainVectors.self, from: Data(contentsOf: FixtureTests.bundled("epoch-chain-vectors.json")))
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        XCTAssertEqual(v.cases.map { $0.expect.split(separator: " ").first.map(String.init) ?? "" },
                       ["ok", "brokenLink:2", "notRooted", "authorNotListed:2", "introducesDevice:2", "introducesDevice:2"])
        for c in v.cases {
            XCTAssertEqual(Self.outcome(c.chain, vaultId: vaultId, root: Self.unhex(c.root)), c.expect, c.name)
        }
    }

    // MARK: - vault.json

    /// A signed `vault.json` for `b`'s last epoch: founder A, N approved by A at epoch 1, K a kit join
    /// at epoch 1, `extra` entries, and the recovery entry; written by `writer`.
    func manifest(_ b: ChainTestBuilder, a: ChainTestDevice, n: ChainTestDevice, k: ChainTestDevice,
                  recovery: MLKEM768X25519Identity, writer: ChainTestDevice? = nil,
                  extra: [EpochKeyEntry] = [], drop: Set<String> = []) throws -> EpochManifest {
        let e = b.entries[b.entries.count - 1]
        let key = b.keys[b.keys.count - 1]
        let entries = [try Self.entry(b.vaultId, a, by: a, addedBy: a.id, epoch: 1), try Self.entry(b.vaultId, n, by: a, addedBy: a.id, epoch: 1),
                       try Self.entry(b.vaultId, k, by: k, addedBy: EntryClaim.recovery, epoch: 1)]
            .filter { !drop.contains($0.key) } + extra
            + [EpochKeyEntry(role: .recovery, key: recovery.recipient.string, added: "2026-10-20T16:20:00Z", name: "Recovery kit",
                             wrap: try EpochKeyWrap.seal(key, vaultId: b.vaultId, epoch: e.epoch,
                                                         to: .mlkem768x25519(recovery.recipient)))]
        let zero = try XCTUnwrap(AuthorSignature(p256: Data(count: 64), mldsa65: Data(count: 3309)))
        var m = EpochManifest(format: "sempere/1", vaultId: b.vaultId, created: "2026-10-20T16:20:00Z", root: b.root,
                              epoch: e.epoch, epochId: key.epochId, parent: e.parent,
                              epochRecord: "epochs/" + EpochRecord.fileName(epoch: e.epoch, epochId: key.epochId),
                              epochRecordHash: Data(repeating: 7, count: 32), keys: entries, listTag: "", epochLink: e.link,
                              epochAuthor: String(Hex.encode(e.author.fingerprint).prefix(8)), epochSig: e.epochSig,
                              markersTag: "", author: (writer ?? a).id, authorSig: zero, features: [], label: nil,
                              reencryptPending: nil, parentList: e.parentList, epochReason: e.reason, rejected: e.rejected)
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
        let r = KeyFingerprint.recovery(key: recovery.recipient.string)
        let b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        let key = b.keys[0]
        let m = try manifest(b, a: a, n: n, k: k, recovery: recovery)
        let data = try JSONEncoder().encode(m)
        let read = try EpochManifest.parse(data)
        XCTAssertEqual(read, m)
        XCTAssertEqual(Set(read.firstList), [a.fingerprint, r], "the creator and the recovery key")
        let verified: Set<Data> = [a.fingerprint, r]
        let admitted = try read.check(key: key, verifiedList: verified)
        XCTAssertEqual(admitted.map(\.entry.key), [n.key, k.key])
        XCTAssertEqual(admitted.map(\.approver), [a.fingerprint, nil], "K is the one kit join")
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
        XCTAssertEqual(problem(try reSigned(2, signer: k, addedBy: a.id)), .addSig(key: k.key), "a kit join that claims iPad")
        XCTAssertEqual(problem(try reSigned(1, signer: x, addedBy: a.id)), .addSig(key: n.key), "signed by an unlisted device")
        XCTAssertEqual(problem(try reSigned(1, signer: a, addedBy: n.id)), .addSig(key: n.key), "addedBy not the signer")
        XCTAssertEqual(problem(try reSigned(1, signer: a, addedBy: EntryClaim.recovery)), .addSig(key: n.key))
        // An approval chain inside the epoch, listed in any order: M approved by N, N by A.
        let mDev = try ChainTestDevice("M")
        var chained = try manifest(b, a: a, n: n, k: k, recovery: recovery,
                                   extra: [try Self.entry(b.vaultId, mDev, by: n, addedBy: n.id, epoch: 1)])
        chained.keys.sort { $0.key > $1.key }
        XCTAssertEqual(Set(try Self.seal(m: &chained, key: key, writer: a).check(key: key, verifiedList: verified).map(\.entry.key)),
                       [n.key, k.key, mDev.key])

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
            ("rejected outside a resolve", { $0["rejected"] = String(repeating: "ab", count: 32) }),
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
        let r = KeyFingerprint.recovery(key: recovery.recipient.string)
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
        // The founder, no longer in the verified list (removed), comes back with its old self-signed entry.
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
        let r = KeyFingerprint.recovery(key: recovery.recipient.string)
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, r])
        try b.add(n, by: a)
        try b.add(k, by: nil)
        try b.next(author: n, list: [a.fingerprint, n.fingerprint, r],
                   parentList: [a.fingerprint, n.fingerprint, k.fingerprint, r])
        let m = try manifest(b, a: a, n: n, k: k, recovery: recovery, drop: [k.key])
        XCTAssertEqual(Set(m.firstList), [a.fingerprint, n.fingerprint, r])
        let pinned: Set<Data> = [a.fingerprint, n.fingerprint, k.fingerprint, r]
        XCTAssertEqual(try m.check(key: b.keys[1], verifiedList: Set(m.firstList), verifiedParentList: pinned).count, 0)
        // A device that never saw N added cannot take the epoch from vault.json alone.
        XCTAssertThrowsError(try m.check(key: b.keys[1], verifiedList: Set(m.firstList),
                                         verifiedParentList: [a.fingerprint, k.fingerprint, r]))
        // A forged parentList is refused: epochSig covers it.
        var forged = m; forged.parentList = [a.fingerprint, n.fingerprint, r]
        XCTAssertThrowsError(try Self.seal(m: &forged, key: b.keys[1], writer: a)
            .check(key: b.keys[1], verifiedList: Set(m.firstList), verifiedParentList: pinned)) {
            XCTAssertEqual(($0 as? EpochManifest.ProblemError)?.problem, .epochSig)
        }
    }

    // MARK: - Chain JSON

    func testChainEntryJSONRoundTripsAndIsStrict() throws {
        let a = try ChainTestDevice("A"), n = try ChainTestDevice("N")
        let r = KeyFingerprint.recovery(key: "age1pq1test-recovery")
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
        let r = KeyFingerprint.recovery(key: "age1pq1test-recovery")
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
        XCTAssertEqual(copy.path, "keys/recovery-\(Hex.encode(KeyFingerprint.recovery(key: identity.recipient.string))).key.age")
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
        let r = KeyFingerprint.recovery(key: recovery.recipient.string)
        var b = try ChainTestBuilder(author: a, founders: [a.fingerprint, bDev.fingerprint, c.fingerprint, r])
        try b.next(author: a, list: [a.fingerprint, bDev.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, c.fingerprint, r])
        try b.next(author: a, list: [a.fingerprint, r], parentList: [a.fingerprint, bDev.fingerprint, r])
        // The re-encryption replaces the recovery key (format.md §15.7).
        let recovery2 = try MLKEM768X25519Identity()
        let r2 = KeyFingerprint.recovery(key: recovery2.recipient.string)
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
        // Records 1 to 4 (4: a re-encryption, no parent key), an orphan 5, and a lost fork at 3.
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
