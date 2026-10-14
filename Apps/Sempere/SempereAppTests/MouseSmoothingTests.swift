import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Smoothed mouse and trackpad strokes on a Mac (`MouseInk.swift`,
/// docs/mac.md "Mouse and trackpad"). The filter itself is tested on Linux
/// (`StrokeSmoothingTests`); these check the app's side: when it applies,
/// the stroke it builds, the canvas, the ledger and undo.
@MainActor
@Suite(.serialized)
struct MouseSmoothingTests {
    typealias S = StrokeSmoothing.Sample

    /// A jagged horizontal mouse drag at y = 200 (canvas coordinates), x 100 → 500.
    static func jaggedDrag() -> [S] {
        (0...200).map { i in S(x: 100 + Double(i) * 2, y: 200 + (i % 2 == 0 ? 1.5 : -1.5), t: 50 + Double(i) / 120) }
    }

    static func withLevel<T>(_ level: StrokeSmoothing.Level?, _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MouseSmoothing.key)
        if let level { defaults.set(level.rawValue, forKey: MouseSmoothing.key) } else { defaults.removeObject(forKey: MouseSmoothing.key) }
        defer { defaults.set(saved, forKey: MouseSmoothing.key) }
        return try body()
    }

    // MARK: - When it applies

    @Test func onlyThePointerOnAMacWithAnInkToolIsSmoothed() {
        #expect(MouseSmoothing.touchTypes.map(\.intValue) == [UITouch.TouchType.indirectPointer.rawValue],
                "the Pencil and fingers never reach the smoothing")
        func takes(isMac: Bool = true, level: StrokeSmoothing.Level = .light, editable: Bool = true,
                   inking: Bool = true, ruler: Bool = false) -> Bool {
            MouseSmoothing.takesPointer(isMac: isMac, level: level, editable: editable, inkingTool: inking, rulerActive: ruler)
        }
        #expect(takes())
        #expect(takes(level: .strong))
        #expect(!takes(isMac: false), "the iPad is unchanged: PencilKit draws")
        #expect(!takes(level: .off), "Off: PencilKit draws the pointer, as before")
        #expect(!takes(editable: false))
        #expect(!takes(inking: false), "eraser and lasso stay PencilKit's (or the object eraser's)")
        #expect(!takes(ruler: true), "the ruler snaps PencilKit's own strokes")
    }

    @Test func aRightClickNeverDraws() {
        #expect(!PointerInkGesture.isSecondaryClick(buttons: .primary, modifiers: []))
        #expect(!PointerInkGesture.isSecondaryClick(buttons: .primary, modifiers: [.shift, .alternate]))
        #expect(PointerInkGesture.isSecondaryClick(buttons: .secondary, modifiers: []))
        #expect(PointerInkGesture.isSecondaryClick(buttons: .primary, modifiers: .control))
    }

    @Test func theSettingDefaultsToLight() {
        Self.withLevel(nil) { #expect(MouseSmoothing.load() == .light) }
        Self.withLevel(.strong) { #expect(MouseSmoothing.load() == .strong) }
        Self.withLevel(.off) { #expect(MouseSmoothing.load() == .off) }
        UserDefaults.standard.set("wobbly", forKey: MouseSmoothing.key)
        #expect(MouseSmoothing.load() == .light)
        UserDefaults.standard.removeObject(forKey: MouseSmoothing.key)
    }

    /// On the iPad (the simulator CI runs), a canvas never hands any input to
    /// the mouse ink: PencilKit's drawing gesture takes the Pencil as before.
    @Test func theIPadCanvasKeepsPencilKitsGesture() throws {
        guard !Platform.isMac else { return }
        try Self.withLevel(.strong) {
            let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
            #expect(host.select(tool: .pen))
            #expect(!host.pointerInkActive)
            #expect(host.canvas.drawingGestureRecognizer.isEnabled)
            _ = try #require(host.canvas.gestureRecognizers?.first { $0 is PointerInkGesture })
            #expect(host.canvas.gestureRecognizers?.first { $0 is PointerInkGesture }?.isEnabled == false)
        }
    }

    /// On a Mac (`scripts/app.sh test-mac`), Light and Strong hand the pointer
    /// to the app for ink tools only; Off and the ruler give it back.
    @Test func theMacCanvasTakesThePointerForInkTools() throws {
        guard Platform.isMac else { return }
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        Self.withLevel(.light) {
            #expect(host.select(tool: .pen))
            #expect(host.pointerInkActive)
            #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
            #expect(!host.canvas.panGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)))
            host.toggleRuler()
            #expect(!host.pointerInkActive, "the ruler: PencilKit draws")
            host.toggleRuler()
            #expect(host.pointerInkActive)
            #expect(host.select(tool: .lasso))
            #expect(!host.pointerInkActive)
            #expect(host.select(tool: .marker))
        }
        Self.withLevel(.off) {
            host.toolDidChange()
            #expect(!host.pointerInkActive)
            #expect(host.canvas.drawingGestureRecognizer.isEnabled)
        }
    }

    // MARK: - The stroke

    @Test func theStrokeIsSmoothedInPagePointsAtTheToolsWidth() throws {
        let tool = PKInkingTool(.pen, color: .systemBlue, width: 4)
        let raw = Self.jaggedDrag()
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let params = try #require(StrokeSmoothing.Level.light.parameters)
        let stroke = try #require(MouseSmoothing.stroke(samples: raw, zoom: 2, tool: tool, parameters: params,
                                                        creationDate: created))
        #expect(stroke.ink.inkType == .pen)
        #expect(stroke.path.creationDate == created)
        let points = Array(stroke.path)
        let first = try #require(points.first), last = try #require(points.last)
        // Endpoints kept (page points = canvas points / zoom), within Float32 storage.
        #expect(abs(first.location.x - 50) < 0.01 && abs(first.location.y - 100.75) < 0.01)
        #expect(abs(last.location.x - 250) < 0.01 && abs(last.location.y - 100.75) < 0.01)
        #expect(first.timeOffset == 0)
        #expect(abs(last.timeOffset - 200.0 / 120) < 0.001)
        // The jitter (±0.75 page pt here) is mostly gone away from the ends.
        let inner = points.filter { $0.location.x > 60 && $0.location.x < 240 }
        #expect(inner.count > 50)
        #expect(inner.allSatisfy { abs($0.location.y - 100) < 0.25 })
        // Every point draws at the tool's width (format width = PencilKit tool width).
        for p in points {
            let w = NibSize.formatSize(p.size, tool: .pen)
            #expect(abs(w.w - 4) < 0.01 && abs(w.h - 4) < 0.01)
        }
    }

    @Test func aClickIsADot() throws {
        let tool = PKInkingTool(.marker, color: .yellow, width: 20)
        let params = try #require(StrokeSmoothing.Level.strong.parameters)
        let p = S(x: 30, y: 40, t: 1)
        let stroke = try #require(MouseSmoothing.stroke(samples: [p], zoom: 1, tool: tool, parameters: params, creationDate: Date()))
        #expect(Array(stroke.path).count == 1)
        #expect(MouseSmoothing.stroke(samples: [], zoom: 1, tool: tool, parameters: params, creationDate: Date()) == nil)
    }

    // MARK: - On the canvas

    static func canvas(_ strokes: [PKStroke]) -> (PKCanvasView, MouseInkController) {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let ink = MouseInkController()
        ink.attach(to: canvas)
        canvas.drawing = PKDrawing(strokes: strokes)
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        return (canvas, ink)
    }

    /// Everything a stroke holds, exactly: ink, colour, transform, mask,
    /// creation date, texture seed and every control point's fields. (The
    /// bytes of `dataRepresentation` differ between encodes of one stroke.)
    static func content(_ s: PKStroke) -> [String] {
        var c = [s.ink.inkType.rawValue, "\(s.ink.color)", "\(s.transform)", "\(s.mask?.bounds as Any)",
                 "\(s.path.creationDate.timeIntervalSinceReferenceDate)", "\(s.randomSeed)", "\(s.path.count)"]
        for p in s.path {
            c.append("\(p.location) \(p.timeOffset) \(p.size) \(p.opacity) \(p.force) \(p.azimuth) \(p.altitude)")
        }
        return c
    }

    static func drag(_ ink: MouseInkController, _ samples: [S]) {
        ink.begin(at: samples[0])
        for chunk in stride(from: 1, to: samples.count, by: 4) {
            ink.add(samples[chunk..<min(chunk + 4, samples.count)])
        }
        ink.end()
    }

    /// A mouse stroke is added after the page's strokes, which stay exactly as
    /// they were (Pencil strokes are never re-smoothed); one undo step.
    @Test func aDragAddsOneStrokeAndLeavesTheOthersByteForByte() throws {
        let pencil = [TS.canvasStroke(TS.stroke(x: 40, y: 60)), TS.canvasStroke(TS.stroke(x: 40, y: 300, tool: .pencil))]
        let (canvas, ink) = Self.canvas(pencil)
        let container = UndoContainer(frame: canvas.frame)
        container.addSubview(canvas)
        let before = canvas.drawing.strokes.map(Self.content)
        try Self.withLevel(.light) {
            Self.drag(ink, Self.jaggedDrag())
            #expect(!ink.isDrawing)
            let strokes = canvas.drawing.strokes
            #expect(strokes.count == 3)
            #expect(strokes.prefix(2).map(Self.content) == before)
            let added = try #require(strokes.last)
            #expect(added.ink.inkType == .pen)
            let undo = try #require(canvas.undoManager)
            #expect(undo === container.undo)
            undo.undo()
            #expect(canvas.drawing.strokes.count == 2)
            #expect(canvas.drawing.strokes.map(Self.content) == before)
            undo.redo()
            #expect(canvas.drawing.strokes.count == 3)
        }
    }

    @Test func thePreviewIsStreamlinedWhileDragging() {
        let (canvas, ink) = Self.canvas([])   // the controller holds the canvas weakly
        defer { withExtendedLifetime(canvas) {} }
        Self.withLevel(.strong) {
            let raw = Self.jaggedDrag()
            ink.begin(at: raw[0])
            ink.add(raw.dropFirst())
            #expect(ink.isDrawing)
            let shown = ink.previewPoints
            #expect(shown.count == raw.count)
            #expect(shown.first == CGPoint(x: raw[0].x, y: raw[0].y))
            let tail = shown.suffix(100).map { abs($0.y - 200) }
            #expect((tail.max() ?? 9) < 0.75, "the ±1.5 pt zigzag is at least halved on screen")
            ink.cancelStroke()
            #expect(!ink.isDrawing && ink.previewPoints.isEmpty)
        }
    }

    @Test func offOrAnEraserDrawsNothing() {
        let (canvas, ink) = Self.canvas([])
        Self.withLevel(.off) {
            Self.drag(ink, Self.jaggedDrag())
            #expect(canvas.drawing.strokes.isEmpty)
        }
        canvas.tool = PKEraserTool(.bitmap)
        Self.withLevel(.light) {
            Self.drag(ink, Self.jaggedDrag())
            #expect(canvas.drawing.strokes.isEmpty)
        }
    }

    /// A page loaded under the pointer (`PageCanvasHost.cancelErasing`) gets
    /// none of the old page's stroke.
    @Test func aCancelledStrokeIsNeverAdded() {
        let (canvas, ink) = Self.canvas([])
        Self.withLevel(.light) {
            let raw = Self.jaggedDrag()
            ink.begin(at: raw[0])
            ink.add(raw.dropFirst())
            ink.cancelStroke()
            ink.add(raw.suffix(3))
            ink.end()
            #expect(canvas.drawing.strokes.isEmpty)
        }
    }

    /// Through the ledger, a mouse stroke is one `addStroke` at the tool's width,
    /// and the page's stored strokes are not touched.
    @Test func aMouseStrokeIsWrittenAsOneAddStroke() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage)
        let full = editor.drawing(for: page.id)
        let (canvas, ink) = Self.canvas(full.strokes)
        let tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.tool = tool
        Self.withLevel(.light) { Self.drag(ink, Self.jaggedDrag()) }
        #expect(canvas.drawing.strokes.count == full.strokes.count + 1)
        editor.drawingDidChange(pageID: page.id, drawing: canvas.drawing, tool: tool)
        await editor.flush()
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        #expect(deltas.first?.count == 1)
        guard case .addStroke(let p, let stroke)? = deltas.first?.first else {
            Issue.record("expected one addStroke, got \(String(describing: deltas.first))")
            return
        }
        #expect(p == page.id)
        #expect(stroke.ink.tool == .pen)
        #expect(abs(stroke.ink.width - 3) < 0.01)
        #expect(stroke.points.allSatisfy { abs($0.w - 3) < 0.01 })
    }
}

/// A superview with an undo manager of its own, as a page of the stack has.
private final class UndoContainer: UIView {
    let undo = UndoManager()
    override var undoManager: UndoManager? { undo }
}
