import Foundation
import XCTest

@testable import Sempere

/// `NoteOps` builders for attachments (placement, PDF pages, recordings, transcripts):
/// what `sempere attach` and the app's add flows call.
final class AttachmentOpsTests: XCTestCase {
    let blob = BlobRef(sha256: String(repeating: "ab", count: 32), size: 10, type: "image/jpeg")
    let pdfBlob = BlobRef(sha256: String(repeating: "cd", count: 32), size: 10, type: "application/pdf")
    let letter = PageSize.letter

    func page(items: [Item] = []) -> Page {
        var p = Page(id: UUID(), order: "a0")
        p.items = items
        return p
    }

    // MARK: z order and fitting

    func testTopZIsAboveEveryItemOfTheLayerOnly() {
        let frame = Rect(x: 0, y: 0, w: 10, h: 10)
        let a = Item.image(blob: blob, pixelSize: Size(w: 1, h: 1), frame: frame, z: "a0")
        let b = Item.image(blob: blob, pixelSize: Size(w: 1, h: 1), frame: frame, z: "b5")
        let bg = Item.pdfPage(blob: pdfBlob, pageIndex: 0, pageSize: Size(w: 1, h: 1), frame: frame, z: "zz")
        let p = page(items: [a, b, bg])
        let z = NoteOps.topZ(of: p, layer: .content)
        XCTAssertTrue(z.utf8.lexicographicallyPrecedes("zz".utf8) == false || z > "b5")
        XCTAssertGreaterThan(z, "b5")
        XCTAssertGreaterThan(NoteOps.topZ(of: p, layer: .background), "zz")
        XCTAssertGreaterThan(NoteOps.topZ(of: p, layer: .content, extra: ["c9"]), "c9")
        XCTAssertFalse(NoteOps.topZ(of: page(), layer: .content).isEmpty)
    }

    func testFitScalesUniformlyAndNeverEnlargesByDefault() {
        XCTAssertEqual(NoteOps.fit(Size(w: 1000, h: 500), into: Size(w: 500, h: 500)), Size(w: 500, h: 250))
        XCTAssertEqual(NoteOps.fit(Size(w: 100, h: 50), into: Size(w: 500, h: 500)), Size(w: 100, h: 50))
        XCTAssertEqual(NoteOps.fit(Size(w: 100, h: 50), into: Size(w: 500, h: 500), upscale: true), Size(w: 500, h: 250))
        // Degenerate input is returned unchanged, never divided by.
        XCTAssertEqual(NoteOps.fit(Size(w: 0, h: 5), into: Size(w: 10, h: 10)), Size(w: 0, h: 5))
        XCTAssertEqual(NoteOps.fit(Size(w: 5, h: 5), into: Size(w: .nan, h: 10)), Size(w: 5, h: 5))
    }

    // MARK: images

    func testImageDefaultsFitInsideMarginsCentred() throws {
        let p = page()
        let placed = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 3024, h: 4032), on: p, pageSize: letter)
        let f = placed.item.frame
        // 540 × 720 box, aspect 3:4 → 540 × 720 fits exactly by width.
        XCTAssertEqual(f.w, 540, accuracy: 0.001)
        XCTAssertEqual(f.h, 720, accuracy: 0.001)
        XCTAssertEqual(f.x, 36, accuracy: 0.001)
        XCTAssertEqual(f.y, 36, accuracy: 0.001)
        XCTAssertEqual(placed.item.layer, .content)
        XCTAssertNil(placed.item.orientation)
        XCTAssertEqual(placed.ops, [.addItem(page: p.id, item: placed.item)])

        // A small image keeps one pixel per point and is centred across the page.
        let small = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 100, h: 50), on: p, pageSize: letter).item.frame
        XCTAssertEqual(small, Rect(x: 256, y: 36, w: 100, h: 50))
    }

    func testImageWidthAtCropAndOrientation() throws {
        let p = page()
        let item = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 400, h: 200), orientation: 6,
                                          crop: Rect(x: 0, y: 0, w: 200, h: 200), on: p, pageSize: letter,
                                          at: (10, 20), width: 100, rotation: 30).item
        XCTAssertEqual(item.frame, Rect(x: 10, y: 20, w: 100, h: 100))   // the crop's aspect, not the image's
        XCTAssertEqual(item.orientation, 6)
        XCTAssertEqual(item.rotation, 30)
        XCTAssertEqual(item.crop, Rect(x: 0, y: 0, w: 200, h: 200))
        // Orientation 1 and rotation 0 are the absent defaults.
        let plain = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 4, h: 4), orientation: 1, on: p, pageSize: letter, rotation: 0).item
        XCTAssertNil(plain.orientation); XCTAssertNil(plain.rotation)
    }

    func testImageStacksOnTopOfEarlierItems() throws {
        var p = page()
        let first = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 10, h: 10), on: p, pageSize: letter).item
        p.items = [first]
        let second = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 10, h: 10), on: p, pageSize: letter).item
        XCTAssertTrue(Item.drawsBefore(first, second))
    }

    func testBadFramesAreRefused() {
        let p = page()
        func place(_ frame: Rect?, width: Double? = nil) throws {
            _ = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 10, h: 10), on: p, pageSize: letter, frame: frame, width: width)
        }
        XCTAssertThrowsError(try place(Rect(x: 0, y: 0, w: 0, h: 5)))
        XCTAssertThrowsError(try place(Rect(x: 0, y: 0, w: -1, h: 5)))
        XCTAssertThrowsError(try place(Rect(x: .nan, y: 0, w: 5, h: 5)))
        XCTAssertThrowsError(try place(Rect(x: 0, y: 0, w: 1e9, h: 5)))
        XCTAssertThrowsError(try place(nil, width: -4))
        XCTAssertThrowsError(try place(nil, width: .infinity))
        XCTAssertThrowsError(try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 0, h: 10), on: p, pageSize: letter))
        XCTAssertThrowsError(try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 10, h: 10), crop: Rect(x: 0, y: 0, w: 0, h: 1),
                                                    on: p, pageSize: letter))
    }

    func testAPageHoldsAtMost10000Items() throws {
        let frame = Rect(x: 0, y: 0, w: 1, h: 1)
        let full = page(items: (0..<NoteOps.Limits.itemsPerPage).map {
            Item.image(blob: blob, pixelSize: Size(w: 1, h: 1), frame: frame, z: String(format: "z%05d", $0))
        })
        XCTAssertThrowsError(try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 1, h: 1), on: full, pageSize: letter)) {
            XCTAssertEqual($0 as? AttachmentOpsError, .pageFull)
        }
    }

    // MARK: text

    func testTextIsNormalisedAndSizedByItsLines() throws {
        let p = page()
        let placed = try NoteOps.placeText("Cafe\u{301}\r\nline two\rthree", style: TextStyle(size: 10, bold: true), on: p, pageSize: letter)
        XCTAssertEqual(placed.item.text?.string, "Café\nline two\nthree")
        XCTAssertEqual(placed.item.text?.runs.count, 1)
        XCTAssertEqual(placed.item.text?.runs.first?.b, true)
        XCTAssertEqual(placed.item.frame, Rect(x: 36, y: 36, w: 540, h: 36))   // 3 lines × 1.2 × 10
        XCTAssertNil(placed.item.text?.breaks)
        let empty = try NoteOps.text("")
        XCTAssertEqual(empty.runs, [])
    }

    func testTextLimitsAndControlCharacters() {
        XCTAssertThrowsError(try NoteOps.text("a\u{7}b"))
        XCTAssertThrowsError(try NoteOps.text(String(repeating: "x", count: TextContent.Limits.utf8Bytes + 1)))
        XCTAssertThrowsError(try NoteOps.text("x", style: TextStyle(size: 0)))
        XCTAssertThrowsError(try NoteOps.text("x", style: TextStyle(size: 5000)))
        XCTAssertNoThrow(try NoteOps.text(String(repeating: "x", count: TextContent.Limits.utf8Bytes)))
        XCTAssertNoThrow(try NoteOps.text("tab\tand\nnewline"))
    }

    // MARK: PDF pages

    func testBackgroundFillsThePageFittedAndCentred() throws {
        let p = page()
        // The same size fills exactly; another aspect is fitted (up or down) and centred.
        let same = try NoteOps.placePDFPage(blob: pdfBlob, PDFPageRef(index: 3, size: Size(w: 612, h: 792)), on: p, pageSize: letter).item
        XCTAssertEqual(same.frame, Rect(x: 0, y: 0, w: 612, h: 792))
        XCTAssertEqual(same.layer, .background)
        XCTAssertEqual(same.pageIndex, 3)
        let wide = try NoteOps.placePDFPage(blob: pdfBlob, PDFPageRef(index: 0, size: Size(w: 800, h: 400)), on: p, pageSize: letter).item
        XCTAssertEqual(wide.frame.w, 612, accuracy: 0.001)
        XCTAssertEqual(wide.frame.h, 306, accuracy: 0.001)
        XCTAssertEqual(wide.frame.y, 243, accuracy: 0.001)
        let small = try NoteOps.placePDFPage(blob: pdfBlob, PDFPageRef(index: 0, size: Size(w: 306, h: 396)), on: p, pageSize: letter).item
        XCTAssertEqual(small.frame, Rect(x: 0, y: 0, w: 612, h: 792))   // enlarged to fill
    }

    func testFigureIsFittedInsideMarginsOrWhereAsked() throws {
        let p = page()
        let figure = try NoteOps.placePDFPage(blob: pdfBlob, PDFPageRef(index: 1, size: Size(w: 360, h: 500)), crop: Rect(x: 0, y: 0, w: 180, h: 250),
                                              on: p, pageSize: letter, layer: .content).item
        XCTAssertEqual(figure.layer, .content)
        XCTAssertEqual(figure.frame, Rect(x: 216, y: 36, w: 180, h: 250))
        let sized = try NoteOps.placePDFPage(blob: pdfBlob, PDFPageRef(index: 0, size: Size(w: 360, h: 500)), on: p, pageSize: letter,
                                             at: (10, 10), width: 100, layer: .content).item
        XCTAssertEqual(sized.frame, Rect(x: 10, y: 10, w: 100, h: 138.889))
    }

    func testInsertPDFPagesAddsOnePagePerPDFPageInOrder() throws {
        let first = Page(id: UUID(), order: "a0"), second = Page(id: UUID(), order: "a1")
        let refs = [PDFPageRef(index: 0, size: Size(w: 612, h: 792)), PDFPageRef(index: 2, size: Size(w: 612, h: 792)),
                    PDFPageRef(index: 5, size: Size(w: 612, h: 792))]
        let edit = try NoteOps.insertPDFPages(blob: pdfBlob, refs, after: 1, in: [first, second], pageSize: letter)
        XCTAssertEqual(edit.pages.count, 5)
        XCTAssertEqual(edit.pages[0].id, first.id); XCTAssertEqual(edit.pages[4].id, second.id)
        XCTAssertEqual(edit.pages[1...3].map { $0.items.first?.pageIndex }, [0, 2, 5])
        XCTAssertEqual(edit.ops.filter { if case .addPage = $0 { return true } else { return false } }.count, 3)
        XCTAssertEqual(edit.ops.filter { if case .addItem = $0 { return true } else { return false } }.count, 3)
        // The ops, replayed on a reducer, give the same pages in the same order.
        let state = try NoteReducer.reconstruct([Revision(noteId: UUID(), device: devA, seq: 1, hlc: HLC(millis: baseMillis, counter: 0)!, wall: wallAt(0), app: "t",
                                                          body: .delta(ops: [.addPage(first), .addPage(second)] + edit.ops))])
        XCTAssertEqual(state.pages.map(\.id), edit.pages.map(\.id))
        XCTAssertEqual(state.pages.map { $0.items.first?.pageIndex }, [nil, 0, 2, 5, nil])
        // Before the first page, and past the end (clamped).
        XCTAssertEqual(try NoteOps.insertPDFPages(blob: pdfBlob, [refs[0]], after: 0, in: [first], pageSize: letter).pages.first?.items.count, 1)
        XCTAssertEqual(try NoteOps.insertPDFPages(blob: pdfBlob, [refs[0]], after: 99, in: [first], pageSize: letter).pages.last?.items.count, 1)
    }

    func testInsertPDFPagesRefusals() {
        let p = page()
        let ref = PDFPageRef(index: 0, size: Size(w: 10, h: 10))
        XCTAssertThrowsError(try NoteOps.insertPDFPages(blob: pdfBlob, [], after: 0, in: [p], pageSize: letter)) {
            XCTAssertEqual($0 as? AttachmentOpsError, .nothingToAdd)
        }
        XCTAssertThrowsError(try NoteOps.insertPDFPages(blob: pdfBlob, [ref], after: 0, in: [p], pageSize: PageSize(width: 612, height: 792, infinite: true))) {
            XCTAssertEqual($0 as? AttachmentOpsError, .pagelessNote)
        }
        XCTAssertThrowsError(try NoteOps.insertPDFPages(blob: pdfBlob, Array(repeating: ref, count: NoteOps.Limits.pdfPages + 1),
                                                        after: 0, in: [p], pageSize: letter))
    }

    func testNewPDFNoteTakesTheFirstPagesSizeAndBlankPaper() throws {
        let refs = [PDFPageRef(index: 0, size: Size(w: 360, h: 500)), PDFPageRef(index: 1, size: Size(w: 720, h: 500))]
        let ops = try NoteOps.newPDFNote(title: "Slides", blob: pdfBlob, refs, notebook: "School/Math", tags: ["pdf"])
        let state = try NoteReducer.reconstruct([Revision(noteId: UUID(), device: devA, seq: 1, hlc: HLC(millis: baseMillis, counter: 0)!, wall: wallAt(0), app: "t",
                                                          body: .delta(ops: ops))])
        XCTAssertEqual(state.meta.title, "Slides")
        XCTAssertEqual(state.meta.pageSize, PageSize(width: 360, height: 500))
        XCTAssertEqual(state.meta.paper.kind, .blank)
        XCTAssertEqual(state.meta.notebook, "School/Math")
        XCTAssertEqual(state.meta.tags, ["pdf"])
        XCTAssertEqual(state.pages.count, 2)
        XCTAssertEqual(state.pages[0].items.first?.frame, Rect(x: 0, y: 0, w: 360, h: 500))
        // The wide page is fitted into 360 × 500 and centred.
        let wide = try XCTUnwrap(state.pages[1].items.first)
        XCTAssertEqual(wide.frame.w, 360, accuracy: 0.001)
        XCTAssertEqual(wide.frame.h, 250, accuracy: 0.001)
        XCTAssertEqual(wide.frame.y, 125, accuracy: 0.001)
        XCTAssertEqual(state.pages.compactMap { $0.items.first?.pageIndex }, [0, 1])
        XCTAssertEqual(state.pages.compactMap { $0.items.first?.layer }, [.background, .background])
        XCTAssertThrowsError(try NoteOps.newPDFNote(title: "x", blob: pdfBlob, []))
    }

    // MARK: recordings and transcripts

    func testRecordingTakesItsInformationalFieldsFromTheProbe() {
        let ref = BlobRef(sha256: String(repeating: "ef", count: 32), size: 9, type: "audio/mp4")
        let r = NoteOps.recording(blob: ref, started: Date(timeIntervalSince1970: 1_760_000_000),
                                  info: AudioInfo(duration: 12.5, codec: "aac", sampleRate: 48000, channels: 1, bitRate: 64000), title: "Lecture")
        XCTAssertEqual(r.duration, 12.5); XCTAssertEqual(r.codec, "aac"); XCTAssertEqual(r.sampleRate, 48000)
        XCTAssertEqual(r.channels, 1); XCTAssertEqual(r.bitRate, 64000); XCTAssertEqual(r.title, "Lecture")
        XCTAssertNil(NoteOps.recording(blob: ref, started: Date(), title: "").title)
        XCTAssertThrowsError(try NoteOps.addRecording(r, to: Array(repeating: r, count: NoteOps.Limits.recordingsPerNote))) {
            XCTAssertEqual($0 as? AttachmentOpsError, .tooManyRecordings)
        }
        XCTAssertEqual(try NoteOps.addRecording(r, to: []), [.addRecording(r)])
    }

    func testSetTranscriptChecksTheRecordingAndTheContent() throws {
        let ref = BlobRef(sha256: String(repeating: "ef", count: 32), size: 9, type: "audio/mp4")
        let rec = NoteOps.recording(blob: ref, started: Date(), title: "T")
        var state = NoteState(meta: NoteMeta(created: Date()))
        state.recordings = [rec]
        let transcript = Transcript(recording: rec.id, engine: "t", language: "en", created: Date(),
                                    segments: [.init(start: 0, end: 1, text: "hello")])
        let content = try transcript.encoded()
        let tRef = BlobRef(content: content, type: BlobRef.transcriptType)
        XCTAssertEqual(try NoteOps.setTranscript(tRef, content: content, for: rec.id, in: state),
                       [.setRecording(recordingId: rec.id, change: .transcript(tRef))])
        // Another recording's id, an unknown recording, and broken content.
        var other = transcript; other.recording = UUID()
        XCTAssertThrowsError(try NoteOps.setTranscript(tRef, content: try other.encoded(), for: rec.id, in: state))
        XCTAssertThrowsError(try NoteOps.setTranscript(tRef, content: content, for: UUID(), in: state)) {
            guard case .noSuchRecording? = $0 as? AttachmentOpsError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try NoteOps.setTranscript(tRef, content: Data("{}".utf8), for: rec.id, in: state))
        var overlapping = transcript
        overlapping.segments = [.init(start: 0, end: 2, text: "a"), .init(start: 1, end: 3, text: "b")]
        XCTAssertThrowsError(try NoteOps.setTranscript(tRef, content: try overlapping.encoded(), for: rec.id, in: state))
    }
}
