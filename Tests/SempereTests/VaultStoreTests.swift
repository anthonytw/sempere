import Age
import Foundation
import XCTest
@testable import Sempere

final class VaultStoreTests: VaultTestCase {
    func testCreateWritesManifestAndLayout() throws {
        let id = pqIdentity()
        let created = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T16:20:00Z"))
        let vid = UUID(uuidString: "0D1C6A1E-9A44-4A6C-8A6B-0E2A0E9B1F3C")!
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], labels: ["Anthony's iPad"],
                                     identities: [id], vaultId: vid, created: created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("keys").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("notes").path))

        let raw = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["format", "vaultId", "created", "recipients", "vaultSecret", "features",
                                       "recipientsTag", "markersTag"])
        XCTAssertEqual(obj["features"] as? [String], ["recipients-tag", "signed-secret-link", "markers-tag"])
        XCTAssertEqual((obj["recipientsTag"] as? String)?.count, 64)
        XCTAssertEqual((obj["markersTag"] as? String)?.count, 64)
        XCTAssertEqual(obj["format"] as? String, "sempere/1")
        XCTAssertEqual(obj["vaultId"] as? String, "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")
        XCTAssertEqual(obj["created"] as? String, "2026-10-04T16:20:00.000Z")
        let r = try XCTUnwrap((obj["recipients"] as? [[String: Any]])?.first)
        XCTAssertEqual(r["key"] as? String, id.recipient.string)
        XCTAssertEqual(r["label"] as? String, "Anthony's iPad")
        let secretText = try XCTUnwrap(obj["vaultSecret"] as? String)
        XCTAssertTrue(secretText.hasPrefix("-----BEGIN AGE ENCRYPTED FILE-----\n"))
        XCTAssertEqual(try AgeFile.decrypt(Data(secretText.utf8), with: [id]).count, 32)

        let reopened = try Vault.open(at: vault.url, identities: [id])
        XCTAssertEqual(reopened.manifest, vault.manifest)
        XCTAssertEqual(reopened.secret, vault.secret)
        XCTAssertFalse(reopened.isLocked)

        XCTAssertThrowsError(try Vault.create(at: vault.url, recipients: [id.recipient])) {
            guard case .alreadyExists = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try Vault.create(at: tmp.appendingPathComponent("plain"), recipients: [id.recipient])) {
            XCTAssertEqual($0 as? VaultError, .invalidVaultName("plain"))
        }
        XCTAssertThrowsError(try Vault.open(at: tmp, identities: [id])) {
            guard case .notAVault = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [pqIdentity()])) {
            guard case .vaultSecretUndecryptable = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    /// The manifest example from format.md §2 decodes.
    func testSpecManifestExampleParses() throws {
        let json = """
        {
          "format": "sempere/1",
          "vaultId": "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c",
          "created": "2026-10-04T16:20:00Z",
          "recipients": [
            { "key": "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p",
              "label": "Anthony's iPad", "added": "2026-10-04T16:20:00Z" }
          ],
          "vaultSecret": "-----BEGIN AGE ENCRYPTED FILE-----\\n...\\n-----END AGE ENCRYPTED FILE-----\\n"
        }
        """
        let m = try Vault.readManifest(Data(json.utf8))
        XCTAssertEqual(m.recipients.map(\.label), ["Anthony's iPad"])
        XCTAssertEqual(m.vaultId, UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c"))
        XCTAssertThrowsError(try Vault.readManifest(Data(json.replacingOccurrences(of: "sempere/1", with: "sempere/0").utf8))) {
            XCTAssertEqual($0 as? VaultError, .unsupportedFormat("sempere/0"))
        }
    }

    func testWriteReadSnapshotReconstructAndIgnoreStrays() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = sampleLog()
        for r in log { try vault.write(r) }

        // Strays: a file in the note dir, a non-UUID dir, a file at the root, an uppercase UUID dir.
        let noteDir = fileURL(vault, testNote, log[0].name).deletingLastPathComponent()
        let strays = [noteDir.appendingPathComponent("notes.txt"), noteDir.appendingPathComponent(".DS_Store"),
                      vault.url.appendingPathComponent("notes/not-a-uuid/x.delta.age"),
                      vault.url.appendingPathComponent("README")]
        for s in strays {
            try FileManager.default.createDirectory(at: s.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stray".utf8).write(to: s)
        }

        XCTAssertEqual(try vault.noteIDs(), [testNote])
        XCTAssertEqual(try vault.revisionNames(of: testNote), log.map(\.name).sorted())
        for r in log { XCTAssertEqual(try vault.readRevision(noteId: testNote, name: r.name), r) }
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devA), 4)
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devB), 3)
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devC), 1)

        let expected = try NoteReducer.reconstruct(log)
        XCTAssertEqual(try vault.reconstruct(noteId: testNote), expected)
        XCTAssertEqual(expected.meta.title, "Lecture 3")
        XCTAssertEqual(expected.pages.first?.strokes.count, 2)

        var clock = HybridClock()
        let snap = try vault.snapshot(noteId: testNote, device: devC, clock: &clock,
                                      wall: wallAt(baseMillis + 40), app: "test/0")
        XCTAssertEqual(snap.seq, 1)
        XCTAssertEqual(snap.kind, .snapshot)
        XCTAssertEqual(try vault.readRevision(noteId: testNote, name: snap.name), snap)
        XCTAssertEqual(try vault.reconstruct(noteId: testNote), try NoteReducer.reconstruct(log + [snap]))
        XCTAssertEqual(try vault.reconstruct(noteId: testNote).pages, expected.pages)

        // History is in (hlc, device, seq) order with wall times.
        let hist = try vault.history(noteId: testNote)
        XCTAssertEqual(hist.map(\.name), (log + [snap]).map(\.name).sorted())
        XCTAssertEqual(hist.first?.wall, log[0].wall)
        XCTAssertTrue(hist.allSatisfy { $0.error == nil && $0.app == "test/0" })

        // Compaction: everything covered and old goes; the snapshot stays.
        let deleted = try vault.compact(noteId: testNote, retention: 0, now: wallAt(baseMillis + 100_000))
        XCTAssertEqual(deleted, log.map(\.name).sorted())
        XCTAssertEqual(try vault.revisionNames(of: testNote), [snap.name])
        XCTAssertEqual(try vault.reconstruct(noteId: testNote).pages, expected.pages)
        // A device whose files were compacted away continues after its covered seqs.
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devA), 4)
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devC), 2)

        for s in strays { XCTAssertTrue(FileManager.default.fileExists(atPath: s.path), "stray kept: \(s.path)") }
    }

    func testWriteRefusesOverwriteAndSeqReuse() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let rev = sampleLog()[0]
        try vault.write(rev)
        let file = fileURL(vault, testNote, rev.name)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try vault.write(rev)) {
            guard case .alreadyExists = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        var other = rev
        other.hlc = HLC(millis: rev.hlc.millis + 1, counter: 0)!
        XCTAssertThrowsError(try vault.write(other)) {
            XCTAssertEqual($0 as? VaultError, .seqInUse(device: devA.rawValue, seq: 1))
        }
        XCTAssertEqual(try Data(contentsOf: file), before, "existing file untouched")
        // No temp files left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
                       [rev.name.filename])
    }

    func testLockedVaultListsNamesOnly() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        let locked = try Vault.open(at: vault.url)
        XCTAssertTrue(locked.isLocked)
        XCTAssertEqual(try locked.noteIDs(), [testNote])
        XCTAssertEqual(try locked.revisionNames(of: testNote).count, log.count)
        XCTAssertEqual(try locked.nextSeq(noteId: testNote, device: devA), 4)
        XCTAssertThrowsError(try locked.readRevision(noteId: testNote, name: log[0].name)) {
            XCTAssertEqual($0 as? VaultError, .locked)
        }
        XCTAssertThrowsError(try locked.write(sampleLog()[0])) { XCTAssertEqual($0 as? VaultError, .locked) }
        XCTAssertThrowsError(try locked.reconstruct(noteId: testNote)) { XCTAssertEqual($0 as? VaultError, .locked) }
        let report = locked.verify()
        XCTAssertEqual(report.counts[.notChecked], log.count)
        XCTAssertTrue(report.manifestOK)
    }

    func testReconstructReportsBadFiles() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        try flipByte(fileURL(vault, testNote, log[2].name), at: 5)
        XCTAssertThrowsError(try vault.reconstruct(noteId: testNote)) {
            guard case .revision(let name, .undecryptable) = $0 as? VaultError else { return XCTFail("\($0)") }
            XCTAssertEqual(name, log[2].name.filename)
        }
        let loaded = try vault.loadNote(testNote)
        XCTAssertEqual(loaded.revisions.count, log.count - 1)
        XCTAssertEqual(Array(loaded.failures.keys), [log[2].name])
        // Compaction never deletes what it cannot read.
        var clock = HybridClock()
        let snapRevs = loaded.revisions
        let snap = try SnapshotBuilder.makeSnapshot(from: snapRevs, device: devC, seq: 1, clock: &clock,
                                                    wall: wallAt(baseMillis + 50), app: "test/0")
        try vault.write(snap)
        let deleted = try vault.compact(noteId: testNote, retention: 0, now: wallAt(baseMillis + 100_000))
        XCTAssertFalse(deleted.contains(log[2].name))
        XCTAssertTrue(try vault.revisionNames(of: testNote).contains(log[2].name))
    }

    func testVerifyHealthyThenCorruptAndStray() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)

        var report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.counts[.ok], log.count + 1)
        XCTAssertEqual(report.counts.count, 1)

        // 1. Storage damage: a flipped ciphertext byte.
        try flipByte(fileURL(vault, testNote, log[1].name), at: 3)
        // 2. A planted file: valid age to our recipient, but the attacker
        //    lacks the vault secret, so the tag cannot match.
        let planted = RevisionName(hlc: HLC(millis: baseMillis + 999, counter: 0)!, device: devC, seq: 1, kind: .delta)
        var forged = log[0]
        forged.device = devC; forged.hlc = planted.hlc
        let body = try BodyFraming.frame(json: InkJSON.encoder().encode(forged), noteId: testNote.uuidString.lowercased(),
                                         filename: planted.filename, secret: .random())
        try AgeFile.encrypt(body, to: [id.recipient]).write(to: fileURL(vault, testNote, planted))
        // 3. A stray file.
        try Data("hi".utf8).write(to: fileURL(vault, testNote, log[0].name).deletingLastPathComponent()
            .appendingPathComponent("stray.txt"))
        // 4. Valid age, valid tag, but not gzip.
        let junkName = RevisionName(hlc: HLC(millis: baseMillis + 1000, counter: 0)!, device: devC, seq: 2, kind: .delta)
        let junk = BodyFraming.frame(gzip: Data("not gzip".utf8), noteId: testNote.uuidString.lowercased(),
                                     filename: junkName.filename, secret: try XCTUnwrap(vault.secret))
        try AgeFile.encrypt(junk, to: [id.recipient]).write(to: fileURL(vault, testNote, junkName))

        report = vault.verify()
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.manifestOK)
        XCTAssertEqual(report.counts[.ok], log.count)    // 4 intact revisions + 1 identity file
        XCTAssertEqual(report.counts[.undecryptable], 1)
        XCTAssertEqual(report.counts[.tagMismatch], 1)
        XCTAssertEqual(report.counts[.corruptBody], 1)
        XCTAssertEqual(report.counts[.unknownFile], 1)
        let bad = Dictionary(uniqueKeysWithValues: report.files.map { ($0.path, $0.status) })
        let base = "notes/\(testNote.uuidString.lowercased())/"
        XCTAssertEqual(bad[base + log[1].name.filename], .undecryptable)
        XCTAssertEqual(bad[base + planted.filename], .tagMismatch)
        XCTAssertEqual(bad[base + junkName.filename], .corruptBody)
        XCTAssertEqual(bad[base + "stray.txt"], .unknownFile)

        // A tampered manifest is reported, not thrown.
        let m = vault.url.appendingPathComponent("vault.json")
        try Data("{".utf8).write(to: m)
        XCTAssertFalse(vault.verify().manifestOK)
    }

    /// Security review 2026-10 (W2): a snapshot whose tag does not verify
    /// was made by someone with only the public keys and covers nothing, so
    /// `nextSeq` skips it and the note stays editable. A snapshot that does
    /// not decrypt may hide real coverage and still stops it.
    func testForgedSnapshotNeverBlocksNextSeq() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        let expected = try vault.nextSeq(noteId: testNote, device: devA)

        let planted = RevisionName(hlc: HLC(millis: baseMillis + 999, counter: 0)!, device: devC, seq: 1, kind: .snapshot)
        var forged = log[0]
        forged.device = devC; forged.hlc = planted.hlc; forged.seq = 1
        forged.body = .snapshot(included: Included([devA: .init(upTo: 1_000_000)]), state: try vault.reconstruct(noteId: testNote))
        let body = try BodyFraming.frame(json: InkJSON.encoder().encode(forged), noteId: testNote.uuidString.lowercased(),
                                         filename: planted.filename, secret: .random())
        try AgeFile.encrypt(body, to: [id.recipient]).write(to: fileURL(vault, testNote, planted))
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devA), expected, "its claimed coverage is ignored")
        XCTAssertNoThrow(try vault.apply([.setMeta(.title("still editable"))], to: testNote,
                                         deviceState: tmp.appendingPathComponent("dev.json"), app: "test/0"))

        let damaged = RevisionName(hlc: HLC(millis: baseMillis + 1999, counter: 0)!, device: devC, seq: 2, kind: .snapshot)
        try Data("age-encryption.org/v1\njunk".utf8).write(to: fileURL(vault, testNote, damaged))
        XCTAssertThrowsError(try vault.nextSeq(noteId: testNote, device: devA)) { error in
            guard case VaultError.revision(let name, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, damaged.filename)
        }
    }
}
