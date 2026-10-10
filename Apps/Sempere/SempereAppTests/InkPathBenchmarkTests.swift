import Foundation
import PencilKit
import Sempere
import Testing
@testable import SempereApp

/// Timings of the ink paths that run on the main actor per pen-up, erase
/// sample or playback tick, at a realistic page size. The default size is
/// small so the suite stays fast; `SEMPERE_BENCH_INK_STROKES=20000` (and
/// `SEMPERE_BENCH_INK_POINTS`, default 200) gives the numbers quoted in
/// commits (pass them as `TEST_RUNNER_SEMPERE_BENCH_INK_STROKES` to
/// xcodebuild). Each test also checks the result, so it is a test at any size.
@MainActor
struct InkPathBenchmarkTests {
    static let env = ProcessInfo.processInfo.environment
    static let strokeCount = Int(env["SEMPERE_BENCH_INK_STROKES"] ?? "") ?? 300
    static let pointCount = Int(env["SEMPERE_BENCH_INK_POINTS"] ?? "") ?? 200

    /// A page of `strokeCount` strokes in rows, as stored.
    static let stored: [Stroke] = (0..<strokeCount).map { i in
        TS.stroke(x: Double(i % 40) * 15, y: Double(i / 40) * 12, n: pointCount)
    }

    /// The process's physical footprint in bytes (what Xcode's memory gauge shows).
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// Runs `body` once and prints its time and the footprint it left behind
    /// (memory it allocated and still holds, in MB).
    static func time(_ label: String, _ body: () -> Void) -> Double {
        let before = footprint()
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        let mb = Double(footprint() - before) / 1_048_576
        print("InkBench \(label) strokes=\(strokeCount) points=\(pointCount): \(String(format: "%.2f", ms)) ms, footprint +\(String(format: "%.1f", mb)) MB")
        return ms
    }

    @Test func penUpOnADensePage() throws {
        let canvas = Self.stored.map(StrokeConversion.pkStroke)
        let drawing = PKDrawing(strokes: canvas)
        var ledger = try #require(StrokeLedger(stored: Self.stored, infos: drawing.strokes.map(CanvasStrokeInfo.init)))
        let next = PKDrawing(strokes: canvas + [TS.canvasStroke(TS.stroke(x: 700, y: 700, n: Self.pointCount))])
        var strokes: [PKStroke] = []
        _ = Self.time("bridge drawing.strokes") { strokes = next.strokes }
        _ = Self.time("read PKStroke.id") { _ = strokes.map(\.id) }
        _ = Self.time("fingerprint every stroke") { _ = strokes.map(CanvasStrokeInfo.init) }
        var change = StrokeLedger.Change()
        _ = Self.time("pen-up ledger update (items + update)") {
            change = ledger.update(StrokeLedger.items(for: next, tool: nil))
        }
        #expect(change.added.count == 1 && change.removed.isEmpty)
        #expect(ledger.live.count == Self.strokeCount + 1)

        // The canvas path: unchanged strokes pass the cheap check, unfingerprinted.
        let shown = drawing.strokes
        let after = next.strokes
        var l = try #require(StrokeLedger(stored: Self.stored, infos: shown.map(CanvasStrokeInfo.init)))
        _ = Self.time("pen-up canvas update") { change = l.update(after, tool: nil) }
        #expect(change.added.count == 1 && change.removed.isEmpty)
    }
}

extension InkPathBenchmarkTests {
    @Test func objectEraserSweepAcrossADensePage() {
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let host = UIView(frame: canvas.frame)
        host.addSubview(canvas)
        let eraser = ObjectEraserController()
        eraser.attach(to: host, canvas: canvas)
        canvas.drawing = PKDrawing(strokes: Self.stored.map(StrokeConversion.pkStroke))
        // A horizontal sweep along the first row, 200 samples 1 pt apart.
        let samples = 200
        _ = Self.time("object eraser sweep, \(samples) samples") {
            eraser.begin(at: EraserPoint(x: 0, y: 2))
            for i in 1..<samples { eraser.move(to: EraserPoint(x: Double(i), y: 2)) }
            eraser.end(at: EraserPoint(x: Double(samples), y: 2))
        }
        // TS.stroke rows: strokes 0, 1, … start every 15 pt and run 3 pt per point.
        let left = canvas.drawing.strokes.count
        #expect(left < Self.strokeCount && left > 0)
    }

    @Test func autosaveScanOfCleanLedgers() {
        let pages = 20
        let perPage = max(Self.strokeCount / pages, 1)
        var ledgers = (0..<pages).map { p in
            StrokeLedger(stored: Array(Self.stored.prefix(perPage)).map { var s = $0; s.id = UUID(); _ = p; return s },
                         info: { _ in CanvasStrokeInfo(key: .init(ink: "pen", values: []), family: .init(ink: "pen", values: []),
                                                         pathSignature: [], bounds: .init(minX: 0, minY: 0, maxX: 0, maxY: 0)) })
        }
        var saves = 0
        _ = Self.time("autosave scan of \(pages) clean ledgers") {
            for i in ledgers.indices where ledgers[i].beginSave(page: UUID()) != nil { saves += 1 }
        }
        #expect(saves == 0)
    }

    @Test func undoOfALargeEraseRevives() throws {
        let canvas = Self.stored.map(StrokeConversion.pkStroke)
        let drawing = PKDrawing(strokes: canvas)
        var ledger = try #require(StrokeLedger(stored: Self.stored, infos: drawing.strokes.map(CanvasStrokeInfo.init)))
        let all = StrokeLedger.items(for: drawing, tool: nil)
        let quarter = Self.strokeCount / 4
        ledger.update(Array(all.dropFirst(quarter)))
        _ = ledger.beginSave(page: UUID())
        var change = StrokeLedger.Change()
        _ = Self.time("undo of an erase of \(quarter) strokes") { change = ledger.update(all) }
        #expect(change.added.count == quarter)
        #expect(change.added.allSatisfy { $0.parent != nil })
    }

    @Test func thumbnailOfADensePage() {
        let size = CGSize(width: 120, height: 155)
        let pageSize = PageSize(width: 612, height: 792)
        _ = Self.time("page thumbnail from stored strokes") {
            _ = PageThumbnail.image(strokes: Self.stored, paper: .blank, pageSize: pageSize, size: size, scale: 2)
        }
    }

    @Test func playbackFirstTickComponents() {
        _ = Self.time("ledger for an unshown page (fingerprint via conversion)") {
            _ = StrokeLedger(stored: Self.stored, info: CanvasStrokeInfo.init(stored:))
        }
        let recording = Recording(blob: BlobRef(content: Data([1]), type: "audio/mp4"), started: Date())
        let state = NoteState(meta: NoteMeta(created: Date()), recordings: [recording])
        let linked = Self.stored.enumerated().map { i, s in
            var s = s
            s.rec = RecordingLink(id: recording.id, at: Double(i) / 10)
            return s
        }
        var scanned = Set<UUID>()
        _ = Self.time("highlight scan of one page") {
            scanned = RecordingSync.highlighted(linked, recording: recording.id, at: 10, in: state)
        }
        let basis = PlaybackIndex.Basis(recording: recording.id, recordings: [recording], pages: [UUID()], revisions: [0], ready: true)
        var index: PlaybackIndex?
        _ = Self.time("playback index of one page") {
            index = PlaybackIndex(basis: basis, pages: [(basis.pages[0], linked)], state: state)
        }
        var ticked: [UUID: Set<UUID>] = [:]
        _ = Self.time("playback tick (indexed)") { ticked = index?.highlighted(at: 10) ?? [:] }
        #expect(ticked[basis.pages[0]] ?? [] == scanned)
    }

    /// A recognition pass over a note: every page's digest, as after a pen-up
    /// on one of them (the others unchanged since the last pass).
    @Test func recognitionPassDigests() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let pages = 20
        let perPage = max(Self.strokeCount / pages, 1)
        let notePages = (0..<pages).map { p in (UUID(), Self.stored[(p * perPage) % Self.stored.count..<min((p + 1) * perPage, Self.stored.count)].map { $0 }) }
        _ = Self.time("recognition pass digests, every page, uncached") {
            for (_, strokes) in notePages { _ = RecognitionBasis.digest(of: strokes.map(\.id)) }
        }
        for (id, strokes) in notePages { _ = editor.strokeDigest(of: id, strokes) }
        var digests: [String] = []
        _ = Self.time("recognition pass digests, cached") {
            digests = notePages.map { editor.strokeDigest(of: $0.0, $0.1) }
        }
        #expect(digests == notePages.map { RecognitionBasis.digest(of: $0.1.map(\.id)) })
    }
}
