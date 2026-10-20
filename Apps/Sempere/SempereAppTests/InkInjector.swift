import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Synthetic ink through the app's real canvas path: a `PageCanvasHost` in a window, its
/// `PageCanvasView.Coordinator` as the canvas delegate (as `PageCanvasView` and the paged stack
/// wire them), showing one page of a `NoteEditor`. Every edit sets `canvas.drawing` the way
/// PencilKit leaves it after the gesture (a new stroke appended; lasso moves, resizes and recolors
/// keeping the stroke's id; a pixel erase leaving masked pieces), so the change reaches the editor
/// through `canvasViewDrawingDidChange`, the ledger and the autosave, and registers one undo step on
/// the canvas's undo manager as PencilKit does. The object eraser runs the app's own gesture
/// controller (`ObjectEraserController`). Device checks c4, c11, c12, c50, c52 and later ones use it.
@MainActor
final class InkInjector {
    let editor: NoteEditor
    let pageID: UUID
    let window: UIWindow
    let host: PageCanvasHost
    let coordinator: PageCanvasView.Coordinator
    private let timer: TimingDelegate
    /// Undo for a one-page canvas, which otherwise takes the window's (none in a test window). Each
    /// gesture is one undo group the injector opens and closes (`grouped`): a test's steps do not
    /// follow run-loop events, so the manager does not group by event.
    private let undo: UndoManager = {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }()

    /// Runs `body` (one gesture: an item drag's end, a turn's end) as one undo group.
    func grouped<T>(_ body: () throws -> T) rethrows -> T {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return try body()
    }

    /// Main-thread time of each drawing change the canvas reported (the delegate call: ledger
    /// update, extent, autosave scheduling), in milliseconds, oldest first.
    var changeTimes: [Double] { timer.times }

    init(editor: NoteEditor, page: UUID? = nil, size: CGSize = CGSize(width: 820, height: 1180)) throws {
        self.editor = editor
        pageID = try #require(page ?? editor.currentPage?.id)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        host = PageCanvasHost(frame: window.bounds)
        coordinator = PageCanvasView.Coordinator()
        timer = TimingDelegate(coordinator)
        host.canvas.delegate = timer
        host.testUndoManager = undo
        window.addSubview(host)
        window.isHidden = false
        show()
        host.layoutIfNeeded()
    }

    /// What `PageCanvasView.updateUIView` does: the page's content on the host (after the editor changed).
    /// `selecting`: selection mode (items are picked, moved, resized and turned; nothing draws).
    func show(selecting: Bool = false, itemSource: ItemLayerSource = ItemLayerSource(),
              itemCommands: ItemCommands = ItemCommands()) {
        let page = editor.pages.first { $0.id == pageID }
        coordinator.apply(editor: editor, pageID: pageID,
                          content: PageCanvasContent(paper: page.map(editor.displayedPaper(of:)) ?? .blank,
                                                     pageSize: editor.pageSize, generation: editor.canvasGeneration,
                                                     itemSource: itemSource, itemCommands: itemCommands,
                                                     selectingItems: selecting),
                          to: host)
    }

    /// Waits until the page's ink is on the canvas (it is prepared off the main actor).
    func ready(timeout: Duration = .seconds(30)) async -> Bool {
        await TS.waitUntil(timeout: timeout) { !self.host.isPreparing && !self.coordinator.isLoading }
    }

    func close() {
        coordinator.loadTask?.cancel()
        editor.detachInkView(coordinator)
        window.isHidden = true
    }

    var drawing: PKDrawing { host.canvas.drawing }
    var strokes: [PKStroke] { host.canvas.drawing.strokes }
    var undoManager: UndoManager { undo }

    // MARK: - Edits, as PencilKit leaves the drawing after each gesture

    /// Pen-up of `strokes` (drawn now, so their creation dates fall in any recording running).
    func draw(_ strokes: [Stroke], created: Date = Date()) {
        apply(self.strokes + strokes.map { TS.canvasStroke($0, created: created) }, action: "Draw")
    }

    /// Pen-up of strokes PencilKit made (`PencilTrace`): points with the pressure, azimuth, altitude and
    /// timing a Pencil reports. `tool` becomes the canvas's tool first, as picking it in the palette
    /// does, so its width reaches the stored stroke (the coordinator reads the tool at pen-up).
    func drawCanvas(_ strokes: [PKStroke], tool: PKInkingTool? = nil) {
        if let tool { host.canvas.tool = tool }
        apply(self.strokes + strokes, action: "Draw")
    }

    /// A lasso move of the strokes `ids` by (`dx`, `dy`): same ids, new transforms, brought to the top.
    func lassoMove(_ ids: Set<UUID>, dx: CGFloat, dy: CGFloat) {
        edit(ids, action: "Move") { $0.transform = $0.transform.concatenating(CGAffineTransform(translationX: dx, y: dy)) }
    }

    /// A lasso resize by `scale` about the strokes' render-bounds center.
    func resize(_ ids: Set<UUID>, scale: CGFloat) {
        let box = strokes.filter { ids.contains($0.id) }.map(\.renderBounds).reduce(CGRect.null) { $0.union($1) }
        let t = CGAffineTransform(translationX: box.midX, y: box.midY).scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        edit(ids, action: "Resize") { $0.transform = $0.transform.concatenating(t) }
    }

    /// A lasso recolor.
    func recolor(_ ids: Set<UUID>, _ color: UIColor) {
        edit(ids, action: "Color") { $0.ink = PKInk($0.ink.inkType, color: color) }
    }

    /// A pixel-eraser pass straight across stroke `id` at its middle: the stroke becomes two masked
    /// pieces (the first keeps the id, as PencilKit sometimes does; `keepID: false` gives both new ids).
    func pixelErase(across id: UUID, keepID: Bool = true, gap: CGFloat = 4) {
        var all = strokes
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        let s = all[i]
        let b = s.renderBounds
        let left = UIBezierPath(rect: CGRect(x: b.minX - 5, y: b.minY - 5, width: b.width / 2 - gap + 5, height: b.height + 10))
        let right = UIBezierPath(rect: CGRect(x: b.midX + gap, y: b.minY - 5, width: b.width / 2 + 5, height: b.height + 10))
        var first = PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: left, randomSeed: s.randomSeed)
        if keepID { first.id = s.id }
        let second = PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: right, randomSeed: s.randomSeed)
        all.replaceSubrange(i...i, with: [first, second])
        apply(all, action: "Erase")
    }

    /// A pixel erase that takes the whole of stroke `id` (it leaves nothing).
    func pixelEraseWhole(_ id: UUID) {
        apply(strokes.filter { $0.id != id }, action: "Erase")
    }

    /// One object-eraser gesture along `path` (page points), through the app's controller: one
    /// undo step for the whole gesture. Returns how many strokes it removed.
    @discardableResult
    func objectErase(_ path: [EraserPoint]) -> Int {
        guard let first = path.first else { return 0 }
        let before = strokes.count
        let eraser = host.objectEraser
        grouped {
            eraser.begin(at: first)
            for p in path.dropFirst() { eraser.move(to: p) }
            eraser.end(at: path.last ?? first)
        }
        return before - strokes.count
    }

    func performUndo() { undo.undo() }
    func performRedo() { undo.redo() }

    /// The object eraser's gesture by hand (a test that interleaves other events with it): `end`
    /// registers the gesture's undo step, inside one group.
    func eraserEnd(at p: EraserPoint) { grouped { host.objectEraser.end(at: p) } }

    private func edit(_ ids: Set<UUID>, action: String, _ change: (inout PKStroke) -> Void) {
        var kept: [PKStroke] = [], moved: [PKStroke] = []
        for var s in strokes {
            if ids.contains(s.id) {
                change(&s)
                moved.append(s)
            } else {
                kept.append(s)
            }
        }
        apply(kept + moved, action: action)
    }

    /// Sets the drawing as the gesture left it (the canvas reports it to the editor) and registers
    /// the undo step PencilKit would: back to the drawing before, and redo to this one.
    private func apply(_ strokes: [PKStroke], action: String) {
        let before = drawing
        grouped {
            host.canvas.drawing = PKDrawing(strokes: strokes)
            register(restoring: before, redoing: drawing, action: action)
        }
    }

    private func register(restoring: PKDrawing, redoing: PKDrawing, action: String) {
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.host.canvas.drawing = restoring
                target.register(restoring: redoing, redoing: restoring, action: action)
            }
        }
        undo.setActionName(action)
    }
}

/// Forwards the canvas's delegate calls to the page's coordinator and times the drawing changes.
@MainActor
private final class TimingDelegate: NSObject, PKCanvasViewDelegate {
    let target: PageCanvasView.Coordinator
    private(set) var times: [Double] = []
    init(_ target: PageCanvasView.Coordinator) { self.target = target }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let start = DispatchTime.now().uptimeNanoseconds
        target.canvasViewDrawingDidChange(canvasView)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { target.canvasViewDidBeginUsingTool(canvasView) }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { target.canvasViewDidEndUsingTool(canvasView) }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { target.scrollViewDidZoom(scrollView) }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { target.scrollViewDidScroll(scrollView) }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        target.scrollViewDidEndZooming(scrollView, with: view, atScale: scale)
    }
}

/// Vaults for the dense-ink device checks, written with the same generator as `sempere pages
/// scribble` (`SyntheticInk`): a copy of the fixture vault plus the notes a check needs.
@MainActor
enum InkFixture {
    struct Made {
        let url: URL
        let key: URL
        let vault: Vault
        let note: UUID
        let page: UUID
    }

    /// Strokes on "the dense page" of checks 11, 12, 18 and 52: 20 000 on the Mac (and on a
    /// device). On the iOS simulator PencilKit draws without the GPU: replacing the drawing of a
    /// visible canvas of 20 000 strokes there took about 45 s per change (Mac Catalyst: under
    /// 0.1 s), so simulator runs (the release sweep's iPad suite) use a tenth. Device timings on
    /// the full page stay the owner's (check 18).
    static let denseStrokes: Int = {
        #if targetEnvironment(simulator)
        return 2_000
        #else
        return 20_000
        #endif
    }()

    /// The same scale for other dense fixtures (`count` on a Mac, a tenth on the simulator).
    static func scaled(_ count: Int) -> Int { count * denseStrokes / 20_000 }

    /// A pageless note whose one page holds `strokes` strokes (`denseStrokes`: the dense page of checks
    /// 11, 12 and 52), written as another device's single import-like delta, or `perRevision` to a
    /// delta (a note of many revisions).
    static func denseNote(strokes: Int = InkFixture.denseStrokes, points: Int = 16, perRevision: Int? = nil, seed: UInt64 = 1,
                          rowHeight: Double = 20, in made: (url: URL, key: URL)? = nil) throws -> Made {
        let (url, key) = try made ?? AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let note = UUID()
        let page = Page(order: PageOrder.between(nil, nil))
        let state = TS.deviceStateURL()
        let height = 40 + (Double(strokes) / 38 + 2) * rowHeight
        _ = try vault.apply([.setMeta(.title("Dense")), .addPage(page),
                             .setMeta(.pageSize(PageSize(width: 612, height: height, infinite: true, breakHeight: 792)))],
                            to: note, deviceState: state, app: "fixture/1")
        var ink = SyntheticInk(seed: seed, options: .init(pointsPerStroke: points, rowHeight: rowHeight, top: 40))
        _ = try vault.applyInOrder(ink.deltas(strokes, page: page.id, perRevision: perRevision ?? strokes),
                                   to: note, deviceState: state, app: "fixture/1")
        return Made(url: url, key: key, vault: vault, note: note, page: page.id)
    }

    /// Opens `made`'s note in an editor of a fresh device (its own clock).
    static func editor(_ made: Made, vault: Vault? = nil, debounce: Duration = .seconds(60),
                       drawingCache: DrawingCache? = nil) async throws -> (NoteEditor, DeviceClock) {
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let editor = try await NoteEditor.open(vault: vault ?? made.vault, noteID: made.note, clock: clock, debounce: debounce,
                                               cache: drawingCache)
        return (editor, clock)
    }

    /// Copies every note file one folder has and the other lacks, both ways: what a sync service does
    /// between two copies of a vault (revisions are write-once, so a copy never overwrites).
    static func sync(_ a: URL, _ b: URL) throws {
        let fm = FileManager.default
        for (from, to) in [(a, b), (b, a)] {
            let notes = from.appendingPathComponent("notes")
            for rel in TS.regularFiles(under: notes, skipHidden: true) {
                let target = to.appendingPathComponent("notes").appendingPathComponent(rel)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: notes.appendingPathComponent(rel), to: target)
            }
        }
    }
}
