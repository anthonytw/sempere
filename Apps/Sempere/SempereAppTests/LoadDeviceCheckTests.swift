import Age
import Foundation
import PDFKit
import PencilKit
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// Playback that reports whatever position the test sets, for a recording of any length.
final class LongPlayback: AudioPlaybackBackend {
    let length: Double
    var currentTime: Double = 0
    var isPlaying = false
    init(length: Double) { self.length = length }
    func load(_ url: URL) throws -> Double { length }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func unload() { isPlaying = false }
}

/// Device checks under load, automated in process (plan "Device checks after the audit"): c14
/// recording playback in a long note, c20 recognition while writing, c21 a long note to PDF, c42
/// export right after drawing (PDF), c54 browser actions and Version History on a note of hundreds
/// of revisions. Fixtures are written with `SyntheticInk` (`sempere pages scribble`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct LoadDeviceCheckTests {
    /// A model on `url`, unlocked, with `note` open in its editor.
    static func model(_ url: URL, key: URL, note: UUID, debounce: Duration = .milliseconds(200),
                      recognizer: (any PageRecognizing)? = nil, recognitionDelay: Duration = .seconds(60),
                      summaryCache: URL? = nil, playback: AudioPlaybackBackend? = nil) async throws -> AppModel {
        let dir = try BrowserTests.tempDir()
        let model = AppModel(deviceStateURL: dir.appendingPathComponent("device.json"), editorDebounce: debounce,
                             recognizer: recognizer, recognitionDelay: recognitionDelay, summaryCacheDirectory: summaryCache)
        model.blobCacheFolder = dir.appendingPathComponent("blobs")
        if let playback { model.playbackBackend = { playback } }
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = note
        try await model.openEditor(for: note)
        return model
    }

    static func vault(_ url: URL, _ key: URL) throws -> Vault {
        try Vault.open(at: url, identities: [try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))])
    }

    /// A paged note of `pages` letter pages, `strokesPerPage` strokes on each.
    static func longNote(_ note: UUID = UUID(), pages count: Int, strokesPerPage: Int, recording: SyntheticInk.Recording? = nil,
                         blob: BlobRef? = nil, in url: URL, key: URL) throws -> (note: UUID, pages: [UUID]) {
        let vault = try vault(url, key)
        var ops: [Op] = [.setMeta(.title("Long")), .setMeta(.pageSize(.letter))]
        var order: String?
        var pages: [UUID] = []
        for _ in 0..<count {
            order = PageOrder.between(order, nil)
            let page = Page(order: order ?? "a0")
            pages.append(page.id)
            ops.append(.addPage(page))
        }
        if let recording, let blob {
            ops.append(.addRecording(Recording(id: recording.id, blob: blob, started: Date(timeIntervalSince1970: 1_800_000_000),
                                               duration: recording.duration)))
        }
        var ink = SyntheticInk(seed: 11, options: .init(pointsPerStroke: 12, rowHeight: 22, top: 60))
        let strokes = ink.strokes(count * strokesPerPage, recording: recording)
        // The rows restart on every page (a block of `strokesPerPage`), so page k holds the k-th slice of the recording.
        for (i, s) in strokes.enumerated() {
            var placed = s
            let shift = Double(i / strokesPerPage) * Double(strokesPerPage) / 38 * 22
            placed.points = s.points.map { var p = $0; p.y = InkJSON.round3(p.y - shift); return p }
            ops.append(.addStroke(page: pages[i / strokesPerPage], stroke: placed))
        }
        _ = try vault.apply(ops, to: note, deviceState: TS.deviceStateURL(), app: "fixture/1")
        return (note, pages)
    }

    // MARK: - c14

    /// c14: a note of 20 pages and 3 000 strokes linked to a one-hour recording. As playback moves
    /// through the hour, the highlighted strokes are exactly those written in the 3 s up to the
    /// position (on whichever page they are), each tick is quick, and the canvas of the page shows
    /// them as playback highlights. Tap Ink to Play on a linked stroke plays from 2 s before it.
    @Test func c14PlaybackHighlightsFollowAndTapInkPlaysFromTheInk() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let vault = try Self.vault(url, key)
        let rec = SyntheticInk.Recording(id: UUID(), duration: 3_600)
        let note = UUID()
        let blob = try vault.writeBlob(note: note, contentsOf: RecordingTests.tone, type: "audio/mp4")
        let built = try Self.longNote(note, pages: 20, strokesPerPage: 150, recording: rec, blob: blob, in: url, key: key)
        let backend = LongPlayback(length: rec.duration)
        let model = try await Self.model(url, key: key, note: built.note, playback: backend)
        defer { model.close() }
        let editor = try #require(model.editor)
        let recording = try #require(editor.recording(rec.id))
        let all = editor.pages.flatMap { p in editor.liveStrokes(of: p.id).map { (page: p.id, stroke: $0) } }
        #expect(all.count == 3_000)

        await model.play(recording, in: editor, from: 0, start: false)
        let player = try #require(editor.player)
        var worst = 0.0
        for t in stride(from: 0.0, through: 3_600, by: 7.3) {
            backend.currentTime = t
            let start = DispatchTime.now().uptimeNanoseconds
            player.update()
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            var expected: [UUID: Set<UUID>] = [:]
            for (page, s) in all {
                if let at = s.rec?.at, at <= t, at >= t - RecordingSync.highlightWindow { expected[page, default: []].insert(s.id) }
            }
            #expect(editor.playbackHighlight == expected, "at \(t) s")
        }
        print("PERF-REPORT c14 playback tick on 3000 linked strokes: worst \(String(format: "%.2f", worst)) ms")
        #expect(worst < 50)

        // The page being looked at shows the highlight boxes.
        let t = 1_800.0
        backend.currentTime = t
        player.update()
        let (page, ids) = try #require(editor.playbackHighlight.first)
        editor.showPage(id: page)
        let i = try InkInjector(editor: editor, page: page)
        defer { i.close() }
        #expect(await i.ready())
        i.show()
        #expect(i.host.highlights.filter { $0.style == .playback }.count == ids.count)

        // Tap Ink to Play on a stroke in the middle of the page.
        editor.listeningToInk = true
        i.show()
        let target = try #require(editor.liveStrokes(of: page).first { $0.rec != nil && !ids.contains($0.id) })
        let at = try #require(target.rec?.at)
        let p = try #require(target.points.first)
        // The app's rule: the earliest linked stroke under the tap (neighbors in a dense row count), 2 s before it.
        let seek = try #require(editor.seekTarget(pageID: page, x: p.x, y: p.y))
        #expect(seek.recording.id == rec.id && abs(seek.time - max(0, at - RecordingSync.leadIn)) < 10)
        let tap = try #require(i.host.inkTapHandler)
        tap(CGPoint(x: p.x, y: p.y))
        #expect(await TS.waitUntil { abs(player.position - seek.time) < 0.01 }, "plays from \(seek.time) s, at \(player.position)")
        #expect(player.recording?.id == rec.id)
        // A tap on unlinked paper does nothing.
        let before = player.position
        tap(CGPoint(x: 5, y: 5))
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.position == before)
    }

    // MARK: - c20

    /// c20: with recognition on, writing steadily (a word every 0.45 s for 6 s, each saved and
    /// recognized in the pause after it) on a vault of 300 notes saves the summary cache at most once per
    /// `summaryCacheSaveInterval`, however many recognition writes and edits reach the list.
    @Test func c20RecognitionWhileWritingSavesTheSummaryCacheRarely() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let vault = try Self.vault(url, key)
        let state = TS.deviceStateURL()
        for k in 0..<300 {
            var ink = SyntheticInk(seed: UInt64(k))
            let page = Page(order: PageOrder.between(nil, nil))
            _ = try vault.apply([.setMeta(.title("Note \(k)")), .addPage(page)]
                                + ink.strokes(10).map { .addStroke(page: page.id, stroke: $0) },
                                to: UUID(), deviceState: state, app: "fixture/1")
        }
        let cacheDir = try BrowserTests.tempDir()
        let fake = FakeRecognizer()
        let model = try await Self.model(url, key: key, note: AppModelTests.lecture, debounce: .milliseconds(150),
                                         recognizer: fake, recognitionDelay: .milliseconds(250), summaryCache: cacheDir)
        defer { model.close() }
        model.summaryCacheSaveInterval = .seconds(2)
        let editor = try #require(model.editor)
        #expect(await TS.waitUntil(timeout: .seconds(30)) { model.notes.count >= 300 })
        await model.summaryCacheSave?.value
        let i = try InkInjector(editor: editor)
        defer { i.close() }
        #expect(await i.ready())
        let saves = model.summaryCacheSaves, written = editor.deltasWritten
        let clock = ContinuousClock(), start = clock.now
        var k = 0
        // A word every 0.45 s: each pause lets the autosave (0.15 s) and recognition (0.25 s) run.
        while clock.now - start < .seconds(6) {
            i.draw([TS.stroke(x: 40 + Double(k % 12) * 45, y: 700 + Double(k / 12) * 30, n: 20)])
            k += 1
            try await Task.sleep(for: .milliseconds(450))
        }
        try await Task.sleep(for: .milliseconds(600))   // the last save and recognition
        let elapsed = (clock.now - start) / .seconds(1)
        let made = model.summaryCacheSaves - saves
        print("PERF-REPORT c20 \(k) strokes in \(String(format: "%.1f", elapsed)) s: \(editor.deltasWritten - written) deltas, "
              + "\(fake.calls.count) recognitions, \(made) summary-cache saves")
        #expect(fake.calls.count >= 4, "recognition ran while writing")
        #expect(editor.deltasWritten - written >= 8, "the ink was saved as it was written")
        #expect(Double(made) <= elapsed / 2 + 1, "\(made) saves in \(elapsed) s")
        #expect(made >= 1, "the index is still saved as the notes change")
    }

    // MARK: - c21, c42

    /// The number of pages of the PDF at `url`.
    static func pageCount(_ url: URL) throws -> Int { try #require(PDFDocument(url: url)).pageCount }

    /// c21: a note of 120 pages to PDF through each of the app's paths (the share/export sheet on the
    /// iPad and the Mac, the Mac's drag-out, Export to Folder): every page is in the file.
    @Test func c21ALongNoteToPDFHasEveryPage() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let built = try Self.longNote(pages: 120, strokesPerPage: 15, in: url, key: key)
        let model = try await Self.model(url, key: key, note: built.note)
        defer { model.close() }

        let dir = try BrowserTests.tempDir()
        let shared = try await model.exportNotes([built.note], options: ShareOptions(format: .pdf), into: dir) { _ in }
        #expect(try Self.pageCount(try #require(shared.items.first)) == 120, "share sheet")

        let dragged = try await model.exportPDF(noteID: built.note)
        #expect(try Self.pageCount(dragged) == 120, "drag out (Mac)")

        let options = BulkExportOptions(format: .pdf, layout: .flat)
        let jobs = model.bulkExportJobs(.notes([built.note]), options: options)
        let folder = try BrowserTests.tempDir()
        let session = try BulkExportSession(destination: .folder(folder), options: options, jobs: jobs)
        let result = try await model.runBulkExport(jobs, session: session) { _ in }
        #expect(result.exported.count == 1)
        let pdf = try #require(TS.regularFiles(under: folder, skipHidden: true).first { $0.hasSuffix(".pdf") })
        #expect(try Self.pageCount(folder.appendingPathComponent(pdf)) == 120, "Export to Folder")
    }

    /// Whether the PDF's first page has ink at page point `p` (rendered at 1 px per point).
    static func inked(_ url: URL, at p: CGPoint) throws -> Bool {
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: box.size, for: .mediaBox)
        let cg = try #require(image.cgImage)
        let ctx = try #require(CGContext(data: nil, width: 9, height: 9, bitsPerComponent: 8, bytesPerRow: 36,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let scale = CGFloat(cg.width) / box.width
        ctx.draw(cg, in: CGRect(x: -(p.x * scale - 4), y: -(CGFloat(cg.height) - p.y * scale - 4),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        var darkest = 255
        for i in 0..<81 { darkest = min(darkest, Int(bytes[i * 4]), Int(bytes[i * 4 + 1]), Int(bytes[i * 4 + 2])) }
        return darkest < 160
    }

    /// c42, the PDF paths: a stroke drawn 0, 0.5 and 1.4 s before a PDF export (drag-out and share
    /// sheet) is on the page (`ExportStressAppTests` counts paths in the HTML export).
    @Test(arguments: [0, 500, 1_400]) func c42AStrokeDrawnJustBeforeAPDFExportIsInIt(delayMS: Int) async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let made = try InkFixture.denseNote(strokes: 0, in: (url, key))
        let model = try await Self.model(url, key: key, note: made.note, debounce: NoteEditor.defaultDebounce)
        defer { model.close() }
        let editor = try #require(model.editor)
        let i = try InkInjector(editor: editor)
        defer { i.close() }
        #expect(await i.ready())
        let spot = CGPoint(x: 300, y: 400)
        i.draw([TS.stroke(x: Double(spot.x) - 30, y: Double(spot.y), n: 30, width: 6)])
        try await Task.sleep(for: .milliseconds(delayMS))
        let dragged = try await model.exportPDF(noteID: made.note)
        #expect(try Self.inked(dragged, at: CGPoint(x: spot.x + 5, y: spot.y)), "drag out \(delayMS) ms after the stroke")
        let shared = try await model.exportNotes([made.note], options: ShareOptions(format: .pdf), into: try BrowserTests.tempDir()) { _ in }
        #expect(try Self.inked(try #require(shared.items.first), at: CGPoint(x: spot.x + 5, y: spot.y)), "share sheet")
        #expect(try !Self.inked(dragged, at: CGPoint(x: 500, y: 700)), "blank paper elsewhere")
        #expect(editor.deltasWritten == 1)
    }

    // MARK: - c54

    /// c54: a note of 400 revisions (one per stroke, as a long session of saves leaves it) on
    /// several pages. Favorite, tag, rename, move and Save Version each decrypt every revision once
    /// (no stroke geometry) and finish within a generous bound; opening Version History reads each
    /// revision once, and a point previewed before shows again from the cache without any read.
    @Test func c54BrowserActionsAndHistoryOnANoteOfHundredsOfRevisions() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let made = try InkFixture.denseNote(strokes: 400, points: 40, perRevision: 1, in: (url, key))
        let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))])
        let counter = DecryptCounter(vault: vault)
        let names = try vault.revisionNames(of: made.note)
        #expect(names.count == 401)

        // The writer's reads, counted.
        let clock = try DeviceClock(url: TS.deviceStateURL())
        var before = counter.count
        _ = try await NoteWriter.append(to: made.note, vault: vault, clock: clock, detail: .withoutStrokePoints) {
            $0.map { NoteOps.setFavorite(true, state: $0) } ?? []
        }
        #expect(counter.count - before == names.count, "favorite: each revision once")

        // The browser's actions through the model, timed.
        let model = try await Self.model(url, key: key, note: AppModelTests.lecture)
        defer { model.close() }
        func timed(_ label: String, _ body: () async throws -> Void) async rethrows {
            let start = ContinuousClock.now
            try await body()
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            print("PERF-REPORT c54 \(label) on \(names.count) revisions: \(String(format: "%.0f", ms)) ms")
            #expect(ms < 5_000, "\(label) took \(ms) ms")
        }
        try await timed("favorite") { try await model.setFavorite(false, for: made.note) }
        try await timed("tag") { try await model.addTag("Lecture", to: made.note) }
        try await timed("rename") { try await model.renameNote(made.note, to: "Renamed") }
        try await timed("move") { try await model.moveNote(made.note, toNotebook: "Archive") }
        try await timed("save version") { _ = try await model.saveVersion(of: made.note, name: "v1") }
        let state = try vault.reconstruct(noteId: made.note)
        #expect(state.meta.title == "Renamed" && state.meta.notebook == "Archive" && !state.meta.favorite)
        #expect(state.meta.tags.contains("Lecture"))
        #expect(state.pages.first?.strokes.count == 400)

        // Version History.
        let n = try vault.revisionNames(of: made.note).count
        before = counter.count
        let data = try AppModel.readHistory(made.note, vault: vault, cloud: false, hooks: .live, thisDevice: nil)
        #expect(counter.count - before == n, "history: each revision once")
        let complete = data.points.filter(\.complete)
        #expect(complete.count >= 2)
        let a = try #require(complete.dropLast().last).name, b = try #require(complete.first).name
        let start = ContinuousClock.now
        _ = try data.state(at: a)
        _ = try data.state(at: b)
        let builds = data.previews.buildCount
        let reads = counter.count
        let shown = try data.state(at: a)   // back to a point already previewed
        #expect(data.previews.buildCount == builds, "re-shown from the cache")
        #expect(counter.count == reads)
        #expect(shown.pages.first.map { !$0.strokes.isEmpty } == true)
        print("PERF-REPORT c54 two previews: \(String(format: "%.0f", (ContinuousClock.now - start) / .milliseconds(1))) ms")
    }
}
