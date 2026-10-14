import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// Notes with placed items and recordings through the binary: `notes show`
/// and `notes list` report them, `snapshot` keeps them, `notes restore`
/// re-creates them (docs/cli.md, format.md §8).
final class CLIAttachmentsTests: CLITestCase {
    let note = UUID(uuidString: "dddddddd-1111-4111-8111-000000000001")!
    let page = UUID(uuidString: "dddddddd-1111-4111-8111-0000000000a1")!
    let imageId = UUID(uuidString: "dddddddd-1111-4111-8111-0000000000b1")!
    let textId = UUID(uuidString: "dddddddd-1111-4111-8111-0000000000b2")!
    let recId = UUID(uuidString: "dddddddd-1111-4111-8111-0000000000c1")!
    let image = BlobRef(sha256: String(repeating: "ab", count: 32), size: 482_113, type: "image/jpeg")
    let audio = BlobRef(sha256: String(repeating: "ef", count: 32), size: 28_311_552, type: "audio/mp4")

    func write(_ vault: Vault, seq: Int, _ ops: [Op]) throws -> Revision {
        let r = Revision(noteId: note, device: DeviceID("cccccccc")!, seq: seq,
                         hlc: HLC(millis: 1_760_000_100_000 + Int64(seq) * 1000, counter: 0)!,
                         wall: Date(timeIntervalSince1970: 1_760_000_100 + Double(seq)), app: "cli-test/1",
                         body: .delta(ops: ops))
        try vault.write(r)
        return r
    }

    func testShowSnapshotAndRestoreWithAttachments() throws {
        let (vault, _, key) = try makeVault()
        let args = ["--vault", vault.url.path, "--identity", key]
        let text = TextContent(size: 12, color: .black, runs: [TextRun("Lecture 3", b: true), TextRun("\nlinear maps")])
        let first = try write(vault, seq: 1, NoteOps.newNote(title: "Lecture", pageId: page) + [
            .addItem(page: page, item: .image(id: imageId, blob: image, pixelSize: Size(w: 3024, h: 4032),
                                              orientation: 6, frame: Rect(x: 72, y: 144, w: 216, h: 288), z: "a0")),
            .addItem(page: page, item: .text(id: textId, text, frame: Rect(x: 72, y: 90, w: 300, h: 40), z: "a1")),
            .addRecording(Recording(id: recId, blob: audio, started: Date(timeIntervalSince1970: 1_760_000_000),
                                    duration: 3540.25, codec: "aac", title: "Lecture 3")),
        ])
        _ = try write(vault, seq: 2, [.removeItem(page: page, itemId: imageId),
                                      .setRecording(recordingId: recId, change: .title("Renamed"))])

        let list = try cli(["notes", "list", "--json"] + args)
        XCTAssertEqual(list.status, 0, list.err)
        let row = try XCTUnwrap((list.json as? [[String: Any]])?.first { $0["title"] as? String == "Lecture" })
        XCTAssertEqual(row["items"] as? Int, 1)
        XCTAssertEqual(row["recordings"] as? Int, 1)

        let show = try cli(["notes", "show", "Lecture"] + args)
        XCTAssertEqual(show.status, 0, show.err)
        XCTAssertTrue(show.out.contains("Items (1):") && show.out.contains("\"Lecture 3 linear maps\""), show.out)
        XCTAssertTrue(show.out.contains("Recordings (1):") && show.out.contains("\"Renamed\""), show.out)
        XCTAssertTrue(show.out.contains("audio/mp4 28311552 B"), show.out)

        let json = try XCTUnwrap(try cli(["notes", "show", "Lecture", "--json"] + args).json as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["page"] as? Int, 1)
        XCTAssertEqual(items[0]["pageId"] as? String, page.uuidString.lowercased())
        let item = try XCTUnwrap(items[0]["item"] as? [String: Any])
        XCTAssertEqual(item["kind"] as? String, "text")
        XCTAssertEqual(item["id"] as? String, textId.uuidString.lowercased())
        XCTAssertNil(item["origin"]); XCTAssertNil(item["clocks"])
        let recs = try XCTUnwrap(json["recordings"] as? [[String: Any]])
        XCTAssertEqual(recs.first?["title"] as? String, "Renamed")
        XCTAssertEqual((recs.first?["blob"] as? [String: Any])?["sha256"] as? String, audio.sha256)

        // A snapshot keeps them (before A1 it was refused).
        let snap = try cli(["snapshot", "Lecture"] + args)
        XCTAssertEqual(snap.status, 0, snap.err)
        XCTAssertEqual(try cli(["notes", "show", "Lecture", "--json"] + args).json.flatMap {
            (($0 as? [String: Any])?["items"] as? [Any])?.count
        }, 1)

        // Restore to the first revision: the image comes back under a new id, the title is set back.
        let dry = try cli(["notes", "restore", "Lecture", "--to", first.name.filename, "--dry-run"] + args)
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertTrue(dry.out.contains("re-add 1 item(s)") && dry.out.contains("set back 1 recording(s)"), dry.out)
        let restore = try cli(["notes", "restore", "Lecture", "--to", first.name.filename, "--json"] + args)
        XCTAssertEqual(restore.status, 0, restore.err)
        let changes = try XCTUnwrap((restore.json as? [String: Any])?["changes"] as? [String: Any])
        XCTAssertEqual(changes["itemsRestored"] as? Int, 1)
        XCTAssertEqual(changes["recordingChanges"] as? Int, 1)
        let state = try vault.reconstruct(noteId: note)
        let restored = try XCTUnwrap(state.pages.first?.items.first { $0.kind == .image })
        XCTAssertEqual(restored.parent, imageId)
        XCTAssertEqual(state.recordings.first?.title, "Lecture 3")
        // Twice is a no-op.
        let again = try cli(["notes", "restore", "Lecture", "--to", first.name.filename, "--json"] + args)
        XCTAssertEqual((again.json as? [String: Any])?["changed"] as? Bool, false, again.out)
    }
}
