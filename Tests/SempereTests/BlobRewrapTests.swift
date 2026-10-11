import Age
import Foundation
import XCTest
@testable import Sempere

/// Recipient changes over blobs (format.md §3.3.1, §8.1.5): the policy,
/// both rewrap methods, renaming on removal, and resuming after an
/// interruption at every point.
final class BlobRewrapTests: VaultTestCase {
    struct Fixture {
        var revisions: [Revision]
        /// Note, reference, content.
        var blobs: [(UUID, BlobRef, Data)]
    }

    /// Two notes: three revisions and three blobs (one unreferenced), six
    /// files to rewrap in all.
    func populateBlobs(_ vault: Vault) throws -> Fixture {
        let writer = vault.allowingLegacyContent()
        var blobs: [(UUID, BlobRef, Data)] = []
        for (note, i) in [(testNote, 1), (testNote, 2), (otherNote, 3)] {
            let content = syntheticBytes(70_000 * i, seed: UInt8(i))
            blobs.append((note, try writer.writeBlob(note: note, content, type: i == 3 ? "audio/mp4" : "image/jpeg"), content))
        }
        var log = LogBuilder(), other = LogBuilder()
        let revs = [
            referencingDelta(&log, 0, refs: [blobs[0].1]),
            log.delta(devA, 10, [.setMeta(.title("Synthetic"))]),
            referencingDelta(&other, 0, note: otherNote, refs: [blobs[2].1]),
        ]
        for r in revs { try writer.write(r) }
        return Fixture(revisions: revs, blobs: blobs)
    }

    /// Every blob file currently in the vault, by note, with its bytes.
    func blobFiles(_ vault: Vault) -> [String: Data] {
        var out: [String: Data] = [:]
        for note in [testNote, otherNote] {
            for f in attEntries(vault, note) {
                out["\(note.uuidString.lowercased())/\(f)"] = try? Data(contentsOf: attDir(vault, note).appendingPathComponent(f))
            }
        }
        return out
    }

    /// True when an old copy of a blob's header opens the current file: the
    /// file key did not change (header-only rewrap).
    func oldHeaderOpens(_ old: Data, current url: URL, with id: any AgeIdentity) throws -> Bool {
        let (_, oldHeaderLength) = try AgeFile.parseHeader(old)
        let spliced = old.prefix(oldHeaderLength) + (try payload(url))
        return (try? AgeFile.decrypt(spliced, with: [id])) != nil
    }

    func assertBlobsReadable(_ fixture: Fixture, at url: URL, by ids: [any AgeIdentity], file: StaticString = #filePath,
                             line: UInt = #line) throws {
        let v = try Vault.open(at: url, identities: ids)
        for (note, ref, content) in fixture.blobs {
            XCTAssertEqual(try v.readBlob(note: note, ref), content, file: file, line: line)
        }
    }

    func journal(_ vault: Vault) throws -> Vault.RewrapJournal {
        try InkJSON.decoder().decode(Vault.RewrapJournal.self,
                                     from: Data(contentsOf: vault.url.appendingPathComponent("rewrap-journal.json")))
    }

    // MARK: - Policy

    func testPolicyChoosesByKindOfChange() {
        let pq1 = pqIdentity().recipient, pq2 = pqIdentity().recipient
        let x = NativeRecipient.x25519(X25519Identity().recipient)
        let p = RewrapPolicy()
        XCTAssertEqual(p.method(rotating: false, from: [pq1], to: [pq1, pq2]), .headerOnly, "add")
        XCTAssertEqual(p.method(rotating: true, from: [pq1, pq2], to: [pq1]), .reencrypt, "remove")
        XCTAssertEqual(p.method(rotating: true, from: [pq1], to: [pq2]), .reencrypt, "replace")
        XCTAssertEqual(p.method(rotating: false, from: [x], to: [x, pq1]), .reencrypt, "add that changes the types")
        XCTAssertEqual(p.method(rotating: true, from: [x, pq1], to: [pq1]), .reencrypt, "finish a migration")
        let swapped = RewrapPolicy(onAdd: .reencrypt, onRemoveOrTypeChange: .headerOnly)
        XCTAssertEqual(swapped.method(rotating: false, from: [pq1], to: [pq1, pq2]), .reencrypt)
        XCTAssertEqual(swapped.method(rotating: true, from: [pq1, pq2], to: [pq1]), .headerOnly)
    }

    // MARK: - Add: header-only by default

    func testAddRewritesHeadersOnlyAndKeepsNames() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try makeVault(a)
        let fx = try populateBlobs(vault)
        let before = blobFiles(vault)
        let report = try vault.addRecipient(b.recipient, label: "B")
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.blobMethod, .headerOnly)
        XCTAssertEqual(report.rewrapped.count, 6)
        XCTAssertFalse(vault.pendingRewrap)
        let after = blobFiles(vault)
        XCTAssertEqual(Set(after.keys), Set(before.keys), "an addition renames nothing")
        for (path, old) in before {
            let url = vault.url.appendingPathComponent("notes/" + path.replacingOccurrences(of: "/", with: "/att/"))
            XCTAssertEqual(try stanzaCount(url), 2)
            let (_, oldLen) = try AgeFile.parseHeader(old)
            XCTAssertEqual(try payload(url), old.dropFirst(oldLen), "nonce and payload copied unchanged")
            XCTAssertTrue(try oldHeaderOpens(old, current: url, with: a))
        }
        try assertBlobsReadable(fx, at: vault.url, by: [b])
        XCTAssertTrue(try Vault.open(at: vault.url, identities: [b]).verify().isHealthy)
    }

    func testAddWithReencryptPolicy() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try makeVault(a)
        let fx = try populateBlobs(vault)
        let before = blobFiles(vault)
        let report = try vault.addRecipient(b.recipient, label: "B", policy: RewrapPolicy(onAdd: .reencrypt))
        XCTAssertEqual(report.blobMethod, .reencrypt)
        XCTAssertEqual(Set(blobFiles(vault).keys), Set(before.keys))
        for (path, old) in before {
            let url = vault.url.appendingPathComponent("notes/" + path.replacingOccurrences(of: "/", with: "/att/"))
            XCTAssertFalse(try oldHeaderOpens(old, current: url, with: a), "new file key")
        }
        try assertBlobsReadable(fx, at: vault.url, by: [b])
    }

    // MARK: - Remove: full re-encryption and rename by default

    func testRemoveReencryptsAndRenames() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let fx = try populateBlobs(vault)
        let before = blobFiles(vault)
        let report = try vault.removeRecipient(b.recipient)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.blobMethod, .reencrypt)
        let after = blobFiles(vault)
        XCTAssertEqual(after.count, 3)
        XCTAssertTrue(Set(after.keys).isDisjoint(with: before.keys), "every blob renamed under the new secret")
        for (note, ref, _) in fx.blobs {
            let url = try blobURL(vault, note, ref)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try stanzaCount(url), 1)
            let oldPath = before.keys.first { $0.hasPrefix(note.uuidString.lowercased()) && before[$0] != nil
                && (try? AgeFile.decrypt(before[$0]!, with: [b]))?.prefix(37).suffix(32) == ref.digest }
            let old = try XCTUnwrap(oldPath.flatMap { before[$0] })
            XCTAssertFalse(try oldHeaderOpens(old, current: url, with: b), "the removed key cannot open the new file")
        }
        try assertBlobsReadable(fx, at: vault.url, by: [a])
        XCTAssertTrue(vault.verify().isHealthy)
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [b]))
    }

    /// The documented weakness of choosing header-only on a removal.
    func testRemoveWithHeaderOnlyKeepsTheFileKey() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let fx = try populateBlobs(vault)
        let before = blobFiles(vault)
        let report = try vault.removeRecipient(b.recipient, policy: RewrapPolicy(onRemoveOrTypeChange: .headerOnly))
        XCTAssertEqual(report.blobMethod, .headerOnly)
        XCTAssertTrue(Set(blobFiles(vault).keys).isDisjoint(with: before.keys), "renamed all the same")
        var opened = 0
        for (note, ref, _) in fx.blobs {
            let url = try blobURL(vault, note, ref)
            for old in before.values where try oldHeaderOpens(old, current: url, with: b) { opened += 1 }
        }
        XCTAssertEqual(opened, 3, "an old header (with the removed key's stanza) still opens each current file")
        try assertBlobsReadable(fx, at: vault.url, by: [a])
    }

    // MARK: - Interrupted and resumed, every point, both methods

    func testInterruptedAddResumesAtEveryPoint() throws {
        for method in RewrapMethod.allCases {
            for stop in 0..<6 {
                let a = pqIdentity(), b = pqIdentity()
                var vault = try makeVault(a, name: "Add-\(method.rawValue)-\(stop)")
                let fx = try populateBlobs(vault)
                let before = blobFiles(vault)
                XCTAssertThrowsError(try vault.addRecipient(b.recipient, label: "B", added: Date(),
                                                            policy: RewrapPolicy(onAdd: method), stopAfter: stop)) {
                    XCTAssertEqual($0 as? VaultError, .interrupted)
                }
                XCTAssertEqual(try journal(vault).rekeyBlobs, method == .reencrypt)
                // Readable throughout by the old key; finished by the new one alone? No: files
                // not yet rewrapped open only with the old key, so resume with it.
                try assertBlobsReadable(fx, at: vault.url, by: [a])
                var resumed = try Vault.open(at: vault.url, identities: [a])
                XCTAssertTrue(resumed.pendingRewrap)
                let report = try resumed.resumeRewrap()
                XCTAssertTrue(report.isComplete, "\(method) stop \(stop): \(report.failures)")
                XCTAssertEqual(report.blobMethod, method)
                XCTAssertFalse(resumed.pendingRewrap)
                XCTAssertEqual(Set(blobFiles(resumed).keys), Set(before.keys))
                for (path, old) in before {
                    let url = vault.url.appendingPathComponent("notes/" + path.replacingOccurrences(of: "/", with: "/att/"))
                    XCTAssertEqual(try stanzaCount(url), 2)
                    XCTAssertEqual(try oldHeaderOpens(old, current: url, with: a), method == .headerOnly, "\(method) \(stop)")
                }
                try assertBlobsReadable(fx, at: vault.url, by: [b])
                XCTAssertTrue(try Vault.open(at: vault.url, identities: [b]).verify().isHealthy)
            }
        }
    }

    func testInterruptedRemoveResumesAtEveryPoint() throws {
        for method in RewrapMethod.allCases {
            for stop in 0..<6 {
                let a = pqIdentity(), b = pqIdentity()
                var vault = try Vault.create(at: vaultURL("Remove-\(method.rawValue)-\(stop)"),
                                             recipients: [a.recipient, b.recipient], identities: [a])
                let fx = try populateBlobs(vault)
                let before = blobFiles(vault)
                XCTAssertThrowsError(try vault.removeRecipient(b.recipient, policy: RewrapPolicy(onRemoveOrTypeChange: method),
                                                               stopAfter: stop)) {
                    XCTAssertEqual($0 as? VaultError, .interrupted)
                }
                XCTAssertEqual(try journal(vault).rekeyBlobs, method == .reencrypt)
                // Pending: references resolve under the new name or, not yet
                // renamed, under the previous secret's (format.md §8.1.5).
                try assertBlobsReadable(fx, at: vault.url, by: [a])
                let pending = try Vault.open(at: vault.url, identities: [a])
                XCTAssertTrue(pending.verify().files.filter { $0.path.contains("/att/") }
                    .allSatisfy { [.ok, .staleRecipients, .unreferenced].contains($0.status) })
                var resumed = pending
                let report = try resumed.resumeRewrap()
                XCTAssertTrue(report.isComplete, "\(method) stop \(stop): \(report.failures)")
                XCTAssertEqual(report.blobMethod, method)
                XCTAssertFalse(resumed.pendingRewrap)
                XCTAssertEqual(blobFiles(resumed).count, 3, "no duplicates left")
                XCTAssertTrue(Set(blobFiles(resumed).keys).isDisjoint(with: before.keys))
                var opened = 0
                for (note, ref, _) in fx.blobs {
                    let url = try blobURL(resumed, note, ref)
                    XCTAssertEqual(try stanzaCount(url), 1)
                    for old in before.values where try oldHeaderOpens(old, current: url, with: b) { opened += 1 }
                }
                XCTAssertEqual(opened, method == .headerOnly ? 3 : 0, "\(method) \(stop)")
                try assertBlobsReadable(fx, at: vault.url, by: [a])
                XCTAssertTrue(resumed.verify().isHealthy, "\(resumed.verify())")
            }
        }
    }

    /// A crash after the new name is in place and before the old one is
    /// deleted: the resume only deletes the old one.
    func testCrashBetweenRenameAndDelete() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let fx = try populateBlobs(vault)
        vault.crashAfterBlobPlace = true
        XCTAssertThrowsError(try vault.removeRecipient(b.recipient)) { XCTAssertEqual($0 as? VaultError, .interrupted) }
        XCTAssertEqual(blobFiles(vault).count, 4, "one blob under both names")
        var resumed = try Vault.open(at: vault.url, identities: [a])
        let report = try resumed.resumeRewrap()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(blobFiles(resumed).count, 3)
        try assertBlobsReadable(fx, at: vault.url, by: [a])
        XCTAssertTrue(resumed.verify().isHealthy)
    }

    /// A crash left a blob under both names and the new copy was then
    /// damaged past its first chunk (bit rot, a partial sync): the resume
    /// must not delete the old, good copy on the strength of the new one's
    /// first chunk. It rewraps the old copy again over the damaged one.
    func testResumeNeverTrustsADamagedNewCopy() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let fx = try populateBlobs(vault)
        vault.crashAfterBlobPlace = true
        XCTAssertThrowsError(try vault.removeRecipient(b.recipient)) { XCTAssertEqual($0 as? VaultError, .interrupted) }
        var resumed = try Vault.open(at: vault.url, identities: [a])
        // The one blob placed under its new name (all are over one 64 KiB chunk).
        let placed = try XCTUnwrap(fx.blobs.first { FileManager.default.fileExists(atPath: try! blobURL(resumed, $0.0, $0.1).path) })
        let newCopy = try blobURL(resumed, placed.0, placed.1)
        var bytes = try Data(contentsOf: newCopy)
        bytes[bytes.count - 1] ^= 0x01   // the last chunk's tag: the first chunk still decrypts
        try bytes.write(to: newCopy)
        XCTAssertNoThrow(try Vault.peekBlobFile(newCopy, identities: [a]), "damage is past the first chunk")

        let report = try resumed.resumeRewrap()
        XCTAssertTrue(report.isComplete, "\(report.failures)")
        XCTAssertEqual(blobFiles(resumed).count, 3)
        try assertBlobsReadable(fx, at: vault.url, by: [a])
        XCTAssertTrue(resumed.verify().isHealthy)
    }

    /// The method recorded in the journal wins on resume; a journal written
    /// before blobs (no `rekeyBlobs`) follows the default for its kind.
    func testResumeUsesTheJournalsMethod() throws {
        for (recorded, expectHeaderOnly) in [(true, false), (false, true), (nil, false)] as [(Bool?, Bool)] {
            let a = pqIdentity(), b = pqIdentity()
            var vault = try Vault.create(at: vaultURL("J\(String(describing: recorded))"),
                                         recipients: [a.recipient, b.recipient], identities: [a])
            let fx = try populateBlobs(vault)
            let before = blobFiles(vault)
            XCTAssertThrowsError(try vault.removeRecipient(b.recipient, policy: RewrapPolicy(onRemoveOrTypeChange: .headerOnly),
                                                           stopAfter: 0))
            var j = try journal(vault)
            j.rekeyBlobs = recorded
            let bytes = try InkJSON.encoder().encode(j)
            try bytes.write(to: vault.url.appendingPathComponent("rewrap-journal.json"))
            // As the writer of such a journal would have: bound in vault.json (format.md §3.3.1).
            let manifestURL = vault.url.appendingPathComponent("vault.json")
            var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
            m.rewrapPending = RecipientsAuth.rewrapPending(vaultId: m.vaultId, journal: bytes, secret: try vault.requireSecret())
            try m.encoded().write(to: manifestURL)
            var resumed = try Vault.open(at: vault.url, identities: [a])
            XCTAssertTrue(try resumed.resumeRewrap().isComplete)
            var opened = 0
            for (note, ref, _) in fx.blobs {
                for old in before.values where try oldHeaderOpens(old, current: try blobURL(resumed, note, ref), with: b) {
                    opened += 1
                }
            }
            XCTAssertEqual(opened, expectHeaderOnly ? 3 : 0, "rekeyBlobs = \(String(describing: recorded))")
        }
    }

    /// A blob named under neither secret is left untouched and reported, and
    /// keeps the journal; a damaged one too.
    func testPlantedAndDamagedBlobsAreNeverRewrapped() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let fx = try populateBlobs(vault)
        let planted = String(repeating: "5", count: 64) + ".image.age"
        try plant(vault, testNote, blobPlaintext(Data("planted".utf8)), as: planted)
        let plantedBytes = try Data(contentsOf: attDir(vault, testNote).appendingPathComponent(planted))
        // A damaged blob: valid header (first chunk) but non-zero padding.
        let damagedContent = Data("synthetic damaged".utf8)
        let damagedRef = BlobRef(content: damagedContent, type: "image/png")
        try plant(vault, otherNote, blobPlaintext(damagedContent, padding: Data([0, 9])),
                  as: try vault.blobFileName(for: damagedRef))
        let report = try vault.removeRecipient(b.recipient)
        XCTAssertFalse(report.isComplete)
        let note = testNote.uuidString.lowercased(), other = otherNote.uuidString.lowercased()
        XCTAssertEqual(report.failures["\(note)/att/\(planted)"], .tagMismatch)
        XCTAssertNotNil(report.failures.keys.first { $0.hasPrefix("\(other)/att/") })
        XCTAssertTrue(vault.pendingRewrap, "the journal stays")
        XCTAssertEqual(try Data(contentsOf: attDir(vault, testNote).appendingPathComponent(planted)), plantedBytes)
        try assertBlobsReadable(fx, at: vault.url, by: [a])
        // Removed by hand, the resume finishes.
        try FileManager.default.removeItem(at: attDir(vault, testNote).appendingPathComponent(planted))
        for f in attEntries(vault, otherNote) {
            let url = attDir(vault, otherNote).appendingPathComponent(f)
            if (try? Vault.readBlobFile(url, identities: [a], secrets: vault.blobSecrets, expected: nil,
                                        maxContent: 1 << 20)) == nil { try FileManager.default.removeItem(at: url) }
        }
        XCTAssertTrue(try vault.resumeRewrap().isComplete)
        XCTAssertFalse(vault.pendingRewrap)
    }

    // MARK: - Post-quantum migration (format.md §3.3.2)

    func testMigrationReencryptsBlobs() throws {
        let x = X25519Identity(), pq = pqIdentity()
        var vault = try makeLegacyVault(x)
        let fx = try populateBlobs(vault)
        let before = blobFiles(vault)
        let report = try vault.replaceRecipient(.x25519(x.recipient), with: pq.recipient)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.blobMethod, .reencrypt)
        for (note, ref, _) in fx.blobs {
            let url = try blobURL(vault, note, ref)
            XCTAssertEqual(try AgeFile.readHeader(contentsOf: url).stanzas.map(\.type), ["mlkem768x25519"])
            for old in before.values { XCTAssertFalse(try oldHeaderOpens(old, current: url, with: x)) }
        }
        try assertBlobsReadable(fx, at: vault.url, by: [pq])

        // Adding a post-quantum key to a legacy vault is a type change.
        let x2 = X25519Identity(), pq2 = pqIdentity()
        var legacy = try makeLegacyVault(x2, name: "Legacy2")
        _ = try populateBlobs(legacy)
        XCTAssertEqual(try legacy.addRecipient(pq2.recipient, label: "pq").blobMethod, .reencrypt)
    }
}
