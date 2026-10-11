import Age
import Crypto
import Foundation
import XCTest
@testable import Sempere

/// The ways an attacker who can write the vault folder (but holds no key)
/// may change vault.json's recipients (format.md §2.1).
enum RecipientsTamper: String, CaseIterable {
    case addedRecipient, removedRecipient, reordered, tagStripped, tagFromAnotherVault, secretReplaced

    /// Rewrites `vault`'s vault.json. The vault must list at least two keys;
    /// `attacker` is the key an attacker adds, `other` another vault's manifest.
    func apply(to vault: URL, attacker: NativeRecipient, other: VaultManifest) throws {
        let url = vault.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: url))
        switch self {
        case .addedRecipient:
            m.recipients.append(.init(key: attacker.string, label: "Anthony's new iPad", added: Date()))
        case .removedRecipient:
            m.recipients.removeLast()
        case .reordered:
            m.recipients.reverse()
        case .tagStripped:
            m.recipientsTag = nil
        case .tagFromAnotherVault:
            m.recipientsTag = other.recipientsTag
        case .secretReplaced:
            // A secret of the attacker's own, encrypted to every listed key
            // and theirs, with a tag that verifies under it.
            let forged = VaultSecret.random()
            m.recipients.append(.init(key: attacker.string, label: "iPad", added: Date()))
            let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
            m.vaultSecret = String(decoding: try AgeFile.encrypt(forged.bytes, to: keys, armor: true), as: UTF8.self)
            m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: forged)
            m.secretLink = .legacy(String(repeating: "0", count: 64))
            m.tagMarkers(secret: forged)   // the markers re-tagged under it too
        }
        try m.encoded().write(to: url)
    }
}

final class RecipientsAuthTests: VaultTestCase {
    let a = pqIdentity(), b = pqIdentity(), x = pqIdentity()

    /// A vault of A and B with two notes, opened as device A (with a trust
    /// record), and another vault's manifest for `tagFromAnotherVault`.
    func setUpVault(store: MemoryRecipientsTrustStore) throws -> (Vault, [Revision], VaultManifest) {
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["A", "B"],
                                     identities: [a], trust: store)
        let revs = try populate(vault)
        let other = try Vault.create(at: vaultURL("Other"), recipients: [a.recipient, b.recipient], identities: [a])
        return (vault, revs, other.manifest)
    }

    func open(_ url: URL, _ store: MemoryRecipientsTrustStore?, _ ids: [NativeIdentity]? = nil) throws -> Vault {
        try Vault.open(at: url, identities: ids ?? [a], trust: store)
    }

    /// Opens as a device that then writes: only writers keep a trust record
    /// (format.md §2.1), and `requireWritable` is where they save it.
    func touch(_ url: URL, _ store: MemoryRecipientsTrustStore, _ ids: [NativeIdentity]) throws {
        let v = try open(url, store, ids)
        XCTAssertEqual(v.recipientsStatus, .verified(.firstUse))
        XCTAssertNil(try store.record(for: v.vaultId), "reading keeps no record")
        try v.requireWritable()
        XCTAssertNotNil(try store.record(for: v.vaultId))
    }

    // MARK: - Tag

    func testTagIsHMACOverVaultIdAndKeysInOrder() throws {
        let secret = VaultSecret.random()
        let id = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
        let keys = [a.recipient.string, b.recipient.string]
        // format.md §2.1, computed independently of RecipientsAuth.
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret.bytes),
                                         info: Data("sempere/1 recipients key".utf8), outputByteCount: 32)
        var message = Data("sempere/1\0recipients\00d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c".utf8)
        for k in keys { message.append(0); message.append(contentsOf: k.utf8) }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(RecipientsAuth.tag(vaultId: id, keys: keys, secret: secret), expected)
        XCTAssertTrue(RecipientsAuth.verifyTag(expected, vaultId: id, keys: keys, secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyTag(expected, vaultId: id, keys: keys.reversed(), secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyTag(expected, vaultId: UUID(), keys: keys, secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyTag(expected, vaultId: id, keys: keys, secret: .random()))
        XCTAssertFalse(RecipientsAuth.verifyTag(expected.uppercased(), vaultId: id, keys: keys, secret: secret), "lowercase hex only")
        XCTAssertFalse(RecipientsAuth.verifyTag(String(expected.dropLast()), vaultId: id, keys: keys, secret: secret))

        // The link: both signatures by the old secret's keys over the new secret's id.
        let old = VaultSecret.random(), new = VaultSecret.random()
        let link = try RecipientsAuth.link(from: old, to: new, vaultId: id)
        XCTAssertTrue(RecipientsAuth.verifyLink(link, keys: try LinkPublicKeys(secret: old), to: new, vaultId: id))
        XCTAssertFalse(RecipientsAuth.verifyLink(link, keys: try LinkPublicKeys(secret: new), to: new, vaultId: id))
        XCTAssertFalse(RecipientsAuth.verifyLink(link, keys: try LinkPublicKeys(secret: old), to: .random(), vaultId: id))
        XCTAssertFalse(RecipientsAuth.verifyLink(link, keys: try LinkPublicKeys(secret: old), to: new, vaultId: UUID()))
    }

    /// Shared with web/test/vault.test.ts.
    func testKnownAnswerVector() throws {
        let secret = try VaultSecret(bytes: Data((1...32).map { UInt8($0) }))
        let id = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
        XCTAssertEqual(RecipientsAuth.tag(vaultId: id, keys: ["age1pq1example0", "age1pq1example1"], secret: secret),
                       "548c16534c81b7cfb1c92c574380129377d3616b02b631d9fa99bf6356b63c0c")
    }

    func testEveryRecipientChangeWritesTagFeatureAndLink() throws {
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a], trust: store)
        XCTAssertEqual(vault.manifest.features, ["recipients-tag", "signed-secret-link", "markers-tag"])
        XCTAssertNil(vault.manifest.secretLink)
        XCTAssertEqual(try open(vault.url, store).recipientsStatus, .verified(.unchanged))
        XCTAssertEqual(try open(vault.url, nil).recipientsStatus, .verified(.firstUse))
        _ = try populate(vault)

        try vault.addRecipient(b.recipient, label: "B")
        XCTAssertNil(vault.manifest.secretLink, "an addition keeps the secret: no link")
        XCTAssertEqual(try open(vault.url, store).recipientsStatus, .verified(.unchanged))

        let before = try XCTUnwrap(vault.secret)
        try vault.removeRecipient(b.recipient)
        let link = try XCTUnwrap(vault.manifest.secretLink)
        XCTAssertTrue(RecipientsAuth.verifyLink(link, keys: try LinkPublicKeys(secret: before), to: try XCTUnwrap(vault.secret),
                                                vaultId: vault.vaultId))
        XCTAssertEqual(try open(vault.url, store).recipientsStatus, .verified(.unchanged), "this device remembered the rotation")

        let c = pqIdentity()
        try vault.replaceRecipient(a.recipient, with: c.recipient)
        XCTAssertEqual(try open(vault.url, store, [c]).recipientsStatus, .verified(.unchanged))
        XCTAssertTrue(try open(vault.url, store, [c]).verify().isHealthy)
    }

    /// A device that saw the secret before a rotation made elsewhere accepts
    /// it through `secretLink`, even when the rotation added a key (replace).
    func testAnotherDeviceConfirmsARotationThroughTheLink() throws {
        let deviceA = MemoryRecipientsTrustStore(), deviceB = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: deviceA)
        _ = try populate(vault)
        try touch(vault.url, deviceB, [b])
        let c = pqIdentity()
        try vault.replaceRecipient(a.recipient, with: c.recipient, label: "C")
        XCTAssertEqual(try open(vault.url, deviceB, [b]).recipientsStatus, .verified(.rotated))
        try open(vault.url, deviceB, [b]).requireWritable()
        XCTAssertEqual(try open(vault.url, deviceB, [b]).recipientsStatus, .verified(.unchanged), "the record moved on")

        // Two rotations missed, the second adding a key: unconfirmed.
        let deviceStale = MemoryRecipientsTrustStore()
        try touch(vault.url, deviceStale, [b])
        let d = pqIdentity(), e = pqIdentity()
        var v2 = try open(vault.url, deviceB, [b])
        try v2.addRecipient(d.recipient, label: "D")
        try v2.removeRecipient(c.recipient)
        try v2.replaceRecipient(d.recipient, with: e.recipient)
        var stale = try open(vault.url, deviceStale, [b])
        XCTAssertEqual(stale.recipientsStatus.problem?.reason, .secretUnconfirmed)
        XCTAssertEqual(stale.recipientsStatus.problem?.unexpected, [e.recipient.string])
        XCTAssertThrowsError(try stale.repairRecipients()) {
            guard case .recipientsNotRepairable = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        try stale.confirmRecipients()
        XCTAssertEqual(try open(vault.url, deviceStale, [b]).recipientsStatus, .verified(.unchanged))

        // Missed rotations that only removed keys: still unconfirmed (the
        // secret cannot be told from an attacker's), until confirmed.
        let deviceOld = MemoryRecipientsTrustStore()
        try touch(vault.url, deviceOld, [b])
        var v3 = try open(vault.url, deviceB, [b])
        let f = pqIdentity(), g = pqIdentity()
        try v3.addRecipient(f.recipient, label: "F")
        try v3.addRecipient(g.recipient, label: "G")
        let pre = try open(vault.url, deviceOld, [b])
        XCTAssertEqual(pre.recipientsStatus.problem?.reason, nil, "additions keep the secret: verified")
        try v3.removeRecipient(f.recipient)
        try v3.removeRecipient(g.recipient)
        var old = try open(vault.url, deviceOld, [b])
        XCTAssertEqual(old.recipientsStatus.problem?.reason, .secretUnconfirmed)
        XCTAssertEqual(old.recipientsStatus.problem?.unexpected, [])
        XCTAssertThrowsError(try old.requireWritable())
        try old.confirmRecipients()
        XCTAssertEqual(try open(vault.url, deviceOld, [b]).recipientsStatus, .verified(.unchanged))
    }

    /// Regression: a secret replaced without adding a key must not count as
    /// verified. If it did, the device would move its record to the
    /// attacker's secret, and a second forgery adding the attacker's key with
    /// a `secretLink` made under that secret would verify as a rotation.
    func testAReplacedSecretWithOnlyKnownKeysIsNotAStepToAddingOne() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, _, _) = try setUpVault(store: store)
        let url = made.url.appendingPathComponent("vault.json")
        let recordBefore = try XCTUnwrap(try store.record(for: made.vaultId))

        // Step 1: the attacker's secret S1, the same keys, a tag under S1.
        let s1 = VaultSecret.random()
        var m = try VaultManifest.decode(Data(contentsOf: url))
        let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
        m.vaultSecret = String(decoding: try AgeFile.encrypt(s1.bytes, to: keys, armor: true), as: UTF8.self)
        m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: s1)
        m.secretLink = nil
        try m.encoded().write(to: url)

        let step1 = try open(made.url, store)
        XCTAssertEqual(step1.recipientsStatus.problem?.reason, .secretUnconfirmed)
        XCTAssertThrowsError(try step1.requireWritable()) {
            guard case .untrustedRecipients = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try store.record(for: made.vaultId), recordBefore, "the record never moves to an unconfirmed secret")

        // Step 2: S2 to the listed keys and the attacker's, linked from S1.
        let s2 = VaultSecret.random()
        m.recipients.append(.init(key: x.recipient.string, label: "iPad", added: Date()))
        let all = try m.recipients.map { try NativeRecipient(string: $0.key) }
        m.vaultSecret = String(decoding: try AgeFile.encrypt(s2.bytes, to: all, armor: true), as: UTF8.self)
        m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: s2)
        m.secretLink = try RecipientsAuth.link(from: s1, to: s2, vaultId: m.vaultId)
        try m.encoded().write(to: url)

        let step2 = try open(made.url, store)
        XCTAssertEqual(step2.recipientsStatus.problem?.reason, .secretUnconfirmed)
        XCTAssertEqual(step2.recipientsStatus.problem?.unexpected, [x.recipient.string])
        XCTAssertThrowsError(try step2.requireWritable())
        XCTAssertEqual(try store.record(for: made.vaultId), recordBefore)
    }

    /// Security review 2026-10 (R1): the subset search must not run under a
    /// secret this device cannot link to its record. An attacker's secret
    /// with a tag over the real keys plus one of theirs, and a second key of
    /// theirs that fails the tag, would otherwise make a one-tap repair keep
    /// the first attacker key (reported as nothing unexpected) and rewrap
    /// every note to it.
    func testSubsetSearchNeverRunsUnderAnUnconfirmedSecret() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, _, _) = try setUpVault(store: store)
        let url = made.url.appendingPathComponent("vault.json")
        let y = pqIdentity()
        let forged = VaultSecret.random()
        var m = try VaultManifest.decode(Data(contentsOf: url))
        m.recipients.append(.init(key: x.recipient.string, label: "iPad", added: Date()))
        let tagged = m.recipients.map(\.key)
        m.recipients.append(.init(key: y.recipient.string, label: "Mac", added: Date()))
        let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
        m.vaultSecret = String(decoding: try AgeFile.encrypt(forged.bytes, to: keys, armor: true), as: UTF8.self)
        m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: tagged, secret: forged)
        try m.encoded().write(to: url)

        var vault = try open(made.url, store)
        let problem = try XCTUnwrap(vault.recipientsStatus.problem)
        XCTAssertEqual(problem.reason, .secretUnconfirmed)
        XCTAssertNil(problem.restore)
        XCTAssertEqual(Set(problem.unexpected), [x.recipient.string, y.recipient.string])
        XCTAssertThrowsError(try vault.repairRecipients()) {
            guard case .recipientsNotRepairable = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try vault.confirmRecipients(), "the tag does not verify under it")
    }

    /// Security review 2026-10 (R3): a replaced secret with the tag stripped
    /// (or bogus) is an unconfirmed secret, not a removed tag: it can be
    /// neither confirmed (which moved the record to the attacker's secret)
    /// nor repaired (which adopted it as the outgoing secret).
    func testAReplacedSecretWithTheTagStrippedIsNeitherConfirmedNorRepaired() throws {
        for bogus in [nil, String(repeating: "0", count: 64)] {
            try FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let store = MemoryRecipientsTrustStore()
            let (made, _, _) = try setUpVault(store: store)
            let recordBefore = try XCTUnwrap(try store.record(for: made.vaultId))
            let url = made.url.appendingPathComponent("vault.json")
            var m = try VaultManifest.decode(Data(contentsOf: url))
            let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
            m.vaultSecret = String(decoding: try AgeFile.encrypt(VaultSecret.random().bytes, to: keys, armor: true), as: UTF8.self)
            m.recipientsTag = bogus
            m.secretLink = nil
            try m.encoded().write(to: url)

            var vault = try open(made.url, store)
            XCTAssertEqual(vault.recipientsStatus.problem?.reason, .secretUnconfirmed, "\(String(describing: bogus))")
            XCTAssertThrowsError(try vault.confirmRecipients())
            XCTAssertThrowsError(try vault.repairRecipients(keeping: [a.recipient.string, b.recipient.string]))
            XCTAssertEqual(try store.record(for: made.vaultId), recordBefore, "the record never moves to an unconfirmed secret")
        }
    }

    /// Security review 2026-10 (R4, W1): `rewrap-journal.json` is plaintext
    /// anyone who can write the folder (or a sync server) can plant, with a
    /// secret of their own encrypted to the public keys. Files tagged under
    /// it would verify, and a resumed rewrap would re-tag them under the
    /// real secret. Its secret counts only when vault.json binds the journal
    /// (`rewrapPending`) and `secretLink` links it to the current one.
    func testAPlantedJournalSecretIsNotAccepted() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, _, _) = try setUpVault(store: store)
        let journal = made.url.appendingPathComponent("rewrap-journal.json")
        func plant(_ secret: VaultSecret) throws {
            let armored = String(decoding: try AgeFile.encrypt(secret.bytes, to: [a.recipient, b.recipient], armor: true),
                                 as: UTF8.self)
            let json = try JSONSerialization.data(withJSONObject: ["format": "sempere/1", "previousVaultSecret": armored])
            try json.write(to: journal)
        }
        try plant(VaultSecret.random())
        var vault = try open(made.url, store)
        XCTAssertTrue(vault.pendingRewrap)
        XCTAssertNil(vault.previousSecret, "a secret nothing links to is not accepted")
        XCTAssertNotNil(vault.journalProblem)
        XCTAssertThrowsError(try vault.resumeRewrap())

        // Nor is the current one: a journal vault.json does not bind (a change
        // interrupted before step 2 changed nothing) counts for nothing (S0).
        try plant(try made.requireSecret())
        vault = try open(made.url, store)
        XCTAssertNil(vault.previousSecret)
        XCTAssertTrue(vault.journalRefused)

        // A real rotation interrupted after vault.json: linked, accepted.
        try FileManager.default.removeItem(at: journal)
        var rotating = try open(made.url, store)
        let outgoing = try rotating.requireSecret()
        XCTAssertThrowsError(try rotating.removeRecipient(b.recipient, policy: RewrapPolicy(), stopAfter: 0))
        let resumed = try open(made.url, store)
        XCTAssertEqual(resumed.previousSecret, outgoing)
        XCTAssertNil(resumed.journalProblem)
    }

    // MARK: - Tamper fixtures

    /// Each tamper, seen by the device that made the vault (it has a trust
    /// record): writes refused, reads work, the right keys reported.
    func testTamperedListsAreRefusedForWritingAndStillRead() throws {
        for kind in RecipientsTamper.allCases {
            try FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let store = MemoryRecipientsTrustStore()
            let (made, revs, other) = try setUpVault(store: store)
            try kind.apply(to: made.url, attacker: x.recipient, other: other)
            var vault = try open(made.url, store)
            let problem = try XCTUnwrap(vault.recipientsStatus.problem, "\(kind)")
            let expected: (RecipientsProblem.Reason, [String], [String]) = switch kind {
            case .addedRecipient: (.tagMismatch, [x.recipient.string], [])
            case .removedRecipient: (.tagMismatch, [], [b.recipient.string])
            case .reordered, .tagFromAnotherVault: (.tagMismatch, [], [])
            case .tagStripped: (.tagRemoved, [], [])
            case .secretReplaced: (.secretUnconfirmed, [x.recipient.string], [])
            }
            XCTAssertEqual(problem.reason, expected.0, "\(kind)")
            XCTAssertEqual(problem.unexpected, expected.1, "\(kind)")
            XCTAssertEqual(problem.missing, expected.2, "\(kind)")

            // Nothing is encrypted to the list.
            func refused(_ what: String, _ body: () throws -> Void) {
                XCTAssertThrowsError(try body(), "\(kind): \(what)") {
                    guard case .untrustedRecipients = $0 as? VaultError else { return XCTFail("\(kind) \(what): \($0)") }
                }
            }
            var log = LogBuilder()
            refused("write") { try vault.write(log.delta(devC, 50, [.setMeta(.title("x"))])) }
            refused("blob") { _ = try vault.writeBlob(note: testNote, Data("x".utf8), type: "image/png") }
            refused("profile") { _ = try vault.captureProfile(device: devC) }
            refused("add") { try vault.addRecipient(pqIdentity().recipient, label: "") }
            refused("remove") { try vault.removeRecipient(a.recipient) }
            XCTAssertFalse(try vault.upgradeRecipientsTag(), "never upgraded")
            XCTAssertFalse(vault.verify().isHealthy, "\(kind)")
            XCTAssertEqual(vault.verify().recipients, vault.recipientsStatus)

            // Reading still works (except under a replaced secret, whose
            // tags no longer match: reported, never trusted).
            if kind == .secretReplaced {
                XCTAssertThrowsError(try vault.readRevision(noteId: revs[0].noteId, name: revs[0].name))
            } else {
                XCTAssertEqual(try vault.readRevision(noteId: revs[0].noteId, name: revs[0].name), revs[0], "\(kind)")
            }
        }
    }

    /// The same tampers seen by a device that never opened the vault (no
    /// trust record): the tag still catches all but a replaced secret,
    /// which first use cannot tell from the real one (format.md §2.1 "Limits").
    func testTamperWithoutATrustRecord() throws {
        for kind in RecipientsTamper.allCases {
            try FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (made, _, other) = try setUpVault(store: MemoryRecipientsTrustStore())
            try kind.apply(to: made.url, attacker: x.recipient, other: other)
            let fresh = MemoryRecipientsTrustStore()
            let vault = try open(made.url, fresh, [b])
            switch kind {
            case .secretReplaced:
                XCTAssertEqual(vault.recipientsStatus, .verified(.firstUse))
            case .addedRecipient:
                let p = try XCTUnwrap(vault.recipientsStatus.problem)
                XCTAssertEqual(p.unexpected, [x.recipient.string], "the subset search finds the inserted key")
                XCTAssertEqual(p.restore, [a.recipient.string, b.recipient.string])
            default:
                let p = try XCTUnwrap(vault.recipientsStatus.problem, "\(kind)")
                XCTAssertNil(p.restore, "\(kind): no record, no verifiable subset")
                XCTAssertEqual(p.unexpected, vault.recipients.map(\.key), "\(kind): nothing can be confirmed")
                XCTAssertNil(try fresh.record(for: vault.vaultId), "a tampered list is never remembered")
            }
        }
    }

    /// Repair: rewrites the last verified list, rotates the secret, rewraps
    /// every file away from the attacker's key; other devices accept it.
    func testRepairRestoresTheLastVerifiedListAndRotates() throws {
        for kind in RecipientsTamper.allCases where kind != .secretReplaced {
            try FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let store = MemoryRecipientsTrustStore(), deviceB = MemoryRecipientsTrustStore()
            let (made, revs, other) = try setUpVault(store: store)
            try touch(made.url, deviceB, [b])
            try kind.apply(to: made.url, attacker: x.recipient, other: other)
            var vault = try open(made.url, store)
            let old = try XCTUnwrap(vault.secret)
            let report = try vault.repairRecipients()
            XCTAssertTrue(report.isComplete, "\(kind): \(report.failures)")
            XCTAssertEqual(vault.recipients.map(\.key), [a.recipient.string, b.recipient.string], "\(kind)")
            XCTAssertNotEqual(vault.secret, old, "\(kind): a repair is a removal: the secret rotates")
            XCTAssertEqual(try open(made.url, store).recipientsStatus, .verified(.unchanged), "\(kind)")
            XCTAssertEqual(try open(made.url, deviceB, [b]).recipientsStatus, .verified(.rotated), "\(kind): B follows the link")
            try assertReadable(revs, at: made.url, by: b)
            XCTAssertEqual(try stanzaCounts(vault, revs), Array(repeating: 2, count: revs.count), "\(kind)")
            XCTAssertThrowsError(try Vault.open(at: made.url, identities: [x]), "\(kind): the attacker's key opens nothing")
            for r in revs {
                XCTAssertThrowsError(try AgeFile.decrypt(Data(contentsOf: fileURL(vault, r.noteId, r.name)), with: [x]))
            }
            if kind == .removedRecipient {
                XCTAssertEqual(vault.recipients.last?.label, "", "a deleted key comes back from the record, unlabelled")
            } else {
                XCTAssertEqual(vault.recipients.map(\.label), ["A", "B"], "\(kind)")
            }
        }
    }

    func testRepairWithoutAKnownListNeedsKeysAndRefusesUnknownOnes() throws {
        let (made, _, other) = try setUpVault(store: MemoryRecipientsTrustStore())
        try RecipientsTamper.reordered.apply(to: made.url, attacker: x.recipient, other: other)
        var vault = try open(made.url, MemoryRecipientsTrustStore(), [b])
        XCTAssertThrowsError(try vault.repairRecipients()) {
            guard case .recipientsNotRepairable = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try vault.repairRecipients(keeping: [x.recipient.string])) {
            XCTAssertEqual($0 as? VaultError, .unknownRecipient(x.recipient.string))
        }
        XCTAssertThrowsError(try vault.confirmRecipients(), "a tag that does not verify is never confirmed")
        try vault.repairRecipients(keeping: [b.recipient.string, a.recipient.string])
        XCTAssertEqual(try open(made.url, nil).recipientsStatus, .verified(.firstUse))
        let verified = try open(made.url, MemoryRecipientsTrustStore())
        XCTAssertThrowsError(try { var v = verified; try v.repairRecipients() }())
    }

    // MARK: - Untagged vaults

    func testUntaggedVaultIsUpgradedOnceAndDowngradeIsCaught() throws {
        let fixture = try FixtureVault.copySample(to: tmp)
        let id = try FixtureVault.sampleIdentity()
        XCTAssertNotNil(try Vault.open(at: FixtureTests.bundled("sample.sempere")).manifest.recipientsTag,
                        "the committed fixture is tagged")
        XCTAssertNil(try Vault.open(at: fixture).manifest.recipientsTag)
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.open(at: fixture, identities: [id], trust: store)
        XCTAssertEqual(vault.recipientsStatus, .untagged)
        XCTAssertTrue(vault.recipientsStatus.allowsWriting)
        XCTAssertNil(try store.record(for: vault.vaultId), "nothing remembered before the upgrade")
        XCTAssertTrue(try vault.upgradeRecipientsTag())
        XCTAssertFalse(try vault.upgradeRecipientsTag(), "once")
        XCTAssertTrue(vault.manifest.features.contains("recipients-tag"))
        XCTAssertTrue(vault.manifest.features.contains("signed-secret-link"), "the first writer also marks signed links")
        XCTAssertEqual(try Vault.open(at: fixture, identities: [id], trust: store).recipientsStatus, .verified(.unchanged))
        XCTAssertTrue(try Vault.open(at: fixture, identities: [id], trust: store).verify().isHealthy)

        // Tag and feature both stripped: a device with a record sees a downgrade.
        var m = try VaultManifest.decode(Data(contentsOf: fixture.appendingPathComponent("vault.json")))
        m.recipientsTag = nil
        m.features.removeAll { $0 == "recipients-tag" }
        m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature }   // older than version markers
        try m.encoded().write(to: fixture.appendingPathComponent("vault.json"))
        var down = try Vault.open(at: fixture, identities: [id], trust: store)
        XCTAssertEqual(down.recipientsStatus.problem?.reason, .tagRemoved)
        XCTAssertFalse(try down.upgradeRecipientsTag(), "a device with a record never re-tags")
        XCTAssertEqual(try Vault.open(at: fixture, identities: [id]).recipientsStatus, .untagged, "first use cannot tell")
    }

    /// Writers tag an untagged vault before their first write; readers never write.
    func testFirstWriteTagsAnUntaggedVault() throws {
        let fixture = try FixtureVault.copySample(to: tmp)
        let id = try FixtureVault.sampleIdentity()
        let store = MemoryRecipientsTrustStore()
        let vault = try Vault.open(at: fixture, identities: [id], trust: store)
        _ = try vault.summaries()
        _ = vault.verify()
        XCTAssertNil(try Vault.open(at: fixture).manifest.recipientsTag, "reading writes nothing")
        var log = LogBuilder()
        var first = log.delta(devC, 1, [.setMeta(.title("new"))])
        first.noteId = UUID()
        try vault.write(first)
        XCTAssertNotNil(try Vault.open(at: fixture).manifest.recipientsTag)
        XCTAssertEqual(try Vault.open(at: fixture, identities: [id], trust: store).recipientsStatus, .verified(.unchanged))
        var second = log.delta(devC, 2, [.setMeta(.title("again"))])
        second.noteId = UUID()
        try vault.write(second)   // already tagged: no rewrite
        XCTAssertTrue(try Vault.open(at: fixture, identities: [id], trust: store).verify().isHealthy)
    }

    func testUpgradeRefusesAManifestChangedSinceOpen() throws {
        let fixture = try FixtureVault.copySample(to: tmp)
        var vault = try Vault.open(at: fixture, identities: [try FixtureVault.sampleIdentity()])
        var m = vault.manifest
        m.recipients.append(.init(key: x.recipient.string, label: "x", added: Date()))
        try m.encoded().write(to: fixture.appendingPathComponent("vault.json"))
        XCTAssertThrowsError(try vault.upgradeRecipientsTag())
        XCTAssertNil(try VaultManifest.decode(Data(contentsOf: fixture.appendingPathComponent("vault.json"))).recipientsTag)
    }

    // MARK: - Rewrap and capture

    /// A planted journal with a planted key: resuming would re-encrypt every
    /// file to the attacker, so it is refused.
    func testPlantedRewrapJournalIsNotResumedToATamperedList() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, revs, other) = try setUpVault(store: store)
        try RecipientsTamper.addedRecipient.apply(to: made.url, attacker: x.recipient, other: other)
        try Data(#"{"format":"sempere/1"}"#.utf8).write(to: made.url.appendingPathComponent("rewrap-journal.json"))
        var vault = try open(made.url, store)
        XCTAssertThrowsError(try vault.resumeRewrap()) {
            guard case .untrustedRecipients = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        for r in revs {
            XCTAssertThrowsError(try AgeFile.decrypt(Data(contentsOf: fileURL(vault, r.noteId, r.name)), with: [x]))
        }
    }

    /// Captures are sealed to the profile's list, made while the list
    /// checked; a list tampered later never reaches a capture.
    func testCaptureSealsToTheVerifiedProfileOnly() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, _, other) = try setUpVault(store: store)
        let profile = try made.captureProfile(device: devC)
        try RecipientsTamper.addedRecipient.apply(to: made.url, attacker: x.recipient, other: other)
        XCTAssertThrowsError(try open(made.url, store).captureProfile(device: devC))
        let sealed = try CaptureWriter(profile: profile).seal(audio: Data(repeating: 1, count: 64), started: Date())
        XCTAssertEqual(try Vault.stanzaCounts(sealed.data), ["mlkem768x25519": 2])
        XCTAssertThrowsError(try AgeFile.decrypt(sealed.data, with: [x]))
    }

    // MARK: - Incoming vault.json (sync)

    func testIncomingManifestIsCheckedBeforeReplacingTheLocalOne() throws {
        let store = MemoryRecipientsTrustStore()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        _ = try populate(vault)
        let manifestURL = vault.url.appendingPathComponent("vault.json")
        let local = try Data(contentsOf: manifestURL)
        let other = try Vault.create(at: vaultURL("Other"), recipients: [a.recipient], identities: [a]).manifest

        // A legitimate change made elsewhere (a copy changed by another device).
        let copy = vaultURL("Copy")
        try FileManager.default.copyItem(at: vault.url, to: copy)
        var elsewhere = try Vault.open(at: copy, identities: [a])
        try elsewhere.removeRecipient(b.recipient)
        let legit = try Data(contentsOf: copy.appendingPathComponent("vault.json"))
        XCTAssertNil(Vault.incomingManifestProblem(legit, local: local, vault: vault), "rotation confirmed by the link")
        XCTAssertNil(Vault.incomingManifestProblem(local, local: local, vault: nil), "same list, no key needed")
        XCTAssertNil(Vault.incomingManifestProblem(legit, local: nil, vault: nil), "a first pull takes what is there")
        XCTAssertNotNil(Vault.incomingManifestProblem(legit, local: local, vault: nil), "a changed list needs the key")

        for kind in RecipientsTamper.allCases {
            try Data(local).write(to: manifestURL)
            try kind.apply(to: vault.url, attacker: x.recipient, other: other)
            let tampered = try Data(contentsOf: manifestURL)
            try Data(local).write(to: manifestURL)
            XCTAssertNotNil(Vault.incomingManifestProblem(tampered, local: local, vault: vault), "\(kind)")
            if kind == .tagFromAnotherVault {
                XCTAssertNotNil(Vault.incomingManifestProblem(tampered, local: local, vault: nil),
                                "a changed tag cannot be checked without the key")
            } else {
                XCTAssertNotNil(Vault.incomingManifestProblem(tampered, local: local, vault: nil), "\(kind) without a key")
            }
        }
        XCTAssertNotNil(Vault.incomingManifestProblem(Data("{".utf8), local: local, vault: vault))

        // Security review 2026-10 (W3): without the key, the same keys with
        // another sealed secret (and any tag) is not taken: it would replace
        // the vault's real secret with one the server chose.
        var swapped = try VaultManifest.decode(local)
        let keys = try swapped.recipients.map { try NativeRecipient(string: $0.key) }
        swapped.vaultSecret = String(decoding: try AgeFile.encrypt(VaultSecret.random().bytes, to: keys, armor: true), as: UTF8.self)
        XCTAssertNotNil(Vault.incomingManifestProblem(try swapped.encoded(), local: local, vault: nil))
        swapped.recipientsTag = String(repeating: "0", count: 64)
        XCTAssertNotNil(Vault.incomingManifestProblem(try swapped.encoded(), local: local, vault: nil))
        vault = try Vault.open(at: vault.url, identities: [a])   // no trust store: the local vault is the anchor
        try kind(.secretReplaced)
        func kind(_ k: RecipientsTamper) throws {
            try k.apply(to: vault.url, attacker: x.recipient, other: other)
            let t = try Data(contentsOf: manifestURL)
            try Data(local).write(to: manifestURL)
            XCTAssertNotNil(Vault.incomingManifestProblem(t, local: local, vault: vault))
        }
    }

    // MARK: - Untrusted input

    func testMalformedTagFieldsReadAsTagsThatDoNotVerify() throws {
        let store = MemoryRecipientsTrustStore()
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a], trust: store)
        let url = vault.url.appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for bad: Any in [42, ["x"], ["k": 1], "", "ZZ", String(repeating: "A", count: 64), true] {
            obj["recipientsTag"] = bad
            obj["secretLink"] = bad
            try JSONSerialization.data(withJSONObject: obj).write(to: url)
            let v = try Vault.open(at: url.deletingLastPathComponent(), identities: [a], trust: store)
            XCTAssertEqual(v.recipientsStatus.problem?.reason, .tagMismatch, "\(bad)")
            XCTAssertEqual(try v.manifest.encoded().isEmpty, false)
        }
        obj["recipientsTag"] = NSNull()
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        XCTAssertEqual(try Vault.open(at: vault.url, identities: [a], trust: store).recipientsStatus.problem?.reason, .tagRemoved)
    }

    func testTrustRecordRoundTripsAndRejectsMalformedFiles() throws {
        let dir = tmp.appendingPathComponent("trust")
        let store = FileRecipientsTrustStore(directory: dir)
        let record = try RecipientsTrustRecord(vaultId: UUID(), secret: .random(), recipients: [a.recipient.string])
        try store.save(record)
        XCTAssertEqual(try store.record(for: record.vaultId), record)
        let file = dir.appendingPathComponent("\(record.vaultId.uuidString.lowercased()).json")
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // Security review 2026-10 (R2): the folder is private too, and a
        // replaced record is created private (never world-readable first).
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        let next = try RecipientsTrustRecord(vaultId: record.vaultId, secret: .random(), recipients: [a.recipient.string])
        try store.save(next)
        XCTAssertEqual(try store.record(for: record.vaultId), next)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [file.lastPathComponent], "no temporary left")
        #endif
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("vaultSecret"))
        let id = record.vaultId.uuidString.lowercased()
        for junk in ["{", #"{"format":"x"}"#, #"{"format":"sempere-trust/1","vaultId":"\#(id)","linkKey":"00","recipients":[]}"#,
                     #"{"format":"sempere-trust/2","vaultId":"\#(id)","linkPublicKeys":{"ed25519":"00","mldsa65":"00"},"recipients":[]}"#,
                     #"{"format":"sempere-trust/2","vaultId":"\#(id)","linkKey":"\#(String(repeating: "0", count: 64))","recipients":[]}"#] {
            try Data(junk.utf8).write(to: file)
            // Security review 2026-10 (R5): unreadable is an error, never "no record".
            XCTAssertThrowsError(try store.record(for: record.vaultId), junk)
        }
        let other = try RecipientsTrustRecord(vaultId: UUID(), secret: .random(), recipients: [a.recipient.string])
        try JSONEncoder().encode(other).write(to: file)
        XCTAssertThrowsError(try store.record(for: record.vaultId), "a record of another vault")
        XCTAssertNil(try store.record(for: UUID()))
    }

    /// Security review 2026-10 (R5): a trust record that exists but cannot be
    /// read fails closed. The open does not read as a first use, nothing is
    /// written (the record is not replaced), and only an explicit confirm
    /// writes it again.
    func testUnreadableTrustRecordFailsClosed() throws {
        let dir = tmp.appendingPathComponent("trust-r5")
        let store = FileRecipientsTrustStore(directory: dir)
        let made = try Vault.create(at: tmp.appendingPathComponent("r5.sempere"), recipients: [a.recipient], identities: [a],
                                    trust: store)
        let file = dir.appendingPathComponent("\(made.vaultId.uuidString.lowercased()).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try Data("{ damaged".utf8).write(to: file)

        var v = try Vault.open(at: made.url, identities: [a], trust: store)
        XCTAssertEqual(v.recipientsStatus.problem?.reason, .recordUnreadable)
        XCTAssertNil(v.recipientsStatus.problem?.restore)
        XCTAssertThrowsError(try v.requireWritable()) { error in
            guard case VaultError.untrustedRecipients(let p) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(p.reason, .recordUnreadable)
        }
        XCTAssertThrowsError(try v.apply([], to: UUID(), deviceState: tmp.appendingPathComponent("dev.json"), app: "test"))
        XCTAssertEqual(try Data(contentsOf: file), Data("{ damaged".utf8), "the damaged record is not replaced")
        XCTAssertThrowsError(try v.repairRecipients(), "no list to restore without a record")

        try v.confirmRecipients()
        XCTAssertEqual(try store.record(for: made.vaultId)?.recipients, [a.recipient.string])
        XCTAssertNoThrow(try v.requireWritable())
        XCTAssertNil(try Vault.open(at: made.url, identities: [a], trust: store).recipientsStatus.problem)

        // A list that does not check stays tagMismatch (the more serious
        // reason), and a confirm never accepts it.
        try Data("{ damaged".utf8).write(to: file)
        let url = made.url.appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["recipientsTag"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        var bad = try Vault.open(at: made.url, identities: [a], trust: store)
        XCTAssertEqual(bad.recipientsStatus.problem?.reason, .tagMismatch)
        XCTAssertThrowsError(try bad.confirmRecipients())
    }

    /// R5: a record that cannot be saved stops the write, and is tried again.
    func testTrustRecordSaveFailureStopsTheWrite() throws {
        let store = FailingSaveTrustStore()
        let made = try Vault.create(at: tmp.appendingPathComponent("r5b.sempere"), recipients: [a.recipient], identities: [a],
                                    trust: MemoryRecipientsTrustStore())
        let v = try Vault.open(at: made.url, identities: [a], trust: store)
        XCTAssertEqual(v.recipientsStatus, .verified(.firstUse))
        store.failing = true
        XCTAssertThrowsError(try v.requireWritable())
        store.failing = false
        XCTAssertNoThrow(try v.requireWritable(), "retried, not memoised as saved")
        XCTAssertEqual(store.saves, 1)
    }

    func testSubsetSearchIsBounded() throws {
        let secret = VaultSecret.random(), id = UUID()
        let keys = (0..<5).map { _ in pqIdentity().recipient.string }
        let tag = RecipientsAuth.tag(vaultId: id, keys: [keys[0], keys[2]], secret: secret)
        let found = try XCTUnwrap(RecipientsAuth.verifiedSubset(of: keys, tag: tag, vaultId: id, secret: secret))
        XCTAssertEqual(found.kept, [keys[0], keys[2]])
        XCTAssertEqual(found.deleted, [keys[1], keys[3], keys[4]])
        let four = RecipientsAuth.tag(vaultId: id, keys: [keys[0]], secret: secret)
        XCTAssertNil(RecipientsAuth.verifiedSubset(of: keys, tag: four, vaultId: id, secret: secret), "four deletions: beyond the bound")
        let many = (0..<17).map { "age1pq1\($0)" }
        let t = RecipientsAuth.tag(vaultId: id, keys: Array(many.dropLast()), secret: secret)
        XCTAssertNil(RecipientsAuth.verifiedSubset(of: many, tag: t, vaultId: id, secret: secret), "lists over 16 keys are not searched")
    }
}

/// The committed sample vault.
enum FixtureVault {
    /// A copy of the sample vault as written before format.md §2.1: the
    /// committed one is tagged, so the tag and the feature are taken out.
    static func copySample(to dir: URL) throws -> URL {
        let dest = dir.appendingPathComponent("sample.sempere")
        try FileManager.default.copyItem(at: try FixtureTests.bundled("sample.sempere"), to: dest)
        let url = dest.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: url))
        m.recipientsTag = nil
        m.markersTag = nil   // older than version markers too (format.md §2.1)
        m.features.removeAll { [VaultManifest.recipientsTagFeature, VaultManifest.signedLinkFeature,
                                VaultManifest.markersTagFeature].contains($0) }
        try m.encoded().write(to: url)
        return dest
    }

    static func sampleIdentity() throws -> NativeIdentity {
        try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
    }
}

/// A trust store whose saves fail while `failing` is set (R5 tests).
final class FailingSaveTrustStore: RecipientsTrustStore, @unchecked Sendable {
    private let inner = MemoryRecipientsTrustStore()
    var failing = false
    var saves = 0

    func record(for vaultId: UUID) throws -> RecipientsTrustRecord? { try inner.record(for: vaultId) }

    func save(_ record: RecipientsTrustRecord) throws {
        if failing { throw VaultError.io("disk full") }
        saves += 1
        try inner.save(record)
    }
}
