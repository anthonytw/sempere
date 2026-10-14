import CoreGraphics
import Foundation
import PencilKit
import Sempere
import SempereRender
import Testing
import UIKit
import Vision
@testable import SempereApp

/// A recogniser that returns fixed text, counting the strokes it was shown.
final class FakeRecognizer: PageRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[UUID]] = []
    private var seenLanguages: [String?] = []
    let gate: Gate?
    let fail: Bool

    init(gate: Gate? = nil, fail: Bool = false) { self.gate = gate; self.fail = fail }

    var calls: [[UUID]] { lock.lock(); defer { lock.unlock() }; return seen }

    /// The `language` of each call.
    var languages: [String?] { lock.lock(); defer { lock.unlock() }; return seenLanguages }

    private func record(_ ids: [UUID], _ language: String?) {
        lock.lock(); seen.append(ids); seenLanguages.append(language); lock.unlock()
    }

    func recognize(strokes: [Stroke], language: String?) async throws -> Recognition {
        record(strokes.map(\.id), language)
        await gate?.pass()
        if fail { throw CocoaError(.fileReadUnknown) }
        return Recognition(engine: "fake-1", text: "fake \(strokes.count)",
                           words: [.init(text: "fake", box: .init(x: 1, y: 2, w: 3, h: 4))])
    }
}

/// Recognition on the editor: when it runs, what it writes, what it leaves alone.
@MainActor
struct EditorRecognitionTests {
    static let lecture = AppModelTests.lecture

    static func open(_ vault: Vault, recognizer: (any PageRecognizing)?, delay: Duration = .seconds(60),
                     note: UUID = lecture) async throws -> (NoteEditor, DeviceClock) {
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let editor = try await NoteEditor.open(vault: vault, noteID: note, clock: clock, debounce: .milliseconds(50),
                                               recognizer: recognizer, recognitionDelay: delay)
        return (editor, clock)
    }

    static func page(_ vault: Vault, _ id: UUID, note: UUID = lecture) throws -> Page {
        try #require(try vault.reconstruct(noteId: note).pages.first { $0.id == id })
    }

    @Test func readsPagesWithoutRecognitionAndWritesTheBasis() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let fake = FakeRecognizer()
        let (editor, _) = try await Self.open(vault, recognizer: fake)
        await editor.recognizePending()
        // Both pages of the lecture have ink (two strokes each).
        #expect(editor.recognitionsWritten == 2)
        #expect(fake.calls.count == 2)
        let first = try #require(editor.pages.first)
        let saved = try Self.page(vault, first.id)
        #expect(saved.recognition?.text == "fake 2")
        #expect(saved.recognition?.engine == "fake-1")
        #expect(saved.recognition?.basis == RecognitionBasis.digest(of: saved))
        #expect(try vault.summary(of: Self.lecture).pagesNeedingRecognition == 0)
        #expect(try vault.summary(of: Self.lecture).pageTexts.map(\.text) == ["fake 2", "fake 2"])

        // Current recognition is skipped, however often it is asked for.
        await editor.recognizePending()
        #expect(editor.recognitionsWritten == 2)
        #expect(fake.calls.count == 2)
    }

    /// The note's handwriting language (format.md §5.4 `lang`) is what the recogniser is asked to read in.
    @Test func readsInTheNotesLanguage() async throws {
        let (vault, _) = try TS.unlockedFixture()
        _ = try vault.apply([.setMeta(.lang("es-ES"))], to: Self.lecture, deviceState: TS.deviceStateURL(), app: "test/1")
        let fake = FakeRecognizer()
        let (editor, _) = try await Self.open(vault, recognizer: fake)
        await editor.recognizePending()
        #expect(fake.languages == ["es-ES", "es-ES"])

        // Without one, the recogniser's default (nil).
        let (plain, _) = try TS.unlockedFixture()
        let other = FakeRecognizer()
        let (editor2, _) = try await Self.open(plain, recognizer: other)
        await editor2.recognizePending()
        #expect(other.languages == [nil, nil])
    }

    @Test func aNewStrokeSavesFirstThenReplacesTheRecognition() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let fake = FakeRecognizer()
        let (editor, clock) = try await Self.open(vault, recognizer: fake)
        await editor.recognizePending()
        let page = try #require(editor.pages.first)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 50, y: 400)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await editor.recognizePending()
        #expect(editor.recognitionsWritten == 3)
        #expect(fake.calls.last?.count == 3)
        let saved = try Self.page(vault, page.id)
        #expect(saved.strokes.count == 3)
        #expect(saved.recognition?.text == "fake 3")
        #expect(saved.recognition?.basis == RecognitionBasis.digest(of: saved))
        // The strokes were written before the text that describes them.
        let mine = try vault.loadNote(Self.lecture).revisions.filter { $0.device == clock.device }.sorted { $0.seq < $1.seq }
        let kinds: [String] = mine.map {
            guard case .delta(let ops) = $0.body, let op = ops.first else { return "?" }
            if case .setPageRecognition = op { return "recognition" }
            if case .addStroke = op { return "stroke" }
            return "other"
        }
        // One delta per pass: both pages on open, then the edited page.
        #expect(kinds == ["recognition", "stroke", "recognition"])
    }

    @Test func importedRecognitionStaysUntilTheStrokesChange() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let pageID = try #require(try vault.reconstruct(noteId: Self.lecture).pages.first?.id)
        let imported = Recognition(engine: "notability-14.2.6", text: "Lecture three",
                                   words: [.init(text: "Lecture", box: .init(x: 5, y: 6, w: 70, h: 20))])
        try vault.apply([.setPageRecognition(pageId: pageID, recognition: imported)], to: Self.lecture,
                        deviceState: TS.deviceStateURL(), app: "test")
        let fake = FakeRecognizer()
        let (editor, _) = try await Self.open(vault, recognizer: fake)
        await editor.recognizePending()
        #expect(fake.calls.count == 1, "only the second page is read; imported text is not read again")
        #expect(editor.recognitionsWritten == 1)
        #expect(try Self.page(vault, pageID).recognition == imported)

        // Viewing the page (a ledger round trip) changes nothing either.
        var drawing = editor.drawing(for: pageID)
        editor.drawingDidChange(pageID: pageID, drawing: drawing, tool: nil)
        await editor.recognizePending()
        #expect(fake.calls.count == 1)
        #expect(try Self.page(vault, pageID).recognition == imported)

        // Drawing on the page replaces it.
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 80, y: 300)))
        editor.drawingDidChange(pageID: pageID, drawing: drawing, tool: nil)
        await editor.recognizePending()
        #expect(fake.calls.count == 2)
        let replaced = try Self.page(vault, pageID).recognition
        #expect(replaced?.engine == "fake-1")
        #expect(replaced?.basis != nil)
    }

    @Test func erasingEverythingClearsTheText() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await Self.open(vault, recognizer: FakeRecognizer())
        await editor.recognizePending()
        let page = try #require(editor.pages.first)
        editor.drawingDidChange(pageID: page.id, drawing: PKDrawing(), tool: nil)
        await editor.recognizePending()
        #expect(try Self.page(vault, page.id).strokes.isEmpty)
        #expect(try Self.page(vault, page.id).recognition == nil)
    }

    @Test func runsAfterTheDelayOnceForABurstOfChanges() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let fake = FakeRecognizer()
        let (editor, _) = try await Self.open(vault, recognizer: fake, delay: .milliseconds(300))
        #expect(await TS.waitUntil { editor.recognitionsWritten == 2 })   // the catch-up on open, both pages
        let page = try #require(editor.pages.first)
        var drawing = editor.drawing(for: page.id)
        for i in 0..<4 {
            drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 50 + 40 * Double(i), y: 420)))
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(editor.recognitionsWritten == 2, "not while the pen is still moving")
        #expect(await TS.waitUntil { editor.recognitionsWritten == 3 })
        try await Task.sleep(for: .milliseconds(700))
        #expect(editor.recognitionsWritten == 3)
        #expect(fake.calls.count == 3)
        #expect(fake.calls.last?.count == 6)
    }

    @Test func aResultForOldStrokesIsDropped() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let gate = Gate()
        await gate.close()
        let fake = FakeRecognizer(gate: gate)
        let (editor, _) = try await Self.open(vault, recognizer: fake)
        let page = try #require(editor.pages.first)
        let running = Task { await editor.recognizePending() }
        defer { running.cancel() }
        await gate.waitForArrivals(1)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 50, y: 500)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await gate.open()
        await running.value
        // The first page's result was for strokes that are gone; the second page's stands.
        #expect(editor.recognitionsWritten == 1)
        #expect(fake.calls.count == 2)
        #expect(try Self.page(vault, page.id).recognition == nil)
        await editor.recognizePending()
        #expect(editor.recognitionsWritten == 2)
        #expect(fake.calls.count == 3)
        let saved = try Self.page(vault, page.id)
        #expect(saved.recognition?.basis == RecognitionBasis.digest(of: saved))
        #expect(saved.recognition?.text == "fake 3")
    }

    @Test func aPassWritesOneDeltaForAllItsPages() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let before = try vault.revisionNames(of: Self.lecture).count
        let (editor, _) = try await Self.open(vault, recognizer: FakeRecognizer())
        await editor.recognizePending()
        #expect(editor.recognitionsWritten == 2)
        // One revision for the pass, not one per page.
        #expect(try vault.revisionNames(of: Self.lecture).count == before + 1)
        let newest = try #require(try vault.loadNote(Self.lecture).revisions.max { $0.name < $1.name })
        guard case .delta(let ops) = newest.body else { Issue.record("not a delta"); return }
        let pages = ops.compactMap { op -> UUID? in
            if case .setPageRecognition(let id, _) = op { return id } else { return nil }
        }
        #expect(ops.count == 2)
        #expect(Set(pages) == Set(editor.pages.map(\.id)))
    }

    @Test func switchingRecognitionOffMidPassStopsItWritingNothing() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let gate = Gate()
        await gate.close()
        let fake = FakeRecognizer(gate: gate)
        let (editor, _) = try await Self.open(vault, recognizer: fake)
        let before = try vault.revisionNames(of: Self.lecture).count
        let running = Task { await editor.recognizePending() }
        await gate.waitForArrivals(1)
        editor.recognizer = nil
        await gate.open()
        await running.value
        #expect(fake.calls.count == 1, "the second page is not read")
        #expect(editor.recognitionsWritten == 0)
        #expect(try vault.revisionNames(of: Self.lecture).count == before)
    }

    @Test func closingTheEditorMidPassStopsItWritingNothing() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let gate = Gate()
        await gate.close()
        let fake = FakeRecognizer(gate: gate)
        let (editor, _) = try await Self.open(vault, recognizer: fake)
        let before = try vault.revisionNames(of: Self.lecture).count
        let running = Task { await editor.recognizePending() }
        await gate.waitForArrivals(1)
        await editor.close()
        await gate.open()
        await running.value
        #expect(fake.calls.count == 1)
        #expect(editor.recognitionsWritten == 0)
        #expect(try vault.revisionNames(of: Self.lecture).count == before)
    }

    @Test func aFailingRecogniserWritesNothingAndReportsIt() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await Self.open(vault, recognizer: FakeRecognizer(fail: true))
        await editor.recognizePending()
        #expect(editor.recognitionsWritten == 0)
        #expect(editor.recognitionError != nil)
        #expect(try vault.summary(of: Self.lecture).pagesNeedingRecognition == 2)
    }

    @Test func readOnlyAndSwitchedOffEditorsDoNotRecognise() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let fake = FakeRecognizer()
        let (deleted, _) = try await Self.open(vault, recognizer: fake, note: AppModelTests.deleted)
        #expect(deleted.isReadOnly)
        await deleted.recognizePending()
        #expect(fake.calls.isEmpty)
        let (off, _) = try await Self.open(vault, recognizer: nil)
        await off.recognizePending()
        #expect(off.recognitionsWritten == 0)
        #expect(try vault.summary(of: Self.lecture).recognizedPages == 0)
        off.recognizer = fake    // turning it on reads the open note
        await off.recognizePending()
        #expect(off.recognitionsWritten == 2)
    }
}

/// Whether Vision's text recogniser can run here. It cannot on the CI Mac (a VM without a
/// Neural Engine, whose TextRecognition model bundles are empty: "No available backends …
/// for compute units ane", "Underlying detector load error"), so the Mac Catalyst run there
/// fails every request with `VNError.unknownError`. The simulator and a real Mac read text.
enum VisionAvailability {
    static let textRecognition: Bool = {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return true }
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = ctx.makeImage() else { return false }
        return (try? VisionText.lines(VNImageRequestHandler(cgImage: image, options: [:]),
                                      region: Recognition.Box(x: 0, y: 0, w: 64, h: 64))) != nil
    }()
}

/// The Vision recogniser itself, on the simulator's Vision (and a Mac's, where it can load).
@MainActor
struct VisionRecognitionTests {
    /// Printed text on white: what Vision reads most reliably.
    static func printed(_ text: String, size: CGSize = CGSize(width: 640, height: 160)) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(at: CGPoint(x: 24, y: 40),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }.cgImage!
    }

    @Test(.enabled(if: VisionAvailability.textRecognition, "Vision cannot load its text recogniser on this Mac"))
    func readsTextAndPlacesWordsInPageCoordinates() throws {
        let region = Recognition.Box(x: 100, y: 300, w: 640, h: 160)
        let lines = try VisionText.lines(VNImageRequestHandler(cgImage: Self.printed("Hello world"), options: [:]), region: region)
        let recognition = RecognitionLayout.assemble(engine: "t", lines: lines, basis: nil)
        #expect(recognition.text.lowercased().contains("hello"))
        #expect(recognition.text.lowercased().contains("world"))
        let words = recognition.words
        #expect(!words.isEmpty)
        for w in words {
            #expect(w.box.x >= region.x - 1 && w.box.x + w.box.w <= region.x + region.w + 1)
            #expect(w.box.y >= region.y - 1 && w.box.y + w.box.h <= region.y + region.h + 1)
        }
        let hello = try #require(words.first { $0.text.lowercased().contains("hello") })
        let world = try #require(words.first { $0.text.lowercased().contains("world") })
        #expect(hello.box.x < world.box.x)
    }

    @Test(.enabled(if: VisionAvailability.textRecognition, "Vision cannot load its text recogniser on this Mac"))
    func strokesBecomeAnImageAndANormalRecognition() throws {
        // A block "H" and "I": whether Vision reads them is not the point, the pipeline is.
        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Stroke {
            let pts = (0...12).map { i -> StrokePoint in
                let t = Double(i) / 12
                return StrokePoint(x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t, t: t * 0.1, w: 6, h: 6, o: 1, f: 0.5, az: 0, al: 1.5)
            }
            return Stroke(ink: Ink(tool: .pen, color: Sempere.Color(r: 200, g: 30, b: 30, a: 255), width: 6), points: pts)
        }
        let strokes = [line(100, 100, 100, 220), line(180, 100, 180, 220), line(100, 160, 180, 160), line(240, 100, 240, 220)]
        let r = try VisionPageRecognizer.recognizeNow(strokes)
        #expect(r.engine.hasPrefix("vision-"))
        #expect(r.basis == nil)
        for w in r.words {
            #expect(w.box.x >= 100 - RecognitionImage.margin - 1 && w.box.x + w.box.w <= 240 + RecognitionImage.margin + 8)
            #expect(w.box.y >= 100 - RecognitionImage.margin - 1 && w.box.y + w.box.h <= 220 + RecognitionImage.margin + 8)
        }
    }

    @Test func blankAndMarkerOnlyPagesAreEmptyRecognitions() throws {
        #expect(try VisionPageRecognizer.recognizeNow([]).text.isEmpty)
        let marker = Stroke(ink: Ink(tool: .marker, color: .black, width: 10),
                            points: (0..<5).map { StrokePoint(x: 10 + Double($0) * 20, y: 50, w: 10, h: 10) })
        #expect(try VisionPageRecognizer.recognizeNow([marker]).text.isEmpty)
    }

    @Test func theRenderedImageIsBlackInkOnWhiteInAnyAppearance() throws {
        let stroke = Stroke(ink: Ink(tool: .pen, color: Sempere.Color(r: 255, g: 255, b: 0, a: 255), width: 6),
                            points: (0...10).map { StrokePoint(x: 20 + Double($0) * 8, y: 40, w: 8, h: 8, o: 1, f: 0.5, al: 1.5) })
        var black = stroke
        black.ink.color = .black
        let drawing = PKDrawing(strokes: [StrokeConversion.pkStroke(black)])
        let region = drawing.bounds.insetBy(dx: -24, dy: -24)
        let image = try #require(VisionPageRecognizer.render(drawing, region: region, scale: 1))
        #expect(abs(image.width - Int(region.width.rounded())) <= 1 && abs(image.height - Int(region.height.rounded())) <= 1)
        // Read the pixels back in a known layout: the renderer's own may be wide-colour or float.
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(drew)
        let dark = stride(from: 0, to: bytes.count - 3, by: 4).filter { bytes[$0] < 80 && bytes[$0 + 1] < 80 }.count
        let white = stride(from: 0, to: bytes.count - 3, by: 4).filter { bytes[$0] > 240 && bytes[$0 + 1] > 240 }.count
        #expect(dark > 20)
        #expect(white > w * h / 2)
    }
}
