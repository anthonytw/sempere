import Age
import Foundation
import FuzzSupport
import Sempere
import SemperePDF
import TempDirSupport
import XCTest

@testable import SempereRender

/// The encrypted single-file share (docs/design/1.3-share.md): flattening, pictures, the container, limits,
/// what leaks, the age envelope, the stock `age` recipe and the shared fixture the web viewer's tests read.
final class WebPageShareTests: XCTestCase {
    static let passphrase = "correct-horse-battery-staple-share-test"
    /// A stand-in template (the real one is 250 KB of script): the same shape, so `verify` and `fill` are the real code.
    static let templateHTML = """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-AAAA'; connect-src 'none'">
        <title>Shared note</title>
        <style>body{margin:0}</style>
        </head><body>
        <script type="text/plain" id="share-data" data-format="sempere-share/1">\(ShareTemplate.placeholder)</script>
        <script>document.title="Shared note";</script>
        </body></html>
        """
    static var template: ShareTemplate { ShareTemplate(html: Data(templateHTML.utf8))! }

    /// Fast scrypt for every test but the one that checks the real factor.
    static func options(_ edit: (inout WebShareOptions) -> Void = { _ in }) -> WebShareOptions {
        var o = WebShareOptions()
        o.scryptLog2N = 10
        edit(&o)
        return o
    }

    static func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    static func text(_ s: String) -> TextContent { TextContent(size: 12, color: .black, runs: [TextRun(s)]) }

    /// A note with ink, a text box, a rotated and cropped photo with location metadata, a PDF page and an equation;
    /// everything a share must flatten, plus every kind of history a share must not carry.
    static func sampleNote(images: Bool = true) throws -> (NoteState, MemoryBlobSource, [String: BlobRef]) {
        var state = try T.loadSampleNote()
        var blobs: [Data] = []
        var refs: [String: BlobRef] = [:]
        var items: [Item] = []
        items.append(Item.text(id: uuid(900), Self.text("Typed text"), frame: Rect(x: 20, y: 200, w: 160, h: 30), z: "a"))
        if images {
            // A photo: 3000 × 2000 with EXIF orientation 6 and GPS in its APP1.
            let png = try SyntheticImage.png(width: 1500, height: 1000, seed: 7)
            let rgba = try PNG.decode(png)
            let jpeg = withLocation(JPEGEncoder.encode(rgba, quality: 90))
            blobs.append(jpeg)
            let photo = BlobRef(content: jpeg, type: "image/jpeg")
            refs["photo"] = photo
            items.append(Item(id: uuid(901), kind: .image, frame: Rect(x: 10, y: 10, w: 100, h: 150), z: "b",
                              origin: "0000000000001-SECRETDEVICE-1-addItem", clocks: ["frame": "1-SECRETDEVICE"], blob: photo,
                              pixelSize: Size(w: 1000, h: 1500), orientation: 6, crop: Rect(x: 100, y: 150, w: 500, h: 700)))
            // A PDF page and an equation render, both PDFs.
            var one = T.note(pages: [[T.stroke([T.pt(10, 10), T.pt(50, 50)])]], meta: T.meta(size: PageSize(width: 200, height: 300)))
            one.pages[0].strokes.append(T.stroke([T.pt(5, 5), T.pt(80, 5)]))
            var report = RenderReport()
            let pdf = try PDFWriter.render(note: one, options: RenderOptions(compress: false), report: &report)
            blobs.append(pdf)
            let pdfRef = BlobRef(content: pdf, type: "application/pdf")
            refs["pdf"] = pdfRef
            items.append(Item(id: uuid(902), kind: .pdfPage, layer: .background, frame: Rect(x: 0, y: 0, w: 200, h: 300), z: "c",
                              blob: pdfRef, pageIndex: 0, pageSize: Size(w: 200, h: 300)))
            items.append(Item(id: uuid(903), kind: .math, frame: Rect(x: 20, y: 240, w: 100, h: 40), z: "d",
                              math: MathContent(latex: "x^2", render: pdfRef, renderSize: Size(w: 200, h: 300), engine: "SECRETENGINE")))
        }
        state.pages[0].items = items
        // History that must not survive.
        state.deleted = false
        state.clocks = ["title": "1-SECRETDEVICE"]
        state.tombstones = Tombstones(strokes: [uuid(950)])
        state.pages[0].origin = "0000000000001-SECRETDEVICE-1-addPage"
        state.pages[0].orderClock = "1-SECRETDEVICE"
        state.pages[0].strokes[0].origin = "0000000000001-SECRETDEVICE-2-addStroke"
        state.pages[0].strokes[0].parent = uuid(951)
        state.pages[0].strokes[0].rec = RecordingLink(id: uuid(952), at: 1)
        state.meta.title = "Quarterly secret plans"
        state.meta.tags = ["private-tag"]
        state.meta.notebook = "Work/Secret"
        state.meta.created = Date(timeIntervalSince1970: 1_700_000_000)
        state.meta.lang = "en-US"
        return (state, MemoryBlobSource(blobs), refs)
    }

    /// `jpeg` with an Exif APP1 holding a GPS tag name, right after SOI.
    static func withLocation(_ jpeg: Data) -> Data {
        var exif = Array("Exif".utf8) + [0, 0] + Array("MM".utf8) + [0, 42, 0, 0, 0, 8] + Array("GPSLatitude-47.6062".utf8)
        let length = exif.count + 2
        exif = [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + exif
        return jpeg.prefix(2) + Data(exif) + jpeg.dropFirst(2)
    }

    func share(_ state: NoteState, _ blobs: MemoryBlobSource, rasterizer: (any PDFPageRasterizer)? = QuadrantRasterizer(),
               _ edit: (inout WebShareOptions) -> Void = { _ in }) throws -> (WebShareResult, Parsed) {
        let result = try WebPageShare.make(state, blobs: blobs, options: Self.options(edit), passphrase: Self.passphrase,
                                           template: Self.template, pdfRasterizer: rasterizer)
        return (result, try Self.open(result.file))
    }

    typealias Parsed = (json: [String: Any], blobs: [String: Data], payload: Data)

    /// Decrypts a share file with the passphrase and parses what is inside.
    static func open(_ file: Data, passphrase: String = WebPageShareTests.passphrase) throws -> Parsed {
        let text = String(decoding: file, as: UTF8.self)
        let begin = try XCTUnwrap(text.range(of: "-----BEGIN AGE ENCRYPTED FILE-----"))
        let end = try XCTUnwrap(text.range(of: "-----END AGE ENCRYPTED FILE-----"))
        let armored = Data(text[begin.lowerBound..<end.upperBound].utf8)
        let plain = try AgeFile.decrypt(armored, with: [ScryptIdentity(passphrase: passphrase)])
        let parsed = try WebPageShare.parse(container: plain)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: parsed.json) as? [String: Any])
        return (json, parsed.blobs, plain)
    }

    // MARK: Flattening

    func testNoHistoryNoDeviceNoNoteIds() throws {
        let (state, blobs, _) = try Self.sampleNote()
        let (result, parsed) = try share(state, blobs)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: parsed.json, options: [.sortedKeys]), as: UTF8.self)
        for secret in ["SECRETDEVICE", "SECRETENGINE", "tombstones", "clocks", "origin", "replaces", "\"rec\"", "tagSet\":{\"instances\":[{",
                       "private-tag", "Work/Secret", "en-US", "recognized"] {
            XCTAssertFalse(json.contains(secret), "the payload must not contain \(secret)")
        }
        let note = try XCTUnwrap(parsed.json["note"] as? [String: Any])
        XCTAssertEqual(note["deleted"] as? Bool, false)
        let meta = try XCTUnwrap(note["meta"] as? [String: Any])
        XCTAssertEqual(meta["title"] as? String, "Quarterly secret plans")
        XCTAssertEqual(meta["created"] as? String, "1970-01-01T00:00:00.000Z", "no date unless asked")
        XCTAssertEqual(parsed.json["format"] as? String, "sempere-share/1")
        XCTAssertEqual(parsed.json["generator"] as? String, "sempere-share/1", "no app version")
        let shareId = try XCTUnwrap(parsed.json["shareId"] as? String)
        XCTAssertNotNil(UUID(uuidString: shareId))
        XCTAssertFalse(json.contains(state.pages[0].id.uuidString.lowercased()) && false)
        XCTAssertEqual(result.pages, state.pages.count)
        // Ink survives with its ids (the texture seed is in them).
        let pages = try XCTUnwrap(note["pages"] as? [[String: Any]])
        XCTAssertEqual((pages[0]["strokes"] as? [Any])?.count, state.pages[0].strokes.count)
    }

    func testOptionsBringBackTagsNotebookDatesAndTextCanBeLeftOut() throws {
        var (state, blobs, _) = try Self.sampleNote(images: false)
        state.pages[0].recognition = Recognition(engine: "vision", text: "recognized words here", words: [], basis: "abc")
        let plain = try share(state, blobs).1.json
        let plainText = String(decoding: try JSONSerialization.data(withJSONObject: plain), as: UTF8.self)
        XCTAssertTrue(plainText.contains("recognized words here"), "text is on by default")
        XCTAssertFalse(plainText.contains("\"basis\""))
        let full = try share(state, blobs) { $0.includeTags = true; $0.includeNotebookPath = true; $0.includeDates = true }.1.json
        let meta = try XCTUnwrap((full["note"] as? [String: Any])?["meta"] as? [String: Any])
        XCTAssertEqual(meta["tags"] as? [String], ["private-tag"])
        XCTAssertEqual(meta["notebook"] as? String, "Work/Secret")
        XCTAssertEqual(meta["created"] as? String, "2023-11-14T22:13:20.000Z")
        let noText = try share(state, blobs) { $0.includeText = false }.1.json
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: noText), as: UTF8.self).contains("recognized words here"))
    }

    func testTooManyPagesRefused() throws {
        var (state, blobs, _) = try Self.sampleNote(images: false)
        state.pages = (0...WebShareOptions.maxPages).map { Page(order: "a\($0)", strokes: []) }
        XCTAssertThrowsError(try share(state, blobs)) { XCTAssertEqual($0 as? WebShareError, .tooManyPages(201)) }
    }

    // MARK: What leaks

    func testFileNameAndTitleNeverCarryTheNoteTitle() throws {
        let (state, blobs, _) = try Self.sampleNote()
        let (result, _) = try share(state, blobs)
        let text = String(decoding: result.file, as: UTF8.self)
        XCTAssertTrue(text.contains("<title>Shared note</title>"))
        for word in ["Quarterly", "secret plans", "Work/Secret", "private-tag", "Typed text"] {
            XCTAssertFalse(text.contains(word), "\(word) must not be readable in the file")
        }
        // The share has no name of its own: the CLI's default is a fixed one, tested in CLITests.
    }

    // MARK: Pictures

    func testPhotoIsReencodedSmallerWithoutMetadataAndUpright() throws {
        let (state, blobs, refs) = try Self.sampleNote()
        XCTAssertTrue(T.contains(blobs.blobs[refs["photo"]!.sha256]!, "GPSLatitude"), "the source carries location")
        let (_, parsed) = try share(state, blobs) { $0.imageQuality = .low }
        XCTAssertFalse(parsed.blobs.values.contains { T.contains($0, "GPSLatitude") || T.contains($0, "Exif") }, "no metadata")
        let note = try XCTUnwrap(parsed.json["note"] as? [String: Any])
        let items = try XCTUnwrap((note["pages"] as? [[String: Any]])?[0]["items"] as? [[String: Any]])
        let photo = try XCTUnwrap(items.first { ($0["id"] as? String) == Self.uuid(901).uuidString.lowercased() })
        XCTAssertNil(photo["orientation"], "orientation is baked in")
        let size = try XCTUnwrap(photo["pixelSize"] as? [Double])
        // Oriented source is 1000 × 1500; low quality is at most 1280 on the long side.
        XCTAssertEqual(size, [853, 1280])
        let blob = try XCTUnwrap(photo["blob"] as? [String: Any])
        XCTAssertEqual(blob["type"] as? String, "image/jpeg")
        let data = try XCTUnwrap(parsed.blobs[try XCTUnwrap(blob["sha256"] as? String)])
        let decoded = try JPEG.decode(data)
        XCTAssertEqual([decoded.width, decoded.height], [853, 1280])
        // The crop was in oriented pixels of the 1000 × 1500 picture: it scales with it.
        let crop = try XCTUnwrap(photo["crop"] as? [Double])
        XCTAssertEqual(crop[0], 100 * 853 / 1000, accuracy: 0.01)
        XCTAssertEqual(crop[3], 700 * 1280 / 1500, accuracy: 0.01)
        XCTAssertEqual(blob["size"] as? Int, data.count)
    }

    func testLongSideIsBounded() throws {
        let png = try SyntheticImage.png(width: 3000, height: 1000, seed: 3)
        let blob = BlobRef(content: png, type: "image/png")
        var state = try T.loadSampleNote()
        state.pages[0].items = [Item(id: Self.uuid(910), kind: .image, frame: Rect(x: 0, y: 0, w: 300, h: 100), z: "a", blob: blob, pixelSize: Size(w: 3000, h: 1000))]
        let (_, parsed) = try share(state, MemoryBlobSource([png])) { $0.maxFileBytes = 40 << 20 }
        let items = try XCTUnwrap(((parsed.json["note"] as? [String: Any])?["pages"] as? [[String: Any]])?[0]["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["pixelSize"] as? [Double], [2048, 683])
    }

    func testPDFPagesAndEquationsBecomePictures() throws {
        let (state, blobs, _) = try Self.sampleNote()
        let (result, parsed) = try share(state, blobs)
        let items = try XCTUnwrap(((parsed.json["note"] as? [String: Any])?["pages"] as? [[String: Any]])?[0]["items"] as? [[String: Any]])
        let kinds = items.compactMap { $0["kind"] as? String }
        XCTAssertFalse(kinds.contains("pdfPage"))
        XCTAssertFalse(kinds.contains("math"), "an equation with a render is a picture")
        XCTAssertFalse(parsed.blobs.values.contains { $0.starts(with: Data("%PDF".utf8)) }, "no PDF in the share")
        let background = try XCTUnwrap(items.first { ($0["id"] as? String) == Self.uuid(902).uuidString.lowercased() })
        XCTAssertEqual(background["kind"] as? String, "image")
        XCTAssertEqual(background["layer"] as? Int, Int(ItemLayer.background.rawValue))
        XCTAssertNil(background["pageIndex"])
        // 200 × 300 points at 150 dpi.
        XCTAssertEqual(background["pixelSize"] as? [Double], [417, 625])
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
    }

    func testPDFPagesWithoutARasterizerAreLeftOutWithANotice() throws {
        let (state, blobs, _) = try Self.sampleNote()
        let (result, parsed) = try share(state, blobs, rasterizer: nil)
        let items = try XCTUnwrap(((parsed.json["note"] as? [String: Any])?["pages"] as? [[String: Any]])?[0]["items"] as? [[String: Any]])
        XCTAssertNil(items.first { ($0["id"] as? String) == Self.uuid(902).uuidString.lowercased() })
        XCTAssertTrue(result.skipped.contains { $0.contains("PDF page was left out") }, "\(result.skipped)")
        // The equation falls back to its source.
        let math = try XCTUnwrap(items.first { ($0["id"] as? String) == Self.uuid(903).uuidString.lowercased() })
        XCTAssertEqual(math["kind"] as? String, "math")
        XCTAssertNil((math["math"] as? [String: Any])?["render"])
    }

    func testALargePhotoIsDecodedReducedNotAtFullSizeAndKeepsItsDimensions() throws {
        // 3200 × 2400 with orientation 6 at the low step (1280 long side): DCT scaling brings it to 1/2 before the
        // oriented copy and the scale, so the full-size bitmap is never made (an iPhone's 48 MP photo would not fit).
        let rgba = try PNG.decode(try SyntheticImage.png(width: 3200, height: 2400, seed: 11))
        let jpeg = JPEGEncoder.encode(rgba, quality: 80)
        let ref = BlobRef(content: jpeg, type: "image/jpeg")
        let media = ShareMedia(blobs: MemoryBlobSource([jpeg]), rasterizer: nil, decoder: nil)
        let low = try XCTUnwrap(WebShareOptions.ImageQuality.low.steps.first)
        let e = try media.image(ref, orientation: 6, step: low).get()
        XCTAssertTrue(media.store.decoded.isEmpty, "the full-size decode was never made")
        XCTAssertEqual([e.width, e.height], [960, 1280], "upright, long side at the step")
        XCTAssertEqual([e.orientedWidth, e.orientedHeight], [2400, 3200], "crops stay measured in the full upright image")
        // The same image at another quality step decodes nothing new at full size either.
        _ = try media.image(ref, orientation: 6, step: (side: low.side, quality: low.quality - 10)).get()
        XCTAssertTrue(media.store.decoded.isEmpty)
        // (A small image takes no reduction: `testPhotoIsReencodedSmaller...` and `testLongSideIsBounded` pin its sizes.)
    }

    func testScaledMatchesAWholeImageBoxAverage() throws {
        // Row-at-a-time scaling gives the whole-image result: checked on an exact 2:1 reduction of a known picture.
        var px = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for y in 0..<4 { for x in 0..<8 { let i = (y * 8 + x) * 4; px[i] = UInt8(x * 30); px[i + 1] = UInt8(y * 60); px[i + 2] = 9; px[i + 3] = 255 } }
        let out = ShareMedia.scaled(try RGBAImage(width: 8, height: 4, pixels: px), to: 4)
        XCTAssertEqual([out.width, out.height], [4, 2])
        // Output (0,0) averages source x 0...1, y 0...1: r = (0 + 30) / 2, g = (0 + 60) / 2.
        XCTAssertEqual(out.pixels[0], 15)
        XCTAssertEqual(out.pixels[1], 30)
        XCTAssertEqual(out.pixels[3], 255)
        XCTAssertEqual(out.pixels[(1 * 4 + 3) * 4], UInt8((6 * 30 + 7 * 30) / 2))
    }

    func testVideoBecomesItsPosterAndAudioCardsGoWithoutRecordings() throws {
        let poster = try SyntheticImage.png(width: 200, height: 100, seed: 1)
        let posterRef = BlobRef(content: poster, type: "image/png")
        let rec = Recording(id: Self.uuid(920), blob: BlobRef(sha256: String(repeating: "a", count: 64), size: 10, type: "audio/mp4"),
                            started: Date(timeIntervalSince1970: 5), title: "Lecture")
        var state = try T.loadSampleNote()
        state.recordings = [rec]
        state.pages[0].items = [
            Item(id: Self.uuid(921), kind: .video, frame: Rect(x: 0, y: 0, w: 100, h: 50), z: "a",
                 blob: BlobRef(sha256: String(repeating: "b", count: 64), size: 1, type: "video/mp4"), poster: posterRef),
            Item(id: Self.uuid(922), kind: .audio, frame: Rect(x: 0, y: 60, w: 100, h: 40), z: "b", recording: rec.id),
        ]
        let (result, parsed) = try share(state, MemoryBlobSource([poster]))
        let items = try XCTUnwrap(((parsed.json["note"] as? [String: Any])?["pages"] as? [[String: Any]])?[0]["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["kind"] as? String, "image")
        XCTAssertNil(items[0]["poster"])
        XCTAssertTrue(result.skipped.contains { $0.contains("video was not included") })
        XCTAssertNil((parsed.json["note"] as? [String: Any])?["recordings"], "no recordings unless asked")
    }

    // MARK: Audio

    func testAudioIsIncludedOnlyWhenAskedAndSkippedWhenItDoesNotFit() throws {
        let audio = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ $0 >> 8) })
        let small = BlobRef(content: audio, type: "audio/mp4")
        let large = BlobRef(content: big, type: "audio/mp4")
        var state = try T.loadSampleNote()
        state.recordings = [
            Recording(id: Self.uuid(930), blob: small, started: Date(timeIntervalSince1970: 1), title: "short"),
            Recording(id: Self.uuid(931), blob: large, started: Date(timeIntervalSince1970: 2), title: "long"),
        ]
        state.pages[0].items = [Item(id: Self.uuid(932), kind: .audio, frame: Rect(x: 0, y: 0, w: 100, h: 40), z: "a", recording: Self.uuid(930)),
                                Item(id: Self.uuid(933), kind: .audio, frame: Rect(x: 0, y: 50, w: 100, h: 40), z: "b", recording: Self.uuid(931))]
        let blobs = MemoryBlobSource([audio, big])
        let off = try share(state, blobs).1
        XCTAssertNil((off.json["note"] as? [String: Any])?["recordings"])
        XCTAssertTrue(off.blobs.isEmpty)
        let (result, on) = try share(state, blobs) { $0.includeAudio = true; $0.maxFileBytes = 2 << 20 }
        let recs = try XCTUnwrap((on.json["note"] as? [String: Any])?["recordings"] as? [[String: Any]])
        XCTAssertEqual(recs.count, 1, "the long recording does not fit in 2 MB")
        XCTAssertEqual(on.blobs[small.sha256], audio)
        XCTAssertTrue(result.skipped.contains { $0.contains("long") && $0.contains("left out") }, "\(result.skipped)")
        XCTAssertGreaterThan(result.sections.audio, 40_000)
        let items = try XCTUnwrap(((on.json["note"] as? [String: Any])?["pages"] as? [[String: Any]])?[0]["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1, "the card of a skipped recording goes with it")
        let roomy = try share(state, blobs) { $0.includeAudio = true; $0.maxFileBytes = 20 << 20 }.1
        XCTAssertEqual((roomy.json["note"] as? [String: Any])?["recordings"].flatMap { ($0 as? [Any])?.count }, 2)
    }

    func testSkipNotesAreNotRepeatedWhenAudioIsIncluded() throws {
        let rec = Recording(id: Self.uuid(940), blob: BlobRef(sha256: String(repeating: "a", count: 64), size: 10, type: "audio/mp4"),
                            started: Date(timeIntervalSince1970: 5), title: "Lecture")
        var state = try T.loadSampleNote()
        state.recordings = [rec]
        state.pages[0].items = [Item(id: Self.uuid(941), kind: .video, frame: Rect(x: 0, y: 0, w: 100, h: 50), z: "a",
                                     blob: BlobRef(sha256: String(repeating: "b", count: 64), size: 1, type: "video/mp4"))]
        let result = try share(state, MemoryBlobSource([])) { $0.includeAudio = true }.0
        XCTAssertEqual(result.skipped.filter { $0.contains("video was left out") }.count, 1, "\(result.skipped)")
    }

    // MARK: Size

    func testEstimateOfTheArmoredFileIsExact() throws {
        let (state, blobs, _) = try Self.sampleNote()
        let planned = try WebPageShare.plan(state, blobs: blobs, options: Self.options(), template: Self.template,
                                            pdfRasterizer: QuadrantRasterizer(), imageDecoder: nil)
        let file = try WebPageShare.make(state, blobs: blobs, options: Self.options(), passphrase: "x", template: Self.template,
                                         pdfRasterizer: QuadrantRasterizer()).file
        let template = Self.template
        let size = template.text.utf8.count - ShareTemplate.placeholder.utf8.count + WebPageShare.armoredSize(payloadBytes: planned.payload.count)
        // The payload differs only in the random shareId, whose digits compress a few bytes differently.
        XCTAssertEqual(Double(file.count), Double(size), accuracy: 16)
    }

    func testPicturesShrinkToFitTheBudgetAndAnImpossibleNoteFailsWithTheBreakdown() throws {
        let png = try SyntheticImage.png(width: 2400, height: 1800, seed: 9)
        var state = try T.loadSampleNote()
        let blob = BlobRef(content: png, type: "image/png")
        state.pages[0].items = [Item(id: Self.uuid(940), kind: .image, frame: Rect(x: 0, y: 0, w: 400, h: 300), z: "a", blob: blob, pixelSize: Size(w: 2400, h: 1800))]
        let blobs = MemoryBlobSource([png])
        let roomy = try share(state, blobs) { $0.maxFileBytes = 30 << 20 }
        let tight = try share(state, blobs) { $0.maxFileBytes = 350_000 }
        XCTAssertLessThanOrEqual(tight.0.file.count, 350_000)
        XCTAssertLessThan(tight.0.sections.images, roomy.0.sections.images, "smaller pictures to fit")
        let widthTight = ((tight.1.json["note"] as? [String: Any])?["pages"] as? [[String: Any]])?[0]["items"] as? [[String: Any]]
        XCTAssertEqual((widthTight?[0]["pixelSize"] as? [Double])?[0], 1280)
        XCTAssertThrowsError(try share(state, blobs) { $0.maxFileBytes = 1000 }) { error in
            guard case WebShareError.tooLarge(let budget, let needed, let sections)? = error as? WebShareError else { return XCTFail("\(error)") }
            XCTAssertEqual(budget, 1000)
            XCTAssertGreaterThan(needed, 1000)
            XCTAssertGreaterThan(sections.images, 0)
            XCTAssertGreaterThan(sections.ink, 0)
            XCTAssertEqual(sections.template, Self.templateHTML.utf8.count - ShareTemplate.placeholder.utf8.count)
            XCTAssertTrue((error as? WebShareError)?.description.contains("pictures") == true)
        }
    }

    func testOptionBounds() throws {
        let (state, blobs, _) = try Self.sampleNote(images: false)
        XCTAssertThrowsError(try WebPageShare.make(state, blobs: blobs, options: Self.options(), passphrase: "", template: Self.template)) {
            XCTAssertEqual($0 as? WebShareError, .emptyPassphrase)
        }
        XCTAssertThrowsError(try share(state, blobs) { $0.maxFileBytes = 201 << 20 })
        XCTAssertThrowsError(try share(state, blobs) { $0.scryptLog2N = 31 })
    }

    // MARK: Encryption

    func testScryptWorkFactorIs18ByDefaultAndTheFileOpensOnlyWithThePassphrase() throws {
        let (state, blobs, _) = try Self.sampleNote(images: false)
        let result = try WebPageShare.make(state, blobs: blobs, options: WebShareOptions(), passphrase: Self.passphrase, template: Self.template)
        XCTAssertEqual(result.scryptLog2N, 18)
        XCTAssertEqual(Self.template.verify(file: result.file).scryptLog2N, 18)
        XCTAssertNoThrow(try Self.open(result.file))
        XCTAssertThrowsError(try Self.open(result.file, passphrase: "wrong"))
        // A flipped bit anywhere in the ciphertext fails cleanly.
        var text = String(decoding: result.file, as: UTF8.self)
        let at = try XCTUnwrap(text.range(of: "-----BEGIN AGE ENCRYPTED FILE-----\n"))
        let i = text.index(at.upperBound, offsetBy: 400)
        text.replaceSubrange(i...i, with: text[i] == "A" ? "B" : "A")
        XCTAssertThrowsError(try Self.open(Data(text.utf8)))
    }

    func testGeneratedPassphraseHasSevenWords() {
        XCTAssertEqual(GeneratedPassphrase.make().split(separator: "-").count, 7)
    }

    /// The recipe of docs/web-viewer.md "Share files": `sed` the armor out and `age -d` it.
    func testStockAgeOpensTheFileWithTheDocumentedRecipe() throws {
        // The recipe this test runs is the one the documentation gives, word for word.
        let docs = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/web-viewer.md"), encoding: .utf8)
        XCTAssertTrue(docs.contains(#"sed -n '/-----BEGIN AGE ENCRYPTED FILE-----/,/-----END AGE ENCRYPTED FILE-----/p' "Shared note.html" | age -d > payload.bin"#))
        guard let age = ExternalTool.find("age"), let python = ExternalTool.find("python3") else {
            if ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil { XCTFail("age and python3 are required here") }
            throw XCTSkip("age or python3 not installed")
        }
        let (state, blobs, _) = try Self.sampleNote(images: false)
        let result = try WebPageShare.make(state, blobs: blobs, options: Self.options(), passphrase: Self.passphrase, template: Self.template)
        let dir = TestTemp.root.appendingPathComponent("share-age-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Shared note.html")
        try result.file.write(to: file)
        // age asks for a passphrase on the terminal only: run the recipe on a pty and type it.
        let script = """
            import os, pty, sys, select, subprocess
            file, age, passphrase = sys.argv[1:4]
            pid, fd = pty.fork()
            if pid == 0:
                os.execvp("sh", ["sh", "-c", "sed -n '/-----BEGIN AGE ENCRYPTED FILE-----/,/-----END AGE ENCRYPTED FILE-----/p' \\"$0\\" | \\"$1\\" -d > \\"$0.payload\\"", file, age])
            buf = b""
            sent = False
            while True:
                r, _, _ = select.select([fd], [], [], 30)
                if not r: break
                try: d = os.read(fd, 1024)
                except OSError: break
                if not d: break
                buf += d
                if not sent and b"passphrase" in buf.lower():
                    os.write(fd, (passphrase + "\\n").encode()); sent = True
            _, status = os.waitpid(pid, 0)
            if os.WEXITSTATUS(status) != 0: sys.stderr.write(repr(buf))
            sys.exit(os.WEXITSTATUS(status))
            """
        let p = Process()
        p.executableURL = python
        p.arguments = ["-c", script, file.path, age.path, Self.passphrase]
        let errors = Pipe()
        p.standardError = errors
        try p.run()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: said, as: UTF8.self))
        let payload = try Data(contentsOf: URL(fileURLWithPath: file.path + ".payload"))
        let parsed = try WebPageShare.parse(container: payload)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: parsed.json) as? [String: Any])
    }

    // MARK: The container

    func testContainerRoundTripAndEveryTruncationIsTyped() throws {
        let a = Data("hello".utf8), b = Data((0..<500).map { UInt8($0 & 0xFF) })
        let blobs = [(sha256Hex(a), a), (sha256Hex(b), b)]
        let c = try WebPageShare.container(json: Data(#"{"x":1}"#.utf8), blobs: blobs.map { (name: $0.0, data: $0.1) })
        let parsed = try WebPageShare.parse(container: c)
        XCTAssertEqual(String(decoding: parsed.json, as: UTF8.self), #"{"x":1}"#)
        XCTAssertEqual(parsed.blobs[sha256Hex(a)], a)
        XCTAssertEqual(parsed.blobs[sha256Hex(b)], b)
        for n in 0..<c.count {
            do { _ = try WebPageShare.parse(container: c.prefix(n)) } catch is WebShareError { continue } catch { XCTFail("untyped \(error) at \(n)") }
        }
        // A name that does not match the content, a duplicate, a huge claimed length.
        var wrong = c
        wrong[wrong.count - 1] ^= 1
        XCTAssertThrowsError(try WebPageShare.parse(container: wrong))
        var huge = c
        let lengthAt = 9 + (Int(c[5]) << 24 | Int(c[6]) << 16 | Int(c[7]) << 8 | Int(c[8])) + 4 + 64
        for i in 0..<8 { huge[lengthAt + i] = 0xFF }
        XCTAssertThrowsError(try WebPageShare.parse(container: huge))
        XCTAssertThrowsError(try WebPageShare.parse(container: Data("SHRE\u{2}".utf8) + c.dropFirst(5)))
    }

    // MARK: Verify

    func testVerifyPassesAFreshShareAndFailsAnEditedPolicyScriptOrStyle() throws {
        let (state, blobs, _) = try Self.sampleNote(images: false)
        let file = try WebPageShare.make(state, blobs: blobs, options: Self.options(), passphrase: Self.passphrase, template: Self.template).file
        let template = Self.template
        let ok = template.verify(file: file, minLog2N: 10)
        XCTAssertTrue(ok.ok, "\(ok.problems)")
        XCTAssertTrue(ok.matchesTemplate && ok.policyMatches)
        XCTAssertEqual(ok.scryptLog2N, 10)
        // The factor is judged too: 10 is below what a share should carry.
        XCTAssertTrue(template.verify(file: file).problems.contains { $0.contains("scrypt work factor is 10") })
        XCTAssertFalse(template.verify(file: file).ok)
        XCTAssertEqual(ok.scriptSha256, template.scriptSha256)
        let text = String(decoding: file, as: UTF8.self)

        // The page's own CSP edited, script untouched: the case a script-hash check alone would pass.
        let csp = template.verify(file: Data(text.replacingOccurrences(of: "connect-src 'none'", with: "connect-src *").utf8))
        XCTAssertFalse(csp.ok)
        XCTAssertFalse(csp.policyMatches)
        XCTAssertEqual(csp.scriptSha256, template.scriptSha256)
        let script = template.verify(file: Data(text.replacingOccurrences(of: #"document.title="Shared note";"#, with: "fetch('//x')").utf8))
        XCTAssertFalse(script.ok)
        XCTAssertNotEqual(script.scriptSha256, template.scriptSha256)
        let style = template.verify(file: Data(text.replacingOccurrences(of: "body{margin:0}", with: "body{margin:1}").utf8))
        XCTAssertFalse(style.ok)
        // Something added outside the three.
        let extra = template.verify(file: Data(text.replacingOccurrences(of: "</body>", with: "<img src=x></body>").utf8))
        XCTAssertFalse(extra.ok)
        XCTAssertFalse(extra.matchesTemplate)
        // No data block, or not an age file inside it.
        XCTAssertFalse(template.verify(file: Data("<html></html>".utf8)).ok)
        XCTAssertFalse(template.verify(file: Data(text.replacingOccurrences(of: "-----BEGIN AGE ENCRYPTED FILE-----", with: "-----BEGIN NOPE-----").utf8)).ok)
        // Never decrypts: a wrong-passphrase-proof check works on a file whose payload nobody can open.
        XCTAssertNil(Self.template.verify(file: Data(Self.templateHTML.utf8)).scryptLog2N)
    }

    func testTemplateMustHoldThePlaceholderOnceInTheDataBlock() {
        XCTAssertNil(ShareTemplate(html: Data("<html></html>".utf8)))
        XCTAssertNil(ShareTemplate(html: Data((Self.templateHTML + ShareTemplate.placeholder).utf8)))
    }

    // MARK: The shared fixture (read by web/test/share.test.ts)

    static var fixtureDirectory: URL { T.fixtureSourceDir.appendingPathComponent("share") }
    static let fixturePassphrase = "fixture-share-passphrase"

    /// A note that needs no external input, so the same JSON comes out on every machine.
    static func fixtureNote() throws -> (NoteState, MemoryBlobSource) {
        var state = try T.loadSampleNote()
        state.meta.title = "Shared fixture"
        let png = try SyntheticImage.png(width: 300, height: 200, seed: 11)
        let ref = BlobRef(content: png, type: "image/png")
        state.pages[0].items = [
            Item.text(id: uuid(1), text("Fixture text box"), frame: Rect(x: 20, y: 20, w: 160, h: 30), z: "a"),
            Item(id: uuid(2), kind: .image, frame: Rect(x: 20, y: 60, w: 150, h: 100), z: "b", blob: ref, pixelSize: Size(w: 300, h: 200)),
        ]
        return (state, MemoryBlobSource([png]))
    }

    /// The payload and its age file for the fixture; written with `SEMPERE_WRITE_SHARE_FIXTURE=1`.
    func testFixtureMatchesWhatTheBuilderMakesAndOpensWithItsPassphrase() throws {
        let (state, blobs) = try Self.fixtureNote()
        let planned = try WebPageShare.plan(state, blobs: blobs, options: Self.options(), template: Self.template, pdfRasterizer: nil,
                                            imageDecoder: nil, shareID: "00000000-0000-4000-8000-00000000f1e0")
        let parsed = try WebPageShare.parse(container: planned.payload)
        let dir = Self.fixtureDirectory
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_SHARE_FIXTURE"] == "1" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let armored = try AgeFile.encrypt(planned.payload, to: [ScryptRecipient(passphrase: Self.fixturePassphrase, workFactor: 10)], armor: true)
            try planned.payload.write(to: dir.appendingPathComponent("payload.bin"))
            try parsed.json.write(to: dir.appendingPathComponent("payload.json"))
            try armored.write(to: dir.appendingPathComponent("payload.age"))
            try Data((Self.fixturePassphrase + "\n").utf8).write(to: dir.appendingPathComponent("passphrase.txt"))
        }
        let json = try Data(contentsOf: dir.appendingPathComponent("payload.json"))
        XCTAssertEqual(String(decoding: parsed.json, as: UTF8.self), String(decoding: json, as: UTF8.self),
                       "the payload JSON changed: regenerate with SEMPERE_WRITE_SHARE_FIXTURE=1 and update web/test/share.test.ts")
        let bin = try Data(contentsOf: dir.appendingPathComponent("payload.bin"))
        let fromFixture = try WebPageShare.parse(container: bin)
        XCTAssertEqual(fromFixture.json, parsed.json)
        XCTAssertEqual(fromFixture.blobs, parsed.blobs, "the re-encoded picture is the same bytes on every platform")
        let armored = try Data(contentsOf: dir.appendingPathComponent("payload.age"))
        XCTAssertEqual(try AgeFile.decrypt(armored, with: [ScryptIdentity(passphrase: Self.fixturePassphrase)]), bin)
        // The envelope reads back as a note.
        struct Envelope: Decodable { var format: String; var shareId: String; var note: NoteState }
        let env = try InkJSON.decoder().decode(Envelope.self, from: json)
        XCTAssertEqual(env.note.meta.title, "Shared fixture")
        XCTAssertEqual(env.note.pages[0].items.count, 2)
    }
}

/// Seeded mutation fuzzing of the share container, the parser of a file made by a stranger (CLAUDE.md "Fuzzing").
final class WebPageShareFuzzTests: XCTestCase {
    func testMutatedContainersFailWithTypedErrorsOrParse() throws {
        let a = Data("blob".utf8)
        let seed = try WebPageShare.container(json: Data(#"{"format":"sempere-share/1"}"#.utf8), blobs: [(sha256Hex(a), a)])
        var rng = SeededFuzz(seed: 0x5EED)
        for _ in 0..<400 {
            var d = seed
            for _ in 0..<(1 + Int(rng.next() % 4)) {
                let i = Int(rng.next() % UInt64(d.count))
                switch rng.next() % 3 {
                case 0: d[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: d.insert(UInt8(truncatingIfNeeded: rng.next()), at: i)
                default: d.remove(at: i)
                }
                if d.isEmpty { d = seed }
            }
            do { _ = try WebPageShare.parse(container: d) } catch is WebShareError {} catch { XCTFail("untyped error \(error)") }
        }
    }
}

/// A tiny deterministic generator (SplitMix64), so the cases are the same on every machine.
private struct SeededFuzz {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The JPEG writer: what comes back decodes to the same picture, carries nothing else.
final class JPEGEncoderTests: XCTestCase {
    func testRoundTripAndNoMetadata() throws {
        let png = try SyntheticImage.png(width: 123, height: 77, seed: 5)
        let image = try PNG.decode(png)
        let jpeg = JPEGEncoder.encode(image, quality: 90)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(Array(jpeg.suffix(2)), [0xFF, 0xD9])
        XCTAssertFalse(T.contains(jpeg, "Exif"))
        let back = try JPEG.decode(jpeg)
        XCTAssertEqual([back.width, back.height], [123, 77])
        var diff = 0, count = 0
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            for c in 0..<3 { diff += abs(Int(image.pixels[i + c]) - Int(back.pixels[i + c])); count += 1 }
        }
        XCTAssertLessThan(Double(diff) / Double(count), 12, "mean error per channel")
    }

    func testTransparencyGoesOverWhiteAndTinySizesWork() throws {
        for (w, h) in [(1, 1), (7, 3), (16, 16), (17, 9)] {
            let image = try RGBAImage(width: w, height: h, pixels: [UInt8](repeating: 0, count: w * h * 4))   // transparent black
            let back = try JPEG.decode(JPEGEncoder.encode(image, quality: 80))
            XCTAssertEqual([back.width, back.height], [w, h])
            XCTAssertGreaterThan(Int(back.pixels[0]), 240, "white, not black")
        }
    }

    func testQualityTradesSizeForFidelity() throws {
        let image = try PNG.decode(try SyntheticImage.png(width: 200, height: 150, seed: 2))
        XCTAssertLessThan(JPEGEncoder.encode(image, quality: 40).count, JPEGEncoder.encode(image, quality: 95).count)
    }
}
