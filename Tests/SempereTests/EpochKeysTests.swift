import Age
import Crypto
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// The key schedule of the key hierarchy (docs/design/key-hierarchy.md §2–§4,
/// phase KH1): `Sources/Sempere/EpochKeys.swift` against the shared vectors
/// `Fixtures/epoch-vectors.json` (written by web/scripts/make-epoch-vectors.ts;
/// web/test/epoch.test.ts reads the same file).
final class EpochKeysTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    // MARK: - Shared vectors

    struct Vectors: Codable {
        struct Device: Codable {
            var identity, recipient, signP256, signMLDSA65, fingerprint, id, captureFingerprint: String
        }
        struct Recovery: Codable { var recipient, fingerprint: String }
        struct Epoch: Codable {
            var epoch: Int
            var key, identitySeed, identity, recipient, tagKey, blobNameKey, listKey, markersKey, epochId, pendingKey: String
            var captureKey, linkEd25519Seed, linkMLDSA65Seed, ed25519PublicKey, mldsa65PublicKey, wrapPlaintext: String
        }
        struct Signed: Codable { var by, ed25519, mldsa65: String }
        struct Link: Codable { var epoch: Int; var message: String; var links: [Signed] }
        struct Entry: Codable {
            var role, key, id, signP256, signMLDSA65, kind, added, addedEpoch, addedBy, addSigP256, addSigMLDSA65: String
            var name, wrap: String
        }
        struct ListTag: Codable {
            var epoch: Int; var root, epochId, epochRecordHash: String; var entries: [Entry]; var message, tag: String
        }
        struct Wrap: Codable { var by: String; var epoch: Int; var armored: String }
        var description, vaultId: String
        var device: Device
        var recovery: Recovery
        var epochs: [Epoch]
        var root: String
        var link: Link
        var listTag: ListTag
        var wraps: [Wrap]
    }

    static func loadVectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: FixtureTests.bundled("epoch-vectors.json")))
    }

    static func unhex(_ s: String) -> Data { SecretLinkTests.unhex(s) }

    func key(_ e: Vectors.Epoch) throws -> VaultEpochKey { try VaultEpochKey(bytes: Self.unhex(e.key)) }

    func testDerivationsMatchTheVectors() throws {
        let v = try Self.loadVectors()
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        XCTAssertEqual(v.epochs.map(\.epoch), [1, 2])
        for e in v.epochs {
            let k = try key(e)
            let label = "epoch \(e.epoch)"
            XCTAssertEqual(Hex.encode(k.identitySeed), e.identitySeed, label)
            let identity = try k.vaultIdentity()
            XCTAssertEqual(identity.string, e.identity, label)
            XCTAssertEqual(identity.recipient.string, e.recipient, label)
            XCTAssertEqual(Hex.encode(k.tagKey), e.tagKey, label)
            XCTAssertEqual(Hex.encode(k.blobNameKey), e.blobNameKey, label)
            XCTAssertEqual(Hex.encode(k.listKey), e.listKey, label)
            XCTAssertEqual(Hex.encode(k.markersKey), e.markersKey, label)
            XCTAssertEqual(Hex.encode(k.epochId), e.epochId, label)
            XCTAssertEqual(Hex.encode(k.pendingKey), e.pendingKey, label)
            XCTAssertEqual(Hex.encode(k.captureKey(device: v.device.captureFingerprint).bytes), e.captureKey, label)
            let signing = try k.linkSigningKeys()
            XCTAssertEqual(Hex.encode(signing.ed25519.rawRepresentation), e.linkEd25519Seed, label)
            XCTAssertEqual(Hex.encode(signing.mldsa65Seed), e.linkMLDSA65Seed, label)
            let pub = try LinkPublicKeys(epochKey: k)
            XCTAssertEqual(Hex.encode(pub.ed25519), e.ed25519PublicKey, label)
            XCTAssertEqual(Hex.encode(pub.mldsa65), e.mldsa65PublicKey, label)
            XCTAssertEqual(try EpochKeyWrap.plaintext(k, vaultId: vaultId, epoch: e.epoch), e.wrapPlaintext, label)
            XCTAssertEqual(try EpochKeyWrap.parse(Data(e.wrapPlaintext.utf8), vaultId: vaultId, epoch: e.epoch), k, label)
        }
        // The vault identity and the epoch keys are not today's secret-link
        // keys of the same bytes: every label is new (design §2.2).
        let k1 = try key(v.epochs[0])
        XCTAssertNotEqual(try LinkPublicKeys(epochKey: k1), try LinkPublicKeys(secret: VaultSecret(bytes: k1.bytes)))
        XCTAssertEqual(v.device.captureFingerprint, CaptureKey.fingerprint(of: v.device.recipient))
    }

    func testFingerprintsMatchTheVectors() throws {
        let v = try Self.loadVectors()
        let d = v.device
        XCTAssertEqual(Hex.encode(KeyFingerprint.device(key: d.recipient, signP256: d.signP256, signMLDSA65: d.signMLDSA65)),
                       d.fingerprint)
        XCTAssertEqual(KeyFingerprint.deviceId(key: d.recipient, signP256: d.signP256, signMLDSA65: d.signMLDSA65), d.id)
        XCTAssertEqual(Hex.encode(KeyFingerprint.recovery(key: v.recovery.recipient)), v.recovery.fingerprint)
        // The signing keys are bound: another one changes the fingerprint, and
        // the domain prefixes keep a device and a recovery key apart.
        XCTAssertNotEqual(Hex.encode(KeyFingerprint.device(key: d.recipient, signP256: d.signP256 + "00",
                                                           signMLDSA65: d.signMLDSA65)), d.fingerprint)
        XCTAssertNotEqual(KeyFingerprint.device(key: d.recipient, signP256: "", signMLDSA65: ""),
                          KeyFingerprint.recovery(key: d.recipient))
        XCTAssertNotEqual(d.fingerprint, d.captureFingerprint, "format.md §11.1's fingerprint stays separate")
    }

    func testLPEncoding() {
        var m = LPMessage("p")
        m.field("ab"); m.field(12); m.field(Data())
        XCTAssertEqual([UInt8](m.bytes), [0x70, 0, 0, 0, 2, 0x61, 0x62, 0, 0, 0, 2, 0x31, 0x32, 0, 0, 0, 0])
    }

    func testRootMatchesTheVectors() throws {
        let v = try Self.loadVectors()
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        let k1 = try key(v.epochs[0]), k2 = try key(v.epochs[1])
        XCTAssertEqual(Hex.encode(try VaultRoot.fingerprint(vaultId: vaultId, epochOne: k1)), v.root)
        XCTAssertNotEqual(Hex.encode(try VaultRoot.fingerprint(vaultId: vaultId, epochOne: k2)), v.root)
        XCTAssertNotEqual(Hex.encode(try VaultRoot.fingerprint(vaultId: UUID(), epochOne: k1)), v.root)
        // Uppercase vault ids hash as lowercase (format.md §6).
        XCTAssertEqual(try VaultRoot.fingerprint(vaultId: vaultId, epochOne: k1).count, 32)
    }

    func testEpochLinksMatchTheVectors() throws {
        let v = try Self.loadVectors()
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        let k1 = try key(v.epochs[0]), k2 = try key(v.epochs[1])
        XCTAssertEqual(v.link.epoch, 2)
        XCTAssertEqual(Hex.encode(EpochLinks.message(vaultId: vaultId, epoch: 2, epochId: k2.epochId)), v.link.message)
        let parent = try LinkPublicKeys(epochKey: k1)
        XCTAssertGreaterThanOrEqual(v.link.links.count, 2, "a link made by noble and one made by swift-crypto")
        for l in v.link.links {
            let link = EpochLink.signed(ed25519: Self.unhex(l.ed25519), mldsa65: Self.unhex(l.mldsa65))
            XCTAssertTrue(EpochLinks.verify(link, keys: parent, epoch: 2, childEpochId: k2.epochId, vaultId: vaultId), l.by)
            XCTAssertFalse(EpochLinks.verify(link, keys: parent, epoch: 3, childEpochId: k2.epochId, vaultId: vaultId), l.by)
            XCTAssertFalse(EpochLinks.verify(link, keys: parent, epoch: 2, childEpochId: k1.epochId, vaultId: vaultId), l.by)
            XCTAssertFalse(EpochLinks.verify(link, keys: parent, epoch: 2, childEpochId: k2.epochId, vaultId: UUID()), l.by)
            XCTAssertFalse(EpochLinks.verify(link, keys: try LinkPublicKeys(epochKey: k2), epoch: 2,
                                             childEpochId: k2.epochId, vaultId: vaultId), l.by)
            // A secret link is a different message: the same signatures never verify as one.
            XCTAssertFalse(RecipientsAuth.verifyLink(link, keys: parent, to: try VaultSecret(bytes: k2.bytes), vaultId: vaultId))
        }
        let mine = try EpochLinks.link(from: k1, to: k2, epoch: 2, vaultId: vaultId)
        XCTAssertTrue(EpochLinks.verify(mine, keys: parent, epoch: 2, childEpochId: k2.epochId, vaultId: vaultId))
        XCTAssertThrowsError(try EpochLinks.link(from: k1, to: k2, epoch: 1, vaultId: vaultId))
        XCTAssertFalse(EpochLinks.verify(mine, keys: parent, epoch: 1, childEpochId: k2.epochId, vaultId: vaultId))
        XCTAssertFalse(EpochLinks.verify(.malformed, keys: parent, epoch: 2, childEpochId: k2.epochId, vaultId: vaultId))
        XCTAssertFalse(EpochLinks.verify(nil, keys: parent, epoch: 2, childEpochId: k2.epochId, vaultId: vaultId))
        // Both signatures must verify.
        if case .signed(let ed, let ml) = mine, case .signed(let ed2, let ml2) = try EpochLinks.link(
            from: k2, to: k1, epoch: 2, vaultId: vaultId) {
            for (name, mixed) in [("ML-DSA by another key", EpochLink.signed(ed25519: ed, mldsa65: ml2)),
                                  ("Ed25519 by another key", EpochLink.signed(ed25519: ed2, mldsa65: ml))] {
                XCTAssertFalse(EpochLinks.verify(mixed, keys: parent, epoch: 2, childEpochId: k2.epochId,
                                                 vaultId: vaultId), name)
            }
            if ProcessInfo.processInfo.environment["SEMPERE_WRITE_EPOCH_VECTORS"] == "1" {
                try updateVectors {
                    $0.link.links.removeAll { $0.by == "swift-crypto" }
                    $0.link.links.append(.init(by: "swift-crypto", ed25519: Hex.encode(ed), mldsa65: Hex.encode(ml)))
                }
            }
        } else {
            XCTFail("not signed")
        }
    }

    func testListTagMatchesTheVectors() throws {
        let v = try Self.loadVectors()
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        let t = v.listTag
        let k = try key(v.epochs[1])
        XCTAssertEqual(t.root, v.root)
        XCTAssertEqual(t.epochId, v.epochs[1].epochId)
        let entries = t.entries.map {
            EpochListEntry(role: $0.role, key: $0.key, id: $0.id, signP256: $0.signP256, signMLDSA65: $0.signMLDSA65,
                           kind: $0.kind, added: $0.added, addedEpoch: $0.addedEpoch, addedBy: $0.addedBy,
                           addSigP256: $0.addSigP256, addSigMLDSA65: $0.addSigMLDSA65, name: $0.name, wrap: $0.wrap)
        }
        XCTAssertEqual(entries[0].id, v.device.id)
        XCTAssertTrue(entries[0].name.unicodeScalars.contains { !$0.isASCII } && entries[0].name.contains("/")
                      && entries[0].name.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x2000 },
                      "the vector's name has non-ASCII, a slash and an emoji (review M2')")
        let message = EpochListTag.message(vaultId: vaultId, root: t.root, epoch: t.epoch, epochId: t.epochId,
                                           epochRecordHash: t.epochRecordHash, entries: entries)
        XCTAssertEqual(Hex.encode(message), t.message)
        XCTAssertEqual(EpochListTag.tag(key: k, vaultId: vaultId, root: t.root, epoch: t.epoch, epochId: t.epochId,
                                        epochRecordHash: t.epochRecordHash, entries: entries), t.tag)
        XCTAssertTrue(EpochListTag.verify(t.tag, key: k, vaultId: vaultId, root: t.root, epoch: t.epoch,
                                          epochId: t.epochId, epochRecordHash: t.epochRecordHash, entries: entries))
    }

    func testWrapsOpenAcrossImplementations() throws {
        let v = try Self.loadVectors()
        let vaultId = try XCTUnwrap(UUID(uuidString: v.vaultId))
        let device = try NativeIdentity(string: v.device.identity)
        XCTAssertEqual(device.recipient.string, v.device.recipient)
        let k2 = try key(v.epochs[1])
        XCTAssertTrue(Set(v.wraps.map(\.by)).isSuperset(of: ["typage", "swift"]), "wraps made by typage and by Swift")
        for w in v.wraps {
            XCTAssertEqual(try EpochKeyWrap.open(w.armored, with: [device], vaultId: vaultId, epoch: w.epoch), k2, w.by)
            XCTAssertThrowsError(try EpochKeyWrap.open(w.armored, with: [device], vaultId: vaultId, epoch: 1), w.by) {
                XCTAssertEqual($0 as? EpochKeyError, .wrapOtherEpoch)
            }
            XCTAssertThrowsError(try EpochKeyWrap.open(w.armored, with: [pqIdentity()], vaultId: vaultId, epoch: 2)) {
                XCTAssertEqual($0 as? EpochKeyError, .wrapUnreadable)
            }
            let file = Data(w.armored.utf8)
            let header = try AgeFile.parseHeader(try Armor.decode(file)).header
            XCTAssertEqual(header.stanzas.map(\.type), ["mlkem768x25519"], "one stanza (design §3)")
        }
        let mine = try EpochKeyWrap.seal(k2, vaultId: vaultId, epoch: 2, to: device.recipient)
        XCTAssertEqual(try EpochKeyWrap.open(mine, with: [device], vaultId: vaultId, epoch: 2), k2)
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_EPOCH_VECTORS"] == "1" {
            try updateVectors {
                $0.wraps.removeAll { $0.by == "swift" }
                $0.wraps.append(.init(by: "swift", epoch: 2, armored: mine))
            }
        }
    }

    /// Rewrites the source fixture (not the copy the test bundle was built
    /// with), so the two writers above do not undo each other.
    func updateVectors(_ change: (inout Vectors) -> Void) throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/epoch-vectors.json")
        var v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: source))
        change(&v)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try (enc.encode(v) + Data("\n".utf8)).write(to: source)
    }

    // MARK: - Wrap plaintext

    func testWrapPlaintextIsStrict() throws {
        let vaultId = UUID(), k = VaultEpochKey.random(), other = VaultEpochKey.random()
        let good = try EpochKeyWrap.plaintext(k, vaultId: vaultId, epoch: 3)
        XCTAssertEqual(try EpochKeyWrap.parse(Data(good.utf8), vaultId: vaultId, epoch: 3), k)
        let lines = good.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "# sempere vault key: vault \(vaultId.uuidString.lowercased()), epoch 3")
        let swapped = [lines[0], lines[1], try other.vaultIdentity().string].joined(separator: "\n") + "\n"
        XCTAssertThrowsError(try EpochKeyWrap.parse(Data(swapped.utf8), vaultId: vaultId, epoch: 3)) {
            XCTAssertEqual($0 as? EpochKeyError, .wrapIdentityMismatch)
        }
        XCTAssertThrowsError(try EpochKeyWrap.parse(Data(good.utf8), vaultId: vaultId, epoch: 4)) {
            XCTAssertEqual($0 as? EpochKeyError, .wrapOtherEpoch)
        }
        XCTAssertThrowsError(try EpochKeyWrap.parse(Data(good.utf8), vaultId: UUID(), epoch: 3)) {
            XCTAssertEqual($0 as? EpochKeyError, .wrapOtherEpoch)
        }
        let malformed = [
            String(good.dropLast()),                                     // no final newline
            good + "\n",                                                  // an extra line
            lines[1] + "\n" + lines[0] + "\n" + lines[2] + "\n",          // lines swapped
            good.replacingOccurrences(of: Hex.encode(k.bytes), with: Hex.encode(k.bytes).uppercased()),
            good.replacingOccurrences(of: Hex.encode(k.bytes), with: String(Hex.encode(k.bytes).dropLast(2))),
            good.replacingOccurrences(of: lines[2], with: lines[2].lowercased()),
            good.replacingOccurrences(of: "\n", with: "\r\n"),
            "", "\n", String(repeating: "#", count: 2000) + "\n",
        ]
        for (i, text) in malformed.enumerated() {
            XCTAssertThrowsError(try EpochKeyWrap.parse(Data(text.utf8), vaultId: vaultId, epoch: 3), "case \(i)") {
                XCTAssertEqual($0 as? EpochKeyError, .wrapMalformed, "case \(i)")
            }
        }
        XCTAssertThrowsError(try EpochKeyWrap.parse(Data([0xff, 0xfe, 0x0a]), vaultId: vaultId, epoch: 3))
        XCTAssertThrowsError(try EpochKeyWrap.plaintext(k, vaultId: vaultId, epoch: 0))
        XCTAssertThrowsError(try EpochKeyWrap.open(String(repeating: "a", count: EpochKeyWrap.maxWrapBytes + 1),
                                                   with: [pqIdentity()], vaultId: vaultId, epoch: 3)) {
            XCTAssertEqual($0 as? EpochKeyError, .wrapUnreadable)
        }
    }

    // MARK: - listTag

    func testListTagCoversEveryField() throws {
        let vaultId = UUID(), k = VaultEpochKey.random()
        let root = String(repeating: "ab", count: 32), id = String(repeating: "ef", count: 32)
        let hash = String(repeating: "cd", count: 32)
        let entry = EpochListEntry(role: "device", key: "age1pq1x", id: "a1b2c3d4", signP256: "04aa", signMLDSA65: "bb",
                                   kind: "ipad", added: "2026-10-04T16:20:00Z", addedEpoch: "1", addedBy: "e5f6a7b8",
                                   addSigP256: "cc", addSigMLDSA65: "dd", name: "Alex's iPad", wrap: "W")
        let recovery = EpochListEntry(role: "recovery", key: "age1pq1r", added: "2026-10-04T16:20:00Z",
                                      name: "Recovery kit", wrap: "R")
        let tag = EpochListTag.tag(key: k, vaultId: vaultId, root: root, epoch: 3, epochId: id, epochRecordHash: hash,
                                   entries: [entry, recovery])
        func verifies(_ entries: [EpochListEntry], root r: String = root, epoch: Int = 3, epochId: String = id,
                      hash h: String = hash, key: VaultEpochKey? = nil, vault: UUID? = nil) -> Bool {
            EpochListTag.verify(tag, key: key ?? k, vaultId: vault ?? vaultId, root: r, epoch: epoch, epochId: epochId,
                                epochRecordHash: h, entries: entries)
        }
        XCTAssertTrue(verifies([entry, recovery]))
        XCTAssertFalse(verifies([recovery, entry]), "order")
        XCTAssertFalse(verifies([entry]), "an entry dropped")
        XCTAssertFalse(verifies([entry, recovery], root: String(repeating: "ac", count: 32)))
        XCTAssertFalse(verifies([entry, recovery], epoch: 4))
        XCTAssertFalse(verifies([entry, recovery], epochId: String(repeating: "ee", count: 32)))
        XCTAssertFalse(verifies([entry, recovery], hash: String(repeating: "ce", count: 32)))
        XCTAssertFalse(verifies([entry, recovery], key: .random()))
        XCTAssertFalse(verifies([entry, recovery], vault: UUID()))
        let fields: [WritableKeyPath<EpochListEntry, String>] = [
            \.role, \.key, \.id, \.signP256, \.signMLDSA65, \.kind, \.added, \.addedEpoch, \.addedBy, \.addSigP256,
            \.addSigMLDSA65, \.name, \.wrap,
        ]
        for (i, field) in fields.enumerated() {
            var changed = entry
            changed[keyPath: field] += "x"
            XCTAssertFalse(verifies([changed, recovery]), "field \(i)")
            // lp() keeps field boundaries: moving a byte from one field to the next changes the message.
            if i + 1 < fields.count - 1 {
                var moved = entry
                moved[keyPath: fields[i + 1]] = String(moved[keyPath: field].suffix(1)) + moved[keyPath: fields[i + 1]]
                moved[keyPath: field] = String(moved[keyPath: field].dropLast())
                XCTAssertFalse(verifies([moved, recovery]), "boundary after field \(i)")
            }
            // A NUL is just a byte inside lp(): it never collides with a separator.
            var nul = entry
            nul[keyPath: field] += "\u{0}"
            XCTAssertFalse(verifies([nul, recovery]), "field \(i) with NUL")
        }
        XCTAssertFalse(EpochListTag.verify(tag.uppercased(), key: k, vaultId: vaultId, root: root, epoch: 3, epochId: id,
                                           epochRecordHash: hash, entries: [entry, recovery]))
        XCTAssertFalse(EpochListTag.verify("", key: k, vaultId: vaultId, root: root, epoch: 3, epochId: id,
                                           epochRecordHash: hash, entries: [entry, recovery]))
    }

    // MARK: - Trust record v3

    func testTrustRecordRoundTripsAndDecodesStrictly() throws {
        let vaultId = UUID(), k1 = VaultEpochKey.random(), k2 = VaultEpochKey.random()
        let root = try VaultRoot.fingerprint(vaultId: vaultId, epochOne: k1)
        let sign = try XCTUnwrap(EpochTrustRecord.SigningKeys(p256: Data(repeating: 4, count: 65),
                                                              mldsa65: Data(repeating: 7, count: 1952)))
        let fpA = Data(repeating: 0xa1, count: 32), fpR = Data(repeating: 0xb2, count: 32)
        let chain = [try EpochTrustRecord.ChainEpoch(epoch: 1, key: k1, parent: nil, list: [fpA, fpR]),
                     try EpochTrustRecord.ChainEpoch(epoch: 2, key: k2, parent: k1.epochId, list: [fpA])]
        let record = try EpochTrustRecord(
            vaultId: vaultId, root: root, chain: chain,
            list: [.init(role: "device", key: "age1pq1d", sign: sign, name: "Ñandú / ☕️"),
                   .init(role: "recovery", key: "age1pq1r", sign: nil, name: "Recovery kit")],
            markers: VaultMarkers(format: "sempere/1", features: []), reencryptFinished: true, rejectedAuthors: [fpA])
        XCTAssertEqual(record.pinned?.epochId, k2.epochId)
        XCTAssertEqual(record.pinned?.linkPublicKeys, try LinkPublicKeys(epochKey: k2))
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(EpochTrustRecord.self, from: data), record)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "sempere-trust/3")
        XCTAssertEqual(json["root"] as? String, Hex.encode(root))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertNil(text.range(of: Hex.encode(k1.bytes)), "no key in the record")
        XCTAssertNil(text.range(of: Hex.encode(k2.bytes)), "no key in the record")

        func mutate(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var o = json
            change(&o)
            return try JSONSerialization.data(withJSONObject: o)
        }
        func mutateChain(_ i: Int, _ change: @escaping (inout [String: Any]) -> Void) throws -> Data {
            try mutate {
                var c = $0["chain"] as? [[String: Any]] ?? []
                change(&c[i])
                $0["chain"] = c
            }
        }
        let bad: [(String, Data)] = [
            ("trust/2", try mutate { $0["format"] = "sempere-trust/2" }),
            ("no root", try mutate { $0["root"] = nil }),
            ("short root", try mutate { $0["root"] = "abcd" }),
            ("uppercase root", try mutate { $0["root"] = Hex.encode(root).uppercased() }),
            ("empty chain", try mutate { $0["chain"] = [Any]() }),
            ("chain from epoch 2", try mutate { $0["chain"] = Array(($0["chain"] as? [Any] ?? []).dropFirst()) }),
            ("epoch 1 with a parent", try mutateChain(0) { $0["parent"] = Hex.encode(k2.epochId) }),
            ("broken parent", try mutateChain(1) { $0["parent"] = Hex.encode(k2.epochId) }),
            ("missing parent", try mutateChain(1) { $0["parent"] = nil }),
            ("short epochId", try mutateChain(1) { $0["epochId"] = "00" }),
            ("short fingerprint", try mutateChain(1) { $0["list"] = ["00"] }),
            ("short link key", try mutateChain(0) { $0["linkPublicKeys"] = ["ed25519": "00", "mldsa65": "00"] }),
            ("no list", try mutate { $0["list"] = nil }),
            ("short rejected author", try mutate { $0["rejectedAuthors"] = ["00"] }),
            ("short p256", try mutate {
                var list = $0["list"] as? [[String: Any]] ?? []
                list[0]["sign"] = ["p256": "04", "mldsa65": Hex.encode(sign.mldsa65)]
                $0["list"] = list
            }),
        ]
        for (name, data) in bad {
            XCTAssertThrowsError(try JSONDecoder().decode(EpochTrustRecord.self, from: data), name)
        }
        let markers = VaultMarkers(format: "sempere/1", features: [])
        XCTAssertThrowsError(try EpochTrustRecord(vaultId: vaultId, root: root, chain: [], list: [], markers: markers))
        XCTAssertThrowsError(try EpochTrustRecord(vaultId: vaultId, root: root, chain: [chain[1]], list: [], markers: markers))
        XCTAssertThrowsError(try EpochTrustRecord(vaultId: vaultId, root: Data(count: 31), chain: chain, list: [],
                                                  markers: markers))
    }

    // MARK: - Stock age

    /// Design §2.1, §3 and the KH1 gate: a file to `v_e` opens with stock
    /// `age -d -i` and the wrap's plaintext, which `age -d -i <device key>`
    /// takes out of the wrap. Needs `age` 1.3+ (CI sets SEMPERE_REQUIRE_AGE_PQ).
    func testStockAgeOpensTheWrapAndFilesToTheVaultIdentity() throws {
        let required = ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil
        guard let age = ExternalTool.find("age") else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is not on PATH") }
            throw XCTSkip("age not on PATH")
        }
        let version = String(decoding: try ExternalTool.run(age, ["--version"]).out, as: UTF8.self)
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
            .split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3) else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is \(version)") }
            throw XCTSkip("age \(version) predates post-quantum recipients (needs 1.3)")
        }
        let vaultId = UUID(), k = VaultEpochKey.random(), device = pqIdentity()
        let deviceFile = tmp.appendingPathComponent("device.txt")
        try IdentityFile.render(device, created: Date()).write(to: deviceFile, atomically: true, encoding: .utf8)
        let wrapFile = tmp.appendingPathComponent("wrap.age")
        try Data(try EpochKeyWrap.seal(k, vaultId: vaultId, epoch: 5, to: device.recipient).utf8).write(to: wrapFile)

        let unwrapped = try ExternalTool.run(age, ["-d", "-i", deviceFile.path, wrapFile.path])
        XCTAssertEqual(unwrapped.status, 0, unwrapped.errText)
        XCTAssertEqual(String(decoding: unwrapped.out, as: UTF8.self), try EpochKeyWrap.plaintext(k, vaultId: vaultId, epoch: 5))
        let keysFile = tmp.appendingPathComponent("vault-keys.txt")
        try unwrapped.out.write(to: keysFile)

        let body = Data("a note body".utf8)
        let noteFile = tmp.appendingPathComponent("note.age")
        try AgeFile.encrypt(body, to: [try k.vaultIdentity().recipient]).write(to: noteFile)
        let read = try ExternalTool.run(age, ["-d", "-i", keysFile.path, noteFile.path])
        XCTAssertEqual(read.status, 0, read.errText)
        XCTAssertEqual(read.out, body)
    }
}
