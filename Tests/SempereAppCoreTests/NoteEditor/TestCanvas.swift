import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing
import VaultTestSupport

/// A canvas of stored strokes (`NoteCanvas`), for the editor's tests on every platform: a canvas stroke is the
/// stored stroke as shown, fingerprinted from all of its content, so a stroke changed in any way is a new one
/// (PencilKit's canvas is the app's `PencilCanvas`, tested in the app's suites).
enum TestCanvas: NoteCanvas {
    struct Drawing: Equatable {
        var strokes: [Stroke]
    }

    typealias CanvasStroke = Stroke
    typealias Tool = Never
    typealias Glue = TestGlue

    static var emptyDrawing: Drawing { Drawing(strokes: []) }
    static func strokes(of drawing: Drawing) -> [Stroke] { drawing.strokes }
    static func drawing(of strokes: [Stroke]) -> Drawing { Drawing(strokes: strokes) }
    static func canvasStroke(_ stroke: Stroke) -> Stroke { stroke }

    static func info(of s: Stroke) -> CanvasStrokeInfo {
        let t = s.transform ?? .identity
        let family = [Double(s.ink.color.r), Double(s.ink.color.g), Double(s.ink.color.b), Double(s.ink.color.a),
                      t.a, t.b, t.c, t.d, t.tx, t.ty]
        let key = family + [Double(s.points.count)] + s.points.flatMap { [$0.x, $0.y, $0.w, $0.t, $0.f] }
        let xs = s.points.map(\.x), ys = s.points.map(\.y)
        let bounds = CanvasStrokeInfo.Bounds(minX: xs.min() ?? 0, minY: ys.min() ?? 0, maxX: xs.max() ?? 0,
                                             maxY: ys.max() ?? 0)
        let ends = [Double(s.points.count)] + [s.points.first, s.points.last].compactMap { $0 }.flatMap { [$0.x, $0.y] }
        return CanvasStrokeInfo(key: .init(ink: s.ink.tool.rawValue, values: key),
                                family: .init(ink: s.ink.tool.rawValue, values: family), pathSignature: ends,
                                bounds: bounds, canvasID: s.id)
    }

    /// Converts in order; with `visible`, the strokes that start inside it go first (as a drawing of their own).
    static func convert(_ strokes: [Stroke], visible: CGRect?, visibleFirst: ((Drawing) -> Void)?) -> Drawing {
        if let visible, let visibleFirst {
            visibleFirst(Drawing(strokes: strokes.filter { s in
                s.points.first.map { visible.contains(CGPoint(x: $0.x, y: $0.y)) } ?? false
            }))
        }
        return Drawing(strokes: strokes)
    }

    static func encode(_ drawing: Drawing) -> Data { (try? JSONEncoder().encode(drawing.strokes)) ?? Data() }
    static func decode(_ data: Data) -> Drawing? { (try? JSONDecoder().decode([Stroke].self, from: data)).map(Drawing.init) }
    static func matches(_ drawing: Drawing, _ strokes: [Stroke]) -> Bool {
        drawing.strokes.map(\.id) == strokes.map(\.id) && drawing.strokes.map(\.points) == strokes.map(\.points)
    }

    /// A canvas stroke the user drew keeps its id while it is new; the ledger gives it the id it is saved under.
    static func update(_ ledger: inout StrokeLedger, to drawing: Drawing, tool: Never?,
                       stamp: (@Sendable (Date) -> RecordingLink?)?) -> StrokeLedger.Change {
        let link = stamp?(Date())
        return ledger.update(drawing.strokes.map { s in
            StrokeLedger.Item(info: info(of: s), make: {
                var made = s
                if let link { made.rec = link }
                return [made]
            })
        })
    }

    static func relayout(_ content: TextContent, frame: Rect) -> (content: TextContent, frame: Rect) { (content, frame) }
    static var textBoxMatcher: TextBoxMatcher { { _, _ in [] } }

    @MainActor static func makeGlue() -> TestGlue { TestGlue() }
    @MainActor static func recordingStamp(of editor: NoteEditorModel<TestCanvas>) -> (@Sendable (Date) -> RecordingLink?)? {
        editor.glue.stamp
    }
    @MainActor static func visibleRect(ofPage page: UUID, in editor: NoteEditorModel<TestCanvas>) -> CGRect? {
        editor.glue.visible
    }
    @MainActor static func editorWillClose(_ editor: NoteEditorModel<TestCanvas>) async { editor.glue.closes += 1 }
    @MainActor static func recordingWillBeRemoved(_ id: UUID, in editor: NoteEditorModel<TestCanvas>) {
        editor.glue.removedRecordings.append(id)
    }
    @MainActor static func recordingFailed(_ failure: RecordingChangeFailure, in editor: NoteEditorModel<TestCanvas>) {
        editor.glue.failures.append(failure)
    }
}

/// What the test canvas's hooks were asked, and what they answer.
@MainActor
final class TestGlue {
    var stamp: (@Sendable (Date) -> RecordingLink?)?
    var visible: CGRect?
    var closes = 0
    var removedRecordings: [UUID] = []
    var failures: [RecordingChangeFailure] = []
}

typealias TestEditor = NoteEditorModel<TestCanvas>

/// The editor's suites, one test at a time: each writes and reads vaults, and run all at once they took the CPU
/// from the suites beside them whose waits are bounded in wall time (`SyncCoordinatorTests`; Gitea Linux job, #18).
@Suite(.serialized)
enum NoteEditorSuites {}

/// A canvas showing one page of an editor (`RemoteInkView`): counts the merges that reloaded it.
@MainActor
final class TestInkView: RemoteInkView {
    var shownPageID: UUID?
    var isUsingInk = false
    var reloads = 0
    var shown: TestCanvas.Drawing?

    init(page: UUID) { shownPageID = page }

    func reloadInk(from editor: TestEditor) {
        guard let page = shownPageID, let drawing = editor.readyDrawing(for: page) else { return }
        reloads += 1
        shown = drawing
    }
}

/// The editor tests' vault: a "lecture" note of two pages, two strokes on the first, and a note in Recently
/// Deleted (the shape of the app's fixture, `Tests/SempereTests/Fixtures`).
///
/// Vault IO (creating, writing, reading back) runs off the main actor (`@concurrent`): the editor suites run in
/// parallel with main-actor suites whose waits are bounded in wall time (`SyncCoordinatorTests`), and a long
/// synchronous read or write on the main actor would hold them all back (Gitea Linux job, #18).
enum EditorFixture {
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deleted = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// A wavy stroke of `n` control points starting at (`x`, `y`).
    static func stroke(x: Double = 40, y: Double = 60, n: Int = 24, tool: InkTool = .pen,
                       color: Sempere.Color = Sempere.Color(r: 0x1A, g: 0x2B, b: 0x3C, a: 0xFF), width: Double = 3) -> Stroke {
        let points = (0..<n).map { i -> StrokePoint in
            let d = Double(i)
            return StrokePoint(x: x + d * 3, y: y + 10 * sin(d / 3), t: d * 0.012, w: width, h: width, o: 0.9,
                               f: 0.2 + d / 100, az: 0.4, al: 1.1)
        }
        return Stroke(ink: Ink(tool: tool, color: color, width: width), points: points)
    }

    /// A fresh device-state file.
    static func deviceStateURL() -> URL {
        TestTemp.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("device.json")
    }

    /// The fixture vault, made once per run: keys and the first revisions cost far more CPU than a copy, and the
    /// editor suites need dozens of vaults.
    private struct Template: @unchecked Sendable {
        let url: URL
        let identity: NativeIdentity
    }

    private static let template = Task<Template, any Error> {
        let identity = try NativeIdentity.generate(.postQuantum)
        let url = TestTemp.root.appendingPathComponent("editor-template-\(UUID().uuidString)")
            .appendingPathComponent("sample.sempere")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let vault = try TestVaults.create(at: url, identities: [identity])
        let first = Page(order: PageOrder.between(nil, nil))
        let second = Page(order: PageOrder.between(first.order, nil))
        let state = deviceStateURL()
        _ = try vault.apply([.setMeta(.title("Lecture")), .addPage(first), .addPage(second),
                             .addStroke(page: first.id, stroke: stroke(x: 40, y: 60)),
                             .addStroke(page: first.id, stroke: stroke(x: 40, y: 160))],
                            to: lecture, deviceState: state, app: "fixture/1", wall: Date(timeIntervalSinceNow: -3600))
        let page = Page(order: PageOrder.between(nil, nil))
        _ = try vault.apply([.setMeta(.title("Old")), .addPage(page), .addStroke(page: page.id, stroke: stroke())],
                            to: deleted, deviceState: state, app: "fixture/1", wall: Date(timeIntervalSinceNow: -3600))
        _ = try vault.apply([.deleteNote], to: deleted, deviceState: state, app: "fixture/1")
        return Template(url: url, identity: identity)
    }

    /// A vault of its own with the two notes, written by another device an hour ago (a copy of the template).
    @concurrent static func vault() async throws -> Vault {
        let template = try await template.value
        let url = TestTemp.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("sample.sempere")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: template.url, to: url)
        return try TestVaults.open(at: url, identity: template.identity)
    }

    @MainActor static func open(_ vault: Vault, note: UUID = lecture, debounce: Duration = .milliseconds(300),
                     recognizer: (any PageRecognizing)? = nil, recognitionDelay: Duration = .seconds(60))
        async throws -> (TestEditor, DeviceClock) {
        let clock = try DeviceClock(url: deviceStateURL(), app: "sempere-test/1")
        let editor = try await TestEditor.open(vault: vault, noteID: note, clock: clock, debounce: debounce,
                                               recognizer: recognizer, recognitionDelay: recognitionDelay)
        return (editor, clock)
    }

    /// Deltas this device wrote to `note`, oldest first.
    @concurrent static func myDeltas(_ vault: Vault, _ clock: DeviceClock, note: UUID = lecture) async throws -> [[Op]] {
        let device = clock.device
        return try vault.loadNote(note).revisions.filter { $0.device == device }.sorted { $0.seq < $1.seq }.map {
            if case .delta(let ops) = $0.body { return ops }
            return []
        }
    }

    /// The note as a fresh read reconstructs it.
    @concurrent static func state(_ vault: Vault, _ note: UUID = lecture) async throws -> NoteState {
        try vault.reconstruct(noteId: note)
    }

    /// `ops` written into `note` by another device (`deviceState`).
    @concurrent static func apply(_ ops: [Op], to note: UUID, in vault: Vault, deviceState: URL) async throws {
        _ = try vault.apply(ops, to: note, deviceState: deviceState, app: "other-device/1")
    }

    /// A revision file written as it is.
    @concurrent static func write(_ revision: Revision, to vault: Vault) async throws {
        try vault.write(revision)
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes.
    @MainActor static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
