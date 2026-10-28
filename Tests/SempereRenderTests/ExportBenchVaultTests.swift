import Age
import Foundation
import VaultTestSupport
import Sempere
import XCTest
@testable import SempereRender

/// Writes a vault holding one large synthetic note for measuring `sempere
/// export` (peak memory with `/usr/bin/time -l`, file size, time) on the
/// command line. Runs only when `SEMPERE_BENCH_VAULT` names a directory that
/// does not exist yet; `SEMPERE_BENCH_PAGES` (default 300), `SEMPERE_BENCH_STROKES`
/// (per page, default 150) and `SEMPERE_BENCH_POINTS` (default 60) size it.
/// Every page has dense random-walk ink (`RenderBenchmarkTests.denseNote`) and,
/// unless `SEMPERE_BENCH_IMAGES=0`, its own 640x480 noise image, so each PDF
/// page carries a large image object.
/// The identity is written next to the vault as `<vault>.key`.
final class ExportBenchVaultTests: XCTestCase {
    func testWriteBenchVault() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SEMPERE_BENCH_VAULT"] else { throw XCTSkip("set SEMPERE_BENCH_VAULT to write the vault") }
        let pages = Int(env["SEMPERE_BENCH_PAGES"] ?? "") ?? 300
        let strokes = Int(env["SEMPERE_BENCH_STROKES"] ?? "") ?? 150
        let points = Int(env["SEMPERE_BENCH_POINTS"] ?? "") ?? 60
        let images = env["SEMPERE_BENCH_IMAGES"] != "0"
        let url = URL(fileURLWithPath: path)
        let id = try NativeIdentity.generate(.postQuantum)
        try IdentityFile.render(id, created: Date(timeIntervalSince1970: 0))
            .write(toFile: path + ".key", atomically: true, encoding: .utf8)
        let vault = try TestVaults.create(at: url, identities: [id], names: ["bench"])
        let note = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000001")!
        let dense = RenderBenchmarkTests.denseNote(strokes: strokes, points: points).pages[0].strokes
        var seed: UInt64 = 7
        let firstPage = UUID()
        var ops = NoteOps.newNote(title: "Bench", paper: .ruled, pageSize: PageSize(width: 612, height: 792), pageId: firstPage)
        var order = PageOrder.between(nil, nil)
        func addImage(_ pageId: UUID) throws {
            var rgba = [UInt8](repeating: 255, count: 640 * 480 * 4)
            for i in 0..<(640 * 480) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                rgba[4 * i] = UInt8(truncatingIfNeeded: seed >> 33)
                rgba[4 * i + 1] = UInt8(truncatingIfNeeded: seed >> 41)
                rgba[4 * i + 2] = UInt8(truncatingIfNeeded: seed >> 49)
            }
            let png = try PNGEncoder.encode(width: 640, height: 480, rgba: rgba)
            let ref = try vault.writeBlob(note: note, png, type: "image/png")
            ops.append(.addItem(page: pageId, item: .image(id: UUID(), blob: ref, pixelSize: Size(w: 640, h: 480),
                                                           frame: Rect(x: 40, y: 400, w: 320, h: 240), z: "a0")))
        }
        for p in 0..<pages {
            var pageId = firstPage
            if p > 0 {
                pageId = UUID()
                order = PageOrder.between(order, nil)
                ops.append(.addPage(Page(id: pageId, order: order)))
            }
            if images { try addImage(pageId) }
            for s in dense {
                var copy = s
                copy.id = UUID()   // a stroke id lives on one page
                ops.append(.addStroke(page: pageId, stroke: copy))
            }
        }
        try vault.apply(ops, to: note, deviceState: url.appendingPathComponent("device.json"), app: "bench/1")
    }
}
