#if canImport(Darwin)
import Darwin
#endif
import Age
import Foundation
import XCTest
@testable import Sempere

/// `Vault.loadNote(_:reusing:)`: what the app's merge of a remote revision
/// uses, so a note is not decrypted again in full for each one.
final class LoadNoteReuseTests: VaultTestCase {
    func known(_ loaded: LoadedNote) -> [String: Revision] {
        Dictionary(uniqueKeysWithValues: loaded.revisions.map { ($0.name.filename, $0) })
    }

    func testReusedLoadEqualsAFullLoad() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        let log = try populate(vault)
        let first = try vault.loadNote(testNote)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: known(first)), first)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: [:]), first)

        // A new revision is read; the known ones are taken as they are.
        var extra = log[4]
        extra.seq = 9
        extra.hlc = HLC(millis: extra.hlc.millis + 1000, counter: 0)!
        try vault.write(extra)
        let full = try vault.loadNote(testNote)
        XCTAssertEqual(full.revisions.count, first.revisions.count + 1)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: known(first)), full)

        // A known file is not read again: damaging it changes nothing here (a full load sees it).
        try flipByte(fileURL(vault, testNote, log[1].name), at: 5)
        XCTAssertEqual(try vault.loadNote(testNote, reusing: known(full)), full)
        let damaged = try vault.loadNote(testNote)
        XCTAssertEqual(Set(damaged.failures.keys), [log[1].name])
        // A failed name is read again (and fails again) when it is not known.
        var partial = known(full)
        partial[log[1].name.filename] = nil
        XCTAssertEqual(try vault.loadNote(testNote, reusing: partial), damaged)

        // A name no longer listed is left out; a known revision under another name is not used for it.
        try FileManager.default.removeItem(at: fileURL(vault, testNote, log[3].name))
        let fewer = try vault.loadNote(testNote, reusing: known(full))
        XCTAssertFalse(fewer.revisions.contains { $0.name == log[3].name })
        var wrong = known(full)
        wrong[log[0].name.filename] = full.revisions[2]
        XCTAssertEqual(try vault.loadNote(testNote, reusing: wrong).revisions.map(\.name),
                       fewer.revisions.map(\.name))
    }

}
