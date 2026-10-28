import Age
import Foundation
import XCTest
import VaultTestSupport
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

    func testMalformedWrapArmorIsReported() throws {
        let a = pqIdentity()
        let vault = try makeVault(a)
        var m = vault.manifest
        let i = try XCTUnwrap(m.keys.firstIndex { $0.role == .recovery })
        m.keys[i].wrap = "-----BEGIN AGE ENCRYPTED FILE-----\nnot base64!\n-----END AGE ENCRYPTED FILE-----\n"
        try m.encoded().write(to: vault.url.appendingPathComponent("vault.json"))
        let problems = vault.verify().manifestProblems
        XCTAssertTrue(problems.contains { $0.hasPrefix("the wrap of recovery is not an armored age file") }, "\(problems)")
    }
}
