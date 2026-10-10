import Age
import Crypto
import Foundation
import XCTest
@testable import Sempere

/// Security review 2026-10, stage 4 (S0, S1, S4, S19): a removed device keeps
/// the outgoing vault secret, and `secretLink` stays in `vault.json` until the
/// next rotation. Before bound journals, such a device could write (or put
/// back) `rewrap-journal.json` at any time after its removal: every reader
/// accepted the old secret again, so revisions, blobs, settings and captures
/// it tagged under it verified, and a resumed rewrap re-tagged them under the
/// current secret for good. A journal now counts only while `vault.json`
/// binds it under the current secret (`rewrapPending`), and never on a device
/// that saw the rotation finish (`rewrapFinished`; format.md §3.3.1).
final class RewrapJournalBindingTests: VaultTestCase {
    let a = pqIdentity(), b = pqIdentity()
    var journalURL: URL { vaultURL().appendingPathComponent("rewrap-journal.json") }
    var manifestURL: URL { vaultURL().appendingPathComponent("vault.json") }

    /// A vault of A and B with notes, written by A (which keeps a trust
    /// record), and a copy of it as removed device B keeps it (B holds the
    /// secret that is about to become the outgoing one).
    func makeVaults(store: MemoryRecipientsTrustStore) throws -> (vault: Vault, revs: [Revision], removed: Vault) {
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["A", "B"],
                                     identities: [a], trust: store)
        let revs = try populate(vault)
        try FileManager.default.copyItem(at: vaultURL(), to: vaultURL("Removed"))
        let removed = try Vault.open(at: vaultURL("Removed"), identities: [b])
        return (vault, revs, removed)
    }

    /// What B does after its removal: a revision tagged under the outgoing
    /// secret (written in its own copy), re-encrypted to the vault's current
    /// public keys and put into the vault.
    func forge(by removed: Vault, title: String) throws -> RevisionName {
        var log = LogBuilder()
        let r = log.delta(devC, 999, [.setMeta(.title(title))])
        try removed.write(r)
        let plain = try AgeFile.decrypt(Data(contentsOf: fileURL(removed, r.noteId, r.name)), with: [b])
        let current = try VaultManifest.decode(Data(contentsOf: manifestURL)).recipients.map { try NativeRecipient(string: $0.key) }
        try AgeFile.encrypt(plain, to: current).write(to: fileURL(try Vault.open(at: vaultURL()), r.noteId, r.name))
        return r.name
    }

    /// A journal holding `secret`, encrypted to the vault's current public keys.
    func plantJournal(_ secret: VaultSecret) throws {
        let current = try VaultManifest.decode(Data(contentsOf: manifestURL)).recipients.map { try NativeRecipient(string: $0.key) }
        let armored = String(decoding: try AgeFile.encrypt(secret.bytes, to: current, armor: true), as: UTF8.self)
        try JSONSerialization.data(withJSONObject: ["format": "sempere/1", "previousVaultSecret": armored]).write(to: journalURL)
    }

    func assertRefused(_ v: Vault, forged: RevisionName, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(v.pendingRewrap, message, file: file, line: line)
        XCTAssertNil(v.previousSecret, message, file: file, line: line)
        XCTAssertTrue(v.journalRefused, message, file: file, line: line)
        XCTAssertThrowsError(try v.readRevision(noteId: testNote, name: forged), message, file: file, line: line)
    }

    /// The attack: after the removal finished, B plants a journal holding its
    /// old secret. Neither the device that removed it (which saw the change
    /// finish) nor one that never opened the vault before accepts it, the
    /// forged revision fails its tag, and nothing re-tags it.
    func testARemovedDeviceCannotReopenItsSecretWithAPlantedJournal() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, revs, removed) = try makeVaults(store: store)
        let outgoing = try removed.requireSecret()
        var writer = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertTrue(try writer.removeRecipient(b.recipient).isComplete)
        XCTAssertNotEqual(try writer.requireSecret(), outgoing)
        XCTAssertTrue(RecipientsAuth.linkConnects(writer.manifest.secretLink, from: outgoing, to: try writer.requireSecret(),
                                                  vaultId: made.vaultId), "the link stays: it is what B relied on")
        XCTAssertNil(writer.manifest.rewrapPending, "cleared by the finishing write")
        XCTAssertTrue(writer.manifest.features.contains(VaultManifest.rewrapPendingFeature))
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, true)

        let forged = try forge(by: removed, title: "Forged")
        try plantJournal(outgoing)

        for (store, who) in [(store, "the device that removed B"), (MemoryRecipientsTrustStore(), "a device with no record")] {
            var v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
            assertRefused(v, forged: forged, who)
            XCTAssertThrowsError(try v.resumeRewrap(), who)
            for r in revs { XCTAssertEqual(try v.readRevision(noteId: r.noteId, name: r.name), r, who) }
        }
        let forgedURL = vaultURL().appendingPathComponent("notes/\(testNote.uuidString.lowercased())/\(forged.filename)")
        let before = try Data(contentsOf: forgedURL)
        // The way out (S19): the refused journal is discarded, never resumed.
        var v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        let planted = try Data(contentsOf: journalURL)
        XCTAssertNotNil(try v.discardRefusedJournal())
        XCTAssertFalse(v.pendingRewrap)
        XCTAssertEqual(try Data(contentsOf: vaultURL().appendingPathComponent("rewrap-journal.refused.json")), planted,
                       "kept aside, never read")
        XCTAssertEqual(try Data(contentsOf: forgedURL), before, "never re-tagged")
        XCTAssertThrowsError(try Vault.open(at: vaultURL(), identities: [a], trust: store).readRevision(noteId: testNote, name: forged))
    }

    /// The genuine journal, saved during the rotation and put back after it
    /// finished, with or without the `vault.json` of step 2 that bound it.
    func testAReplayedJournalOfAFinishedRotationIsRefused() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, _, removed) = try makeVaults(store: store)
        let outgoing = try removed.requireSecret()
        var writer = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertThrowsError(try writer.removeRecipient(b.recipient, policy: RewrapPolicy(), stopAfter: 1))
        let genuine = try Data(contentsOf: journalURL)
        let bound = try Data(contentsOf: manifestURL)
        let step2 = try VaultManifest.decode(bound)
        let current = try writer.requireSecret()
        XCTAssertTrue(RecipientsAuth.verifyRewrapPending(try XCTUnwrap(step2.rewrapPending), vaultId: made.vaultId,
                                                         journal: genuine, secret: current), "step 2 binds the journal")
        XCTAssertEqual(try Vault.open(at: vaultURL(), identities: [a], trust: MemoryRecipientsTrustStore()).previousSecret,
                       outgoing, "while unfinished, any device accepts it")
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, false)

        var resumed = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertTrue(try resumed.resumeRewrap().isComplete)
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, true)
        let finished = try Data(contentsOf: manifestURL)
        let forged = try forge(by: removed, title: "Replayed")

        // The journal alone: vault.json no longer binds it.
        try genuine.write(to: journalURL)
        for (s, who) in [(store, "removing device"), (MemoryRecipientsTrustStore(), "no record")] {
            assertRefused(try Vault.open(at: vaultURL(), identities: [a], trust: s), forged: forged, who)
        }
        // With step 2's vault.json put back: still refused where the rotation was seen to finish.
        try bound.write(to: manifestURL)
        var v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        assertRefused(v, forged: forged, "a device that saw it finish")
        XCTAssertThrowsError(try v.resumeRewrap())
        // A device with no record accepts it, as during the rotation (format.md §3.3.1 "Limits").
        XCTAssertEqual(try Vault.open(at: vaultURL(), identities: [a], trust: MemoryRecipientsTrustStore()).previousSecret, outgoing)
        // Sync never takes such a vault.json over the finished one, locked or not.
        XCTAssertNotNil(Vault.incomingManifestProblem(bound, local: finished, vault: v))
        XCTAssertNotNil(Vault.incomingManifestProblem(bound, local: finished, vault: nil))
        XCTAssertNil(Vault.incomingManifestProblem(finished, local: bound, vault: v), "step 4's removal is taken")
        // Discarding also removes the put-back binding, on a device whose record says the change finished.
        XCTAssertNotNil(try v.discardRefusedJournal())
        XCTAssertNil(try VaultManifest.decode(Data(contentsOf: manifestURL)).rewrapPending)
        XCTAssertEqual(try Vault.open(at: vaultURL(), identities: [a], trust: store).recipientsStatus, .verified(.unchanged))
    }

    /// Taking the feature out of `features` (to make the vault look as if it
    /// predated bound journals) breaks the markers tag, so the journal must
    /// still be bound, even on a device with no record.
    func testAStrippedFeatureStillRequiresABinding() throws {
        let store = MemoryRecipientsTrustStore()
        let (_, _, removed) = try makeVaults(store: store)
        let outgoing = try removed.requireSecret()
        var writer = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        try writer.removeRecipient(b.recipient)
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
        m.features.removeAll { $0 == VaultManifest.rewrapPendingFeature }
        try m.encoded().write(to: manifestURL)
        let forged = try forge(by: removed, title: "Stripped")
        try plantJournal(outgoing)
        assertRefused(try Vault.open(at: vaultURL(), identities: [a], trust: MemoryRecipientsTrustStore()), forged: forged,
                      "no record")
    }

    /// A rotation written before bound journals (no feature, no field: here a
    /// vault.json rewritten as an older writer would, markers re-tagged) is
    /// protected by the device's `rewrapFinished` alone.
    func testUnboundVaultsAreProtectedByTheFinishedMarker() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, _, removed) = try makeVaults(store: store)
        let outgoing = try removed.requireSecret()
        var writer = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        try writer.removeRecipient(b.recipient)
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
        m.features.removeAll { $0 == VaultManifest.rewrapPendingFeature }
        _ = try Vault.writeManifest(m, to: manifestURL, replacing: true, secret: try writer.requireSecret())
        // A device whose record holds the feature is not fooled by the downgrade.
        let forged = try forge(by: removed, title: "Old style")
        try plantJournal(outgoing)
        assertRefused(try Vault.open(at: vaultURL(), identities: [a], trust: store), forged: forged, "record")

        // A record that never named the feature (written before it) still refuses by its marker.
        var record = try XCTUnwrap(try store.record(for: made.vaultId))
        record.markers = record.markers.map { VaultMarkers(format: $0.format,
                                                           features: $0.features.filter { $0 != VaultManifest.rewrapPendingFeature }) }
        try store.save(record)
        XCTAssertTrue(record.rewrapFinished)
        assertRefused(try Vault.open(at: vaultURL(), identities: [a], trust: store), forged: forged, "marker only")
        // Without that marker, an unbound vault falls back to the link check (format.md §3.3.1 "Limits").
        XCTAssertEqual(try Vault.open(at: vaultURL(), identities: [a], trust: MemoryRecipientsTrustStore()).previousSecret, outgoing)
    }

    /// The marker is set when a device that keeps a record opens the vault
    /// with nothing pending, never while a rotation is pending, and never
    /// moves back for the same secret.
    func testTheFinishedMarkerIsMonotonic() throws {
        let store = MemoryRecipientsTrustStore()
        let (made, _, _) = try makeVaults(store: store)
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, true, "a new vault has nothing pending")
        var writer = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertThrowsError(try writer.removeRecipient(b.recipient, policy: RewrapPolicy(), stopAfter: 1))
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, false, "a new secret, pending")
        _ = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, false, "opening while pending sets nothing")
        let bound = try Data(contentsOf: manifestURL), genuine = try Data(contentsOf: journalURL)
        var resumed = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        try resumed.resumeRewrap()
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, true)
        // Put back, then written to: the marker stays.
        try bound.write(to: manifestURL); try genuine.write(to: journalURL)
        let v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        try v.requireWritable()
        XCTAssertEqual(try store.record(for: made.vaultId)?.rewrapFinished, true)
        // A reader that keeps no record still keeps none.
        let fresh = MemoryRecipientsTrustStore()
        try FileManager.default.removeItem(at: journalURL)
        _ = try Vault.open(at: vaultURL(), identities: [a], trust: fresh)
        XCTAssertNil(try fresh.record(for: made.vaultId))
    }

    /// S19: a planted journal (any bytes) blocked every recipient change and
    /// held the app on its migration screen; nothing could remove it. It is
    /// discarded explicitly, and only when it is refused.
    func testARefusedJournalCanBeDiscardedAndAnAcceptedOneCannot() throws {
        let store = MemoryRecipientsTrustStore()
        let (_, _, _) = try makeVaults(store: store)
        for junk in [Data("{".utf8), Data("not json".utf8)] {
            try junk.write(to: journalURL)
            var v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
            XCTAssertTrue(v.journalRefused)
            XCTAssertThrowsError(try v.removeRecipient(b.recipient))
            XCTAssertNotNil(try v.discardRefusedJournal())
            XCTAssertFalse(v.pendingRewrap)
            XCTAssertNil(try v.discardRefusedJournal(), "nothing left")
        }
        try plantJournal(.random())
        var v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertTrue(v.journalRefused, "a secret nothing links to")
        try v.discardRefusedJournal()
        XCTAssertTrue(try v.removeRecipient(b.recipient).isComplete, "recipient changes run again")

        // An unfinished change's journal is never discarded.
        let c = pqIdentity()
        v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        try v.addRecipient(c.recipient, label: "C")
        XCTAssertThrowsError(try v.removeRecipient(c.recipient, policy: RewrapPolicy(), stopAfter: 0))
        var again = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertFalse(again.journalRefused)
        XCTAssertThrowsError(try again.discardRefusedJournal()) {
            guard case .rewrapJournalKept = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(again.pendingRewrap)
        // Nor with a list that does not check.
        try plantJournal(.random())
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
        m.recipientsTag = String(repeating: "0", count: 64)
        try m.encoded().write(to: manifestURL)
        var tampered = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertThrowsError(try tampered.discardRefusedJournal()) {
            guard case .untrustedRecipients = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    /// A journal that cannot be read now (here: a directory in its place) is
    /// not refused, and never discarded.
    func testAnUnreadableJournalIsKept() throws {
        let store = MemoryRecipientsTrustStore()
        _ = try makeVaults(store: store)
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
        var v = try Vault.open(at: vaultURL(), identities: [a], trust: store)
        XCTAssertTrue(v.pendingRewrap)
        XCTAssertFalse(v.journalRefused)
        XCTAssertThrowsError(try v.discardRefusedJournal()) {
            guard case .rewrapJournalKept = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    /// `rewrapPending` follows format.md §3.3.1, computed independently.
    func testRewrapPendingIsHMACOverVaultIdAndJournalDigest() throws {
        let secret = VaultSecret.random()
        let id = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
        let journal = Data(#"{"format":"sempere/1"}"#.utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret.bytes),
                                         info: Data("sempere/1 rewrap pending key".utf8), outputByteCount: 32)
        var message = Data("sempere/1\0rewrap pending\00d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c\0".utf8)
        message.append(contentsOf: SHA256.hash(data: journal))
        let expected = Hex.encode(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
        XCTAssertEqual(RecipientsAuth.rewrapPending(vaultId: id, journal: journal, secret: secret), expected)
        XCTAssertTrue(RecipientsAuth.verifyRewrapPending(expected, vaultId: id, journal: journal, secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyRewrapPending(expected, vaultId: id, journal: journal + Data(" ".utf8), secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyRewrapPending(expected, vaultId: id, journal: journal, secret: .random()))
        XCTAssertFalse(RecipientsAuth.verifyRewrapPending(expected.uppercased(), vaultId: id, journal: journal, secret: secret))
        // The vector web/test/journal.test.ts checks too (computed with Python's hmac/hashlib).
        let fixed = try VaultSecret(bytes: Data(0..<32))
        XCTAssertEqual(RecipientsAuth.rewrapPending(vaultId: id, journal: Data(#"{"format":"sempere/1","previousVaultSecret":"x"}"#.utf8),
                                                    secret: fixed),
                       "5d73a94df76ab2b2e3c4decc6ac2b9853a0823650753ca8142e584ccc9529a25")
    }

    /// The trust record keeps the marker, and only on a signed record.
    func testTrustRecordRoundTripsTheMarker() throws {
        let dir = tmp.appendingPathComponent("trust")
        let files = FileRecipientsTrustStore(directory: dir)
        let record = try RecipientsTrustRecord(vaultId: UUID(), secret: .random(), recipients: [a.recipient.string],
                                               rewrapFinished: true)
        try files.save(record)
        XCTAssertEqual(try files.record(for: record.vaultId), record)
        let text = try String(contentsOf: files.fileURL(record.vaultId), encoding: .utf8)
        XCTAssertTrue(text.contains("\"rewrapFinished\" : true"))
        var unset = record
        unset.rewrapFinished = false
        try files.save(unset)
        XCTAssertFalse(try String(contentsOf: files.fileURL(record.vaultId), encoding: .utf8).contains("rewrapFinished"))
        // A value of another type is an unreadable record (fail closed, R5), not "unset".
        try Data(text.replacingOccurrences(of: "\"rewrapFinished\" : true", with: "\"rewrapFinished\" : \"yes\"").utf8)
            .write(to: files.fileURL(record.vaultId))
        XCTAssertThrowsError(try files.record(for: record.vaultId))
    }
}
