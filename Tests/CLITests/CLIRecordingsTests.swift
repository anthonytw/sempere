import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// Recordings on the page (`audio` items, format.md §8.2.9) from the command
/// line: `attach recording --place`, `recordings list|place|rename|delete`,
/// `items list`, `notes show`, `items copy` across notes, and exports that
/// draw the card and attach the audio ("PDF + attachments").
final class CLIRecordingsTests: CLITestCase {
    let physics = "aaaaaaaa-1111-4111-8111-000000000001"   // two pages
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"

    var vaultPath: String { path("mine.sempere") }
    var keyPath: String { path("mine.sempere.key") }
    var tone: String { Self.fixtures.appendingPathComponent("audio/tone-aac.m4a").path }

    func setUpVault() throws -> [String] {
        _ = try makeVault()
        return ["--vault", vaultPath, "--identity", keyPath]
    }

    @discardableResult
    func ok(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let r = try cli(args)
        XCTAssertEqual(r.status, 0, "\(args.prefix(3)): \(r.err)", file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    func state(_ note: String) throws -> NoteState {
        let identity = try IdentityFile.parse(String(contentsOfFile: keyPath, encoding: .utf8))
        let vault = try Vault.open(at: URL(fileURLWithPath: vaultPath), identities: [identity])
        return try vault.reconstruct(noteId: UUID(uuidString: note)!)
    }

    func revisionCount(_ note: String) throws -> Int {
        let identity = try IdentityFile.parse(String(contentsOfFile: keyPath, encoding: .utf8))
        let vault = try Vault.open(at: URL(fileURLWithPath: vaultPath), identities: [identity])
        return try vault.loadNote(UUID(uuidString: note)!).revisions.count
    }

    func testAttachRecordingWithPlaceAddsTheItemInTheSameDelta() throws {
        let args = try setUpVault()
        let before = try revisionCount(physics)
        let out = try ok(["attach", "recording", physics, tone, "--title", "Lecture 3", "--place", "--page", "2", "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1, "one delta: the recording and its item")
        let rid = try XCTUnwrap((out["recording"] as? [String: Any])?["id"] as? String)
        let placed = try XCTUnwrap((out["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(placed["page"] as? Int, 2)
        let item = try XCTUnwrap(placed["item"] as? [String: Any])
        XCTAssertEqual(item["kind"] as? String, "audio")
        XCTAssertEqual(item["recording"] as? String, rid)
        XCTAssertEqual(item["frame"] as? [Double], [156, 36, 300, 96])
        let note = try state(physics)
        XCTAssertEqual(note.pages[1].items.map(\.kind), [.audio])
        XCTAssertEqual(note.recording(shownBy: note.pages[1].items[0])?.title, "Lecture 3")

        // Plain text: the item's id, then the recording's.
        let plain = try cli(["attach", "recording", physics, tone, "--at", "10,20", "--width", "200"] + args)
        XCTAssertEqual(plain.status, 0, plain.err)
        XCTAssertEqual(plain.out.split(separator: "\n").count, 2)
        // Without --place nothing is placed; bad placements are refused before anything is stored.
        let unplaced = try ok(["attach", "recording", physics, tone, "--json"] + args)
        XCTAssertEqual((unplaced["items"] as? [Any])?.count, 0)
        XCTAssertEqual(try cli(["attach", "recording", physics, tone, "--page", "0"] + args).status, 2)
        let tooFar = try cli(["attach", "recording", physics, tone, "--page", "9"] + args)
        XCTAssertEqual(tooFar.status, 1)
        XCTAssertTrue(tooFar.err.contains("no page 9"), tooFar.err)
        XCTAssertEqual(try state(physics).recordings.count, 3)
    }

    func testRecordingsListPlaceRenameDelete() throws {
        let args = try setUpVault()
        let added = try ok(["attach", "recording", physics, tone, "--title", "Talk", "--json"] + args)
        let rid = try XCTUnwrap((added["recording"] as? [String: Any])?["id"] as? String)

        var listed = try ok(["recordings", "list", physics, "--json"] + args)
        var rows = try XCTUnwrap(listed["recordings"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual((rows[0]["items"] as? [Any])?.count, 0)

        // Place it twice: page 1 by title, page 2 by id prefix at a frame.
        let first = try ok(["recordings", "place", physics, "Talk", "--json"] + args)
        let itemID = try XCTUnwrap(((first["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        _ = try ok(["recordings", "place", physics, String(rid.prefix(6)), "--page", "2", "--frame", "10,10,240,80"] + args)
        let dry = try ok(["recordings", "place", physics, rid, "--dry-run", "--json"] + args)
        XCTAssertEqual(dry["dryRun"] as? Bool, true)
        XCTAssertNil(dry["file"] as? String)
        listed = try ok(["recordings", "list", physics, "--json"] + args)
        rows = try XCTUnwrap(listed["recordings"] as? [[String: Any]])
        XCTAssertEqual((rows[0]["items"] as? [[String: Any]])?.compactMap { $0["page"] as? Int }, [1, 2])
        let table = try cli(["recordings", "list", physics] + args)
        XCTAssertTrue(table.out.contains("p1,p2"), table.out)
        XCTAssertTrue(table.out.contains("\"Talk\""), table.out)

        // items list and notes show name the recording.
        let items = try cli(["items", "list", physics, "--json"] + args)
        let audio = try XCTUnwrap((items.json as? [[String: Any]])?.first { $0["kind"] as? String == "audio" })
        XCTAssertEqual(audio["recording"] as? String, rid)
        XCTAssertEqual(audio["recordingMissing"] as? Bool, false)
        let show = try cli(["notes", "show", physics] + args)
        XCTAssertTrue(show.out.contains("recording \(rid.prefix(8))"), show.out)

        // Rename: once; the same title again writes nothing.
        let before = try revisionCount(physics)
        _ = try ok(["recordings", "rename", physics, rid, "Seminar"] + args)
        _ = try ok(["recordings", "rename", physics, rid, "Seminar"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1)
        XCTAssertEqual(try state(physics).recordings.first?.title, "Seminar")

        // Deleting the item keeps the recording; deleting the recording removes the other item in the same delta.
        _ = try ok(["items", "delete", physics, itemID] + args)
        XCTAssertEqual(try state(physics).recordings.count, 1)
        let count = try revisionCount(physics)
        _ = try ok(["recordings", "delete", physics, "Seminar"] + args)
        XCTAssertEqual(try revisionCount(physics), count + 1)
        let after = try state(physics)
        XCTAssertTrue(after.recordings.isEmpty)
        XCTAssertFalse(after.pages.flatMap(\.items).contains { $0.kind == .audio })
        let gone = try cli(["recordings", "place", physics, rid] + args)
        XCTAssertEqual(gone.status, 1, "no such recording any more")
        XCTAssertTrue(gone.err.contains("no recording \(rid) in this note"), gone.err)
        let short = try cli(["recordings", "place", physics, String(rid.prefix(3))] + args)
        XCTAssertTrue(short.err.contains("give a whole id or at least 4 characters"), short.err)
    }

    func testCopyToAnotherNoteLeavesAudioItemsBehind() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "recording", physics, tone, "--place", "--json"] + args)
        let itemID = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        let text = try ok(["attach", "text", physics, "hello", "--json"] + args)
        let textID = try XCTUnwrap(((text["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        let copied = try cli(["items", "copy", physics, itemID, textID, "--to", groceries] + args)
        XCTAssertEqual(copied.status, 0, copied.err)
        XCTAssertTrue(copied.err.contains("1 audio item(s) not copied"), copied.err)
        XCTAssertEqual(try state(groceries).pages[0].items.map(\.kind), [.text])
        let none = try cli(["items", "copy", physics, itemID, "--to", groceries] + args)
        XCTAssertEqual(none.status, 1)
        // Duplicating on the same note keeps it (the recording is there).
        _ = try ok(["items", "duplicate", physics, itemID] + args)
        XCTAssertEqual(try state(physics).pages[0].items.filter { $0.kind == .audio }.count, 2)
    }

    func testExportsDrawTheCardAndAttachTheAudio() throws {
        let args = try setUpVault()
        let transcript = path("t.json")
        _ = try ok(["attach", "recording", groceries, tone, "--title", "Lecture", "--place", "--json"] + args)
        let rid = try XCTUnwrap(try state(groceries).recordings.first?.id)
        let t = Transcript(recording: rid, engine: "test-1", language: "en-US", created: Date(timeIntervalSince1970: 0),
                           segments: [.init(start: 0, end: 2, text: "Linear maps and kernels.")])
        try t.encoded().write(to: URL(fileURLWithPath: transcript))
        _ = try ok(["attach", "transcript", groceries, rid.uuidString.lowercased(), transcript] + args)

        let svg = try cli(["export", groceries, "--format", "svg", "--pdf-renderer", "none", "--out", path("svg")] + args)
        XCTAssertEqual(svg.status, 0, svg.err)
        XCTAssertFalse(svg.err.contains("placeholder"), svg.err)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: path("svg")).first)
        let text = try String(contentsOf: URL(fileURLWithPath: path("svg")).appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(text.contains(">Lecture · 0:02</text>"), text)
        XCTAssertTrue(text.contains(">Linear maps and kernels.</text>"))

        let pdf = try cli(["export", groceries, "--format", "pdf", "--recordings", "attach", "--out", path("o.pdf")] + args)
        XCTAssertEqual(pdf.status, 0, pdf.err)
        XCTAssertEqual(pdf.err, "", "no placeholder, nothing left out")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path("o.pdf")))
        XCTAssertNotNil(bytes.range(of: Data("/F (Lecture.m4a)".utf8)))
        XCTAssertNotNil(bytes.range(of: Data("/F (Lecture.txt)".utf8)))
        XCTAssertEqual(try cli(["export", groceries, "--format", "png", "--pdf-renderer", "none", "--out", path("png")] + args).status, 0)

        // A recording deleted elsewhere (an item left showing it): a placeholder, reported.
        let identity = try IdentityFile.parse(String(contentsOfFile: keyPath, encoding: .utf8))
        let vault = try Vault.open(at: URL(fileURLWithPath: vaultPath), identities: [identity])
        _ = try vault.apply(to: UUID(uuidString: groceries)!, deviceState: URL(fileURLWithPath: path("dev.json")), app: "test/0") { _ in
            [.removeRecording(recordingId: rid)]
        }
        let orphan = try cli(["export", groceries, "--format", "pdf", "--out", path("p.pdf")] + args)
        XCTAssertEqual(orphan.status, 0, orphan.err)
        XCTAssertTrue(orphan.err.contains("recording missing"), orphan.err)
        let listed = try cli(["recordings", "list", groceries] + args)
        XCTAssertTrue((listed.out + listed.err).contains("shows a recording that is missing"), listed.out + listed.err)
    }
}
