import Age
import Crypto
import Foundation
import XCTest
@testable import Sempere

/// The signed secret link and `sempere-trust/2` records (format.md §2.1;
/// security review 2026-10, R2).
final class SecretLinkTests: VaultTestCase {
    let a = pqIdentity(), b = pqIdentity(), x = pqIdentity()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "ML-DSA needs Apple OS 26 (always on Linux)")
    }

    // MARK: - Shared vectors (web/test/link.test.ts reads the same file)

    struct Vectors: Codable {
        struct Link: Codable { var by: String; var ed25519: String; var mldsa65: String }
        var description: String
        var vaultId: String, oldSecret: String, newSecret: String, secretIdNew: String, message: String
        var ed25519Seed: String, mldsa65Seed: String, ed25519PublicKey: String, mldsa65PublicKey: String
        var legacyLink: String
        var links: [Link]
    }

    static func unhex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func testSharedVectors() throws {
        let url = try FixtureTests.bundled("secret-link-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        let old = try VaultSecret(bytes: Self.unhex(v.oldSecret)), new = try VaultSecret(bytes: Self.unhex(v.newSecret))
        let id = try XCTUnwrap(UUID(uuidString: v.vaultId))
        XCTAssertEqual(Hex.encode(RecipientsAuth.secretId(new)), v.secretIdNew)
        XCTAssertEqual(Hex.encode(RecipientsAuth.linkMessage(to: new, vaultId: id)), v.message)
        let signing = try LinkSigningKeys(secret: old)
        XCTAssertEqual(Hex.encode(signing.ed25519.rawRepresentation), v.ed25519Seed)
        XCTAssertEqual(Hex.encode(signing.mldsa65Seed), v.mldsa65Seed)
        let keys = try LinkPublicKeys(secret: old)
        XCTAssertEqual(Hex.encode(keys.ed25519), v.ed25519PublicKey)
        XCTAssertEqual(Hex.encode(keys.mldsa65), v.mldsa65PublicKey, "FIPS 204 KeyGen_internal from the seed")
        XCTAssertEqual(RecipientsAuth.legacyLink(from: old, to: new, vaultId: id), .legacy(v.legacyLink))
        XCTAssertGreaterThanOrEqual(v.links.count, 2, "a link made by noble and one made by swift-crypto")
        for l in v.links {
            let link = SecretLink.signed(ed25519: Self.unhex(l.ed25519), mldsa65: Self.unhex(l.mldsa65))
            XCTAssertTrue(RecipientsAuth.verifyLink(link, keys: keys, to: new, vaultId: id), l.by)
            XCTAssertFalse(RecipientsAuth.verifyLink(link, keys: keys, to: old, vaultId: id), l.by)
        }
        // Our own link verifies too. Writing it into the source file (once,
        // by hand) lets the web tests check swift-crypto's signatures.
        let mine = try RecipientsAuth.link(from: old, to: new, vaultId: id)
        XCTAssertTrue(RecipientsAuth.verifyLink(mine, keys: keys, to: new, vaultId: id))
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_LINK_VECTORS"] == "1",
           case .signed(let ed, let ml) = mine {
            var out = v
            out.links.removeAll { $0.by == "swift-crypto" }
            out.links.append(.init(by: "swift-crypto", ed25519: Hex.encode(ed), mldsa65: Hex.encode(ml)))
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/secret-link-vectors.json")
            try (enc.encode(out) + Data("\n".utf8)).write(to: source)
        }
    }

    func testSizesAndEncoding() throws {
        let old = VaultSecret.random(), new = VaultSecret.random(), id = UUID()
        guard case .signed(let ed, let ml) = try RecipientsAuth.link(from: old, to: new, vaultId: id) else {
            return XCTFail("not signed")
        }
        XCTAssertEqual(ed.count, 64)
        XCTAssertEqual(ml.count, 3309)
        let keys = try LinkPublicKeys(secret: old)
        XCTAssertEqual(keys.ed25519.count, 32)
        XCTAssertEqual(keys.mldsa65.count, 1952)
        XCTAssertEqual(try LinkPublicKeys(secret: old), keys, "deterministic")
        XCTAssertNotEqual(try LinkPublicKeys(secret: new), keys)

        // Lowercase hex of exact sizes only; anything else reads as malformed.
        let good = #"{"ed25519":"\#(Hex.encode(ed))","mldsa65":"\#(Hex.encode(ml))"}"#
        XCTAssertEqual(try JSONDecoder().decode(SecretLink.self, from: Data(good.utf8)), .signed(ed25519: ed, mldsa65: ml))
        for bad in [#"{"ed25519":"\#(Hex.encode(ed))"}"#,
                    #"{"ed25519":"\#(Hex.encode(ed).uppercased())","mldsa65":"\#(Hex.encode(ml))"}"#,
                    #"{"ed25519":"\#(Hex.encode(ed))","mldsa65":"\#(Hex.encode(ml.dropLast()))"}"#,
                    "42", "[]", "true"] {
            XCTAssertEqual(try JSONDecoder().decode(SecretLink.self, from: Data(bad.utf8)), .malformed, bad)
        }
        XCTAssertEqual(try JSONDecoder().decode(SecretLink.self, from: Data(#""abc""#.utf8)), .legacy("abc"))
    }

    // MARK: - Forgery and mixed signatures

    /// R2: whoever reads a trust record (public keys only) cannot make a
    /// link the device accepts: not with keys of their own, not by reusing a
    /// real link for another secret, not as a legacy HMAC.
    func testTheRecordCannotForgeALink() throws {
        let store = MemoryRecipientsTrustStore()
        let made = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        let record = try XCTUnwrap(try store.record(for: made.vaultId))
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertEqual(record.format, "sempere-trust/2")
        XCTAssertTrue(json.contains("linkPublicKeys"))
        XCTAssertFalse(json.contains("linkKey"), "no symmetric key")
        let real = try made.requireSecret()

        let attacker = VaultSecret.random()
        let attempts: [SecretLink?] = [
            // Signed with keys of the attacker's own secret.
            try RecipientsAuth.link(from: .random(), to: attacker, vaultId: made.vaultId),
            try RecipientsAuth.link(from: attacker, to: attacker, vaultId: made.vaultId),
            // A legacy HMAC under every key the attacker could hold or guess.
            RecipientsAuth.legacyLink(from: attacker, to: attacker, vaultId: made.vaultId),
            .legacy(Hex.encode(RecipientsAuth.legacyLinkBytes(linkKey: RecipientsAuth.legacyLinkKey(real),
                                                                       to: attacker, vaultId: made.vaultId))),
            // A real link (old → real) replayed for the attacker's secret.
            try RecipientsAuth.link(from: real, to: .random(), vaultId: made.vaultId),
            .malformed, nil,
        ]
        for (i, link) in attempts.enumerated() {
            try forge(made.url, secret: attacker, adding: x.recipient, link: link)
            let v = try Vault.open(at: made.url, identities: [a], trust: store)
            XCTAssertEqual(v.recipientsStatus.problem?.reason, .secretUnconfirmed, "attempt \(i)")
            XCTAssertThrowsError(try v.requireWritable(), "attempt \(i)")
            XCTAssertEqual(try store.record(for: made.vaultId), record, "attempt \(i): the record never moves")
        }
    }

    /// Both signatures must verify: one valid signature with the other
    /// missing, wrong, from another message or from another key is refused.
    func testOneSignatureAloneIsRejected() throws {
        let old = VaultSecret.random(), new = VaultSecret.random(), other = VaultSecret.random(), id = UUID()
        let keys = try LinkPublicKeys(secret: old)
        guard case .signed(let ed, let ml) = try RecipientsAuth.link(from: old, to: new, vaultId: id),
              case .signed(let edOtherMessage, let mlOtherMessage) = try RecipientsAuth.link(from: old, to: other, vaultId: id),
              case .signed(let edOtherKey, let mlOtherKey) = try RecipientsAuth.link(from: other, to: new, vaultId: id)
        else { return XCTFail("not signed") }
        XCTAssertTrue(RecipientsAuth.verifyLink(.signed(ed25519: ed, mldsa65: ml), keys: keys, to: new, vaultId: id))
        var flipped = ml
        flipped[100] ^= 1
        let mixed: [(String, SecretLink)] = [
            ("Ed25519 + ML-DSA of another message", .signed(ed25519: ed, mldsa65: mlOtherMessage)),
            ("ML-DSA + Ed25519 of another message", .signed(ed25519: edOtherMessage, mldsa65: ml)),
            ("Ed25519 + ML-DSA by another key", .signed(ed25519: ed, mldsa65: mlOtherKey)),
            ("ML-DSA + Ed25519 by another key", .signed(ed25519: edOtherKey, mldsa65: ml)),
            ("Ed25519 + zero ML-DSA", .signed(ed25519: ed, mldsa65: Data(count: 3309))),
            ("ML-DSA + zero Ed25519", .signed(ed25519: Data(count: 64), mldsa65: ml)),
            ("Ed25519 + one flipped ML-DSA bit", .signed(ed25519: ed, mldsa65: flipped)),
            ("Ed25519 + empty ML-DSA", .signed(ed25519: ed, mldsa65: Data())),
            ("ML-DSA + empty Ed25519", .signed(ed25519: Data(), mldsa65: ml)),
        ]
        for (name, link) in mixed {
            XCTAssertFalse(RecipientsAuth.verifyLink(link, keys: keys, to: new, vaultId: id), name)
            XCTAssertFalse(RecipientsAuth.linkConnects(link, from: old, to: new, vaultId: id), name)
        }

        // The same through a vault: a rotation whose link lost one signature is unconfirmed.
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        let elsewhere = MemoryRecipientsTrustStore()
        try touch(vault.url, elsewhere)
        try vault.removeRecipient(b.recipient)
        guard case .signed(let goodEd, _)? = vault.manifest.secretLink else { return XCTFail("not signed") }
        try rewrite(vault.url) { $0.secretLink = .signed(ed25519: goodEd, mldsa65: Data(count: 3309)) }
        XCTAssertEqual(try Vault.open(at: vault.url, identities: [a], trust: elsewhere).recipientsStatus.problem?.reason,
                       .secretUnconfirmed)
    }

    // MARK: - Downgrades

    /// A device with a signed record never accepts a legacy (HMAC) link,
    /// even a genuine one, nor a vault with the feature stripped.
    func testASignedRecordRefusesLegacyLinks() throws {
        let store = MemoryRecipientsTrustStore()
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        let old = try vault.requireSecret()
        let record = try XCTUnwrap(try store.record(for: vault.vaultId))
        // A rotation as an old writer would make it: a genuine HMAC link, no feature.
        let new = VaultSecret.random()
        try rewrite(vault.url) { m in
            m.vaultSecret = String(decoding: try AgeFile.encrypt(new.bytes, to: [self.a.recipient, self.b.recipient],
                                                                 armor: true), as: UTF8.self)
            m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: new)
            m.secretLink = RecipientsAuth.legacyLink(from: old, to: new, vaultId: m.vaultId)
            m.features.removeAll { $0 == VaultManifest.signedLinkFeature }
            m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature }   // older than version markers
        }
        let v = try Vault.open(at: vault.url, identities: [a], trust: store)
        XCTAssertEqual(v.recipientsStatus.problem?.reason, .secretUnconfirmed)
        XCTAssertThrowsError(try v.requireWritable())
        XCTAssertEqual(try store.record(for: vault.vaultId), record)
        XCTAssertFalse(try XCTUnwrap(try store.record(for: vault.vaultId)).isLegacy, "never downgraded")
    }

    /// A legacy record confirms the same secret only: a rotation linked by a
    /// legacy HMAC, which whoever read that record could forge, is unconfirmed.
    func testALegacyRecordConfirmsOnlyTheSameSecret() throws {
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        let old = try vault.requireSecret()
        try makeLegacy(vault, store)
        let same = try Vault.open(at: vault.url, identities: [a], trust: store)
        XCTAssertEqual(same.recipientsStatus, .verified(.unchanged))
        XCTAssertTrue(try XCTUnwrap(try store.record(for: vault.vaultId)).isLegacy, "reading keeps the record as it is")
        XCTAssertEqual(same.secretLinkStatus.record, .legacy)
        XCTAssertTrue(same.secretLinkStatus.needsUpgrade)

        // Another device rotates (as an old writer would: legacy link).
        try vault.removeRecipient(b.recipient)
        let new = try vault.requireSecret()
        try rewrite(vault.url) { m in
            m.secretLink = RecipientsAuth.legacyLink(from: old, to: new, vaultId: m.vaultId)
            m.features.removeAll { $0 == VaultManifest.signedLinkFeature }
            m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature }   // older than version markers
        }
        let stale = MemoryRecipientsTrustStore()
        try stale.save(RecipientsTrustRecord(vaultId: vault.vaultId, anchor: .legacy(RecipientsAuth.legacyLinkKey(old)),
                                             recipients: [a.recipient.string, b.recipient.string]))
        var rotated = try Vault.open(at: vault.url, identities: [a], trust: stale)
        XCTAssertEqual(rotated.recipientsStatus.problem?.reason, .secretUnconfirmed)
        // The explicit confirmation is the way out, and writes a signed record.
        try rotated.confirmRecipients()
        let after = try XCTUnwrap(try stale.record(for: vault.vaultId))
        XCTAssertFalse(after.isLegacy)
        XCTAssertEqual(after.anchor, .signed(try LinkPublicKeys(secret: new)))
    }

    // MARK: - Migration

    /// The upgrade: a legacy record becomes a signed one, a legacy link is
    /// retired, the feature is added; a second run changes nothing; older
    /// writers then stop (unknown feature).
    func testUpgradeMigratesRecordAndVaultOnce() throws {
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        try vault.removeRecipient(b.recipient)
        let old = VaultSecret.random()
        try makeLegacy(vault, store, link: RecipientsAuth.legacyLink(from: old, to: try vault.requireSecret(),
                                                                       vaultId: vault.vaultId))
        var opened = try Vault.open(at: vault.url, identities: [a], trust: store)
        XCTAssertEqual(opened.secretLinkStatus, SecretLinkStatus(link: .legacy, featureListed: false, record: .legacy))
        let report = try opened.upgradeSecretLink()
        XCTAssertEqual(report, SecretLinkUpgrade(link: .retired, featureAdded: true, recordUpgraded: true))
        XCTAssertEqual(opened.secretLinkStatus, SecretLinkStatus(link: .none, featureListed: true, record: .signed))
        XCTAssertFalse(opened.secretLinkStatus.needsUpgrade)
        let onDisk = try VaultManifest.decode(Data(contentsOf: vault.url.appendingPathComponent("vault.json")))
        XCTAssertNil(onDisk.secretLink)
        XCTAssertTrue(onDisk.features.contains("signed-secret-link"))

        var again = try Vault.open(at: vault.url, identities: [a], trust: store)
        XCTAssertEqual(again.recipientsStatus, .verified(.unchanged))
        XCTAssertFalse(try again.upgradeSecretLink().changed)
        XCTAssertTrue(try again.verify().isHealthy)
    }

    /// A rotation that an older writer left unfinished: its journal's secret
    /// is linked by a legacy HMAC (which a reader holding both secrets may
    /// check). The upgrade re-signs that link, and the rewrap still resumes.
    func testUpgradeReSignsTheLinkOfAnUnfinishedRewrap() throws {
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        _ = try populate(vault)
        let outgoing = try vault.requireSecret()
        XCTAssertThrowsError(try vault.removeRecipient(b.recipient, policy: RewrapPolicy(), stopAfter: 0))
        let current = try vault.requireSecret()
        try makeLegacy(vault, store, link: RecipientsAuth.legacyLink(from: outgoing, to: current, vaultId: vault.vaultId))
        // The legacy record is at the outgoing secret (it never saw the rotation)...
        try store.save(RecipientsTrustRecord(vaultId: vault.vaultId, anchor: .legacy(RecipientsAuth.legacyLinkKey(outgoing)),
                                             recipients: [a.recipient.string, b.recipient.string]))
        XCTAssertEqual(try Vault.open(at: vault.url, identities: [a], trust: store).recipientsStatus.problem?.reason,
                       .secretUnconfirmed, "...so it cannot confirm the rotation")
        // ...while a device at the current secret upgrades the vault.
        let here = MemoryRecipientsTrustStore()
        var opened = try Vault.open(at: vault.url, identities: [a], trust: here)
        XCTAssertEqual(opened.previousSecret, outgoing, "the journal's secret, linked by the legacy HMAC")
        XCTAssertEqual(try opened.upgradeSecretLink().link, .reSigned)
        let link = try XCTUnwrap(VaultManifest.decode(Data(contentsOf: vault.url.appendingPathComponent("vault.json"))).secretLink)
        XCTAssertTrue(RecipientsAuth.verifyLink(link, keys: try LinkPublicKeys(secret: outgoing), to: current, vaultId: vault.vaultId))
        var resumed = try Vault.open(at: vault.url, identities: [a], trust: here)
        XCTAssertEqual(resumed.previousSecret, outgoing)
        XCTAssertTrue(try resumed.resumeRewrap().isComplete)
        XCTAssertTrue(try resumed.verify().isHealthy)
    }

    /// The upgrade refuses what `requireWritable` refuses, and a vault.json
    /// changed since it was opened.
    func testUpgradeRefusesTamperedAndChangedManifests() throws {
        let store = MemoryRecipientsTrustStore()
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        var opened = try Vault.open(at: vault.url, identities: [a], trust: store)
        try forge(vault.url, secret: .random(), adding: x.recipient, link: nil)
        XCTAssertThrowsError(try opened.upgradeSecretLink()) {
            guard case .manifestCorrupt = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        var tampered = try Vault.open(at: vault.url, identities: [a], trust: store)
        XCTAssertThrowsError(try tampered.upgradeSecretLink()) {
            guard case .untrustedRecipients = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    /// An untagged vault (written before §2.1) is tagged first, then marked.
    func testUpgradeTagsAnUntaggedVaultFirst() throws {
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a])
        try rewrite(vault.url) { m in
            m.recipientsTag = nil
            m.features = []
            m.markersTag = nil
        }
        let store = MemoryRecipientsTrustStore()
        var opened = try Vault.open(at: vault.url, identities: [a], trust: store)
        XCTAssertEqual(opened.recipientsStatus, .untagged)
        try opened.upgradeSecretLink()
        XCTAssertEqual(opened.recipientsStatus, .verified(.firstUse))
        XCTAssertNotNil(opened.manifest.recipientsTag)
        XCTAssertEqual(opened.secretLinkStatus, SecretLinkStatus(link: .none, featureListed: true, record: .signed))
        XCTAssertEqual(try Vault.open(at: vault.url, identities: [a], trust: store).recipientsStatus, .verified(.unchanged))
    }

    /// A non-rotating change (an addition) by a new writer also retires a
    /// legacy link and adds the feature.
    func testRecipientChangesWriteTheFeatureAndRetireLegacyLinks() throws {
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a], trust: store)
        try makeLegacy(vault, store, link: .legacy(String(repeating: "0", count: 64)))
        vault = try Vault.open(at: vault.url, identities: [a], trust: store)
        try vault.addRecipient(b.recipient, label: "B")
        XCTAssertNil(vault.manifest.secretLink)
        XCTAssertTrue(vault.manifest.features.contains("signed-secret-link"))
        XCTAssertFalse(try XCTUnwrap(try store.record(for: vault.vaultId)).isLegacy)
    }

    // MARK: - Helpers

    /// Opens as a device that writes, so it keeps a record.
    func touch(_ url: URL, _ store: MemoryRecipientsTrustStore) throws {
        try Vault.open(at: url, identities: [a], trust: store).requireWritable()
    }

    func rewrite(_ vault: URL, _ change: (inout VaultManifest) throws -> Void) throws {
        let url = vault.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: url))
        try change(&m)
        try m.encoded().write(to: url)
    }

    /// The attacker's own secret, encrypted to the listed keys and `adding`,
    /// tagged under it, with `link`.
    func forge(_ vault: URL, secret: VaultSecret, adding: NativeRecipient, link: SecretLink?) throws {
        try rewrite(vault) { m in
            if !m.recipients.contains(where: { $0.key == adding.string }) {
                m.recipients.append(.init(key: adding.string, label: "iPad", added: Date()))
            }
            let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
            m.vaultSecret = String(decoding: try AgeFile.encrypt(secret.bytes, to: keys, armor: true), as: UTF8.self)
            m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: secret)
            m.secretLink = link
        }
    }

    /// The vault and this device as written before signed links: no
    /// `signed-secret-link` feature, `link` (legacy), a `sempere-trust/1` record.
    func makeLegacy(_ vault: Vault, _ store: MemoryRecipientsTrustStore, link: SecretLink? = nil) throws {
        try rewrite(vault.url) { m in
            m.features.removeAll { $0 == VaultManifest.signedLinkFeature }
            m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature }   // older than version markers
            m.secretLink = link
        }
        try store.save(RecipientsTrustRecord(vaultId: vault.vaultId,
                                             anchor: .legacy(RecipientsAuth.legacyLinkKey(try vault.requireSecret())),
                                             recipients: vault.recipients.map(\.key)))
    }
}
