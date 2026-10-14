import Age
import Foundation
import XCTest
@testable import Sempere

/// "Could not read" must never look like "nothing there" (review of #6).
final class FailurePathTests: VaultTestCase {
    override func tearDownWithError() throws {
        // Restore permissions so the temporary directory can be removed.
        if let e = FileManager.default.enumerator(atPath: tmp.path) {
            for case let rel as String in e {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: tmp.appendingPathComponent(rel).path)
            }
        }
        try super.tearDownWithError()
    }

    /// Makes `url` unreadable (a file) or unlistable (a directory) and
    /// returns a closure that undoes it. Uses chmod 000; where that does not
    /// stop reads (root, as in the Linux CI container) it falls back to a
    /// dangling symlink in place of a file, or a regular file in place of a
    /// directory, so the test runs everywhere instead of skipping.
    func makeUnreadable(_ url: URL) throws -> () throws -> Void {
        let fm = FileManager.default
        let isDir = FileIO.isDirectory(url)
        let mode = isDir ? 0o755 : 0o644
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let stillReadable = isDir ? (try? fm.contentsOfDirectory(atPath: url.path)) != nil
                                  : fm.isReadableFile(atPath: url.path)
        guard stillReadable else {
            return { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        }
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        let aside = url.deletingLastPathComponent().appendingPathComponent(".aside-\(UUID().uuidString)")
        try fm.moveItem(at: url, to: aside)
        if isDir {
            try Data("not a directory".utf8).write(to: url)
        } else {
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: "/nonexistent/\(UUID().uuidString)")
        }
        return {
            try fm.removeItem(at: url)
            try fm.moveItem(at: aside, to: url)
        }
    }

    func testUnreadableFileKeepsJournalUntilRetrySucceeds() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let revs = try populate(vault)
        let oldSecret = try XCTUnwrap(vault.secret)
        let victim = fileURL(vault, revs[1].noteId, revs[1].name)
        let undo = try makeUnreadable(victim)

        let report = try vault.removeRecipient(b.recipient)
        XCTAssertFalse(report.isComplete)
        guard case .unreadable = report.failures.values.first else { return XCTFail("\(report.failures)") }
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.rewrapped.count, revs.count - 1)
        XCTAssertTrue(vault.pendingRewrap, "journal survives a failed file")
        XCTAssertEqual(vault.previousSecret, oldSecret)

        // A fresh process still has the outgoing secret, via the journal.
        try undo()
        var again = try Vault.open(at: vault.url, identities: [a])
        XCTAssertNil(again.journalProblem)
        XCTAssertEqual(again.previousSecret, oldSecret)
        XCTAssertEqual(try again.readRevision(noteId: revs[1].noteId, name: revs[1].name), revs[1])
        let retry = try again.resumeRewrap()
        XCTAssertTrue(retry.isComplete)
        XCTAssertEqual(retry.rewrapped, ["\(revs[1].noteId.uuidString.lowercased())/\(revs[1].name.filename)"])
        XCTAssertFalse(again.pendingRewrap)
        try assertReadable(revs, at: vault.url, by: a)
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [b]))
    }

    func testUnlistableNotesDirectoryIsNeverHealthy() throws {
        let a = pqIdentity()
        let vault = try makeVault(a)
        _ = try populate(vault)
        let notes = vault.url.appendingPathComponent("notes")
        let undo = try makeUnreadable(notes)
        defer { try? undo() }
        XCTAssertThrowsError(try vault.noteIDs()) {
            guard case .io = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        let report = vault.verify()
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.counts[.unlistable], 1)
        var v = vault
        XCTAssertThrowsError(try v.addRecipient(pqIdentity().recipient, label: "x"))
    }

    func testUnreadableJournalIsRecordedAndSurfaced() throws {
        let a = pqIdentity(), b = pqIdentity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let revs = try populate(vault)
        XCTAssertThrowsError(try vault.removeRecipient(b.recipient, stopAfter: 2))
        try Data("{".utf8).write(to: vault.url.appendingPathComponent("rewrap-journal.json"))

        var again = try Vault.open(at: vault.url, identities: [a])
        XCTAssertNotNil(again.journalProblem)
        XCTAssertNil(again.previousSecret)
        // Files still tagged with the outgoing secret say why they fail.
        let stale = revs.filter { r in
            (try? again.readRevision(noteId: r.noteId, name: r.name)) == nil
        }
        XCTAssertEqual(stale.count, revs.count - 2)
        XCTAssertThrowsError(try again.readRevision(noteId: stale[0].noteId, name: stale[0].name)) {
            guard case .tagMismatchJournalUnreadable(let why) = $0 as? RevisionReadError else { return XCTFail("\($0)") }
            XCTAssertTrue(why.hasPrefix("a pending rewrap journal could not be read"))
        }
        let report = again.verify()
        XCTAssertFalse(report.isHealthy)
        XCTAssertNotNil(report.journalProblem)
        XCTAssertEqual(report.counts[.tagMismatch], revs.count - 2)
        XCTAssertThrowsError(try again.resumeRewrap()) {
            guard case .rewrapJournalUnreadable = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(again.pendingRewrap)
    }

    func testNextSeqRefusesUnreadableSnapshot() throws {
        let a = pqIdentity()
        let vault = try makeVault(a)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        var clock = HybridClock()
        let snap = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                      app: "test/0")
        XCTAssertEqual(Vault.nextSeq(from: log + [snap], device: devA), 4)
        XCTAssertEqual(Vault.nextSeq(from: [snap], device: devB), 3, "coverage counts without the files")
        XCTAssertEqual(Vault.nextSeq(from: [], device: devA), 1)
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devC), 2)

        try flipByte(fileURL(vault, testNote, snap.name), at: 4)
        XCTAssertThrowsError(try vault.nextSeq(noteId: testNote, device: devA)) {
            guard case .revision(let name, .undecryptable) = $0 as? VaultError else { return XCTFail("\($0)") }
            XCTAssertEqual(name, snap.name.filename)
        }
    }

    func testWriteOnlyVaultCannotRead() throws {
        let a = pqIdentity()
        let vault = try Vault.create(at: vaultURL(), recipients: [a.recipient])
        XCTAssertFalse(vault.isLocked)
        XCTAssertFalse(vault.canRead)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        XCTAssertThrowsError(try vault.readRevision(noteId: testNote, name: log[0].name)) {
            XCTAssertEqual($0 as? VaultError, .noIdentities)
        }
        XCTAssertThrowsError(try vault.reconstruct(noteId: testNote)) { XCTAssertEqual($0 as? VaultError, .noIdentities) }
        XCTAssertThrowsError(try vault.history(noteId: testNote)) { XCTAssertEqual($0 as? VaultError, .noIdentities) }
        let report = vault.verify()
        XCTAssertEqual(report.counts[.notChecked], log.count)
        XCTAssertTrue(report.files.filter { $0.status == .notChecked }.allSatisfy { $0.detail == "no identities" })
        var v = vault
        XCTAssertThrowsError(try v.addRecipient(pqIdentity().recipient, label: "x")) {
            XCTAssertEqual($0 as? VaultError, .noIdentities)
        }
        // Another device with the identity reads everything.
        let reader = try Vault.open(at: vault.url, identities: [a])
        XCTAssertTrue(reader.canRead)
        XCTAssertEqual(try reader.reconstruct(noteId: testNote), try NoteReducer.reconstruct(log))
    }

    func testMalformedVaultSecretArmorIsReported() throws {
        let a = pqIdentity()
        let vault = try makeVault(a)
        var m = vault.manifest
        m.vaultSecret = "-----BEGIN AGE ENCRYPTED FILE-----\nnot base64!\n-----END AGE ENCRYPTED FILE-----\n"
        try m.encoded().write(to: vault.url.appendingPathComponent("vault.json"))
        let problems = vault.verify().manifestProblems
        XCTAssertTrue(problems.contains { $0.hasPrefix("vaultSecret is not an armored age file") }, "\(problems)")
    }
}
