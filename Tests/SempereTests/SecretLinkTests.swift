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
                    "42", "[]", "true", #""abc""#, "\"\(String(repeating: "0", count: 64))\""] {
            XCTAssertEqual(try JSONDecoder().decode(SecretLink.self, from: Data(bad.utf8)), .malformed, bad)
        }
    }

    // MARK: - Forgery and mixed signatures

    /// R2: whoever reads a trust record (public keys only) cannot make a
    /// link the device accepts: not with keys of their own, not by reusing a
    /// real link for another secret, not in any other form.
    func testTheRecordCannotForgeALink() throws {
        let store = MemoryRecipientsTrustStore()
        let made = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        let record = try XCTUnwrap(try store.record(for: made.vaultId))
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertTrue(json.contains(#""format":"sempere-trust\/2""#) || json.contains(#""format":"sempere-trust/2""#), json)
        XCTAssertTrue(json.contains("linkPublicKeys"))
        XCTAssertFalse(json.contains("linkKey"), "no symmetric key")
        let real = try made.requireSecret()

        let attacker = VaultSecret.random()
        let attempts: [SecretLink?] = [
            // Signed with keys of the attacker's own secret.
            try RecipientsAuth.link(from: .random(), to: attacker, vaultId: made.vaultId),
            try RecipientsAuth.link(from: attacker, to: attacker, vaultId: made.vaultId),
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

    // MARK: - Other link forms

    /// A `secretLink` in any form but the two signatures (a JSON string
    /// included) reads as malformed: it never confirms a rotation, and a
    /// change that keeps the secret drops it.
    func testAnyOtherLinkFormIsMalformedAndDropped() throws {
        let store = MemoryRecipientsTrustStore(), elsewhere = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        try touch(vault.url, elsewhere)
        let old = try vault.requireSecret()
        try vault.removeRecipient(b.recipient)
        let url = vault.url.appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // An HMAC-shaped string, even one a holder of the old secret could make.
        let hmac = HMAC<SHA256>.authenticationCode(for: RecipientsAuth.linkMessage(to: try vault.requireSecret(),
                                                                                  vaultId: vault.vaultId),
                                                   using: SymmetricKey(data: old.bytes))
        obj["secretLink"] = Hex.encode(Data(hmac))
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        var opened = try Vault.open(at: vault.url, identities: [a], trust: store)
        XCTAssertEqual(opened.manifest.secretLink, .malformed)
        XCTAssertEqual(try Vault.open(at: vault.url, identities: [a], trust: elsewhere).recipientsStatus.problem?.reason,
                       .secretUnconfirmed, "a device that missed the rotation is not convinced by it")
        try opened.addRecipient(x.recipient, label: "X")
        XCTAssertNil(opened.manifest.secretLink, "a change that keeps the secret drops it")
        XCTAssertNil(try VaultManifest.decode(Data(contentsOf: url)).secretLink)
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
}
