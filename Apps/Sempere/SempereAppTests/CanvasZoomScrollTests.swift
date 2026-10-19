import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The one-page canvas of a long pageless note (TestFlight 1.0.0 (6), the owner's iPad, a note
/// imported from Notability): a pinch zooms out below the fitted width, centered; an update in
/// the middle of a pinch leaves the zoom alone; the ruled paper is drawn only near the screen;
/// and the main thread's time per scroll and per pinch frame on a dense page is measured
/// (`PERF-REPORT` lines). The pinch on the screen and the scroll hitches are in
/// `IPadZoomScrollUITests` (iPad simulator).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct CanvasZoomScrollTests {
    static let ruled = Paper(kind: .ruled)

    /// Rows of the dense page: 24 points apart on a Mac (20 000 strokes, about 12 600 points of
    /// page, a long lecture), farther apart on the simulator (a tenth of the strokes) so the page is
    /// as long.
    static let rowHeight = 24 * 20_000 / Double(InkFixture.denseStrokes)

    /// A canvas showing a dense pageless ruled page of `strokes` strokes.
    static func dense(strokes: Int = InkFixture.denseStrokes, rowHeight: Double = rowHeight) async throws -> InkInjector {
        let made = try InkFixture.denseNote(strokes: strokes, rowHeight: rowHeight)
        let (editor, _) = try await InkFixture.editor(made)
        let i = try InkInjector(editor: editor)
        i.host.apply(paper: ruled, pageSize: editor.pageSize)
        i.host.layoutIfNeeded()
        return i
    }

    /// The fitted width's scale (the page is 612 points wide).
    static func fit(_ host: PageCanvasHost) -> CGFloat { host.bounds.width / 612 }

    /// The paper's shape layers (its ruling), wherever they are in its layer tree.
    static func paperShapeLayers(_ host: PageCanvasHost) -> (UIView?, [CAShapeLayer]) {
        guard let paper = host.canvas.subviews.first(where: { $0 is PaperView }) else { return (nil, []) }
        var out: [CAShapeLayer] = []
        var layers = [paper.layer]
        while let l = layers.popLast() {
            if let s = l as? CAShapeLayer { out.append(s) }
            layers.append(contentsOf: l.sublayers ?? [])
        }
        return (paper, out)
    }

    static func ms(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }

    static func summary(_ times: [Double]) -> String {
        let sorted = times.sorted()
        guard !sorted.isEmpty else { return "none" }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return String(format: "mean %.2f ms, p95 %.2f ms, max %.2f ms (%d frames)", mean, p95, sorted.last ?? 0, sorted.count)
    }

    // MARK: Zoom

    /// "Still can't zoom out farther than 100%": the pageless canvas's range stopped at the fit.
    @Test func aPagelessNoteZoomsOutBelowTheFitCentered() async throws {
        let i = try await Self.dense(strokes: 200)
        defer { i.close() }
        let host = i.host, canvas = host.canvas
        let fit = Self.fit(host)
        #expect(abs(canvas.zoomScale - fit) < 0.001, "it opens at the fitted width")
        #expect(canvas.minimumZoomScale <= fit * 0.5 + 0.001, "a pinch zooms out to half the fit")
        canvas.setZoomScale(fit * 0.6, animated: false)
        host.zoomEnded()
        #expect(abs(canvas.zoomScale - fit * 0.6) < 0.001, "and stays there")
        let side = (host.bounds.width - canvas.contentSize.width) / 2
        #expect(side > 50, "narrower than the screen")
        #expect(abs(canvas.contentInset.left - side) < 0.5 && abs(canvas.contentInset.right - side) < 0.5, "in the middle")
        // Back near the fit: the detent takes it to the fit, and the margins go.
        canvas.setZoomScale(fit * 0.93, animated: false)
        host.zoomEnded()
        #expect(await TS.waitUntil(timeout: .seconds(5)) { abs(canvas.zoomScale - fit) < 0.001 }, "snaps to the fit")
        #expect(canvas.contentInset.left == 0)
    }

    /// A SwiftUI update in the middle of a pinch that passes the fit put the zoom back on the fit
    /// under the fingers ("the zoom jostles around a bit"): an update now leaves the zoom alone.
    @Test func anUpdateDuringAPinchLeavesTheZoomAlone() async throws {
        let i = try await Self.dense(strokes: 200)
        defer { i.close() }
        let canvas = i.host.canvas
        let fit = Self.fit(i.host)
        canvas.zoomScale = fit * 1.0005
        i.show()   // `PageCanvasView.updateUIView`: Coordinator.apply → host.apply(paper:pageSize:)
        #expect(abs(canvas.zoomScale - fit * 1.0005) < fit * 0.0001, "zoom \(canvas.zoomScale), fit \(fit)")
    }

    // MARK: Paper

    /// The ruling of a page tens of screens long is drawn near the screen only: its shape layers
    /// were each as tall as the whole note, drawn again by Core Animation as the page scrolled.
    @Test func thePaperIsDrawnNearTheScreenOnly() async throws {
        let i = try await Self.dense()
        defer { i.close() }
        let canvas = i.host.canvas
        let z = canvas.zoomScale
        let tall = canvas.contentSize.height
        #expect(tall > canvas.bounds.height * 8, "a long page: \(tall)")
        func check(_ label: String) {
            let (paper, layers) = Self.paperShapeLayers(i.host)
            #expect(!layers.isEmpty, "\(label): ruled")
            var total: CGFloat = 0
            for l in layers { total += l.bounds.height }
            let band: CGFloat = 792 * z
            let screen: CGFloat = canvas.bounds.height
            let limit: CGFloat = (screen * 3 + band * 2) * 2   // three screens and a band each side, two looks
            #expect(layers.allSatisfy { $0.bounds.height <= band + 1 }, "\(label): a layer per band, not per note")
            #expect(total <= limit, "\(label): \(total) points of ruling for a screen of \(screen)")
            let visible = canvas.bounds
            #expect(layers.contains { l in
                guard let paper, let path = l.path, !path.isEmpty else { return false }
                return l.convert(l.bounds, to: paper.layer).intersects(visible)
            }, "\(label): the ruling on screen is there")
        }
        check("top")
        canvas.contentOffset = CGPoint(x: 0, y: tall * 0.6)   // the canvas's delegate is told
        check("scrolled")
    }

    // MARK: Measured

    /// Main-thread time per frame while scrolling and pinching a dense page (UIKit's layout,
    /// PencilKit's and the app's work, and the Core Animation commit). Printed for comparisons;
    /// the bound only catches a page that would stall.
    @Test func scrollingAndZoomingADensePageMeasured() async throws {
        let i = try await Self.dense()
        defer { i.close() }
        #expect(await i.ready(timeout: .seconds(120)))
        let canvas = i.host.canvas
        let fit = Self.fit(i.host)
        canvas.layoutIfNeeded()
        CATransaction.flush()

        var scroll: [Double] = []
        for _ in 0..<150 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            canvas.contentOffset.y += 24
            canvas.layoutIfNeeded()
            CATransaction.flush()
            scroll.append(Self.ms(since: t0))
        }
        var zoom: [Double] = []
        var steps: [CGFloat] = []
        for k in 0..<30 {
            let t = CGFloat(k) / 30
            steps.append(fit * (1 + t))
        }
        for k in 0..<30 {
            let t = CGFloat(k) / 30
            steps.append(fit * (2 - 1.4 * t))
        }
        for z in steps {
            let t0 = DispatchTime.now().uptimeNanoseconds
            canvas.zoomScale = z
            canvas.layoutIfNeeded()
            CATransaction.flush()
            zoom.append(Self.ms(since: t0))
        }
        // What drawing the paper of one screen costs (Core Animation draws the shape layers again as
        // they move; here Core Graphics draws them, the visible rect clipped), at 40 places down the page.
        let (paperView, _) = Self.paperShapeLayers(i.host)
        var paint: [Double] = []
        if let paperView {
            canvas.zoomScale = fit
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let renderer = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format)
            let maxY = max(canvas.contentSize.height - canvas.bounds.height, 0)
            for k in 0..<40 {
                canvas.contentOffset = CGPoint(x: 0, y: maxY * CGFloat(k) / 40)
                canvas.layoutIfNeeded()
                CATransaction.flush()
                let origin = canvas.bounds.origin
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = renderer.image { ctx in
                    ctx.cgContext.translateBy(x: -origin.x, y: -origin.y)
                    paperView.layer.render(in: ctx.cgContext)
                }
                paint.append(Self.ms(since: t0))
            }
        }
        print("PERF-REPORT canvas paper per screen on a \(Int(canvas.contentSize.height)) pt page: \(Self.summary(paint))")
        print("PERF-REPORT canvas scroll on \(i.strokes.count) strokes, ruled: \(Self.summary(scroll))")
        print("PERF-REPORT canvas pinch on \(i.strokes.count) strokes, ruled: \(Self.summary(zoom))")
        #expect((scroll.max() ?? 0) < 2_000 && (zoom.max() ?? 0) < 2_000)
    }
}
