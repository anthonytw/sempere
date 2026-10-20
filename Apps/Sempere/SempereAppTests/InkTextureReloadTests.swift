import Foundation
import PencilKit
import SempereRender
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// What the pen drew is what the page shows after it is reopened, grain included. A textured ink
/// (pencil, crayon, watercolor) takes its grain from `PKStroke.randomSeed`; the format does not store
/// a seed, a load derives it from the stroke's id (`StrokeConversion.seed(for:)`), and a canvas stroke
/// is saved under an id that carries the seed PencilKit gave it (`StrokeConversion.id(seed:)`).
/// Before that, the live canvas kept PencilKit's own seed until the reload took the id's, so the
/// grain changed once, on the first reopen.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct InkTextureReloadTests {
    static let textured: [InkTool] = [.pencil, .crayon, .watercolor]
    static let pageWidth = 612
    static let pageHeight = 792

    static let colors: [InkTool: UIColor] = [
        .pen: UIColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1),
        .pencil: UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1),
        .marker: UIColor(red: 1, green: 0.9, blue: 0, alpha: 1),
        .monoline: UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1),
        .fountainPen: UIColor(red: 0, green: 0.4, blue: 0.2, alpha: 1),
        .watercolor: UIColor(red: 0.3, green: 0.1, blue: 0.7, alpha: 1),
        .crayon: UIColor(red: 0.9, green: 0.4, blue: 0, alpha: 1),
    ]
    static let widths: [InkTool: Double] = [
        .pen: 3, .pencil: 5, .marker: 18, .monoline: 4, .fountainPen: 6, .watercolor: 12, .crayon: 8,
    ]

    /// One trace per tool, one row each, 70 pt apart.
    static func traces() -> [PencilTrace] {
        InkTool.allCases.enumerated().map { i, tool in
            PencilTrace(tool: tool, color: colors[tool] ?? .black, width: widths[tool] ?? 3, points: 40 + i * 5,
                        start: CGPoint(x: 60, y: 90 + Double(i) * 70), seed: UInt64(i + 1))
        }
    }

    static func band(_ i: Int) -> CGRect { CGRect(x: 0, y: 90 + CGFloat(i) * 70 - 35, width: 612, height: 70) }

    /// The pixels of `drawing` over `rect` on white, 2x (the page's light interface).
    static func pixels(_ drawing: PKDrawing, in rect: CGRect) -> [UInt8] {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = drawing.image(from: rect, scale: 2) }
        let w = Int(rect.width * 2), h = Int(rect.height * 2)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let cg = image.cgImage,
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// Mean absolute difference per channel (0...255) and the share of channel values that differ by more than 24.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, share: Double) {
        guard a.count == b.count, !a.isEmpty else { return (255, 1) }
        var sum = 0, over = 0
        for i in 0..<a.count {
            let d = abs(Int(a[i]) - Int(b[i]))
            sum += d
            if d > 24 { over += 1 }
        }
        return (Double(sum) / Double(a.count), Double(over) / Double(a.count))
    }

    static func canvas(_ made: InkFixture.Made) async throws -> InkInjector {
        let (editor, _) = try await InkFixture.editor(made, debounce: .milliseconds(200))
        let i = try InkInjector(editor: editor)
        #expect(await i.ready())
        return i
    }

    /// Draws every tool's trace through the canvas, saves and reopens: the drawing the pen made and
    /// the drawing after a reload.
    static func drawnAndReloaded() async throws -> (made: InkFixture.Made, drawn: PKDrawing, reloaded: PKDrawing,
                                                    traces: [PencilTrace]) {
        let made = try InkFixture.denseNote(strokes: 0)
        let traces = Self.traces()
        let first = try await canvas(made)
        for trace in traces { first.drawCanvas([trace.stroke()], tool: trace.inkingTool) }
        let drawn = first.drawing
        await first.editor.flush()
        first.close()
        await first.editor.close()
        let again = try await canvas(made)
        let reloaded = again.drawing
        again.close()
        await again.editor.close()
        return (made, drawn, reloaded, traces)
    }

    // MARK: Ids and seeds

    @Test func idWithSeedKeepsTheSeedAndStaysUnique() {
        for seed in [UInt32(0), 1, 0xDEAD_BEEF, .max, 0x0100_0000] {
            let a = StrokeConversion.id(seed: seed), b = StrokeConversion.id(seed: seed)
            #expect(StrokeConversion.seed(for: a) == seed)
            #expect(StrokeConversion.seed(for: b) == seed)
            #expect(a != b)
        }
    }

    // MARK: Live canvas against reload

    /// The strokes the pen drew and the strokes after a reload have the same seeds, and textured inks
    /// draw the very same pixels (a smooth ink within anti-aliasing noise).
    @Test func texturedInksReloadPixelForPixel() async throws {
        let r = try await Self.drawnAndReloaded()
        #expect(r.drawn.strokes.count == r.traces.count)
        #expect(r.reloaded.strokes.count == r.traces.count)
        for (i, trace) in r.traces.enumerated() {
            let type = trace.tool.pkInkType
            let one = r.drawn.strokes.filter { $0.ink.inkType == type }
            let two = r.reloaded.strokes.filter { $0.ink.inkType == type }
            #expect(one.map(\.randomSeed) == two.map(\.randomSeed), "\(trace.tool): the seed changed on reload")
            let a = Self.pixels(PKDrawing(strokes: one), in: Self.band(i))
            let b = Self.pixels(PKDrawing(strokes: two), in: Self.band(i))
            let diff = Self.difference(a, b)
            print(String(format: "INK-TEXTURE %@ meanDiff %.5f share>24 %.5f", trace.tool.rawValue, diff.mean, diff.share))
            if Self.textured.contains(trace.tool) {
                #expect(diff.mean < 0.05, "\(trace.tool): grain differs after reload (mean \(diff.mean))")
                #expect(diff.share < 0.001, "\(trace.tool): grain differs after reload (share \(diff.share))")
            } else {
                #expect(diff.mean < 0.1, "\(trace.tool): differs after reload (mean \(diff.mean))")
            }
        }
    }

    /// A second reopen keeps the grain of the first (strokes keep their stored ids).
    @Test func grainIsStableAcrossRepeatedReopens() async throws {
        let r = try await Self.drawnAndReloaded()
        let again = try await Self.canvas(r.made)
        let third = again.drawing
        again.close()
        await again.editor.close()
        let area = CGRect(x: 0, y: 0, width: 612, height: 90 + CGFloat(r.traces.count) * 70)
        #expect(Self.pixels(r.reloaded, in: area) == Self.pixels(third, in: area))
    }

    // MARK: CLI renderer against the app

    /// The CLI's renderer (`SempereRender.PNGWriter`, no grain by design) and the app's canvas show the
    /// same page: per stroke, the inked area has the same extent and the two silhouettes overlap.
    @Test func cliAndAppRenderTheSameNote() async throws {
        let r = try await Self.drawnAndReloaded()
        let state = try r.made.vault.reconstruct(noteId: r.made.note)
        var options = RenderOptions()
        options.paper = false
        let png = try #require(try PNGWriter.render(note: state, options: options, png: PNGOptions(scale: 2)).first)
        let w = Self.pageWidth * 2, h = Self.pageHeight * 2
        let cli = try Self.decode(png, width: w, height: h)
        let app = Self.pixels(r.reloaded, in: CGRect(x: 0, y: 0, width: Self.pageWidth, height: Self.pageHeight))
        for (i, trace) in r.traces.enumerated() {
            let band = Self.band(i)
            let a = Self.ink(app, width: w, in: band), c = Self.ink(cli, width: w, in: band)
            let ab = try #require(Self.bounds(a, width: w, in: band), "\(trace.tool): app drew nothing")
            let cb = try #require(Self.bounds(c, width: w, in: band), "\(trace.tool): CLI drew nothing")
            var both = 0, either = 0
            for k in a.indices where a[k] || c[k] { either += 1; if a[k] && c[k] { both += 1 } }
            let iou = Double(both) / Double(max(either, 1))
            print("INK-CLI \(trace.tool.rawValue) iou \(iou) appBox \(ab) cliBox \(cb)")
            // The same extent to a few pixels (caps and grain edges differ).
            for (x, y) in [(ab.minX, cb.minX), (ab.maxX, cb.maxX), (ab.minY, cb.minY), (ab.maxY, cb.maxY)] {
                #expect(abs(x - y) <= 8, "\(trace.tool): app \(ab), CLI \(cb)")
            }
            // Measured on the simulator: 0.80 to 0.96, except the fountain pen (0.67) and the marker (0.45), whose
            // renderers differ in nib shape and translucency (not part of this fix); a grain-only difference stays above 0.85.
            #expect(iou > 0.4, "\(trace.tool): silhouettes overlap \(iou)")
            if Self.textured.contains(trace.tool) { #expect(iou > 0.85, "\(trace.tool): silhouettes overlap \(iou)") }
        }
    }

    /// RGBA bytes of a PNG composited on white, `width` x `height`, its top edge at the top.
    static func decode(_ png: Data, width: Int, height: Int) throws -> [UInt8] {
        let image = try #require(UIImage(data: png)?.cgImage)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
        return bytes
    }

    /// Which pixels (row-major, `width` per row) inside `rect` (points, 2x) are inked: not close to white.
    static func ink(_ rgba: [UInt8], width: Int, in rect: CGRect) -> [Bool] {
        var out = [Bool](repeating: false, count: rgba.count / 4)
        for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let d = max(255 - Int(rgba[o]), 255 - Int(rgba[o + 1]), 255 - Int(rgba[o + 2]))
                out[y * width + x] = d > 40
            }
        }
        return out
    }

    static func bounds(_ mask: [Bool], width: Int, in rect: CGRect) -> CGRect? {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
            for x in 0..<width where mask[y * width + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
