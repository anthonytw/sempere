import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere items`: the app's item gestures from the command line, one delta
/// each, and copying items (attachments first) to another note.
final class CLIItemsTests: CLITestCase {
    let note = UUID(uuidString: "eeeeeeee-1111-4111-8111-000000000001")!
    let other = UUID(uuidString: "eeeeeeee-1111-4111-8111-000000000002")!
    let page = UUID(uuidString: "eeeeeeee-1111-4111-8111-0000000000a1")!
    let otherPage = UUID(uuidString: "eeeeeeee-1111-4111-8111-0000000000a2")!
    let imageId = UUID(uuidString: "eeeeeeee-1111-4111-8111-0000000000b1")!
    let textId = UUID(uuidString: "eeeeeeee-2222-4111-8111-0000000000b2")!

    func revisions(_ vault: Vault, _ id: UUID) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: vault.url.appendingPathComponent("notes/\(id.uuidString.lowercased())").path)
            .filter { $0.hasSuffix(".age") }.count
    }

    func testItemGesturesAndCopyToAnotherNote() throws {
        let (vault, _, key) = try makeVault()
        let args = ["--vault", vault.url.path, "--identity", key]
        let bytes = Data((0..<300).map { UInt8($0 % 251) })   // synthetic attachment content
        let ref = try vault.writeBlob(note: note, bytes, type: "image/png")
        let device = vault.url.appendingPathComponent("device.json")
        _ = try vault.apply(NoteOps.newNote(title: "Board", pageId: page) + [
            .addItem(page: page, item: .image(id: imageId, blob: ref, pixelSize: Size(w: 10, h: 10),
                                              frame: Rect(x: 10, y: 10, w: 100, h: 100), z: "a0")),
            .addItem(page: page, item: .text(id: textId, TextContent(size: 12, color: .black, runs: [TextRun("Board")]),
                                              frame: Rect(x: 10, y: 200, w: 100, h: 40), z: "a1")),
        ], to: note, deviceState: device, app: "test/1")
        _ = try vault.apply(NoteOps.newNote(title: "Other", pageId: otherPage), to: other, deviceState: device, app: "test/1")

        func items(_ title: String) throws -> [[String: Any]] {
            let r = try cli(["items", "list", title, "--json"] + args)
            XCTAssertEqual(r.status, 0, r.err)
            return try XCTUnwrap(r.json as? [[String: Any]])
        }
        XCTAssertEqual(try items("Board").map { $0["kind"] as? String }, ["image", "text"])
        let image = String(imageId.uuidString.lowercased().prefix(13))   // the 8-character prefix is shared: ambiguous

        let ambiguous = try cli(["items", "front", "Board", "eeeeeeee"] + args)
        XCTAssertEqual(ambiguous.status, 1)
        XCTAssertTrue(ambiguous.err.contains("'eeeeeeee' matches 2 items: "), ambiguous.err)
        XCTAssertTrue(ambiguous.err.contains(imageId.uuidString.lowercased()), "lists the candidates: \(ambiguous.err)")
        // The messages items, recordings and strokes share.
        let short = try cli(["items", "front", "Board", "eee"] + args)
        XCTAssertTrue(short.err.contains("item eee: give a whole id or at least 4 characters"), short.err)
        let none = try cli(["items", "front", "Board", "0000"] + args)
        XCTAssertTrue(none.err.contains("no item 0000 in this note"), none.err)
        var before = try revisions(vault, note)
        let move = try cli(["items", "move", "Board", image, "--frame", "20,30,200,150", "--json"] + args)
        XCTAssertEqual(move.status, 0, move.err)
        XCTAssertEqual((move.json as? [String: Any])?["changed"] as? Bool, true)
        XCTAssertEqual(try revisions(vault, note), before + 1, "one delta")
        let moved = try XCTUnwrap(try items("Board").first { $0["kind"] as? String == "image" }?["frame"] as? [Double])
        XCTAssertEqual(moved, [20, 30, 200, 150])
        let again = try cli(["items", "move", "Board", image, "--frame", "20,30,200,150", "--json"] + args)
        XCTAssertEqual((again.json as? [String: Any])?["changed"] as? Bool, false)
        XCTAssertEqual(try revisions(vault, note), before + 1, "nothing written for no change")

        XCTAssertEqual(try cli(["items", "rotate", "Board", image, "--degrees", "90"] + args).status, 0)
        // Crop the right half: the frame follows (the visible half stays put), one delta; --clear undoes it.
        before = try revisions(vault, note)
        XCTAssertEqual(try cli(["items", "rotate", "Board", image, "--degrees", "0"] + args).status, 0)
        let crop = try cli(["items", "crop", "Board", image, "--crop", "5,0,5,10", "--json"] + args)
        XCTAssertEqual(crop.status, 0, crop.err)
        let cropped = try XCTUnwrap(try items("Board").first { $0["kind"] as? String == "image" })
        XCTAssertEqual(cropped["crop"] as? [Double], [5, 0, 5, 10])
        XCTAssertEqual(cropped["frame"] as? [Double], [120, 30, 100, 150])
        XCTAssertEqual(try cli(["items", "crop", "Board", image, "--clear"] + args).status, 0)
        let uncropped = try XCTUnwrap(try items("Board").first { $0["kind"] as? String == "image" })
        XCTAssertNil(uncropped["crop"])
        XCTAssertEqual(uncropped["frame"] as? [Double], [20, 30, 200, 150])
        XCTAssertEqual(try revisions(vault, note), before + 3)
        XCTAssertEqual(try cli(["items", "crop", "Board", image] + args).status, 2, "--crop or --clear")
        let outside = try cli(["items", "crop", "Board", image, "--crop", "50,50,5,5"] + args)
        XCTAssertEqual(outside.status, 1)
        XCTAssertTrue(outside.err.contains("outside"), outside.err)
        let textCrop = try cli(["items", "crop", "Board", String(textId.uuidString.lowercased().prefix(13)), "--clear"] + args)
        XCTAssertEqual(textCrop.status, 1, "a text box has no crop")
        XCTAssertEqual(try cli(["items", "rotate", "Board", image, "--degrees", "90"] + args).status, 0)
        XCTAssertEqual(try cli(["items", "front", "Board", image] + args).status, 0)
        XCTAssertEqual(try items("Board").last?["kind"] as? String, "image", "drawn above the text box")

        before = try revisions(vault, note)
        XCTAssertEqual(try cli(["items", "duplicate", "Board", image] + args).status, 0)
        XCTAssertEqual(try items("Board").count, 3)
        XCTAssertEqual(try cli(["items", "delete", "Board", String(textId.uuidString.lowercased().prefix(13))] + args).status, 0)
        XCTAssertEqual(try items("Board").count, 2)
        XCTAssertEqual(try revisions(vault, note), before + 2)

        // Copy to another note: the attachment is copied first, then one delta.
        let copy = try cli(["items", "copy", "Board", image, "--to", "Other"] + args)
        XCTAssertEqual(copy.status, 0, copy.err)
        XCTAssertEqual(try items("Other").map { $0["kind"] as? String }, ["image"])
        XCTAssertEqual(try vault.readBlob(note: other, ref), bytes)
        XCTAssertEqual(try cli(["vault", "verify"] + args).status, 0)

        for bad in [["move", "Board", image, "--frame", "1,2,0,4"], ["move", "Board", image, "--frame", "x"]] {
            XCTAssertEqual(try cli(["items"] + bad + args).status, 2, "\(bad)")
        }
        let unknown = try cli(["items", "front", "Board", "ffff0000"] + args)
        XCTAssertEqual(unknown.status, 1)
        XCTAssertTrue(unknown.err.contains("no item"), unknown.err)
        XCTAssertEqual(try cli(["notes", "delete", "Board"] + args).status, 0)
        let refused = try cli(["items", "front", "Board", image] + args)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.err.contains("undelete"), refused.err)
    }
}
