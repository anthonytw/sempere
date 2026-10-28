import Foundation
import XCTest
@testable import Sempere

/// The attachment model types against docs/format.md §8: every example
/// round-trips, unknown kinds, fields and layers are re-emitted unchanged,
/// invalid `setItem` / `setRecording` are rejected.
final class AttachmentModelTests: XCTestCase {
    // Concrete stand-ins for the examples' "…".
    static let itemId = "6f1c2d4e-0000-4000-8000-000000000001"
    static let parentId = "6f1c2d4e-0000-4000-8000-000000000002"
    static let recId = "6f1c2d4e-0000-4000-8000-000000000003"
    static let pageId = "6f1c2d4e-0000-4000-8000-000000000004"
    static let hashA = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    static let hashB = "b023506dad39637be6e6e2ec3a0c31f8c0af3fe9bc060be0223b789cb75e5c00"

    func json(_ s: String) throws -> JSONValue {
        try InkJSON.decoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    /// Decodes `source` as `T`, encodes it again and checks that the JSON is
    /// the same value (keys in any order), the bytes are the canonical
    /// sorted encoding, and decoding the output gives the same model.
    @discardableResult
    func assertRoundTrip<T: Codable & Equatable>(_ source: String, as: T.Type, expected: String? = nil,
                                                 file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let value = try InkJSON.decoder().decode(T.self, from: Data(source.utf8))
        let out = try InkJSON.encoder().encode(value)
        XCTAssertEqual(try json(String(decoding: out, as: UTF8.self)), try json(expected ?? source), file: file, line: line)
        let canonical = try InkJSON.encoder().encode(try json(expected ?? source))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), String(decoding: canonical, as: UTF8.self), file: file, line: line)
        XCTAssertEqual(try InkJSON.decoder().decode(T.self, from: out), value, file: file, line: line)
        return value
    }

    func assertDecodeFails<T: Decodable>(_ source: String, as: T.Type, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try InkJSON.decoder().decode(T.self, from: Data(source.utf8)), file: file, line: line) { e in
            XCTAssert(e is DecodingError, "\(e)", file: file, line: line)
        }
    }

    // MARK: format.md §8 examples

    func testBlobReferenceExample() throws {
        let ref = try assertRoundTrip(#"""
            { "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
              "size": 482113, "type": "image/jpeg" }
            """#, as: BlobRef.self)
        XCTAssertEqual(ref.size, 482113)
        XCTAssertEqual(ref.kind, .image)
        XCTAssertEqual(ref.digest?.count, 32)
    }

    func testCommonFieldsExample() throws {
        // §8.2.1 with the image fields of §8.2.5 ("plus the fields of its kind").
        let item = try assertRoundTrip(#"""
            {
              "id": "\#(Self.itemId)",
              "kind": "image",
              "layer": 100,
              "frame": [72, 144, 288, 216],
              "rotation": 0,
              "z": "a0",
              "parent": "\#(Self.parentId)",
              "rec": { "id": "\#(Self.recId)", "at": 12.5 },
              "origin": "17596320000000003-a1b2c3d4-12-4",
              "clocks": { "frame": "17596320000000003-a1b2c3d4" },
              "blob": { "sha256": "\#(Self.hashA)", "size": 482113, "type": "image/jpeg" },
              "pixelSize": [3024, 4032]
            }
            """#, as: Item.self)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.layer, .content)
        XCTAssertEqual(item.frame, Rect(x: 72, y: 144, w: 288, h: 216))
        XCTAssertEqual(item.rotation, 0)   // written 0 stays written
        XCTAssertEqual(item.parent, UUID(uuidString: Self.parentId))
        XCTAssertEqual(item.rec, RecordingLink(id: UUID(uuidString: Self.recId)!, at: 12.5))
        XCTAssertEqual(item.clocks, ["frame": "17596320000000003-a1b2c3d4"])
        XCTAssertEqual(item.pixelSize, Size(w: 3024, h: 4032))
        XCTAssert(item.extra.isEmpty)
    }

    func testTextExample() throws {
        let item = try assertRoundTrip(#"""
            { "id": "\#(Self.itemId)", "kind": "text", "layer": 100, "frame": [72, 90, 300, 40], "z": "a1",
              "text": {
                "font": "sans", "family": "SF Pro", "size": 12, "color": "#1A1A1AFF",
                "align": "start", "dir": "auto", "lang": "en",
                "runs": [ { "t": "Lecture 3", "b": true, "size": 18 },
                          { "t": "\nlinear maps and their kernels" } ],
                "breaks": [] } }
            """#, as: Item.self)
        let text = try XCTUnwrap(item.text)
        XCTAssertEqual(text.font, .sans)
        XCTAssertEqual(text.family, "SF Pro")
        XCTAssertEqual(text.color, Color(r: 0x1A, g: 0x1A, b: 0x1A))
        XCTAssertEqual(text.align, .start)
        XCTAssertEqual(text.dir, .auto)
        XCTAssertEqual(text.runs.count, 2)
        XCTAssertTrue(text.runs[0].b)
        XCTAssertEqual(text.runs[0].size, 18)
        XCTAssertEqual(text.breaks, [])
        XCTAssertEqual(text.string, "Lecture 3\nlinear maps and their kernels")
        XCTAssertNil(item.rotation)
        XCTAssertNil(item.blob)
    }

    func testImageExample() throws {
        let item = try assertRoundTrip(#"""
            { "id": "\#(Self.itemId)", "kind": "image", "layer": 100, "frame": [72, 144, 216, 288], "z": "a0",
              "blob": { "sha256": "\#(Self.hashA)", "size": 482113, "type": "image/jpeg" },
              "pixelSize": [3024, 4032], "orientation": 6, "crop": [0, 0, 3024, 4032] }
            """#, as: Item.self)
        XCTAssertEqual(item.orientation, 6)
        XCTAssertEqual(item.crop, Rect(x: 0, y: 0, w: 3024, h: 4032))
        XCTAssertEqual(item.blob?.type, "image/jpeg")
    }

    func testPDFPageExample() throws {
        let item = try assertRoundTrip(#"""
            { "id": "\#(Self.itemId)", "kind": "pdfPage", "layer": 0, "frame": [0, 0, 612, 792], "z": "a0",
              "blob": { "sha256": "\#(Self.hashA)", "size": 1830221, "type": "application/pdf" },
              "pageIndex": 3, "pageSize": [612, 792], "crop": [36, 36, 540, 720] }
            """#, as: Item.self)
        XCTAssertEqual(item.layer, .background)
        XCTAssertTrue(item.layer.isBackground)
        XCTAssertEqual(item.pageIndex, 3)
        XCTAssertEqual(item.pageSize, Size(w: 612, h: 792))
        XCTAssertEqual(item.blob?.kind, .pdf)
    }

    func testRecordingExample() throws {
        let rec = try assertRoundTrip(#"""
            { "id": "\#(Self.recId)",
              "blob": { "sha256": "\#(Self.hashA)", "size": 28311552, "type": "audio/mp4" },
              "started": "2026-10-04T16:20:00.000Z",
              "duration": 3540.25,
              "codec": "aac", "sampleRate": 48000, "channels": 1, "bitRate": 64000,
              "title": "Lecture 3",
              "transcript": { "sha256": "\#(Self.hashB)", "size": 52011,
                              "type": "application/vnd.sempere.transcript+json" },
              "parent": "\#(Self.parentId)", "origin": "17596320000000003-a1b2c3d4-12-5",
              "clocks": { "title": "17596320000000003-a1b2c3d4" } }
            """#, as: Recording.self)
        XCTAssertEqual(rec.duration, 3540.25)
        XCTAssertEqual(rec.codec, "aac")
        XCTAssertEqual(rec.sampleRate, 48000)
        XCTAssertEqual(rec.title, "Lecture 3")
        XCTAssertEqual(rec.transcript?.kind, .transcript)
        XCTAssertEqual(rec.blob.kind, .audio)
        XCTAssertEqual(rec.started, Date(timeIntervalSince1970: 1_791_130_800))
    }

    func testTranscriptExample() throws {
        let source = #"""
            { "format": "sempere-transcript/1",
              "recording": "\#(Self.recId)",
              "engine": "apple-speechtranscriber-26.4",
              "language": "en-US",
              "created": "2026-10-04T17:21:00Z",
              "segments": [
                { "start": 0.52, "end": 3.1, "text": "Today we look at linear maps.",
                  "confidence": 0.94,
                  "words": [ { "t": "Today", "start": 0.52, "end": 0.8, "c": 0.97 },
                             { "t": "we", "start": 0.8, "end": 0.93, "c": 0.91 } ] } ] }
            """#
        // Writers emit milliseconds (§6), so only the date's spelling changes.
        let t = try assertRoundTrip(source, as: Transcript.self,
                                    expected: source.replacingOccurrences(of: "17:21:00Z", with: "17:21:00.000Z"))
        XCTAssertEqual(t, try Transcript.decode(Data(source.utf8)))
        XCTAssertEqual(t.recording, UUID(uuidString: Self.recId))
        XCTAssertEqual(t.segments[0].words?.map(\.t), ["Today", "we"])
        XCTAssertEqual(t.segments[0].confidence, 0.94)
        XCTAssertEqual(try Transcript.decode(t.encoded()), t)
    }

    func testStrokeRecExample() throws {
        // §5.6 with `rec`; the stroke is closed, so this is a typed field.
        let s = try assertRoundTrip(#"""
            { "id": "\#(Self.itemId)", "ink": { "tool": "pen", "color": "#1A1A1AFF", "width": 2.5 },
              "points": [[1, 2, 0, 2, 2, 1, 0, 0, 1.571]], "parent": "\#(Self.parentId)",
              "rec": { "id": "\#(Self.recId)", "at": 754.125 } }
            """#, as: Stroke.self)
        XCTAssertEqual(s.rec?.at, 754.125)
        // Without it nothing changes for existing strokes.
        XCTAssertNil(try InkJSON.decoder().decode(Stroke.self, from: InkJSON.encoder().encode(stroke())).rec)
    }

    func testSixOpsRoundTrip() throws {
        let item = ##"{"frame":[1,2,3,4],"id":"\##(Self.itemId)","kind":"text","layer":100,"text":{"color":"#000000FF","font":"sans","runs":[{"t":"x"}],"size":12},"z":"a0"}"##
        let recording = #"{"blob":{"sha256":"\#(Self.hashA)","size":10,"type":"audio/mp4"},"id":"\#(Self.recId)","started":"2026-10-04T16:20:00.000Z"}"#
        let ops = [
            #"{"item":\#(item),"op":"addItem","page":"\#(Self.pageId)"}"#,
            #"{"itemId":"\#(Self.itemId)","op":"removeItem","page":"\#(Self.pageId)"}"#,
            #"{"field":"frame","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":[5,6,7,8]}"#,
            #"{"field":"rotation","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":null}"#,
            #"{"field":"rotation","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":-12.5}"#,
            #"{"field":"z","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":"a5"}"#,
            #"{"field":"crop","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":null}"#,
            #"{"field":"crop","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":[0,0,10,10]}"#,
            ##"{"field":"text","itemId":"\##(Self.itemId)","op":"setItem","page":"\##(Self.pageId)","value":{"color":"#000000FF","font":"mono","runs":[],"size":9}}"##,
            #"{"field":"glow","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":{"r":[1,true,null,"x"]}}"#,
            #"{"field":"glow","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":null}"#,
            #"{"op":"addRecording","recording":\#(recording)}"#,
            #"{"op":"removeRecording","recordingId":"\#(Self.recId)"}"#,
            #"{"field":"title","op":"setRecording","recordingId":"\#(Self.recId)","value":"Week 2"}"#,
            #"{"field":"title","op":"setRecording","recordingId":"\#(Self.recId)","value":null}"#,
            #"{"field":"transcript","op":"setRecording","recordingId":"\#(Self.recId)","value":{"sha256":"\#(Self.hashB)","size":5,"type":"application/vnd.sempere.transcript+json"}}"#,
            #"{"field":"transcript","op":"setRecording","recordingId":"\#(Self.recId)","value":null}"#,
            #"{"field":"speaker","op":"setRecording","recordingId":"\#(Self.recId)","value":["a"]}"#,
        ]
        var decoded: [Op] = []
        for source in ops {
            decoded.append(try assertRoundTrip(source, as: Op.self))
        }
        let page = UUID(uuidString: Self.pageId)!, itemId = UUID(uuidString: Self.itemId)!
        XCTAssertEqual(decoded[2], .setItem(page: page, itemId: itemId, change: .frame(Rect(x: 5, y: 6, w: 7, h: 8))))
        XCTAssertEqual(decoded[3], .setItem(page: page, itemId: itemId, change: .rotation(nil)))
        XCTAssertEqual(decoded[9], .setItem(page: page, itemId: itemId,
                                            change: .other(field: "glow", value: .object(["r": .array([.number(1), .bool(true), .null, .string("x")])]))))
        XCTAssertEqual(decoded[10], .setItem(page: page, itemId: itemId, change: .other(field: "glow", value: .null)))
        XCTAssertEqual(decoded[14], .setRecording(recordingId: UUID(uuidString: Self.recId)!, change: .title(nil)))
        // A missing `value` reads as null, like `setMeta` of `notebook`.
        let missing = #"{"field":"rotation","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)"}"#
        XCTAssertEqual(try InkJSON.decoder().decode(Op.self, from: Data(missing.utf8)), decoded[3])

        // The whole delta, as a revision.
        let rev = Revision(noteId: testNote, device: devA, seq: 3, hlc: HLC(millis: baseMillis, counter: 0)!,
                           wall: wallAt(baseMillis), app: "test", body: .delta(ops: decoded))
        XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: InkJSON.encoder().encode(rev)), rev)
    }

    func testSnapshotStateWithAttachments() throws {
        let item = Item.text(id: UUID(uuidString: Self.itemId)!,
                             TextContent(size: 12, color: .black, runs: [TextRun("hi")]),
                             frame: Rect(x: 0, y: 0, w: 100, h: 20), z: "a0")
        let recording = Recording(id: UUID(uuidString: Self.recId)!, blob: BlobRef(content: Data("x".utf8), type: "audio/mp4"),
                                  started: wallAt(baseMillis))
        let state = NoteState(meta: NoteMeta(created: wallAt(baseMillis)),
                              pages: [Page(id: UUID(uuidString: Self.pageId)!, order: "a0", items: [item])],
                              tombstones: Tombstones(items: [UUID(uuidString: Self.parentId)!],
                                                     recordings: [UUID(uuidString: Self.parentId)!]),
                              recordings: [recording])
        let data = try InkJSON.encoder().encode(state)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssert(text.contains(#""tombstones":{"items":["\#(Self.parentId)"],"recordings":["\#(Self.parentId)"]}"#), text)
        XCTAssertEqual(try InkJSON.decoder().decode(NoteState.self, from: data), state)

        // Without attachments, no attachment fields are written.
        let plain = NoteState(meta: NoteMeta(created: wallAt(baseMillis)), pages: [Page(order: "a0")],
                              tombstones: Tombstones(pages: [UUID()]))
        let plainText = String(decoding: try InkJSON.encoder().encode(plain), as: UTF8.self)
        for key in ["items", "recordings"] { XCTAssertFalse(plainText.contains("\"\(key)\""), plainText) }
    }

    // MARK: Open format (§7)

    func testUnknownKindFieldsAndLayerAreKeptVerbatim() throws {
        // An item of a kind this reader does not know on an undefined layer,
        // with unknown fields, some of them named like fields of other kinds.
        let source = #"""
            { "id": "\#(Self.itemId)", "kind": "shape", "layer": 250, "frame": [10.5, 20, 30, 40], "z": "b",
              "latex": "e^{i\\pi} + 1 = 0", "display": true, "size": 14.25, "color": "#112233FF",
              "text": "not a text object", "crop": "whatever", "pixelSize": [1, 2, 3],
              "render": { "sha256": "\#(Self.hashA)", "size": 1000, "type": "application/pdf", "pages": 1 },
              "nested": { "a": [1, 2.5, -3e-7, 1e+300, null, false, { "deep": [[[]]] }], "": "" },
              "big": 12345678901234 }
            """#
        let item = try assertRoundTrip(source, as: Item.self)
        XCTAssertEqual(item.kind, ItemKind(rawValue: "shape"))
        XCTAssertFalse(item.kind.isDefined)
        XCTAssertEqual(item.layer.rawValue, 250)
        XCTAssertNil(item.text)
        XCTAssertNil(item.crop)
        XCTAssertEqual(item.extra["text"], .string("not a text object"))
        XCTAssertEqual(item.extra["display"], .bool(true))
        XCTAssertEqual(Set(item.extra.keys), ["latex", "display", "size", "color", "text", "crop", "pixelSize", "render",
                                              "nested", "big"])

        // Fields of another kind on a defined kind are unknown there too.
        let image = try assertRoundTrip(#"""
            { "id": "\#(Self.itemId)", "kind": "image", "layer": 100, "frame": [0, 0, 1, 1], "z": "a",
              "blob": { "sha256": "\#(Self.hashA)", "size": 1, "type": "image/webp", "exif": { "kept": true } },
              "pixelSize": [1, 1], "pageIndex": "seven", "text": 5, "alt": "a cat" }
            """#, as: Item.self)
        XCTAssertNil(image.pageIndex)
        XCTAssertEqual(image.extra["pageIndex"], .string("seven"))
        XCTAssertEqual(image.extra["alt"], .string("a cat"))
        XCTAssertEqual(image.blob?.extra["exif"], .object(["kept": .bool(true)]))
        XCTAssertEqual(image.blob?.kind, .image)
    }

    func testUnknownFieldsOnTextRunsAndRecordings() throws {
        let item = try assertRoundTrip(#"""
            { "id": "\#(Self.itemId)", "kind": "text", "layer": 100, "frame": [0, 0, 100, 20], "z": "a",
              "text": { "font": "handwriting", "size": 12, "color": "#000000FF", "align": "justify", "dir": "ttb",
                        "runs": [ { "t": "x", "link": "https://example.org", "i": true, "u": true, "s": true,
                                    "color": "#FF0000FF", "lang": "es" } ],
                        "lineHeight": 1.5 } }
            """#, as: Item.self)
        let text = try XCTUnwrap(item.text)
        XCTAssertEqual(text.font.rawValue, "handwriting")
        XCTAssertEqual(text.font.effective, .sans)
        XCTAssertEqual(text.align?.effective, .start)
        XCTAssertEqual(text.dir?.effective, .auto)
        XCTAssertEqual(text.extra["lineHeight"], .number(1.5))
        XCTAssertEqual(text.runs[0].extra["link"], .string("https://example.org"))
        XCTAssertEqual(text.runs[0].lang, "es")

        let rec = try assertRoundTrip(#"""
            { "id": "\#(Self.recId)", "blob": { "sha256": "\#(Self.hashA)", "size": 9, "type": "audio/x-notability" },
              "started": "2026-10-04T16:20:00.000Z", "speakers": ["A", "B"], "markers": [{ "at": 1, "label": "q" }] }
            """#, as: Recording.self)
        XCTAssertEqual(rec.extra["speakers"], .array([.string("A"), .string("B")]))
        XCTAssertNil(rec.title)
        XCTAssertEqual(rec.blob.kind, .audio)
    }

    func testLayers() throws {
        func layer(_ v: String) throws -> Int {
            let s = #"{"id":"\#(Self.itemId)","kind":"x","layer":\#(v),"frame":[0,0,1,1],"z":"a"}"#
            return try InkJSON.decoder().decode(Item.self, from: Data(s.utf8)).layer.rawValue
        }
        XCTAssertEqual(try layer("0"), 0)
        XCTAssertEqual(try layer("65535"), 65535)
        XCTAssertEqual(try layer("7.0"), 7)
        // Out of range or not an integer: read as content (§8.2.1).
        for bad in ["65536", "-1", "1.5", "\"0\"", "null", "true", "1e300", "[0]"] {
            XCTAssertEqual(try layer(bad), 100, bad)
        }
        // Absent: content.
        let absent = #"{"id":"\#(Self.itemId)","kind":"x","frame":[0,0,1,1],"z":"a"}"#
        XCTAssertEqual(try InkJSON.decoder().decode(Item.self, from: Data(absent.utf8)).layer, .content)
        // Writers refuse an out-of-range layer.
        let item = Item(kind: ItemKind(rawValue: "x"), layer: ItemLayer(rawValue: 70_000), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "a")
        XCTAssertThrowsError(try InkJSON.encoder().encode(item))
    }

    func testDrawingOrder() {
        func item(_ layer: Int, _ z: String, _ id: String) -> Item {
            Item(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(id)")!, kind: .text,
                 layer: ItemLayer(rawValue: layer), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: z)
        }
        let items = [item(100, "a", "2"), item(0, "z", "1"), item(100, "a", "1"), item(100, "Z", "3"),
                     item(250, "a", "4"), item(100, "é", "5"), item(100, "f", "6")]
        let sorted = items.sorted(by: Item.drawsBefore).map { "\($0.layer)/\($0.z)" }
        // Layers by number; `z` byte-wise ("Z" < "a" < "f" < "é").
        XCTAssertEqual(sorted, ["0/z", "100/Z", "100/a", "100/a", "100/f", "100/é", "250/a"])
        XCTAssertEqual(items.sorted(by: Item.drawsBefore)[2].id.uuidString.lowercased().suffix(1), "1")
    }

    // MARK: Validation

    func testSetItemValidation() {
        func setItem(_ field: String, _ value: String) -> String {
            #"{"field":"\#(field)","itemId":"\#(Self.itemId)","op":"setItem","page":"\#(Self.pageId)","value":\#(value)}"#
        }
        // Immutable fields (every kind) and snapshot-only fields.
        for field in ["id", "kind", "layer", "parent", "rec", "blob", "pixelSize", "orientation", "pageIndex",
                      "pageSize", "origin", "clocks"] {
            assertDecodeFails(setItem(field, "null"), as: Op.self)
            XCTAssertThrowsError(try ItemChange(field: field, value: .null)) { e in
                XCTAssertEqual(e as? ItemChangeError, .immutableField(field))
            }
        }
        // `null` is only for optional registers.
        for field in ["frame", "z", "text"] {
            assertDecodeFails(setItem(field, "null"), as: Op.self)
            XCTAssertThrowsError(try ItemChange(field: field, value: .null)) { e in
                XCTAssertEqual(e as? ItemChangeError, .nullNotAllowed(field))
            }
        }
        // Wrong types and ranges.
        for (field, value) in [("frame", "[0,0,0,10]"), ("frame", "[0,0,10]"), ("frame", "\"x\""), ("frame", "[0,0,0.0004,1]"),
                               ("rotation", "\"90\""), ("z", "1"), ("crop", "[0,0,-1,1]"), ("crop", "{}"),
                               ("text", "\"plain\""), ("text", ##"{"font":"sans","size":0,"color":"#000000FF","runs":[]}"##)] {
            assertDecodeFails(setItem(field, value), as: Op.self)
        }
        // Writers cannot sneak a known field through `.other`.
        for field in ["frame", "layer", "text"] {
            let op = Op.setItem(page: UUID(), itemId: UUID(), change: .other(field: field, value: .null))
            XCTAssertThrowsError(try InkJSON.encoder().encode(op), field)
        }
        XCTAssertThrowsError(try InkJSON.encoder().encode(Op.setItem(page: UUID(), itemId: UUID(),
                                                                     change: .frame(Rect(x: 0, y: 0, w: 0, h: 1)))))
    }

    func testSetRecordingValidation() {
        for field in ["id", "blob", "started", "duration", "codec", "sampleRate", "channels", "bitRate", "parent",
                      "origin", "clocks"] {
            let s = #"{"field":"\#(field)","op":"setRecording","recordingId":"\#(Self.recId)","value":null}"#
            assertDecodeFails(s, as: Op.self)
        }
        for (field, value) in [("title", "5"), ("transcript", "\"x\""), ("transcript", #"{"sha256":"AB","size":1,"type":"t"}"#)] {
            let s = #"{"field":"\#(field)","op":"setRecording","recordingId":"\#(Self.recId)","value":\#(value)}"#
            assertDecodeFails(s, as: Op.self)
        }
        let op = Op.setRecording(recordingId: UUID(), change: .other(field: "started", value: .null))
        XCTAssertThrowsError(try InkJSON.encoder().encode(op))
    }

    func testInvalidItemsAreRejected() {
        let blob = #"{"sha256":"\#(Self.hashA)","size":1,"type":"image/png"}"#
        let base = #""id":"\#(Self.itemId)","layer":100,"z":"a""#
        for bad in [
            #"{\#(base),"kind":"text","frame":[0,0,1,1]}"#,                                       // no text
            #"{\#(base),"kind":"image","frame":[0,0,1,1],"blob":\#(blob)}"#,                       // no pixelSize
            #"{\#(base),"kind":"image","frame":[0,0,1,1],"pixelSize":[1,1]}"#,                     // no blob
            #"{\#(base),"kind":"image","frame":[0,0,1,1],"blob":\#(blob),"pixelSize":[0,1]}"#,
            #"{\#(base),"kind":"image","frame":[0,0,1,1],"blob":\#(blob),"pixelSize":[1,1],"orientation":9}"#,
            #"{\#(base),"kind":"pdfPage","frame":[0,0,1,1],"blob":\#(blob),"pageSize":[1,1]}"#,  // no pageIndex
            #"{\#(base),"kind":"pdfPage","frame":[0,0,1,1],"blob":\#(blob),"pageIndex":-1,"pageSize":[1,1]}"#,
            #"{\#(base),"kind":"x","frame":[0,0,1,0]}"#,                                           // zero height
            #"{\#(base),"kind":"x","frame":[0,0,1,1,1]}"#,
            #"{\#(base),"kind":"x","frame":[0,0,1,1],"rotation":"90"}"#,
            #"{\#(base),"kind":"x","frame":[0,0,1,1],"parent":"nope"}"#,
            #"{\#(base),"kind":"x","frame":[0,0,1,1],"rec":{"id":"\#(Self.recId)"}}"#,
            #"{"id":"\#(Self.itemId)","kind":"x","frame":[0,0,1,1]}"#,                             // no z
            #"{"id":"\#(Self.itemId)","z":"a","frame":[0,0,1,1]}"#,                                // no kind
        ] {
            assertDecodeFails(bad, as: Item.self)
        }
        // Encoding refuses what decoding would refuse.
        XCTAssertThrowsError(try InkJSON.encoder().encode(Item(kind: .text, frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "a")))
        var item = Item.text(TextContent(size: 12, color: .black, runs: []), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "a")
        XCTAssertNoThrow(try InkJSON.encoder().encode(item))
        item.pageIndex = 2   // not a field of a text item
        XCTAssertThrowsError(try InkJSON.encoder().encode(item))
        item.pageIndex = nil
        item.extra["frame"] = .null   // would be written twice
        XCTAssertThrowsError(try InkJSON.encoder().encode(item))
    }

    func testBlobReferences() throws {
        // format.md §8.1.3 test vector content.
        let ref = BlobRef(content: Data("hello, sempere!\n".utf8), type: "text/plain")
        XCTAssertEqual(ref.sha256, "8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65")
        XCTAssertEqual(ref.size, 16)
        XCTAssertEqual(ref.kind, .bin)

        let kinds: [(String, BlobKind)] = [
            ("image/jpeg", .image), ("image/png", .image), ("image/heic", .image), ("IMAGE/PNG", .image),
            ("application/pdf", .pdf), ("Application/PDF; x=1", .pdf), ("audio/mp4", .audio),
            ("audio/mp4; codecs=\"mp4a.40.2\"", .audio), ("video/mp4", .video), ("video/quicktime", .video),
            (BlobRef.transcriptType, .transcript), ("application/json", .bin), ("text/plain", .bin), ("", .bin),
            ("imagex/png", .bin), ("image", .bin),
        ]
        for (type, kind) in kinds { XCTAssertEqual(BlobKind(mediaType: type), kind, type) }
        for kind in [BlobKind.image, .pdf, .audio, .video, .transcript, .bin] { XCTAssertTrue(kind.isValidName) }
        XCTAssertFalse(BlobKind(rawValue: "Image").isValidName)
        XCTAssertFalse(BlobKind(rawValue: "").isValidName)
        XCTAssertFalse(BlobKind(rawValue: String(repeating: "a", count: 17)).isValidName)

        for bad in [
            #"{"sha256":"\#(Self.hashA.uppercased())","size":1,"type":"t"}"#,
            #"{"sha256":"\#(Self.hashA.dropLast())","size":1,"type":"t"}"#,
            #"{"sha256":"\#(Self.hashA.dropLast())g","size":1,"type":"t"}"#,
            #"{"sha256":"\#(Self.hashA)","size":-1,"type":"t"}"#,
            #"{"sha256":"\#(Self.hashA)","size":1073741825,"type":"t"}"#,
            #"{"sha256":"\#(Self.hashA)","size":1.5,"type":"t"}"#,
            #"{"sha256":"\#(Self.hashA)","size":1}"#,
        ] {
            assertDecodeFails(bad, as: BlobRef.self)
        }
        try assertRoundTrip(#"{"sha256":"\#(Self.hashA)","size":1073741824,"type":"video/mp4"}"#, as: BlobRef.self)
        XCTAssertThrowsError(try InkJSON.encoder().encode(BlobRef(sha256: "x", size: 1, type: "t")))
    }

    func testTextContent() throws {
        // Offsets are Unicode scalars: "é" as e + U+0301 is two, the flag two,
        // the Arabic word four.
        let text = TextContent(size: 12, color: .black, dir: .rtl,
                               runs: [TextRun("e\u{301}🇪🇸 "), TextRun("سلام", b: true), TextRun("\nab")],
                               breaks: [4])
        XCTAssertEqual(text.scalarCount, 2 + 2 + 1 + 4 + 3)
        XCTAssertEqual(text.validBreaks, [4])
        let item = Item.text(text, frame: Rect(x: 0, y: 0, w: 50, h: 40), z: "a")
        XCTAssertEqual(try InkJSON.decoder().decode(Item.self, from: InkJSON.encoder().encode(item)), item)

        func breaks(_ b: [Int]?) -> [Int]? {
            var t = text
            t.breaks = b
            return t.validBreaks
        }
        XCTAssertNil(breaks(nil))
        XCTAssertEqual(breaks([]), [])
        XCTAssertNil(breaks([0]))        // before the first character
        XCTAssertNil(breaks([4, 4]))     // not strictly increasing
        XCTAssertNil(breaks([9]))        // the \n itself
        XCTAssertNil(breaks([10]))       // right after a \n
        XCTAssertEqual(breaks([4, 11]), [4, 11])
        XCTAssertNil(breaks([12]))       // the end

        XCTAssertTrue(TextRun("a", b: true).hasSameAttributes(as: TextRun("b", b: true)))
        XCTAssertFalse(TextRun("a").hasSameAttributes(as: TextRun("a", lang: "en")))

        // Limits (§8.4, §8.2.4), on both sides.
        let ok = ##"{"font":"sans","size":1000,"color":"#000000FF","runs":[]}"##
        XCTAssertNoThrow(try InkJSON.decoder().decode(TextContent.self, from: Data(ok.utf8)))
        func content(runs: String, size: String = "12", breaks: String? = nil) -> String {
            ##"{"font":"sans","size":\##(size),"color":"#000000FF","runs":\##(runs)\##(breaks.map { ",\"breaks\":\($0)" } ?? "")}"##
        }
        let manyRuns = "[" + Array(repeating: #"{"t":"a"}"#, count: 1001).joined(separator: ",") + "]"
        let longRun = #"[{"t":""# + String(repeating: "é", count: 32_769) + #""}]"#
        let manyBreaks = "[" + (1...10_001).map(String.init).joined(separator: ",") + "]"
        for bad in [content(runs: manyRuns), content(runs: longRun), content(runs: "[]", breaks: manyBreaks),
                    content(runs: "[]", size: "0"), content(runs: "[]", size: "1000.001"), content(runs: "[]", size: "-1"),
                    content(runs: #"[{"t":"a","size":0}]"#), content(runs: #"[{"b":true}]"#)] {
            assertDecodeFails(bad, as: TextContent.self)
        }
        XCTAssertNoThrow(try InkJSON.decoder().decode(TextContent.self, from: Data(content(runs: "[]", breaks: "null").utf8)))
        var big = TextContent(size: 12, color: .black, runs: [TextRun(String(repeating: "a", count: 65_537))])
        XCTAssertThrowsError(try InkJSON.encoder().encode(big))
        big.runs = [TextRun(String(repeating: "a", count: 65_536))]
        XCTAssertNoThrow(try InkJSON.encoder().encode(big))
    }

    func testTranscriptValidation() throws {
        func transcript(_ segments: String, format: String = "sempere-transcript/1") -> Data {
            Data(#"{"format":"\#(format)","recording":"\#(Self.recId)","engine":"e","language":"en","created":"2026-10-04T17:21:00Z","segments":\#(segments)}"#.utf8)
        }
        XCTAssertNoThrow(try Transcript.decode(transcript("[]")))
        XCTAssertNoThrow(try Transcript.decode(transcript(#"[{"start":0,"end":1,"text":"a"},{"start":1,"end":1,"text":"b"}]"#)))
        for bad in [
            transcript("[]", format: "sempere-transcript/2"),
            transcript(#"[{"start":2,"end":1,"text":"a"}]"#),                                        // start > end
            transcript(#"[{"start":-1,"end":1,"text":"a"}]"#),
            transcript(#"[{"start":0,"end":2,"text":"a"},{"start":1,"end":3,"text":"b"}]"#),          // overlap
            transcript(#"[{"start":5,"end":6,"text":"a"},{"start":1,"end":2,"text":"b"}]"#),          // order
            transcript(#"[{"start":0,"end":1,"text":"a","confidence":1.5}]"#),
            transcript(#"[{"start":1,"end":2,"text":"a","words":[{"t":"a","start":0.5,"end":1}]}]"#),  // word outside
            transcript(#"[{"start":1,"end":2,"text":"a","words":[{"t":"a","start":1,"end":2,"c":-0.1}]}]"#),
            transcript(#"[{"start":0,"end":5,"text":"a b","words":[{"t":"b","start":3,"end":4},{"t":"a","start":0,"end":5}]}]"#),  // word order
            transcript(#"[{"start":0,"end":5,"text":"a b","words":[{"t":"a","start":0,"end":3},{"t":"b","start":2,"end":4}]}]"#),  // word overlap
            Data("[]".utf8),
        ] {
            XCTAssertThrowsError(try Transcript.decode(bad)) { XCTAssert($0 is DecodingError) }
        }
        XCTAssertThrowsError(try Transcript.decode(Data(count: Transcript.maxSize + 1)))
        // Adjacent words (one ends where the next starts) are in order.
        XCTAssertNoThrow(try Transcript.decode(transcript(
            #"[{"start":0,"end":5,"text":"a b","words":[{"t":"a","start":0,"end":2},{"t":"b","start":2,"end":5}]}]"#)))
    }

    /// format.md §8.2.4: run text holds no C0 controls but `\n` and `\t`.
    func testTextRunsRefuseControlCharacters() throws {
        let ok = try InkJSON.decoder().decode(TextRun.self, from: Data(#"{"t":"a\tb\nc"}"#.utf8))
        XCTAssertEqual(ok.t, "a\tb\nc")
        for bad in [#"{"t":"a\u0000b"}"#, #"{"t":"a\u001b"}"#, #"{"t":"a\r\nb"}"#] {
            XCTAssertThrowsError(try InkJSON.decoder().decode(TextRun.self, from: Data(bad.utf8)), bad) {
                XCTAssert($0 is DecodingError, "\($0)")
            }
        }
        XCTAssertThrowsError(try InkJSON.encoder().encode(TextRun("a\rb"))) { XCTAssert($0 is EncodingError) }
        XCTAssertTrue(TextRun.isValidText("e\u{301}🇪🇸 \n\t"))
    }

    /// Restoring a stroke keeps its link to the recording (§8.3.3: `rec` is
    /// set when a stroke is added and copies keep it); a second restore is a no-op.
    func testRestoreKeepsTheStrokesRecordingLink() throws {
        var log = LogBuilder()
        let page = UUID()
        var linked = stroke()
        linked.rec = RecordingLink(id: UUID(), at: 3.5)
        let d1 = log.delta(devA, 0, NoteOps.newNote(title: "Rec", pageId: page) + [.addStroke(page: page, stroke: linked)])
        let d2 = log.delta(devA, 10, [.removeStroke(page: page, strokeId: linked.id)])
        var clock = HybridClock()
        let restore = try XCTUnwrap(try NoteHistory.makeRestore(from: [d1, d2], to: d1.name, device: devB, clock: &clock,
                                                                wall: wallAt(baseMillis + 20), app: "test"))
        let state = try NoteReducer.reconstruct([d1, d2, restore])
        let copy = try XCTUnwrap(state.pages.first?.strokes.first)
        XCTAssertEqual(copy.parent, linked.id)
        XCTAssertEqual(copy.rec, linked.rec)
        XCTAssertNil(try NoteHistory.makeRestore(from: [d1, d2, restore], to: d1.name, device: devB, clock: &clock,
                                                 wall: wallAt(baseMillis + 30), app: "test"))
    }

    func testJSONValue() throws {
        let source = #"{"a":[1,1.5,-0.25,true,false,null,"s",{"b":{}}],"n":0,"t":true,"z":"1"}"#
        let v = try json(source)
        XCTAssertEqual(v, .object(["a": .array([.number(1), .number(1.5), .number(-0.25), .bool(true), .bool(false), .null,
                                                .string("s"), .object(["b": .object([:])])]),
                                   "n": .number(0), "t": .bool(true), "z": .string("1")]))
        XCTAssertEqual(String(decoding: try InkJSON.encoder().encode(v), as: UTF8.self), source)
        XCTAssertEqual(try JSONValue(encoding: Rect(x: 1.23456, y: 0, w: 1, h: 2)),
                       .array([.number(1.235), .number(0), .number(1), .number(2)]))
        XCTAssertEqual(try JSONValue.array([.number(1), .number(2)]).decode(Size.self), Size(w: 1, h: 2))
        XCTAssertThrowsError(try InkJSON.encoder().encode(JSONValue.number(.nan)))
    }

    func testRounding() throws {
        let item = Item(kind: .pdfPage, frame: Rect(x: 1.00049, y: 2.0006, w: 3.1234, h: 4), rotation: 12.34567, z: "a",
                        rec: RecordingLink(id: UUID(), at: 1.23456),
                        blob: BlobRef(sha256: Self.hashA, size: 1, type: "application/pdf"),
                        crop: Rect(x: 0.1111, y: 0, w: 1, h: 1), pageIndex: 0, pageSize: Size(w: 612.0004, h: 792))
        let back = try InkJSON.decoder().decode(Item.self, from: InkJSON.encoder().encode(item))
        XCTAssertEqual(back.frame, Rect(x: 1, y: 2.001, w: 3.123, h: 4))
        XCTAssertEqual(back.rotation, 12.346)
        XCTAssertEqual(back.rec?.at, 1.235)
        XCTAssertEqual(back.crop?.x, 0.111)
        XCTAssertEqual(back.pageSize, Size(w: 612, h: 792))
    }
}
