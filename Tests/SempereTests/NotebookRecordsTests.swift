import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Notebook records (format.md §14): the observed-remove set, the file, merges and rewraps.
final class NotebookRecordsTests: VaultTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - The set (pure)

    func testCreateDeclaresOnceAndCanonicalizes() throws {
        let first = try XCTUnwrap(NotebookRecords.create(" School // Math ", records: [], now: now))
        XCTAssertEqual(first.add, ["School/Math"])
        XCTAssertEqual(NotebookRecords.declared([first]), ["School/Math"])
        XCTAssertNil(NotebookRecords.create("School/Math", records: [first], now: now), "declared already")
        XCTAssertNil(NotebookRecords.create(" / ", records: [], now: now), "names no notebook")
    }

    func testRemoveEndsOnlyObservedRecordsSoConcurrentAddsWin() throws {
        let a = NotebookRecord(add: ["Ideas"])
        // Device 1 deletes Ideas having seen only `a`; device 2 declared it again meanwhile.
        let delete = try XCTUnwrap(NotebookRecords.delete("Ideas", records: [a], now: now))
        let b = NotebookRecord(add: ["Ideas"])
        XCTAssertEqual(NotebookRecords.declared([a, delete]), [])
        XCTAssertEqual(NotebookRecords.declared([a, delete, b]), ["Ideas"], "an add the remove did not see survives")
        // Order does not matter: it is a set of files.
        XCTAssertEqual(NotebookRecords.declared([b, delete, a]), ["Ideas"])
    }

    func testRenameMovesPathsWithinAndKeepsTheOthers() throws {
        let r = NotebookRecord(add: ["School", "School/Math", "Schoolwork", "Home"])
        let plan = try XCTUnwrap(NotebookRecords.rename("School", to: "Uni", records: [r], now: now))
        XCTAssertEqual(plan.remove, [r.id])
        XCTAssertEqual(Set(plan.add), ["Uni", "Uni/Math", "Schoolwork", "Home"], "Schoolwork is not inside School")
        XCTAssertEqual(NotebookRecords.declared([r, plan]), ["Home", "Schoolwork", "Uni", "Uni/Math"])
        // Renaming to the top level drops the prefix; the notebook itself names nothing then.
        let lifted = try XCTUnwrap(NotebookRecords.rename("Uni", to: nil, records: [r, plan], now: now))
        XCTAssertEqual(Set(NotebookRecords.declared([r, plan, lifted])), ["Home", "Schoolwork", "Math"])
        XCTAssertNil(NotebookRecords.rename("Nothing", to: "X", records: [r], now: now))
    }

    func testDeleteEndsTheSubtreeOnly() throws {
        let r = NotebookRecord(add: ["A", "A/B", "Ab"])
        let plan = try XCTUnwrap(NotebookRecords.delete("A", records: [r], now: now))
        XCTAssertEqual(plan.add, ["Ab"])
        XCTAssertEqual(NotebookRecords.declared([r, plan]), ["Ab"])
        XCTAssertNil(NotebookRecords.delete("Z", records: [r], now: now))
    }

    func testTreeUnitesNotesAndDeclaredNotebooks() {
        let tree = NotebookRecords.tree(noteNotebooks: ["Work/Atlas", nil], declared: ["Empty/Inner"])
        XCTAssertEqual(NotebookNode.flatten(tree), ["Empty", "Empty/Inner", "Work", "Work/Atlas"])
    }

    // MARK: - JSON

    func testJSONRoundTripsAndRejectsBadRecords() throws {
        let id = UUID()
        let r = NotebookRecord(id: id, created: now, add: ["A/B"], remove: [UUID()])
        let json = try NotebookRecords.encode(r)
        XCTAssertEqual(try NotebookRecords.decode(json, id: id), r)

        func bad(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try NotebookRecords.decode(Data(s.utf8), id: id), file: file, line: line)
        }
        bad(#"{"format":"sempere-notebooks/2","add":["A"]}"#)
        bad(#"{"add":["A"]}"#)
        bad(#"{"format":"sempere-notebooks/1","add":"A"}"#)
        bad(#"{"format":"sempere-notebooks/1","add":[1]}"#)
        bad(#"{"format":"sempere-notebooks/1","remove":["nope"]}"#)
        bad("[]")
        bad("not json")
        let tooMany = "[" + Array(repeating: "\"x\"", count: NotebookRecords.maxAdds + 1).joined(separator: ",") + "]"
        bad(#"{"format":"sempere-notebooks/1","add":"# + tooMany + "}")
        let long = String(repeating: "a", count: NotebookRecords.maxPathScalars + 1)
        bad(#"{"format":"sempere-notebooks/1","add":[""# + long + #""]}"#)

        // Lenient where the format says so: blank paths skipped, a self-removal ignored, unknown fields ignored.
        let lenient = try NotebookRecords.decode(Data(#"{"format":"sempere-notebooks/1","add":[" / ","A//B"],"remove":["\#(id.uuidString.lowercased())"],"x":1}"#.utf8), id: id)
        XCTAssertEqual(lenient.add, ["A/B"])
        XCTAssertEqual(lenient.remove, [])
    }

    func testFileNames() {
        let id = UUID()
        XCTAssertEqual(NotebookRecords.id(ofFileName: NotebookRecords.fileName(id)), id)
        XCTAssertNil(NotebookRecords.id(ofFileName: id.uuidString.uppercased() + ".notebook.age"))
        XCTAssertNil(NotebookRecords.id(ofFileName: ".sempere-tmp-x"))
        XCTAssertNil(NotebookRecords.id(ofFileName: id.uuidString.lowercased() + ".notebook"))
    }

    // MARK: - Files in a vault

    func testVaultCreatesRenamesAndDeletesWithWriteOnceFiles() throws {
        let a = pqIdentity()
        let vault = try makeVault(a)
        XCTAssertEqual(try vault.readNotebookRecords().declared, [])
        XCTAssertNotNil(try vault.createNotebook("Ideas"))
        XCTAssertNil(try vault.createNotebook(" Ideas "), "declared already: nothing written")
        XCTAssertNotNil(try vault.createNotebook("School/Math"))
        XCTAssertEqual(try vault.readNotebookRecords().declared, ["Ideas", "School/Math"])
        XCTAssertNotNil(try vault.renameNotebookRecords("School", to: "Uni"))
        XCTAssertEqual(try vault.readNotebookRecords().declared, ["Ideas", "Uni/Math"])
        XCTAssertNotNil(try vault.deleteNotebookRecords("Ideas"))
        XCTAssertEqual(try vault.readNotebookRecords().declared, ["Uni/Math"])
        XCTAssertEqual(try vault.notebookRecordNames().count, 4, "every change is a new file")
        XCTAssertTrue(vault.verify().isHealthy)

        // Another device (the same keys) reads the same set.
        let reopened = try Vault.open(at: vault.url, identities: [a])
        XCTAssertEqual(try reopened.readNotebookRecords().declared, ["Uni/Math"])
    }

    func testDamagedRecordIsSkippedAndReportedNeverHidesANotebook() throws {
        let vault = try makeVault(pqIdentity())
        let add = try XCTUnwrap(try vault.createNotebook("Kept"))
        let remove = try XCTUnwrap(try vault.deleteNotebookRecords("Kept"))
        XCTAssertEqual(try vault.readNotebookRecords().declared, [])
        try flipByte(vault.notebooksURL.appendingPathComponent(remove.fileName), at: 20)
        let set = try vault.readNotebookRecords()
        XCTAssertEqual(set.declared, ["Kept"], "a remove that cannot be read counts for nothing")
        XCTAssertEqual(Array(set.problems.keys), ["notebooks/\(remove.fileName)"])
        XCTAssertEqual(set.records.map(\.id), [add.id])
        XCTAssertFalse(vault.verify().isHealthy)
    }

    func testARecordRenamedOnDiskDoesNotVerify() throws {
        let vault = try makeVault(pqIdentity())
        let r = try XCTUnwrap(try vault.createNotebook("A"))
        let other = UUID()
        try FileManager.default.moveItem(at: vault.notebooksURL.appendingPathComponent(r.fileName),
                                         to: vault.notebooksURL.appendingPathComponent(NotebookRecords.fileName(other)))
        let set = try vault.readNotebookRecords()
        XCTAssertEqual(set.declared, [])
        XCTAssertEqual(set.problems.count, 1, "the tag binds the file name")
    }

    func testMergeCopyTakesTheUnion() throws {
        let a = pqIdentity()
        let vault = try makeVault(a)
        try vault.createNotebook("Mine")
        let copyURL = tmp.appendingPathComponent("Copy.sempere")
        try FileManager.default.copyItem(at: vault.url, to: copyURL)
        let copy = try Vault.open(at: copyURL, identities: [a])
        try copy.createNotebook("Theirs")
        try copy.deleteNotebookRecords("Mine")
        try vault.createNotebook("Concurrent")

        let report = try vault.mergeCopy(from: copyURL)
        XCTAssertEqual(report.added.filter { $0.hasPrefix("notebooks/") }.count, 2)
        XCTAssertEqual(try vault.readNotebookRecords().declared, ["Concurrent", "Theirs"])
        XCTAssertTrue(try vault.mergeCopy(from: copyURL).added.isEmpty, "idempotent")
    }

    func testBackupListsRecords() throws {
        let vault = try makeVault(pqIdentity())
        let r = try XCTUnwrap(try vault.createNotebook("A"))
        XCTAssertTrue(try Backup.formatFiles(in: vault.url).contains("notebooks/\(r.fileName)"))
        XCTAssertEqual(Backup.maxBytes(forPath: "notebooks/\(r.fileName)"), NotebookRecords.maxFileBytes)
    }

    func testReadOnlyVaultWritesNoRecord() throws {
        let vault = try makeVault(pqIdentity())
        vault.noteNewerContent(in: UUID())
        XCTAssertThrowsError(try vault.createNotebook("A")) { error in
            guard case .readOnly? = error as? VaultError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try vault.notebookRecordNames(), [])
    }
}
