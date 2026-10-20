import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// What the pen did is what the page keeps: synthetic Pencil strokes (`PencilTrace`: pressure ramp,
/// azimuth sweep, tilt, 120 Hz timing, every ink tool at its own width and color) go through the app's
/// real canvas path (`InkInjector`: canvas delegate, stroke ledger, autosave), are read back from the
/// vault, reloaded into a new canvas and rendered. Checks: every point's force, azimuth, altitude,
/// opacity, size and time within PencilKit's and the format's precision; the ink tool, color and the
/// tool's width; and that rendering is stable (two reloads draw the same pixels, and a reload draws
/// what the pen drew, within the grain a textured ink gets from its seed).
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
    /// textured ones share their shape, their grain differs: the stroke's seed is derived from its stored id).
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
            #expect(diff.mean < (textured ? 4 : 0.1), "\(trace.tool): a reload draws differently from the pen's stroke (mean \(diff.mean))")
        }
    }
}
