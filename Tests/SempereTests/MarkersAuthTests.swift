import Age
import Foundation
import XCTest
@testable import Sempere

/// Authenticated version markers (format.md §2.1 "Version markers"; security
/// review 2026-10, N3): `format` and `features` cannot be lowered, removed
/// or replayed without the vault's key going unnoticed by a writer.
final class MarkersAuthTests: VaultTestCase {
    let a = pqIdentity()

    func manifestURL(_ v: Vault) -> URL { v.url.appendingPathComponent("vault.json") }

    func edit(_ v: Vault, _ change: (inout VaultManifest) throws -> Void) throws {
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL(v)))
        try change(&m)
        try m.encoded().write(to: manifestURL(v))
    }

    func reason(_ v: Vault) -> RecipientsProblem.Reason? { v.recipientsStatus.problem?.reason }

    /// A vault this device has written to (so it holds a trust record with markers).
    func setUpVault(_ store: MemoryRecipientsTrustStore) throws -> Vault {
        try XCTSkipUnless(postQuantumAvailable)
        let v = try Vault.create(at: vaultURL(), recipients: [a.recipient], identities: [a], trust: store)
        _ = try v.apply(NoteOps.newNote(title: "Plain"), to: UUID(), deviceState: tmp.appendingPathComponent("d.json"), app: "t")
        return try Vault.open(at: v.url, identities: [a], trust: store)
    }

    func testKnownAnswerVectorAndCanonicalFeatures() throws {
        let secret = try VaultSecret(bytes: Data((1...32).map { UInt8($0) }))
        let id = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
        let tag = try XCTUnwrap(RecipientsAuth.markersTag(vaultId: id, format: "sempere/1",
                                                          features: ["recipients-tag", "attachments", "markers-tag"], secret: secret))
        // Computed independently from format.md §2.1 (Python hmac/hashlib); shared with web/test/markers.test.ts.
        XCTAssertEqual(tag, "015d9f46c6560d1d087b0ad3bb4696179fc2a7fb917a453285ce92b3569f4ace")
        for features in [["attachments", "markers-tag", "recipients-tag"], ["markers-tag", "attachments", "recipients-tag", "attachments"]] {
            XCTAssertTrue(RecipientsAuth.verifyMarkers(tag, vaultId: id, format: "sempere/1", features: features, secret: secret),
                          "order and repetition do not matter")
        }
        XCTAssertFalse(RecipientsAuth.verifyMarkers(tag, vaultId: id, format: "sempere/2",
                                                    features: ["attachments", "markers-tag", "recipients-tag"], secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyMarkers(tag, vaultId: id, format: "sempere/1",
                                                    features: ["attachments", "recipients-tag"], secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyMarkers(tag.uppercased(), vaultId: id, format: "sempere/1",
                                                    features: ["attachments", "markers-tag", "recipients-tag"], secret: secret))
        // A NUL would let two lists share a message: never tagged, never verifies.
        XCTAssertNil(RecipientsAuth.markersTag(vaultId: id, format: "sempere/1", features: ["a\u{0}b"], secret: secret))
        XCTAssertFalse(RecipientsAuth.verifyMarkers(tag, vaultId: id, format: "sempere/1", features: ["a\u{0}b"], secret: secret))
        // Bytes, not Unicode ordering or canonical equivalence.
        XCTAssertEqual(RecipientsAuth.canonicalFeatures(["\u{e9}", "e\u{301}", "b", "\u{e9}"]), ["b", "e\u{301}", "\u{e9}"])
    }

    func testNewVaultsAreTaggedAndTheRecordKeepsTheMarkers() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        XCTAssertNotNil(v.manifest.markersTag)
        XCTAssertTrue(v.manifest.features.contains("markers-tag"))
        XCTAssertEqual(v.recipientsStatus, .verified(.unchanged))
        XCTAssertEqual(try store.record(for: v.vaultId)?.markers, VaultMarkers(v.manifest))
        // A feature added later is tagged in the same write.
        _ = try v.writeBlob(note: UUID(), Data("x".utf8), type: "image/png")
        let after = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertTrue(after.manifest.features.contains("attachments"))
        XCTAssertEqual(after.recipientsStatus, .verified(.unchanged))
    }

    /// Attack: a vault of a later major (or with an extension this version
    /// does not know) is set back to `sempere/1` without the extension, so
    /// that this version would write to it. Refused and reported; reading works.
    func testADowngradedFormatIsRefusedForWriting() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        let secret = try v.requireSecret()
        // What a newer writer leaves: sempere/2 and its feature, tagged.
        try edit(v) { m in
            m.format = "sempere/2"; m.features.append("tables"); m.tagMarkers(secret: secret)
        }
        let newer = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertTrue(newer.isReadOnly)
        XCTAssertNil(reason(newer), "the markers check; the vault is read-only for being newer")
        // The attacker sets it back, keeping the newer writer's tag.
        try edit(v) { m in m.format = "sempere/1"; m.features.removeAll { $0 == "tables" } }
        let downgraded = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertFalse(downgraded.isReadOnly)
        XCTAssertEqual(reason(downgraded), .markersMismatch)
        XCTAssertThrowsError(try downgraded.apply(NoteOps.newNote(title: "x"), to: UUID(),
                                                  deviceState: tmp.appendingPathComponent("d.json"), app: "t")) {
            guard case .untrustedRecipients(let p)? = $0 as? VaultError else { return XCTFail("\($0)") }
            XCTAssertEqual(p.reason, .markersMismatch)
        }
        XCTAssertNoThrow(try downgraded.noteIDs().map { try downgraded.reconstruct(noteId: $0) })
        // A device without a record catches it too: the tag does not verify.
        XCTAssertEqual(reason(try Vault.open(at: v.url, identities: [a], trust: MemoryRecipientsTrustStore())), .markersMismatch)
    }

    /// Attack: the tag is stripped (with or without its feature).
    func testAStrippedTagIsADowngrade() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        try edit(v) { m in m.markersTag = nil }
        XCTAssertEqual(reason(try Vault.open(at: v.url, identities: [a], trust: store)), .markersRemoved)
        XCTAssertEqual(reason(try Vault.open(at: v.url, identities: [a], trust: MemoryRecipientsTrustStore())), .markersRemoved,
                       "the feature still says it was tagged")
        try edit(v) { m in m.features.removeAll { $0 == "markers-tag" } }
        XCTAssertEqual(reason(try Vault.open(at: v.url, identities: [a], trust: store)), .markersRemoved, "the record knows")
        // A device that never wrote to it cannot tell (format.md §2.1 "Limits").
        XCTAssertEqual(try Vault.open(at: v.url, identities: [a], trust: MemoryRecipientsTrustStore()).recipientsStatus,
                       .verified(.firstUse))
    }

    /// Attack: an older `vault.json` (fewer features, a tag that verified
    /// then) is put back. Only the trust record can tell.
    func testAReplayedOlderManifestIsARollback() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        let old = try Data(contentsOf: manifestURL(v))
        _ = try v.writeBlob(note: UUID(), Data("x".utf8), type: "image/png")   // adds attachments
        _ = try Vault.open(at: v.url, identities: [a], trust: store).requireWritable()   // the record learns it
        XCTAssertTrue(try store.record(for: v.vaultId)?.markers?.features.contains("attachments") == true)
        try old.write(to: manifestURL(v))
        let replayed = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(reason(replayed), .markersRolledBack)
        XCTAssertNotNil(RecipientsAuth.markersProblem(replayed.manifest, secret: try replayed.requireSecret(), record: try store.record(for: v.vaultId)))

        // Repair writes the larger markers back, tagged.
        var repairing = replayed
        try repairing.repairMarkers()
        XCTAssertTrue(repairing.manifest.features.contains("attachments"))
        XCTAssertEqual(try Vault.open(at: v.url, identities: [a], trust: store).recipientsStatus, .verified(.unchanged))
        XCTAssertThrowsError(try repairing.repairMarkers(), "nothing left to repair")
    }

    func testRepairNeverWritesMarkersThisVersionDoesNotImplement() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        var record = try XCTUnwrap(try store.record(for: v.vaultId))
        record.markers = VaultMarkers(format: "sempere/2", features: ["tables"])
        try store.save(record)
        var opened = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(reason(opened), .markersRolledBack)
        XCTAssertThrowsError(try opened.repairMarkers()) {
            guard case .recipientsNotRepairable? = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        // Nor does a markers repair touch a list that does not check.
        try edit(v) { m in m.recipients.append(.init(key: pqIdentity().recipient.string, label: "x", added: Date())) }
        opened = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(reason(opened), .tagMismatch)
        XCTAssertThrowsError(try opened.repairMarkers())
    }

    /// Vaults written before version markers are tagged by the first write
    /// (not by a read), like an untagged list (format.md §2.1).
    func testAnUntaggedVaultIsTaggedByItsFirstWriteOnly() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        try edit(v) { m in m.markersTag = nil; m.features.removeAll { $0 == "markers-tag" } }
        let fresh = MemoryRecipientsTrustStore()
        let reader = try Vault.open(at: v.url, identities: [a], trust: fresh)
        XCTAssertEqual(reader.recipientsStatus, .verified(.firstUse))
        _ = try reader.noteIDs().map { try reader.reconstruct(noteId: $0) }
        XCTAssertNil(try VaultManifest.decode(Data(contentsOf: manifestURL(v))).markersTag, "reads write nothing")
        try reader.requireWritable()
        let m = try VaultManifest.decode(Data(contentsOf: manifestURL(v)))
        XCTAssertNotNil(m.markersTag)
        XCTAssertTrue(m.features.contains("markers-tag"))
        XCTAssertEqual(try fresh.record(for: v.vaultId)?.markers, VaultMarkers(m))
        // A later copy of the record never loses them.
        try reader.requireWritable()
        XCTAssertEqual(try fresh.record(for: v.vaultId)?.markers, VaultMarkers(m))
    }

    /// A writer never re-tags markers that changed on disk after it opened the vault.
    func testMarkersChangedSinceOpenAreNotRetagged() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        try edit(v) { m in m.features.removeAll { $0 == "recipients-tag" } }
        XCTAssertThrowsError(try v.writeBlob(note: UUID(), Data("x".utf8), type: "image/png")) {
            guard case .manifestCorrupt? = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(try VaultManifest.decode(Data(contentsOf: manifestURL(v))).features.contains("attachments"))
    }

    /// A sync never takes a `vault.json` whose markers went down; locked, it
    /// takes no change of tagged markers at all.
    func testIncomingManifestsCannotLowerTheMarkers() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        let local = try Data(contentsOf: manifestURL(v))
        let secret = try v.requireSecret()
        var lowered = try VaultManifest.decode(local)
        lowered.features.removeAll { $0 == "signed-secret-link" }
        lowered.tagMarkers(secret: try VaultSecret(bytes: Data(repeating: 9, count: 32)))
        XCTAssertNotNil(Vault.incomingManifestProblem(try lowered.encoded(), local: local, vault: v))
        XCTAssertNotNil(Vault.incomingManifestProblem(try lowered.encoded(), local: local, vault: nil))
        var grown = try VaultManifest.decode(local)
        grown.features.append("attachments")
        grown.tagMarkers(secret: secret)
        XCTAssertNil(Vault.incomingManifestProblem(try grown.encoded(), local: local, vault: v), "a key holder's change")
        XCTAssertNotNil(Vault.incomingManifestProblem(try grown.encoded(), local: local, vault: nil), "unchecked while locked")
        var untagged = try VaultManifest.decode(local)
        untagged.markersTag = nil
        XCTAssertNotNil(Vault.incomingManifestProblem(try untagged.encoded(), local: local, vault: nil))
        XCTAssertNotNil(Vault.incomingManifestProblem(try untagged.encoded(), local: local, vault: v))
    }

    func testTrustRecordsRoundTripTheMarkers() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let secret = VaultSecret.random()
        let record = try RecipientsTrustRecord(vaultId: UUID(), secret: secret, recipients: ["age1pq1x"],
                                               markers: VaultMarkers(format: "sempere/1", features: ["b", "a", "b"]))
        let back = try JSONDecoder().decode(RecipientsTrustRecord.self, from: try JSONEncoder().encode(record))
        XCTAssertEqual(back, record)
        XCTAssertEqual(back.markers?.features, ["a", "b"])
        // A record from before markers still reads.
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(record)) as? [String: Any])
        obj["markers"] = nil
        XCTAssertNil(try JSONDecoder().decode(RecipientsTrustRecord.self, from: try JSONSerialization.data(withJSONObject: obj)).markers)
    }

    /// Attack: the list and the markers changed together. The list's repair
    /// also restores the markers (else neither repair could run first).
    func testARecipientsRepairAlsoRestoresTheMarkers() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        let attacker = pqIdentity()
        try edit(v) { m in
            m.recipients.append(.init(key: attacker.recipient.string, label: "x", added: Date()))
            m.features.removeAll { $0 == VaultManifest.signedLinkFeature }
        }
        var opened = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(reason(opened), .tagMismatch)
        _ = try opened.repairRecipients()
        let after = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(after.recipientsStatus, .verified(.unchanged), "this device wrote the repair")
        XCTAssertEqual(after.recipients.map(\.key), [a.recipient.string])
        XCTAssertTrue(after.manifest.features.contains(VaultManifest.signedLinkFeature))
    }

    /// Attack, then `recipients confirm` (review of #125): confirming the
    /// device list never clears a format or feature downgrade. Each markers
    /// reason is refused, the status stays tampered, and the trust record is
    /// left as it was.
    func testConfirmNeverClearsTamperedMarkers() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        let original = try Data(contentsOf: manifestURL(v))
        let older = original
        _ = try v.writeBlob(note: UUID(), Data("x".utf8), type: "image/png")   // adds attachments
        try Vault.open(at: v.url, identities: [a], trust: store).requireWritable()   // the record learns it
        let current = try Data(contentsOf: manifestURL(v))
        let tampers: [(RecipientsProblem.Reason, () throws -> Void)] = [
            (.markersMismatch, { try self.edit(v) { m in m.features.removeAll { $0 == VaultManifest.signedLinkFeature } } }),
            (.markersRemoved, { try self.edit(v) { m in m.markersTag = nil } }),
            (.markersRolledBack, { try older.write(to: self.manifestURL(v)) }),
        ]
        for (expected, tamper) in tampers {
            try current.write(to: manifestURL(v))
            try tamper()
            let recordBefore = try store.record(for: v.vaultId)
            var opened = try Vault.open(at: v.url, identities: [a], trust: store)
            XCTAssertEqual(reason(opened), expected)
            XCTAssertThrowsError(try opened.confirmRecipients(), "\(expected)") {
                guard case .recipientsNotRepairable? = $0 as? VaultError else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(reason(opened), expected, "still tampered")
            XCTAssertEqual(try store.record(for: v.vaultId), recordBefore, "the record is untouched")
            XCTAssertEqual(reason(try Vault.open(at: v.url, identities: [a], trust: store)), expected)
        }
    }

    /// Confirming another problem never accepts markers that do not check:
    /// with this device's record unreadable, a list whose markers were also
    /// changed is reported as the markers problem and cannot be confirmed.
    func testConfirmOfAnUnreadableRecordChecksTheMarkers() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        try edit(v) { m in m.features.removeAll { $0 == VaultManifest.signedLinkFeature } }
        store.markUnreadable(v.vaultId, "damaged")
        var opened = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(reason(opened), .markersMismatch)
        XCTAssertThrowsError(try opened.confirmRecipients())
        XCTAssertThrowsError(try store.record(for: v.vaultId), "not rewritten")
    }

    /// A restored backup from before both tags (the list's and the markers'):
    /// confirming the list restores the markers this device verified, tagged,
    /// rather than accepting fewer (or leaving both repairs refusing).
    func testConfirmingAnOlderBackupRestoresTheMarkers() throws {
        let store = MemoryRecipientsTrustStore()
        let v = try setUpVault(store)
        try edit(v) { m in
            m.recipientsTag = nil; m.markersTag = nil
            m.features.removeAll { [VaultManifest.recipientsTagFeature, VaultManifest.markersTagFeature,
                                    VaultManifest.signedLinkFeature].contains($0) }
        }
        var opened = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(reason(opened), .tagRemoved)
        try opened.confirmRecipients()
        let after = try Vault.open(at: v.url, identities: [a], trust: store)
        XCTAssertEqual(after.recipientsStatus, .verified(.unchanged))
        XCTAssertNotNil(after.manifest.markersTag)
        XCTAssertTrue(after.manifest.features.contains(VaultManifest.signedLinkFeature), "the record's features come back")
    }
}
