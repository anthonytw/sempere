import Foundation
import SempereRender
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// Stroke ⇄ PKStroke conversion (format.md §5.6).
@MainActor
struct StrokeConversionTests {
    /// PencilKit keeps control points in reduced precision: locations, times
    /// and sizes as Float32, opacity, azimuth and altitude quantized to about
    /// 1e-4. Round trips are therefore equal within that, not bit for bit.
    static let pencilKitPrecision = 2e-4

    static func expectClose(_ a: [StrokePoint], _ b: [StrokePoint], tolerance: Double = pencilKitPrecision) {
        #expect(a.count == b.count)
        for (p, q) in zip(a, b) {
            let pv = [p.x, p.y, p.t, p.w, p.h, p.o, p.f, p.az, p.al]
            let qv = [q.x, q.y, q.t, q.w, q.h, q.o, q.f, q.az, q.al]
            for (u, v) in zip(pv, qv) { #expect(abs(u - v) <= tolerance) }
        }
    }

    @Test(arguments: InkTool.allCases)
    func roundTripsEveryTool(tool: InkTool) throws {
        let original = TS.stroke(tool: tool, transform: Transform(a: 1.5, b: 0.2, c: -0.1, d: 0.9, tx: 12, ty: -4))
        let pk = StrokeConversion.pkStroke(original)
        let back = try #require(StrokeConversion.strokes(from: pk, nominalWidth: original.ink.width).first)
        #expect(StrokeConversion.strokes(from: pk).count == 1)
        #expect(back.ink == original.ink)
        #expect(back.transform == original.transform)
        // PencilKit keeps a size's height as a ratio of its width rounded to
        // 1e-3, and the marker map makes that ratio far from 1.
        Self.expectClose(back.points, original.points, tolerance: tool == .marker ? 0.01 : Self.pencilKitPrecision)
    }

    /// Locations, sizes, times, force, opacity and azimuth come back bit for
    /// bit; altitude is re-quantized by PencilKit on each pass (≈2e-5).
    @Test func pencilKitToFormatToPencilKitIsStable() throws {
        let drawn = TS.canvasStroke(TS.stroke(transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 3, ty: 4)))
        let ours = try #require(StrokeConversion.strokes(from: drawn).first)
        let again = try #require(StrokeConversion.strokes(from: StrokeConversion.pkStroke(ours)).first)
        #expect(again.points.map { [$0.x, $0.y, $0.t, $0.w, $0.h, $0.o, $0.f, $0.az] }
                == ours.points.map { [$0.x, $0.y, $0.t, $0.w, $0.h, $0.o, $0.f, $0.az] })
        Self.expectClose(again.points, ours.points)
        #expect(again.ink == ours.ink)
        #expect(again.transform == ours.transform)
    }

    @Test func roundTripSurvivesTheFormatEncoding() throws {
        let original = TS.stroke()
        let json = try InkJSON.encoder().encode(original)
        let decoded = try InkJSON.decoder().decode(Stroke.self, from: json)
        let back = try #require(StrokeConversion.strokes(from: StrokeConversion.pkStroke(decoded),
                                                         nominalWidth: decoded.ink.width).first)
        Self.expectClose(back.points, original.points, tolerance: 0.0005 + Self.pencilKitPrecision)   // writers round to 3 decimals
        #expect(back.ink == original.ink)
    }

    @Test func identityTransformIsOmittedAndColoursAreExact() throws {
        for color in [Sempere.Color.black, .white, Sempere.Color(r: 1, g: 128, b: 254, a: 77)] {
            let s = TS.stroke(color: color)
            let back = try #require(StrokeConversion.strokes(from: StrokeConversion.pkStroke(s)).first)
            #expect(back.ink.color == color)
            #expect(back.transform == nil)
        }
    }

    @Test func nominalWidthDefaultsToTheWidestPoint() throws {
        let s = TS.stroke(width: 3)
        let back = try #require(StrokeConversion.strokes(from: StrokeConversion.pkStroke(s)).first)
        #expect(back.ink.width == s.points.map(\.w).max())
    }

    @Test func renderedBoundsMatchSempereRender() {
        for tool in [InkTool.pen, .monoline, .marker] {
            let s = TS.stroke(tool: tool, width: 4)
            let pk = StrokeConversion.pkStroke(s)
            // Our renderer's outline bounds: sampled centre line widened by half the size.
            let samples = StrokeSampler.samples(for: s)
            let minX = samples.map { $0.x - $0.w / 2 }.min() ?? 0, maxX = samples.map { $0.x + $0.w / 2 }.max() ?? 0
            let minY = samples.map { $0.y - $0.h / 2 }.min() ?? 0, maxY = samples.map { $0.y + $0.h / 2 }.max() ?? 0
            let b = pk.renderBounds
            let slack = 3.0   // PencilKit pads render bounds for antialiasing and tool shape
            #expect(abs(Double(b.minX) - minX) <= slack, "\(tool) minX \(b.minX) vs \(minX)")
            #expect(abs(Double(b.maxX) - maxX) <= slack, "\(tool) maxX \(b.maxX) vs \(maxX)")
            #expect(abs(Double(b.minY) - minY) <= slack, "\(tool) minY \(b.minY) vs \(minY)")
            #expect(abs(Double(b.maxY) - maxY) <= slack, "\(tool) maxY \(b.maxY) vs \(maxY)")
            // And converting back and forth again renders identically.
            let again = StrokeConversion.strokes(from: pk, nominalWidth: s.ink.width).map(StrokeConversion.pkStroke)
            #expect(again.count == 1)
            #expect(again.first?.renderBounds == b)
        }
    }

    @Test func canvasRoundTripKeepsTheFingerprint() {
        let strokes = [TS.stroke(), TS.stroke(x: 100, tool: .pencil), TS.stroke(y: 300, tool: .crayon)]
        let drawing = PKDrawing(strokes: strokes.map(StrokeConversion.pkStroke))
        let viaData = (try? PKDrawing(data: drawing.dataRepresentation())) ?? drawing
        for (s, pk) in zip(strokes, viaData.strokes) {
            #expect(CanvasStrokeInfo(stored: s) == CanvasStrokeInfo(pk))
        }
        #expect(CanvasStrokeInfo(stored: strokes[0]) != CanvasStrokeInfo(stored: strokes[1]))
    }

    @Test func textureSeedIsStablePerId() {
        let s = TS.stroke()
        #expect(StrokeConversion.pkStroke(s).randomSeed == StrokeConversion.pkStroke(s).randomSeed)
    }

    @Test func maskedStrokeBecomesOnePiecePerVisibleRange() throws {
        let s = TS.stroke(n: 40)   // x from 40 to 157
        var pk = StrokeConversion.pkStroke(s)
        // Hide the middle: keep x < 80 and x > 120.
        let visible = UIBezierPath(rect: CGRect(x: 0, y: -100, width: 80, height: 400))
        visible.append(UIBezierPath(rect: CGRect(x: 120, y: -100, width: 200, height: 400)))
        pk.mask = visible
        let ranges = pk.maskedPathRanges
        try #require(ranges.count == 2, "maskedPathRanges: \(ranges)")
        let pieces = StrokeConversion.strokes(from: pk, nominalWidth: 3)
        #expect(pieces.count == 2)
        let first = try #require(pieces.first), second = try #require(pieces.last)
        #expect(abs((first.points.first?.x ?? 0) - (s.points.first?.x ?? 0)) < 1e-6)
        #expect((first.points.last?.x ?? 0) < 90)
        #expect((second.points.first?.x ?? 0) > 110)
        #expect(abs((second.points.last?.x ?? 0) - (s.points.last?.x ?? 0)) < 1e-9)
        #expect(Set(pieces.map(\.id)).count == 2)
    }
}
