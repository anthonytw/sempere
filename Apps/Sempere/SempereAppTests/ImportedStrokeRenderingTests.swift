import Foundation
import SempereRender
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// Imported strokes (Notability: thin pens, polylines, highlighters, scaled to
/// letter width) must show on the canvas where SempereRender draws them. PencilKit
/// draws a pen point of size `s` as `2s − 4` wide, so storing the format width
/// as the PencilKit size made every pen thinner than 2 pt invisible.
@MainActor
struct ImportedStrokeRenderingTests {
    // MARK: - Synthetic strokes shaped like the importer's output

    /// Notability's 716.8-unit page scaled to 612 pt.
    static let k = 612 / 716.8
    /// Notability's x inset on that page: `W / 38.4` (`NotabilityNote.horizontalInsetFraction`).
    static let inset = 716.8 / 38.4

    /// Rounds a point as a writer does (format.md §5.6).
    static func rounded(_ p: StrokePoint) -> StrokePoint {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        return StrokePoint(x: r(p.x), y: r(p.y), t: r(p.t), w: r(p.w), h: r(p.h), o: r(p.o), f: r(p.f),
                           az: r(p.az), al: r(p.al))
    }

    /// A handwriting-like pen stroke: dense B-spline control points (as solved
    /// from sampled Béziers), width multipliers that change only every few
    /// points, 1/120 s timing, force 0, altitude π/2, far down a tall page.
    static func importedPen(x: Double, y: Double, glyphs: Int = 3, base: Double = 1.4) -> Stroke {
        let n = glyphs * 16
        let fw = [0.75, 0.9, 1.0, 0.85, 0.7, 0.95]
        let points = (0..<n).map { i -> StrokePoint in
            let u = Double(i) / 16 * 2 * .pi
            let px = (x + inset + Double(i) * 1.1 + 4 * cos(u)) * k
            let py = (y + 9 * sin(u) + 3 * sin(u / 2)) * k
            let w = base * k * fw[(i / 4) % fw.count]
            return rounded(StrokePoint(x: px, y: py, t: Double(i) / 120, w: w, h: w, o: 1, f: 0, az: 0, al: .pi / 2))
        }
        return Stroke(ink: Ink(tool: .pen, color: .black, width: base * k), points: points)
    }

    /// A short polyline stroke (two to four points, one width).
    static func importedPolyline(_ xy: [(Double, Double)], width: Double = 1.1) -> Stroke {
        let points = xy.enumerated().map { i, p in
            rounded(StrokePoint(x: p.0, y: p.1, t: Double(i) / 120, w: width, h: width, o: 1, f: 0, az: 0, al: .pi / 2))
        }
        return Stroke(ink: Ink(tool: .pen, color: Sempere.Color(r: 0, g: 0x6F, b: 0xFF, a: 0xFF), width: width),
                      points: points)
    }

    /// A horizontal highlighter pass (Notability style 4 → `marker`).
    static func importedHighlighter(x: Double, y: Double, length: Double = 160, width: Double = 23.9) -> Stroke {
        let n = Int(length / 2.5)
        let points = (0..<n).map { i -> StrokePoint in
            let w = width * (0.75 + 0.05 * Double(i % 3))
            return rounded(StrokePoint(x: x + Double(i) * 2.5, y: y + 0.6 * sin(Double(i) / 5), t: Double(i) / 120,
                                       w: w, h: w, o: 1, f: 0, az: 0, al: .pi / 2))
        }
        return Stroke(ink: Ink(tool: .marker, color: Sempere.Color(r: 0xFF, g: 0xFF, b: 0, a: 0xFF), width: width),
                      points: points)
    }

    /// A page's worth of imported ink: lines of handwriting plus polylines.
    static func importedPage(top: Double = 3000) -> [Stroke] {
        var strokes: [Stroke] = []
        for line in 0..<4 {
            for word in 0..<5 {
                strokes.append(importedPen(x: 20 + Double(word) * 130, y: top + Double(line) * 40,
                                           glyphs: 2 + word % 3, base: [0.933, 1.4, 1.867][word % 3]))
            }
        }
        strokes.append(importedPolyline([(60, top * k + 150), (300, top * k + 152)]))
        strokes.append(importedPolyline([(80, top * k + 170), (90, top * k + 185), (110, top * k + 172), (125, top * k + 190)]))
        return strokes
    }

    // MARK: - Rasterising

    struct Coverage {
        var pixels: Int
        /// Bounds of the inked pixels, in points of the rendered rect.
        var bounds: CGRect
    }

    /// Pixels with alpha above ~8 % and their bounds.
    static func coverage(_ image: UIImage, scale: CGFloat) -> Coverage {
        guard let cg = image.cgImage else { return Coverage(pixels: 0, bounds: .null) }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var n = 0, minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where buf[(y * w + x) * 4 + 3] > 20 {
                n += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return Coverage(pixels: 0, bounds: .null) }
        return Coverage(pixels: n, bounds: CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                                                  width: CGFloat(maxX - minX + 1) / scale,
                                                  height: CGFloat(maxY - minY + 1) / scale))
    }

    /// SempereRender's geometry (the PDF/SVG export's), filled with CoreGraphics.
    static func inkRenderImage(_ strokes: [Stroke], rect: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { rc in
            let c = rc.cgContext
            c.translateBy(x: -rect.minX, y: -rect.minY)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            for s in strokes {
                for cmd in StrokeOutline.commands(for: s) {
                    guard case .path(let subpaths) = cmd.primitive else { continue }
                    let path = CGMutablePath()
                    for sp in subpaths {
                        guard let first = sp.points.first else { continue }
                        path.move(to: CGPoint(x: first.x, y: first.y))
                        for q in sp.points.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
                        if sp.closed { path.closeSubpath() }
                    }
                    c.addPath(path)
                    func color(_ p: Paint) -> CGColor {
                        UIColor(red: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255,
                                alpha: CGFloat(p.alpha)).cgColor
                    }
                    if let fill = cmd.fill {
                        c.setFillColor(color(fill))
                        c.fillPath()
                    } else if let stroke = cmd.stroke {
                        c.setStrokeColor(color(stroke))
                        c.setLineWidth(cmd.lineWidth)
                        c.strokePath()
                    }
                }
            }
        }
    }

    /// Renders `strokes` both ways over their bounds and compares.
    static func compare(_ strokes: [Stroke], scale: CGFloat = 2) -> (canvas: Coverage, inkRender: Coverage) {
        let xs = strokes.flatMap { $0.points.map(\.x) }, ys = strokes.flatMap { $0.points.map(\.y) }
        let rect = CGRect(x: (xs.min() ?? 0) - 30, y: (ys.min() ?? 0) - 30,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0) + 60, height: (ys.max() ?? 0) - (ys.min() ?? 0) + 60)
        let drawing = PKDrawing(strokes: strokes.map(StrokeConversion.pkStroke))
        return (coverage(drawing.image(from: rect, scale: scale), scale: scale),
                coverage(inkRenderImage(strokes, rect: rect, scale: scale), scale: scale))
    }

    static func expectSimilar(_ r: (canvas: Coverage, inkRender: Coverage), ratio: ClosedRange<Double>,
                              edgeSlack: CGFloat, _ label: String) {
        let measured = Double(r.canvas.pixels) / Double(max(r.inkRender.pixels, 1))
        #expect(r.inkRender.pixels > 0, "\(label): SempereRender drew nothing")
        #expect(ratio.contains(measured), "\(label): canvas/SempereRender ink pixels \(r.canvas.pixels)/\(r.inkRender.pixels)")
        let a = r.canvas.bounds, b = r.inkRender.bounds
        #expect(!a.isNull, "\(label): canvas drew nothing")
        guard !a.isNull, !b.isNull else { return }
        for (u, v, edge) in [(a.minX, b.minX, "minX"), (a.maxX, b.maxX, "maxX"), (a.minY, b.minY, "minY"), (a.maxY, b.maxY, "maxY")] {
            #expect(abs(u - v) <= edgeSlack, "\(label): \(edge) canvas \(u) vs SempereRender \(v)")
        }
    }

    // MARK: - Rendering matches SempereRender

    @Test func importedHandwritingRendersWhereSempereRenderDoes() {
        let strokes = Self.importedPage()
        #expect(strokes.allSatisfy { $0.points.allSatisfy { $0.w < 2 } })   // all below PencilKit's old cut-off
        Self.expectSimilar(Self.compare(strokes), ratio: 0.8...1.5, edgeSlack: 1.5, "handwriting")
    }

    @Test(arguments: [0.4, 0.7, 1.0, 1.6, 3.0])
    func everyImportedPenWidthIsVisible(width: Double) {
        let s = Self.importedPen(x: 40, y: 200, glyphs: 2, base: width / Self.k)
        Self.expectSimilar(Self.compare([s], scale: 4), ratio: 0.7...1.6, edgeSlack: 1, "pen \(width)")
    }

    @Test func polylineStrokesRender() {
        let strokes = [Self.importedPolyline([(60, 100), (300, 102)]),
                       Self.importedPolyline([(80, 140), (90, 155), (110, 142), (125, 160)], width: 0.6)]
        Self.expectSimilar(Self.compare(strokes, scale: 4), ratio: 0.7...1.6, edgeSlack: 1, "polyline")
    }

    @Test func highlighterCoversTheBandSempereRenderDoes() {
        let strokes = [Self.importedHighlighter(x: 100, y: 500)]
        let r = Self.compare(strokes)
        // PencilKit's marker nib is not round: allow more slack than for pens.
        Self.expectSimilar(r, ratio: 0.6...1.6, edgeSlack: 6, "highlighter")
        #expect(abs(r.canvas.bounds.height - r.inkRender.bounds.height) <= 0.15 * r.inkRender.bounds.height,
                "highlighter band height \(r.canvas.bounds.height) vs \(r.inkRender.bounds.height)")
    }

    // MARK: - NibSize against PencilKit

    /// Drawn thickness (pt) across the middle of a straight stroke of format
    /// width `w`: the extent where alpha exceeds a quarter of its peak.
    static func drawnThickness(_ tool: InkTool, width w: Double, vertical: Bool) -> Double {
        let scale: CGFloat = 4
        let points = (0..<30).map { i -> StrokePoint in
            let d = 30 + Double(i) * 2
            return StrokePoint(x: vertical ? 60 : d, y: vertical ? d : 60, t: Double(i) / 120, w: w, h: w, o: 1,
                               f: 0.5, az: 0, al: .pi / 2)
        }
        let stroke = Stroke(ink: Ink(tool: tool, color: .black, width: w), points: points)
        let image = PKDrawing(strokes: [StrokeConversion.pkStroke(stroke)])
            .image(from: CGRect(x: 0, y: 0, width: 120, height: 120), scale: scale)
        guard let cg = image.cgImage else { return 0 }
        let W = cg.width, H = cg.height
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        let mid = Int(60 * scale)
        let line = (0..<(vertical ? W : H)).map { k -> Double in
            Double(buf[(vertical ? mid * W + k : k * W + mid) * 4 + 3]) / 255
        }
        guard let peak = line.max(), peak > 0 else { return 0 }
        return Double(line.filter { $0 > peak / 4 }.count) / Double(scale)
    }

    /// Pins PencilKit's size → drawn width relation: if an iPadOS update
    /// changes it, this fails before users see ink at the wrong width.
    @Test(arguments: [InkTool.pen, .monoline])
    func penFamilyDrawsAtTheFormatWidth(tool: InkTool) {
        for w in [0.5, 1.0, 2.0, 4.0, 8.0, 20.0] {
            for vertical in [false, true] {
                let t = Self.drawnThickness(tool, width: w, vertical: vertical)
                #expect(abs(t - w) <= 0.5, "\(tool) w=\(w) vertical=\(vertical): drawn \(t)")
            }
        }
    }

    /// Crayon's texture is the least even: a vertical 12-wide stroke measured
    /// 7.5 on the iPadOS 26.5 simulator.
    @Test func markerAndTexturedInksDrawNearTheFormatWidth() {
        for (tool, tolerance) in [(InkTool.marker, 0.25), (.pencil, 0.35), (.crayon, 0.4), (.watercolor, 0.35)] {
            for w in [6.0, 12.0, 24.0] {
                for vertical in [false, true] {
                    let t = Self.drawnThickness(tool, width: w, vertical: vertical)
                    #expect(abs(t - w) <= tolerance * w, "\(tool) w=\(w) vertical=\(vertical): drawn \(t)")
                }
            }
        }
    }

    @Test(arguments: InkTool.allCases)
    func nibSizeRoundTrips(tool: InkTool) {
        for (w, h) in [(0.0, 0.0), (0.42, 0.42), (1.12, 1.12), (6, 3), (23.9, 23.9)] {
            let pk = NibSize.pkSize(w: w, h: h, tool: tool)
            let back = NibSize.formatSize(CGSize(width: CGFloat(Float(pk.width)), height: CGFloat(Float(pk.height))), tool: tool)
            #expect(abs(back.w - w) < 1e-5 && abs(back.h - h) < 1e-5, "\(tool) \(w)x\(h) → \(pk) → \(back)")
        }
    }

    /// Below size 2 PencilKit draws no pen ink; such points come back as width 0.
    @Test func invisiblePencilKitPenSizesBecomeZeroWidth() {
        let p = PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 1.5, height: 1.5), opacity: 1,
                              force: 1, azimuth: 0, altitude: 1)
        let point = StrokePoint(p, tool: .pen)
        #expect(point.w == 0 && point.h == 0)
        #expect(point.pkStrokePoint(tool: .pen).size == CGSize(width: 2, height: 2))
    }

    // MARK: - Loading imported strokes does not rewrite them

    @Test func loadingImportedStrokesProducesNoOps() throws {
        let page = UUID()
        let stored = Self.importedPage() + [Self.importedHighlighter(x: 100, y: 2700)]
        var ledger = StrokeLedger(stored: stored, info: CanvasStrokeInfo.init(stored:))
        ledger.rebase(info: CanvasStrokeInfo.init(stored:))
        let shown = ledger.drawing
        let reported = (try? PKDrawing(data: shown.dataRepresentation())) ?? shown
        let change = ledger.update(StrokeLedger.items(for: reported, tool: PKInkingTool(.pen, color: .black, width: 3)))
        #expect(change.isEmpty)
        #expect(ledger.pendingOps(page: page, live: ledger.live).isEmpty)
        #expect(ledger.live.map(\.id) == stored.map(\.id))

        // Drawing one stroke adds exactly it; the imported ids stay.
        var edited = reported
        edited.strokes.append(TS.canvasStroke(TS.stroke(x: 50, y: 80)))
        let next = ledger.update(StrokeLedger.items(for: edited, tool: nil))
        #expect(next.removed.isEmpty)
        #expect(next.added.count == 1)
        #expect(Array(ledger.live.map(\.id).prefix(stored.count)) == stored.map(\.id))
    }

    @Test func reopenedImportedNoteSavesOnlyNewStrokes() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes += (Self.importedPage(top: 100) + [Self.importedHighlighter(x: 100, y: 60)])
            .map(StrokeConversion.pkStroke)
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await editor.close()
        let ids = Set(try vault.reconstruct(noteId: NoteEditorTests.lecture).pages
            .first { $0.id == page.id }?.strokes.map(\.id) ?? [])

        // Reopen: the stored (rounded) strokes come back; reporting the canvas
        // unchanged must not remove or re-add any of them.
        let (again, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let shown = again.drawing(for: page.id)
        #expect(shown.strokes.count == ids.count)
        #expect(again.drawingDidChange(pageID: page.id, drawing: shown, tool: nil).isEmpty)
        var edited = shown
        edited.strokes.append(TS.canvasStroke(TS.stroke(x: 300, y: 600)))
        let change = again.drawingDidChange(pageID: page.id, drawing: edited, tool: nil)
        #expect(change.removed.isEmpty && change.added.count == 1)
        await again.close()
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        let last = try #require(deltas.last)
        #expect(last.count == 1)
        if case .addStroke(_, let s) = last.first { #expect(!ids.contains(s.id)) } else { Issue.record("expected an addStroke") }
        let saved = Set(try vault.reconstruct(noteId: NoteEditorTests.lecture).pages
            .first { $0.id == page.id }?.strokes.map(\.id) ?? [])
        #expect(ids.isSubset(of: saved) && saved.count == ids.count + 1)
    }
}
