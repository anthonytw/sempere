import Foundation
@testable import Sempere
import XCTest

/// What Spotlight indexing donates (docs/design/1.3-spotlight.md §3.2, §3.3, §6).
final class SpotlightPlanTests: XCTestCase {
    let vault = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!

    func note(_ title: String, tags: [String] = [], notebook: String? = nil, deleted: Bool = false,
              modified: TimeInterval = 1_700_000_000, text: String? = nil) -> NoteSummary {
        var s = NoteSummary(id: UUID(), title: title, tags: tags, notebook: notebook, deleted: deleted, pages: 1, strokes: 3,
                            modified: Date(timeIntervalSince1970: modified), problem: nil)
        if let text { s.pageTexts = [PageText(pageId: UUID(), number: 1, text: text)] }
        return s
    }

    func testMetadataOnlyByDefault() throws {
        let n = note("Lecture 4", tags: ["physics", "exam"], notebook: "School/Physics", text: "secret handwriting")
        let plan = SpotlightPlanner.plan(vaultId: vault, notes: [n], options: SpotlightOptions())
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.title, "Lecture 4")
        XCTAssertEqual(item.keywords, ["physics", "exam"])
        XCTAssertEqual(item.contentDescription, "School/Physics · 2023-11-14")
        XCTAssertNil(item.textContent)
        XCTAssertFalse(item.contentDescription.contains("secret"))
        XCTAssertEqual(item.id, "\(vault.uuidString.lowercased())/\(n.id.uuidString.lowercased())")
        XCTAssertEqual(item.domain, "io.github.anthonytw.sempere.\(vault.uuidString.lowercased())")
    }

    func testTextOnlyBehindTheSecondSwitchAndCapped() throws {
        let long = String(repeating: "abc ", count: 10_000)
        let n = note("Big", notebook: "A", text: long)
        let item = try XCTUnwrap(SpotlightPlanner.plan(vaultId: vault, notes: [n], options: SpotlightOptions(includeText: true)).items.first)
        XCTAssertEqual(item.textContent?.count, SpotlightPlanner.maxTextCharacters)
        // The description carries the first 140 characters of text instead of the date.
        XCTAssertEqual(item.contentDescription, "A · " + String(repeating: "abc ", count: 35).trimmingCharacters(in: .whitespaces))
        XCTAssertFalse(item.contentDescription.contains("2023"))
    }

    func testTranscriptsOnlyWithTextAndWhenSupplied() throws {
        let n = note("Voice", text: "page text")
        let with = SpotlightPlanner.plan(vaultId: vault, notes: [n], options: SpotlightOptions(includeText: true),
                                         transcripts: [n.id: ["spoken words"]])
        XCTAssertEqual(with.items.first?.textContent, "page text\nspoken words")
        let without = SpotlightPlanner.plan(vaultId: vault, notes: [n], options: SpotlightOptions(includeText: true))
        XCTAssertEqual(without.items.first?.textContent, "page text")
        let metadata = SpotlightPlanner.plan(vaultId: vault, notes: [n], options: SpotlightOptions(), transcripts: [n.id: ["spoken words"]])
        XCTAssertNil(metadata.items.first?.textContent)
    }

    func testDeletedAndNotDownloadedNotesAreLeftOut() {
        let kept = note("Kept"), gone = note("Gone", deleted: true), partial = note("Partial")
        let plan = SpotlightPlanner.plan(vaultId: vault, notes: [kept, gone, partial], options: SpotlightOptions(),
                                         notDownloaded: [partial.id])
        XCTAssertEqual(plan.items.map(\.noteId), [kept.id])
    }

    func testBlankTitleAndVaultName() throws {
        let n = note("   ", notebook: nil)
        let item = try XCTUnwrap(SpotlightPlanner.plan(vaultId: vault, notes: [n], options: SpotlightOptions(vaultName: "Work")).items.first)
        XCTAssertEqual(item.title, "Untitled note")
        XCTAssertEqual(item.contentDescription, "Work · 2023-11-14")
        let single = try XCTUnwrap(SpotlightPlanner.plan(vaultId: vault, notes: [n], options: SpotlightOptions()).items.first)
        XCTAssertEqual(single.contentDescription, "2023-11-14")
    }

    func testNoteCap() {
        // The cap is exercised on its own rule: the oldest are the ones left out.
        let notes = (0..<5).map { note("N\($0)", modified: 1_000 + Double($0)) }
        var plan = SpotlightPlanner.plan(vaultId: vault, notes: notes, options: SpotlightOptions())
        XCTAssertEqual(plan.omitted, 0)
        XCTAssertEqual(plan.items.map(\.title), ["N4", "N3", "N2", "N1", "N0"])
        XCTAssertEqual(SpotlightPlanner.maxNotes, 50_000)
        plan = SpotlightPlan(items: plan.items, omitted: 2)
        XCTAssertEqual(plan.omitted, 2)
    }

    func testDiffTracksEveryDonatedField() {
        let a = note("A", tags: ["x"], notebook: "N", text: "one")
        let options = SpotlightOptions(includeText: true)
        let first = SpotlightPlanner.plan(vaultId: vault, notes: [a], options: options).items
        let old = SpotlightPlanner.fingerprints(first)
        XCTAssertTrue(SpotlightPlanner.diff(old: old, new: first).isEmpty)
        var changed = a
        for edit in [{ (n: inout NoteSummary) in n.title = "B" }, { $0.tags = ["y"] }, { $0.notebook = "M" },
                     { $0.pageTexts = [PageText(pageId: UUID(), number: 1, text: "two")] },
                     { $0.modified = Date(timeIntervalSince1970: 5) }] {
            changed = a
            edit(&changed)
            let next = SpotlightPlanner.plan(vaultId: vault, notes: [changed], options: options).items
            XCTAssertEqual(SpotlightPlanner.diff(old: old, new: next).upserts.count, 1)
            XCTAssertTrue(SpotlightPlanner.diff(old: old, new: next).deletes.isEmpty)
        }
    }

    func testDiffDeletesAndRestores() {
        let a = note("A"), b = note("B")
        let both = SpotlightPlanner.plan(vaultId: vault, notes: [a, b], options: SpotlightOptions()).items
        let old = SpotlightPlanner.fingerprints(both)
        var deleted = b
        deleted.deleted = true
        let after = SpotlightPlanner.plan(vaultId: vault, notes: [a, deleted], options: SpotlightOptions()).items
        let change = SpotlightPlanner.diff(old: old, new: after)
        XCTAssertEqual(change.deletes, [SpotlightPlanner.identifier(vault: vault, note: b.id)])
        XCTAssertTrue(change.upserts.isEmpty)
        // Restoring re-donates it.
        let restored = SpotlightPlanner.diff(old: SpotlightPlanner.fingerprints(after), new: both)
        XCTAssertEqual(restored.upserts.map(\.noteId), [b.id])
    }

    func testIdentifiersParse() {
        let n = UUID()
        let id = SpotlightPlanner.identifier(vault: vault, note: n)
        XCTAssertEqual(id, id.lowercased())
        let parsed = SpotlightPlanner.parse(identifier: id)
        XCTAssertEqual(parsed?.vault, vault)
        XCTAssertEqual(parsed?.note, n)
        XCTAssertNil(SpotlightPlanner.parse(identifier: "nonsense"))
        XCTAssertNil(SpotlightPlanner.parse(identifier: "\(vault)/\(n)/extra"))
    }

    func testNoThumbnailOrDerivedFieldsExist() {
        // The item has no field for pictures, summaries or embeddings: what is donated is exactly these.
        let item = SpotlightItem(vaultId: vault, noteId: UUID(), title: "t", contentDescription: "d", keywords: [], modified: nil, textContent: nil)
        let names = Mirror(reflecting: item).children.compactMap(\.label).sorted()
        XCTAssertEqual(names, ["contentDescription", "domain", "id", "keywords", "modified", "noteId", "textContent", "title", "vaultId"])
    }
}
