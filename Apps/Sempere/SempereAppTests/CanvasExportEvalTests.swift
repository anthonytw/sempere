import Foundation
import SempereRender
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// Stage 2 of the import fidelity evaluation (`docs/import-notability.md`,
/// "Fidelity evaluation"; driven by `scripts/import-eval.sh`): every band of
/// every page of every note in a vault, as the canvas shows it and as the
/// export draws it. Disabled unless `SEMPERE_EVAL_VAULT`,
/// `SEMPERE_EVAL_IDENTITY` and `SEMPERE_EVAL_OUT` are set (pass them to
/// `xcodebuild test` as `TEST_RUNNER_SEMPERE_EVAL_…`); CI never sets them.
/// The vault is only read.
///
/// For each page band (one `breakHeight`, the export's page) it writes to
/// `<out>/<id8>/` (`id8`: the first 8 hex digits of the note id):
/// - `pNN-bNNN-canvas.png`: an on-screen snapshot of a `PageCanvasHost`
///   (window one band in size, fit-width zoom 1) showing the drawing
///   `NoteEditor.drawing(for:)` builds (Stroke → PKStroke → PKDrawing), on
///   blank paper, scrolled to the band;
/// - `pNN-bNNN-pk.png`: the same drawing through `PKDrawing.image` (light);
/// - `pNN-bNNN-export.png`: `PNGWriter`'s page for the band, no paper.
/// All at the screen scale. `<out>/<id8>/bands.json` lists the bands.
@MainActor
@Suite(.serialized)
struct CanvasExportEvalTests {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static let enabled = ["SEMPERE_EVAL_VAULT", "SEMPERE_EVAL_IDENTITY", "SEMPERE_EVAL_OUT"]
        .allSatisfy { env[$0] != nil }

    @Test(.enabled(if: enabled, "SEMPERE_EVAL_VAULT, SEMPERE_EVAL_IDENTITY and SEMPERE_EVAL_OUT not set"))
    func everyBandOfEveryNote() async throws {
        let vaultURL = URL(fileURLWithPath: try #require(Self.env["SEMPERE_EVAL_VAULT"]))
        let keyText = try String(contentsOfFile: try #require(Self.env["SEMPERE_EVAL_IDENTITY"]), encoding: .utf8)
        let out = URL(fileURLWithPath: try #require(Self.env["SEMPERE_EVAL_OUT"]))
        let only = Self.env["SEMPERE_EVAL_ONLY"]?.lowercased()
        let vault = try Vault.open(at: vaultURL, identities: [try IdentityFile.parse(keyText)])
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var bandsWritten = 0
        for noteID in try vault.noteIDs().sorted(by: { $0.uuidString < $1.uuidString }) {
            let id8 = String(noteID.uuidString.lowercased().prefix(8))
            if let only, !id8.hasPrefix(only) { continue }
            let state = try vault.reconstruct(noteId: noteID)
            let dir = out.appendingPathComponent(id8)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let editor = NoteEditor(noteID: noteID, state: state, writer: nil, readOnlyReason: "evaluation")
            var bands: [[String: Any]] = []
            for (pageIndex, page) in state.pages.enumerated() {
                bands += try await evaluate(page: page, index: pageIndex, meta: state.meta, editor: editor, dir: dir)
            }
            bandsWritten += bands.count
            let json = try JSONSerialization.data(withJSONObject: ["id": noteID.uuidString.lowercased(),
                                                                   "bands": bands], options: [.sortedKeys])
            try json.write(to: dir.appendingPathComponent("bands.json"))
        }
        print("EVAL: wrote \(bandsWritten) bands to \(out.path)")
        #expect(bandsWritten > 0)
    }

    /// Writes the canvas, PencilKit and export images of every band of one page.
    func evaluate(page: Page, index pageIndex: Int, meta: NoteMeta, editor: NoteEditor, dir: URL) async throws
        -> [[String: Any]] {
        let size = meta.pageSize
        let scale = UIScreen.main.scale
        let exports = try PNGWriter.render(page: page, meta: meta, options: RenderOptions(paper: false),
                                           png: PNGOptions(scale: Double(scale)))
        // The export's page height: one break on an infinite page, else the page.
        let bandHeight = size.infinite ? PreparedPageChunk.height(size) : size.height
        let drawing = editor.drawing(for: page.id)

        // A window one band in size at zoom 1; the page is extended to whole
        // bands so the last band can be scrolled to the top like the others.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: size.width, height: bandHeight))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }
        host.isReadOnly = true
        host.canvas.drawing = drawing
        var shown = size
        shown.height = max(size.height, Double(exports.count) * bandHeight)
        host.apply(paper: .blank, pageSize: shown)
        host.layoutIfNeeded()

        var bands: [[String: Any]] = []
        for (b, export) in exports.enumerated() {
            let top = Double(b) * bandHeight
            let rect = CGRect(x: 0, y: top, width: size.width, height: bandHeight)
            let name = String(format: "p%02d-b%03d", pageIndex, b)
            try export.write(to: dir.appendingPathComponent(name + "-export.png"))

            var pk: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                pk = drawing.image(from: rect, scale: scale)
            }
            try pk?.pngData()?.write(to: dir.appendingPathComponent(name + "-pk.png"))

            let z = host.canvas.zoomScale
            host.canvas.setContentOffset(CGPoint(x: 0, y: CGFloat(top) * z), animated: false)
            host.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(Int(settleMilliseconds)))
            let shot = UIGraphicsImageRenderer(bounds: host.canvas.bounds).image { _ in
                host.canvas.drawHierarchy(in: host.canvas.bounds, afterScreenUpdates: true)
            }
            try shot.pngData()?.write(to: dir.appendingPathComponent(name + "-canvas.png"))
            let shownRect = CGRect(x: host.canvas.contentOffset.x / z, y: host.canvas.contentOffset.y / z,
                                   width: host.canvas.bounds.width / z, height: host.canvas.bounds.height / z)
            bands.append(["page": pageIndex, "band": b, "name": name, "top": top, "height": bandHeight,
                          "canvasTop": Double(shownRect.minY), "canvasHeight": Double(shownRect.height),
                          "zoom": Double(z), "strokes": drawing.strokes.count])
        }
        return bands
    }

    var settleMilliseconds: Double { Double(Self.env["SEMPERE_EVAL_SETTLE_MS"] ?? "") ?? 1200 }
}

/// The export's chunk height for an infinite page (`PreparedPage.chunkHeight`
/// with default options): the page's `breakHeight`, else letter aspect,
/// clamped to 72 … `RenderLimits.maxExtent`.
enum PreparedPageChunk {
    static func height(_ size: PageSize) -> Double {
        let base = size.breakHeight ?? size.width * 11 / 8.5
        return min(max(base.isFinite ? base : 792, 72), RenderLimits.maxExtent)
    }
}
