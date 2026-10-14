import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere recognize` and `notes search`. Reading handwriting needs Vision: on Linux the commands
/// must refuse (and change nothing); on macOS they run for real. Neither
/// asserts what Vision reads from synthetic strokes, only what is stored.
final class CLIRecognizeTests: CLITestCase {
    /// A vault from `makeVault` whose first note's page 1 carries Notability's
    /// recognition (no `basis`).
    func vaultWithImportedText() throws -> (vault: Vault, keyPath: String, note: UUID, pages: [UUID]) {
        let (vault, _, keyPath) = try makeVault()
        let note = UUID(uuidString: "aaaaaaaa-1111-4111-8111-000000000001")!
        let pages = try vault.reconstruct(noteId: note).pages.map(\.id)
        let other = DeviceID("0badf00d")!
        try vault.write(Revision(noteId: note, device: other, seq: 1, hlc: HLC(millis: 1_760_000_009_000, counter: 0)!,
                                 wall: Date(timeIntervalSince1970: 1_760_000_009), app: "cli-test/1",
                                 body: .delta(ops: [.setPageRecognition(pageId: pages[0],
                                                                        recognition: Recognition(engine: "notability-14.2",
                                                                                                 text: "Imported"))])))
        return (vault, keyPath, note, pages)
    }

    func args(_ vault: Vault, _ keyPath: String) -> [String] { ["--vault", vault.url.path, "--identity", keyPath] }

    func revisionCount(_ vault: Vault) throws -> Int {
        try vault.noteIDs().reduce(0) { $0 + (try vault.revisionNames(of: $1).count) }
    }

    /// `read` page numbers per note id, from `--json`.
    func readPages(_ r: CLIResult) throws -> [String: [Int]] {
        let notes = try XCTUnwrap((r.json as? [String: Any])?["notes"] as? [[String: Any]], r.out + r.err)
        return Dictionary(uniqueKeysWithValues: notes.map { ($0["note"] as! String, $0["read"] as! [Int]) })
    }

    func testDryRunListsThePagesEachModeReads() throws {
        let (vault, key, note, _) = try vaultWithImportedText()
        let before = try revisionCount(vault)
        let n1 = note.uuidString.lowercased(), n2 = "bbbbbbbb-2222-4222-8222-000000000002"

        let stale = try cli(["recognize", "--all", "--dry-run", "--json"] + args(vault, key))
        XCTAssertEqual(stale.status, 0, stale.err)
        XCTAssertEqual(try readPages(stale), [n1: [2], n2: [1]], "Notability's text on page 1 is kept")
        let missing = try cli(["recognize", "Physics / Week 3", "--missing-only", "--dry-run", "--json"] + args(vault, key))
        XCTAssertEqual(try readPages(missing), [n1: [2]])
        let force = try cli(["recognize", "aaaa", "--force", "--dry-run", "--json"] + args(vault, key))
        XCTAssertEqual(try readPages(force), [n1: [1, 2]])
        let text = try cli(["recognize", "--all", "--dry-run"] + args(vault, key))
        XCTAssertTrue(text.out.contains("would read page(s) 2"), text.out)
        XCTAssertEqual(try revisionCount(vault), before)
    }

    func testUsageErrors() throws {
        let (vault, key, _, _) = try vaultWithImportedText()
        for bad in [["recognize"], ["recognize", "--all", "Groceries"], ["recognize", "--all", "--force", "--missing-only"],
                    ["notes", "search", "  "]] {
            XCTAssertEqual(try cli(bad + args(vault, key)).status, 2, "\(bad)")
        }
    }

    func testNotesSearchRanksLikeTheApp() throws {
        let (vault, key, note, _) = try vaultWithImportedText()
        _ = try cli(["notes", "tag", "Groceries", "--add", "imported"] + args(vault, key))
        let r = try cli(["notes", "search", "imported", "--json"] + args(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let hits = try XCTUnwrap(r.json as? [[String: Any]])
        // A tag match outranks a match in page text.
        XCTAssertEqual(hits.map { $0["title"] as? String }, ["Groceries", "Physics / Week 3"])
        XCTAssertEqual(hits.map { $0["fields"] as? [String] }, [["tag"], ["text"]])
        XCTAssertEqual((hits[1]["page"] as? [String: Any])?["number"] as? Int, 1)
        XCTAssertEqual(hits[1]["note"] as? String, note.uuidString.lowercased())
        XCTAssertEqual(hits[1]["snippet"] as? String, "Imported")

        let tagOnly = try cli(["notes", "search", "#imported", "--json"] + args(vault, key))
        XCTAssertEqual((tagOnly.json as? [[String: Any]])?.count, 1)
        let scoped = try cli(["notes", "search", "imported", "--tag", "IMPORTED", "--json"] + args(vault, key))
        XCTAssertEqual((scoped.json as? [[String: Any]])?.map { $0["title"] as? String }, ["Groceries"])
        XCTAssertEqual((try cli(["notes", "search", "imported", "--deleted", "--json"] + args(vault, key)).json
                        as? [[String: Any]])?.count, 0)
        _ = try cli(["notes", "delete", "Groceries"] + args(vault, key))
        XCTAssertEqual((try cli(["notes", "search", "imported", "--deleted", "--json"] + args(vault, key)).json
                        as? [[String: Any]])?.count, 1)
        let plain = try cli(["notes", "search", "week imported"] + args(vault, key))
        XCTAssertTrue(plain.out.contains("Physics / Week 3"), plain.out)
    }

    /// `--recent` lists the notes whose `meta.recognized` (written by any
    /// device's run, format.md §5.4) is within the window, newest first.
    func testRecentListsTheSharedRecentlyRecognized() throws {
        let (vault, key, note, _) = try vaultWithImportedText()
        let other = UUID(uuidString: "bbbbbbbb-2222-4222-8222-000000000002")!
        let now = Date()
        let device = DeviceID("0badf00e")!
        func mark(_ id: UUID, _ at: Date, seq: Int, hlc: Int64) throws {
            try vault.write(Revision(noteId: id, device: device, seq: seq, hlc: HLC(millis: hlc, counter: 0)!,
                                     wall: at, app: "cli-test/1",
                                     body: .delta(ops: [.setMeta(.recognized(RecognitionRecord(at: at, pages: 2, read: 1)))])))
        }
        let empty = try cli(["recognize", "--recent", "--json"] + args(vault, key))
        XCTAssertEqual(empty.status, 0, empty.err)
        XCTAssertEqual(((empty.json as? [String: Any])?["notes"] as? [Any])?.count, 0)

        try mark(note, now.addingTimeInterval(-3600), seq: 1, hlc: 1_760_000_010_000)
        try mark(other, now.addingTimeInterval(-10 * 86_400), seq: 2, hlc: 1_760_000_011_000)
        let before = try revisionCount(vault)
        let r = try cli(["recognize", "--recent", "--json"] + args(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let out = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(out["days"] as? Int, 7)
        let listed = try XCTUnwrap(out["notes"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["note"] as? String }, [note.uuidString.lowercased()])
        XCTAssertEqual(listed.first?["pages"] as? Int, 2)
        XCTAssertEqual(listed.first?["read"] as? Int, 1)
        XCTAssertNotNil(listed.first?["at"] as? String)

        let wide = try cli(["recognize", "--recent", "--days", "30", "--json"] + args(vault, key))
        XCTAssertEqual(((wide.json as? [String: Any])?["notes"] as? [[String: Any]])?.map { $0["note"] as? String },
                       [note.uuidString.lowercased(), other.uuidString.lowercased()])
        let text = try cli(["recognize", "--recent"] + args(vault, key))
        XCTAssertTrue(text.out.contains("Physics / Week 3: read 1 of 2 page(s)"), text.out)
        // notes show carries it too.
        let show = try cli(["notes", "show", note.uuidString, "--json"] + args(vault, key))
        let shown = ((show.json as? [String: Any])?["note"] as? [String: Any])?["recognized"] as? [String: Any]
        XCTAssertEqual(shown?["read"] as? Int, 1, show.out)
        XCTAssertEqual(try revisionCount(vault), before, "--recent writes nothing")

        for bad in [["recognize", "--recent", "--all"], ["recognize", "--recent", "--dry-run"],
                    ["recognize", "--recent", "--days", "0"], ["recognize", "--all", "--days", "3"]] {
            XCTAssertEqual(try cli(bad + args(vault, key)).status, 2, "\(bad)")
        }
    }

    #if canImport(Vision)
    func testRecognizeStoresOneDeltaPerNoteWithABasis() throws {
        let (vault, key, note, pages) = try vaultWithImportedText()
        let r = try cli(["recognize", "--all", "--json"] + args(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let notes = try XCTUnwrap((r.json as? [String: Any])?["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.allSatisfy { ($0["file"] as? String)?.hasSuffix(".delta.age") == true }, "\(notes)")

        var state = try vault.reconstruct(noteId: note)
        XCTAssertEqual(state.pages[0].recognition?.text, "Imported", "Notability's text is kept")
        let read = try XCTUnwrap(state.pages[1].recognition)
        XCTAssertTrue(read.engine.hasPrefix("vision-"), read.engine)
        XCTAssertEqual(read.basis, RecognitionBasis.digest(of: state.pages[1].strokes.map(\.id)))

        // Everything is current: a second pass writes nothing.
        let before = try revisionCount(vault)
        let again = try cli(["recognize", "--all", "--json"] + args(vault, key))
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertEqual(try revisionCount(vault), before)

        // Both notes are now in Recently Recognized, with the run's counts.
        let recent = try cli(["recognize", "--recent", "--json"] + args(vault, key))
        XCTAssertEqual(recent.status, 0, recent.err)
        let listed = try XCTUnwrap((recent.json as? [String: Any])?["notes"] as? [[String: Any]])
        XCTAssertEqual(Set(listed.compactMap { $0["note"] as? String }), Set(notes.compactMap { $0["note"] as? String }))
        XCTAssertNotNil(state.meta.recognized)
        XCTAssertEqual(state.meta.recognized?.read, 1)

        // --force replaces Notability's text too.
        let forced = try cli(["recognize", note.uuidString, "--force"] + args(vault, key))
        XCTAssertEqual(forced.status, 0, forced.err)
        state = try vault.reconstruct(noteId: note)
        XCTAssertEqual(state.pages.first { $0.id == pages[0] }?.recognition?.basis,
                       RecognitionBasis.digest(of: state.pages[0].strokes.map(\.id)))
    }

    #else
    func testRecognizeIsRefusedWithoutVision() throws {
        let (vault, key, _, _) = try vaultWithImportedText()
        let before = try revisionCount(vault)
        let r = try cli(["recognize", "--all"] + args(vault, key))
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("Vision") && r.err.contains("macOS"), r.err)
        XCTAssertEqual(try revisionCount(vault), before)
    }
    #endif
}
