import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere export --format png` writes pages under temporary names and moves
/// them into place only when every page is drawn: a note that fails halfway
/// leaves an earlier export's pages as they were, never a mix of revisions.
final class CLIPNGExportTests: CLITestCase {
    func testAFailedNoteLeavesTheEarlierPagesAlone() throws {
        let (vault, _, key) = try makeVault()
        let args = ["--vault", vault.url.path, "--identity", key]
        let note = UUID(uuidString: "cccccccc-1111-4111-8111-000000000001")!
        let p1 = UUID(), p2 = UUID(), p3 = UUID()
        let device = vault.url.appendingPathComponent("device.json")
        func ink(_ x: Double, _ y: Double) -> Stroke {
            Stroke(ink: Ink(tool: .pen, color: .black, width: 3),
                   points: [StrokePoint(x: x, y: y, w: 3, h: 3), StrokePoint(x: x + 50, y: y + 20, w: 3, h: 3)])
        }
        try vault.apply(NoteOps.newNote(title: "Pages", paper: .blank, pageSize: PageSize(width: 200, height: 200), pageId: p1)
                        + [.addPage(Page(id: p2, order: PageOrder.between(PageOrder.between(nil, nil), nil))),
                           .addStroke(page: p1, stroke: ink(20, 20)), .addStroke(page: p2, stroke: ink(30, 60))],
                        to: note, deviceState: device, app: "test")
        let out = path("png")
        let first = try cli(["export", "Pages", "--format", "png", "--dpi", "36", "--out", out] + args)
        XCTAssertEqual(first.status, 0, first.err)
        func pages() throws -> [String: Data] {
            var d: [String: Data] = [:]
            for f in try FileManager.default.contentsOfDirectory(atPath: out) {
                d[f] = try Data(contentsOf: URL(fileURLWithPath: out).appendingPathComponent(f))
            }
            return d
        }
        let before = try pages()
        XCTAssertEqual(before.keys.filter { $0.hasSuffix(".png") }.count, 2)

        // A second revision: page 1 changes, page 2 now holds a stroke beyond the render limits.
        var far = ink(250_000, 50)
        far.id = UUID()
        try vault.apply([.addStroke(page: p1, stroke: ink(100, 120)), .addStroke(page: p2, stroke: far),
                         .addPage(Page(id: p3, order: "zz"))],
                        to: note, deviceState: device, app: "test")
        let second = try cli(["export", "Pages", "--format", "png", "--dpi", "36", "--out", out] + args)
        XCTAssertNotEqual(second.status, 0)
        XCTAssertEqual(try pages(), before, "the earlier pages stay, nothing new or partial is left")
    }
}
