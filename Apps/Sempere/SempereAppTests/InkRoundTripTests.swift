import Foundation
import PencilKit
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// What the pen did is what the page keeps: synthetic Pencil strokes (`PencilTrace`: pressure ramp,
/// azimuth sweep, tilt, 120 Hz timing, every ink tool at its own width and color) go through the app's
/// real canvas path (`InkInjector`: canvas delegate, stroke ledger, autosave), are read back from the
/// vault, reloaded into a new canvas and rendered. Checks: every point's force, azimuth, altitude,
/// opacity, size and time within PencilKit's and the format's precision; the ink tool, color and the
/// tool's width; and that rendering is stable (two reloads draw the same pixels, and a reload draws
/// what the pen drew: textured inks too, since a saved stroke's id carries PencilKit's seed).
/// The palette's own per-tool settings (`DrawingToolbox`) are tested with the palette (PR #51).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct InkRoundTripTests {
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

    static func traces(created: Date = Date()) -> [PencilTrace] {
        InkTool.allCases.enumerated().map { i, tool in
            PencilTrace(tool: tool, color: colors[tool] ?? .black, width: widths[tool] ?? 3, points: 40 + i * 5,
                        start: CGPoint(x: 60, y: 90 + Double(i) * 70), seed: UInt64(i + 1), created: created)
        }
    }

    /// The pixels of `drawing` over `rect` on white, 2x (what the page shows, light interface).
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

    static func rgba(_ color: UIColor) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    /// A canvas showing `made`'s page.
    static func canvas(_ made: InkFixture.Made, debounce: Duration = .milliseconds(200)) async throws -> InkInjector {
        let (editor, _) = try await InkFixture.editor(made, debounce: debounce)
        let i = try InkInjector(editor: editor)
        #expect(await i.ready())
        return i
    }

    // MARK: Fields

    /// Every tool's stroke, pen-up through the canvas: the saved stroke has the pen's pressure, azimuth,
    /// altitude, opacity, timing and size at each point, the tool, color and width; a new canvas opened
    /// on the vault has the same points and ink.
    @Test func everyToolKeepsPressureAzimuthTimingAndSettingsAcrossSaveAndReload() async throws {
        let made = try InkFixture.denseNote(strokes: 0)
        let traces = Self.traces()
        let sources = traces.map { $0.stroke() }
        let first = try await Self.canvas(made)
        for (trace, stroke) in zip(traces, sources) { first.drawCanvas([stroke], tool: trace.inkingTool) }
        #expect(first.strokes.count == traces.count)
        await first.editor.flush()

        // Saved.
        let stored = try InkDeviceCheckTests.onDisk(made.vault, made.note, page: made.page)
        #expect(stored.duplicates == 0)
        #expect(stored.live.count == traces.count)
        for (trace, source) in zip(traces, sources) {
            let kept = try #require(stored.live.first { $0.ink.tool == trace.tool }, "\(trace.tool) was not saved")
            #expect(kept.ink.width == trace.width, "\(trace.tool): the tool's width \(trace.width), stored \(kept.ink.width)")
            #expect(Self.rgba(kept.ink.color.uiColor) == Self.rgba(trace.color), "\(trace.tool): color")
            let drawnPoints = source.path.map { $0 }
            #expect(kept.points.count == drawnPoints.count, "\(trace.tool): points")
            for (k, (p, q)) in zip(kept.points, drawnPoints).enumerated() {
                let size = NibSize.formatSize(q.size, tool: trace.tool)
                let pairs: [(String, Double, Double)] = [
                    ("x", p.x, Double(q.location.x)), ("y", p.y, Double(q.location.y)),
                    ("t", p.t, q.timeOffset), ("force", p.f, Double(q.force)), ("azimuth", p.az, Double(q.azimuth)),
                    ("altitude", p.al, Double(q.altitude)), ("opacity", p.o, Double(q.opacity)),
                    ("w", p.w, size.w), ("h", p.h, size.h),
                ]
                for (name, saved, drawn) in pairs {
                    // The format keeps three decimals; PencilKit keeps Float32 and quantized angles.
                    #expect(abs(saved - drawn) <= 0.002, "\(trace.tool) point \(k) \(name): drawn \(drawn), stored \(saved)")
                }
            }
        }

        // Reloaded into a new canvas.
        first.close()
        await first.editor.close()
        let again = try await Self.canvas(made)
        defer { again.close() }
        #expect(again.strokes.count == traces.count)
        for (trace, source) in zip(traces, sources) {
            let kept = try #require(again.strokes.first { $0.ink.inkType == source.ink.inkType }, "\(trace.tool) not reloaded")
            #expect(Self.rgba(kept.ink.color) == Self.rgba(trace.color), "\(trace.tool): reloaded color")
            let a = kept.path.map { $0 }, b = source.path.map { $0 }
            #expect(a.count == b.count)
            for (p, q) in zip(a, b) {
                let close = abs(Double(p.force - q.force)) <= 0.002 && abs(Double(p.azimuth - q.azimuth)) <= 0.002
                    && abs(Double(p.altitude - q.altitude)) <= 0.002 && abs(p.timeOffset - q.timeOffset) <= 0.002
                    && abs(Double(p.opacity - q.opacity)) <= 0.002 && abs(Double(p.location.x - q.location.x)) <= 0.002
                    && abs(Double(p.size.width - q.size.width)) <= 0.01
                #expect(close, "\(trace.tool): reloaded point \(p) against \(q)")
            }
        }
        await again.editor.close()
    }

    // MARK: Rendering

    /// Rendering: a page reloaded twice draws the same pixels (textured inks take their grain from the stroke's
    /// id, not from chance), and a reload draws what the pen drew (the smooth inks within anti-aliasing; the
    /// textured ones the same pixels, grain included: a canvas stroke is saved under an id that carries its seed).
    @Test func reloadedInkRendersTheSameEveryTimeAndLikeTheOriginal() async throws {
        let made = try InkFixture.denseNote(strokes: 0)
        let traces = Self.traces()
        let first = try await Self.canvas(made)
        for trace in traces { first.drawCanvas([trace.stroke()], tool: trace.inkingTool) }
        let drawn = first.drawing
        let area = CGRect(x: 0, y: 0, width: 612, height: 90 + CGFloat(traces.count) * 70)
        await first.editor.flush()
        first.close()
        await first.editor.close()

        var reloads: [PKDrawing] = []
        for _ in 0..<2 {
            let again = try await Self.canvas(made)
            reloads.append(again.drawing)
            again.close()
            await again.editor.close()
        }
        let a = Self.pixels(reloads[0], in: area), b = Self.pixels(reloads[1], in: area)
        #expect(a == b, "two reloads of the same page draw different pixels")

        // Per tool: the band of its stroke.
        for (i, trace) in traces.enumerated() {
            let type = trace.stroke().ink.inkType
            let band = CGRect(x: 0, y: 90 + CGFloat(i) * 70 - 35, width: 612, height: 70)
            let one = Self.pixels(PKDrawing(strokes: drawn.strokes.filter { $0.ink.inkType == type }), in: band)
            let two = Self.pixels(PKDrawing(strokes: reloads[0].strokes.filter { $0.ink.inkType == type }), in: band)
            let diff = Self.difference(one, two)
            let textured = [InkTool.pencil, .crayon, .watercolor].contains(trace.tool)
            print(String(format: "INK-ROUNDTRIP %@ meanDiff %.3f share>24 %.4f", trace.tool.rawValue, diff.mean, diff.share))
            #expect(diff.mean < (textured ? 0.05 : 0.1), "\(trace.tool): a reload draws differently from the pen's stroke (mean \(diff.mean))")
            if textured {
                // Measured 0.002 to 0.033 with the seed kept; with a different seed 0.5 to 1.7 and a share over 0.005.
                #expect(diff.share < 0.001, "\(trace.tool): grain differs after reload (share \(diff.share))")
                let seeds = { (d: PKDrawing) in d.strokes.filter { $0.ink.inkType == type }.map(\.randomSeed) }
                #expect(seeds(drawn) == seeds(reloads[0]), "\(trace.tool): the seed changed on reload")
            }
        }
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

    static let textured: [InkTool] = [.pencil, .crayon, .watercolor]
    static let pageWidth = 612
    static let pageHeight = 792

    static func band(_ i: Int) -> CGRect { CGRect(x: 0, y: 90 + CGFloat(i) * 70 - 35, width: 612, height: 70) }

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
