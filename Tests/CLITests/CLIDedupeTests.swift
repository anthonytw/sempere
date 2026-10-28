import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `notes dedupe` (format.md §5.6.1) on a note two devices edited concurrently.
final class CLIDedupeTests: CLITestCase {
    let race = UUID(uuidString: "cccccccc-3333-4333-8333-000000000003")!

    /// Writes "Race": A and B slice x concurrently (B later: A's piece is
    /// superseded); A erases y and brings it back by undo while B slices it
    /// (both stay: a duplicate the merge cannot resolve, B's piece the older).
    func writeRace(_ vault: Vault) throws -> (b1: UUID, y2: UUID, c1: UUID) {
        func stroke(_ n: Double, parent: UUID? = nil) -> Stroke {
            let pts = (0..<4).map { StrokePoint(x: 40 + n * 10 + Double($0) * 12, y: 100, w: 2.5, h: 2.5) }
            return Stroke(ink: Ink(tool: .pen, color: .black, width: 2.5), points: pts, parent: parent)
        }
        func rev(_ device: String, _ seq: Int, _ ms: Int64, _ ops: [Op]) -> Revision {
            Revision(noteId: race, device: DeviceID(device)!, seq: seq, hlc: HLC(millis: 1_760_000_000_000 + ms, counter: 0)!,
                     wall: Date(timeIntervalSince1970: Double(1_760_000_000_000 + ms) / 1000),
                     app: "cli-test/1", body: .delta(ops: ops))
        }
        let page = UUID()
        let x = stroke(1), y = stroke(2)
        let a1 = stroke(1, parent: x.id), b1 = stroke(1.5, parent: x.id)
        let y2 = stroke(2, parent: y.id), c1 = stroke(2.5, parent: y.id)
        try vault.write(rev("aaaaaaaa", 1, 0, [.addPage(Page(id: page, order: "a0")), .setMeta(.title("Race")),
                                               .addStroke(page: page, stroke: x), .addStroke(page: page, stroke: y)]))
        try vault.write(rev("aaaaaaaa", 2, 100, [.removeStroke(page: page, strokeId: x.id), .addStroke(page: page, stroke: a1)]))
        try vault.write(rev("bbbbbbbb", 1, 200, [.removeStroke(page: page, strokeId: x.id), .addStroke(page: page, stroke: b1)]))
        try vault.write(rev("aaaaaaaa", 3, 300, [.removeStroke(page: page, strokeId: y.id)]))
        try vault.write(rev("bbbbbbbb", 2, 400, [.removeStroke(page: page, strokeId: y.id), .addStroke(page: page, stroke: c1)]))
        try vault.write(rev("aaaaaaaa", 4, 500, [.addStroke(page: page, stroke: y2)]))
        return (b1.id, y2.id, c1.id)
    }

    private func strokes(_ access: [String]) throws -> Int {
        let list = try cli(["notes", "list", "--json"] + access)
        let note = try XCTUnwrap((list.json as? [[String: Any]])?.first { $0["title"] as? String == "Race" })
        return try XCTUnwrap(note["strokes"] as? Int)
    }

    private func revisionCount(_ vault: Vault) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: vault.url.appendingPathComponent("notes")
            .appendingPathComponent(race.uuidString.lowercased()).path).filter { $0.hasSuffix(".age") }.count
    }

    func testCheckThenRepair() throws {
        let (vault, _, key) = try makeVault()
        let ids = try writeRace(vault)
        let access = ["--vault", vault.url.path, "--identity", key]
        // The merge already hides A's superseded piece: b1, y2 and c1 are live.
        XCTAssertEqual(try strokes(access), 3)
        let files = try revisionCount(vault)

        let check = try cli(["notes", "dedupe", "Race", "--dry-run", "--json"] + access)
        XCTAssertEqual(check.status, 0, check.err)
        let item = try XCTUnwrap((check.json as? [[String: Any]])?.first)
        XCTAssertEqual((item["superseded"] as? [[String: String]])?.count, 1)
        XCTAssertEqual((item["duplicates"] as? [[String: String]])?.map { $0["stroke"] }, [ids.c1.uuidString.lowercased()])
        XCTAssertNil(item["file"] as? String)
        XCTAssertEqual(try revisionCount(vault), files, "a dry run writes nothing")

        let text = try cli(["notes", "dedupe", "--all", "--dry-run"] + access)
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("would remove 1 superseded, 1 duplicate stroke(s) in \(race.uuidString.lowercased())"),
                      text.out)

        let fix = try cli(["notes", "dedupe", race.uuidString.lowercased(), "--json"] + access)
        XCTAssertEqual(fix.status, 0, fix.err)
        let done = try XCTUnwrap((fix.json as? [[String: Any]])?.first)
        XCTAssertTrue((done["file"] as? String)?.hasSuffix(".delta.age") ?? false, fix.out)
        XCTAssertEqual(try revisionCount(vault), files + 1)
        XCTAssertEqual(try strokes(access), 2)

        let again = try cli(["notes", "dedupe", "--all"] + access)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("No leftover strokes in 3 note(s)."), again.out)
        XCTAssertEqual(try revisionCount(vault), files + 1, "nothing left to write")
        XCTAssertEqual(try cli(["vault", "verify"] + access).status, 0)
    }

    func testArguments() throws {
        let (vault, _, key) = try makeVault()
        let access = ["--vault", vault.url.path, "--identity", key]
        XCTAssertNotEqual(try cli(["notes", "dedupe"] + access).status, 0)
        XCTAssertNotEqual(try cli(["notes", "dedupe", "Groceries", "--all"] + access).status, 0)
        let clean = try cli(["notes", "dedupe", "Groceries", "--dry-run"] + access)
        XCTAssertEqual(clean.status, 0, clean.err)
        XCTAssertTrue(clean.out.contains("No leftover strokes in 1 note(s)."), clean.out)
        let missing = try cli(["notes", "dedupe", "No such note"] + access)
        XCTAssertNotEqual(missing.status, 0)
    }
}
