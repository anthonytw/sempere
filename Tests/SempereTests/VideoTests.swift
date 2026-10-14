import FuzzSupport
import Foundation
import XCTest

@testable import Sempere

/// `video` items (format.md §8.2.7): the container probe on real ffmpeg output
/// (Fixtures/video) and on hostile bytes, metadata removal in place, the item's
/// fields and its `poster` register through merge and snapshots, the placement
/// builder and a streamed write into a vault.
final class VideoProbeTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/video")

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    func testH264WithMoovAfterTheSamples() throws {
        let info = try VideoProbe.probe(file: Self.url("clip-h264.mp4"))
        XCTAssertEqual(info.mediaType, "video/mp4")
        XCTAssertEqual(info.codec, "h264")
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(info.pixelSize, Size(w: 160, h: 90))
        XCTAssertEqual(info.rotation, 0)
        XCTAssertEqual(info.duration, 1.0, accuracy: 0.1)
        XCTAssertFalse(info.fastStart)
        XCTAssertFalse(info.metadataBoxes.isEmpty, "location and make are in moov's udta/meta")
    }

    func testFastStartGivesTheSameAnswer() throws {
        let a = try VideoProbe.probe(try Self.fixture("clip-h264.mp4"))
        let b = try VideoProbe.probe(try Self.fixture("clip-h264-faststart.mp4"))
        XCTAssertTrue(b.fastStart)
        XCTAssertEqual(a.pixelSize, b.pixelSize)
        XCTAssertEqual(a.duration, b.duration)
        XCTAssertEqual(a.codec, b.codec)
    }

    func testRotationSwapsTheDisplaySize() throws {
        let info = try VideoProbe.probe(try Self.fixture("clip-h264-rotated.mp4"))
        // ffmpeg's display rotation 90 is counter-clockwise: a clockwise 270.
        XCTAssertEqual(info.rotation, 270)
        XCTAssertEqual(info.pixelSize, Size(w: 90, h: 160))
    }

    func testQuickTimeHEVC() throws {
        let info = try VideoProbe.probe(try Self.fixture("clip-hevc.mov"))
        XCTAssertEqual(info.mediaType, "video/quicktime")
        XCTAssertEqual(info.codec, "hevc")
        XCTAssertNil(info.audioCodec)
        XCTAssertEqual(info.pixelSize, Size(w: 128, h: 72))
        XCTAssertEqual(info.duration, 0.5, accuracy: 0.1)
        XCTAssertTrue(info.metadataBoxes.contains { $0.type == "udta" })
    }

    func testRefusals() throws {
        XCTAssertThrowsError(try VideoProbe.probe(try Self.fixture("clip-mpeg4.mp4"))) {
            XCTAssertEqual($0 as? VideoProbeError, .unsupportedCodec("mp4v"))
        }
        XCTAssertThrowsError(try VideoProbe.probe(try Self.fixture("clip-fragmented.mp4"))) {
            XCTAssertEqual($0 as? VideoProbeError, .fragmented)
        }
        XCTAssertThrowsError(try VideoProbe.probe(try Self.fixture("poster.jpg"))) { XCTAssertEqual($0 as? VideoProbeError, .notVideo) }
        XCTAssertThrowsError(try VideoProbe.probe(Data())) { XCTAssertEqual($0 as? VideoProbeError, .notVideo) }
        // Audio only: an MP4 without a video track.
        let audio = try Data(contentsOf: Self.dir.deletingLastPathComponent().appendingPathComponent("audio/tone-aac.m4a"))
        XCTAssertThrowsError(try VideoProbe.probe(audio)) { XCTAssertEqual($0 as? VideoProbeError, .noVideoTrack) }
        // Only a file type box: no movie.
        let good = try Self.fixture("clip-h264-faststart.mp4")
        let ftypLength = Int(VideoProbe.be32([UInt8](good), 0))
        XCTAssertThrowsError(try VideoProbe.probe(good.prefix(ftypLength))) { XCTAssertEqual($0 as? VideoProbeError, .noMovie) }
    }

    func testCutOffInsideTheSamplesKeepsTheHeader() throws {
        // moov first: a clip cut inside mdat is still described.
        let good = try Self.fixture("clip-h264-faststart.mp4")
        XCTAssertEqual(try VideoProbe.probe(good.prefix(good.count - 500)).codec, "h264")
        // moov last: no movie.
        let late = try Self.fixture("clip-h264.mp4")
        XCTAssertThrowsError(try VideoProbe.probe(late.prefix(late.count - 500))) { XCTAssertTrue($0 is VideoProbeError) }
    }

    func testHugeSixtyFourBitSizesDoNotOverflow() throws {
        let good = try Self.fixture("clip-h264-faststart.mp4")
        let ftyp = Int(VideoProbe.be32([UInt8](good), 0))
        for size: UInt64 in [.max, .max - 7, 1 << 63, 17] {
            let be = (0..<8).map { UInt8(truncatingIfNeeded: size >> (56 - 8 * $0)) }
            for type in ["moov", "free"] {
                let hostile = Array(good.prefix(ftyp)) + [0, 0, 0, 1] + Array(type.utf8) + be + [UInt8](repeating: 0, count: 16)
                XCTAssertThrowsError(try VideoProbe.probe(Data(hostile)), "size \(size)") { XCTAssertTrue($0 is VideoProbeError, "\($0)") }
            }
        }
    }

    func testDeepNestingAndBoxFloodsAreBounded() throws {
        // A flood of tiny boxes inside moov stops at the box budget instead of walking them all.
        var flood = [UInt8]()
        for _ in 0..<30_000 { flood += [0, 0, 0, 8] + Array("free".utf8) }
        let moov = [UInt8](be32(UInt32(8 + flood.count))) + Array("moov".utf8) + flood
        let file = [0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0] + moov
        XCTAssertThrowsError(try VideoProbe.probe(Data(file))) { XCTAssertEqual($0 as? VideoProbeError, .malformed("too many boxes")) }
    }

    func testFlippedBytesNeverTrap() throws {
        let good = try Self.fixture("clip-h264-faststart.mp4")
        for i in 0..<min(good.count, 2000) {
            var d = good
            d[i] ^= 0xFF
            do { _ = try VideoProbe.probe(d) } catch is VideoProbeError {} catch { XCTFail("untyped \(error)") }
        }
    }

    func testFuzz() throws {
        let seeds = try ["clip-h264-faststart.mp4", "clip-hevc.mov", "clip-h264-rotated.mp4", "clip-fragmented.mp4"].map(Self.fixture)
        let report = Fuzz.run("video-probe", seeds: seeds, quick: 300, maxSize: 64 << 10) { input in
            do {
                let info = try VideoProbe.probe(input)
                // Every edit stays inside the file.
                for e in VideoMetadata.strippingEdits(info) where e.range.upperBound > UInt64(input.count) {
                    return "edit \(e.range) past the end of \(input.count) bytes"
                }
            } catch is VideoProbeError {} catch { return "untyped error: \(error)" }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    // MARK: - Metadata removal

    func testStrippingRemovesTheLocationAndKeepsTheClip() throws {
        for name in ["clip-h264.mp4", "clip-h264-faststart.mp4", "clip-hevc.mov"] {
            let data = try Self.fixture(name)
            XCTAssertNotNil(data.range(of: Data("48.8584".utf8)), name)
            let info = try VideoProbe.probe(data)
            var stripped = data
            ByteEdit.apply(VideoMetadata.strippingEdits(info), to: &stripped, at: 0)
            XCTAssertEqual(stripped.count, data.count, name)
            XCTAssertNil(stripped.range(of: Data("48.8584".utf8)), name)
            XCTAssertNil(stripped.range(of: Data("TestCam".utf8)), name)
            // Still the same clip, now without metadata boxes (they are `free`).
            let again = try VideoProbe.probe(stripped)
            XCTAssertEqual(again.pixelSize, info.pixelSize)
            XCTAssertEqual(again.duration, info.duration)
            XCTAssertTrue(again.metadataBoxes.isEmpty, name)
            // Only the metadata boxes changed: the samples are byte for byte the same.
            var changed = 0
            for i in 0..<data.count where data[i] != stripped[i] { changed += 1 }
            let budget = info.metadataBoxes.reduce(0) { $0 + Int($1.length) }
            XCTAssertLessThanOrEqual(changed, budget, name)
        }
    }

    /// A box of `type` with `body`.
    static func box(_ type: String, _ body: Data) -> Data {
        let n = UInt32(8 + body.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + Data(type.utf8) + body
    }

    /// An XMP packet with a GPS position, as cameras and editors write it.
    static let xmpGPS = Data("<x:xmpmeta><rdf:Description exif:GPSLatitude=\"48,51.504N\" exif:GPSLongitude=\"2,17.67E\"/></x:xmpmeta>".utf8)

    /// XMP can carry a position too: an XMP `uuid` box at the top level or
    /// inside `moov` / a `trak`, and a top-level `meta`, are blanked like
    /// `udta`; a `uuid` box of another kind is left alone.
    func testStrippingRemovesXMPAndTopLevelMeta() throws {
        let clip = try Self.fixture("clip-h264.mp4")   // moov after mdat: a box appended to moov moves no sample
        var info = try VideoProbe.probe(clip)
        XCTAssertFalse(info.fastStart)
        // The last top-level box must be moov, so growing it moves nothing else.
        var pos = 0, last = 0
        let bytes = [UInt8](clip)
        while pos + 8 <= bytes.count {
            last = pos
            pos += Int(VideoProbe.be32(bytes, pos))
        }
        XCTAssertEqual(VideoProbe.fourcc(bytes, last + 4), "moov")
        let xmp = Self.box("uuid", Data(VideoProbe.xmpUUID) + Self.xmpGPS)
        let other = Self.box("uuid", Data(repeating: 0x11, count: 16) + Data("keep me".utf8))
        var moov = clip[last...]
        moov += xmp
        let n = UInt32(moov.count)
        moov.replaceSubrange(moov.startIndex..<moov.startIndex + 4, with: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        var data = clip[..<last] + moov
        data += Self.box("uuid", Data(VideoProbe.xmpUUID) + Self.xmpGPS) + other + Self.box("meta", Data("TestCam 48.8584".utf8))
        let original = try VideoProbe.probe(clip)
        info = try VideoProbe.probe(data)
        XCTAssertEqual(info.pixelSize, original.pixelSize)
        XCTAssertEqual(info.metadataBoxes.count, original.metadataBoxes.count + 3)
        XCTAssertEqual(info.metadataBoxes.map(\.offset), info.metadataBoxes.map(\.offset).sorted())
        var stripped = data
        ByteEdit.apply(VideoMetadata.strippingEdits(info), to: &stripped, at: 0)
        XCTAssertEqual(stripped.count, data.count)
        XCTAssertNil(stripped.range(of: Data("GPSLatitude".utf8)))
        XCTAssertNil(stripped.range(of: Data("48.8584".utf8)))
        XCTAssertNotNil(stripped.range(of: Data("keep me".utf8)), "another uuid box is not metadata")
        let again = try VideoProbe.probe(stripped)
        XCTAssertTrue(again.metadataBoxes.isEmpty)
        XCTAssertEqual(again.pixelSize, original.pixelSize)
        XCTAssertEqual(again.duration, original.duration)
        // A uuid box too short for a usertype is no XMP and no error.
        XCTAssertEqual(try VideoProbe.probe(clip + Self.box("uuid", Data([1, 2, 3]))).metadataBoxes.count,
                       original.metadataBoxes.count)
    }

    /// Security review 2026-10 (V2): layouts whose location the walk would
    /// not see fail closed or are blanked: a second moov (refused), a
    /// top-level udta (blanked like moov's), and a truncated box other than
    /// mdat at the end (refused).
    func testLocationOutsideTheWalkedBoxesIsNeverKept() throws {
        let clip = try Self.fixture("clip-h264-faststart.mp4")
        let gps = Self.box("udta", Self.box("\u{A9}xyz", Data("+48.8584+002.2945/".utf8)))
        // A second moov.
        XCTAssertThrowsError(try VideoProbe.probe(clip + Self.box("moov", gps))) {
            guard case .malformed = $0 as? VideoProbeError else { return XCTFail("\($0)") }
        }
        // A top-level udta.
        let withUdta = clip + gps
        let info = try VideoProbe.probe(withUdta)
        var stripped = withUdta
        ByteEdit.apply(VideoMetadata.strippingEdits(info), to: &stripped, at: 0)
        XCTAssertNil(stripped.range(of: Data("48.8584".utf8)))
        XCTAssertEqual(try VideoProbe.probe(stripped).pixelSize, info.pixelSize)
        // A trailing meta whose size runs past the end.
        var meta = Self.box("meta", Data("+48.8584+002.2945/".utf8))
        meta[3] &+= 64
        XCTAssertThrowsError(try VideoProbe.probe(clip + meta)) {
            guard case .malformed = $0 as? VideoProbeError else { return XCTFail("\($0)") }
        }
    }

    func testEditsApplyAcrossPieceBoundaries() {
        let data = Data((0..<100).map { UInt8($0) })
        let edits = [ByteEdit(range: 10..<30), ByteEdit(range: 50..<54, bytes: Data("free".utf8))]
        var whole = data
        ByteEdit.apply(edits, to: &whole, at: 0)
        var pieces = Data()
        var offset: UInt64 = 0
        for size in [7, 13, 1, 40, 39] {
            var piece = data.subdata(in: Int(offset)..<Int(offset) + size)
            ByteEdit.apply(edits, to: &piece, at: offset)
            pieces += piece
            offset += UInt64(size)
        }
        XCTAssertEqual(pieces, whole)
        XCTAssertEqual(whole[10..<30], Data(count: 20))
        XCTAssertEqual(whole[50..<54], Data("free".utf8))
        XCTAssertEqual(whole[49], 49)
        XCTAssertEqual(whole[54], 54)
    }

    private func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
}

/// The `video` item in the model, merge and ops.
final class VideoItemTests: XCTestCase {
    static let clip = BlobRef(sha256: String(repeating: "ab", count: 32), size: 48_211_330, type: "video/mp4")
    static let poster = BlobRef(sha256: String(repeating: "cd", count: 32), size: 81_211, type: "image/jpeg")
    static let poster2 = BlobRef(sha256: String(repeating: "ef", count: 32), size: 9_000, type: "image/png")
    static let info = VideoInfo(mediaType: "video/mp4", duration: 42.5174, pixelSize: Size(w: 1080, h: 1920), rotation: 90,
                                codec: "hevc")

    func item(poster: BlobRef? = poster) -> Item {
        Item.video(id: UUID(uuidString: "6f1c2d4e-0000-4000-8000-000000000001")!, blob: Self.clip,
                   pixelSize: Size(w: 1920, h: 1080), duration: 42.517, videoRotation: 90, codec: "hevc", poster: poster,
                   frame: Rect(x: 72, y: 144, w: 320, h: 180), z: "a2")
    }

    func testRoundTripAndWireForm() throws {
        let json = try InkJSON.encoder().encode(item())
        let s = String(decoding: json, as: UTF8.self)
        for key in ["\"kind\":\"video\"", "\"duration\":42.517", "\"videoRotation\":90", "\"codec\":\"hevc\"", "\"poster\":{",
                    "\"pixelSize\":[1920,1080]"] {
            XCTAssertTrue(s.contains(key), "\(key) in \(s)")
        }
        XCTAssertEqual(try InkJSON.decoder().decode(Item.self, from: json), item())
        // videoRotation 0 and no poster are written as absent.
        let plain = Item.video(blob: Self.clip, pixelSize: Size(w: 4, h: 3), duration: 0, videoRotation: 0,
                               frame: Rect(x: 0, y: 0, w: 4, h: 3), z: "a")
        let p = String(decoding: try InkJSON.encoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(p.contains("videoRotation"))
        XCTAssertFalse(p.contains("poster"))
        XCTAssertTrue(ItemKind.video.isDefined)
        XCTAssertTrue(ItemKind.math.isDefined)
    }

    func testInvalidVideoItemsAreRejected() throws {
        let base = #"{"id":"6f1c2d4e-0000-4000-8000-000000000001","kind":"video","frame":[0,0,10,10],"z":"a","#
        let blob = #""blob":{"sha256":"\#(String(repeating: "ab", count: 32))","size":5,"type":"video/mp4"}"#
        let ok = base + blob + #","pixelSize":[4,3],"duration":1.5}"#
        XCTAssertNoThrow(try InkJSON.decoder().decode(Item.self, from: Data(ok.utf8)))
        XCTAssertNoThrow(try InkJSON.decoder().decode(Item.self, from: Data((base + blob + #","pixelSize":[4,3],"duration":1.5,"poster":null}"#).utf8)))
        for bad in [base + blob + #","pixelSize":[4,3]}"#,                                   // no duration
                    base + blob + #","duration":1}"#,                                        // no pixelSize
                    base + #""pixelSize":[4,3],"duration":1}"#,                              // no blob
                    base + blob + #","pixelSize":[4,3],"duration":-1}"#,
                    base + blob + #","pixelSize":[0,3],"duration":1}"#,
                    base + blob + #","pixelSize":[4,3],"duration":1,"videoRotation":45}"#,
                    base + blob + #","pixelSize":[4,3],"duration":1,"poster":"x"}"#,
                    base + blob + #","pixelSize":[4,3],"duration":1,"codec":7}"#] {
            XCTAssertThrowsError(try InkJSON.decoder().decode(Item.self, from: Data(bad.utf8)), bad)
        }
        // A video field on an image is an unknown field there, kept.
        let image = #"{"id":"6f1c2d4e-0000-4000-8000-000000000001","kind":"image","frame":[0,0,10,10],"z":"a","#
            + #""blob":{"sha256":"\#(String(repeating: "ab", count: 32))","size":5,"type":"image/png"},"pixelSize":[4,3],"duration":7}"#
        let decoded = try InkJSON.decoder().decode(Item.self, from: Data(image.utf8))
        XCTAssertNil(decoded.duration)
        XCTAssertEqual(decoded.extra["duration"], .number(7))
    }

    func testImmutableFieldsCannotBeSet() throws {
        for field in ["duration", "videoRotation", "codec", "blob", "pixelSize"] {
            XCTAssertThrowsError(try ItemChange(field: field, value: .number(1))) {
                XCTAssertEqual($0 as? ItemChangeError, .immutableField(field))
            }
        }
        XCTAssertEqual(try ItemChange(field: "poster", value: .null), .poster(nil))
        XCTAssertEqual(try ItemChange(field: "poster", value: try JSONValue(encoding: Self.poster)), .poster(Self.poster))
        XCTAssertThrowsError(try ItemChange(field: "poster", value: .string("x")))
    }

    func testPosterIsALastWriterWinsRegisterThroughSnapshots() throws {
        var log = LogBuilder()
        let page = UUID()
        let v = item(poster: nil)
        let d1 = log.delta(devA, 0, [.addPage(Page(id: page, order: "a0")), .addItem(page: page, item: v)])
        let d2 = log.delta(devA, 10, [.setItem(page: page, itemId: v.id, change: .poster(Self.poster))])
        let d3 = log.delta(devB, 20, [.setItem(page: page, itemId: v.id, change: .poster(Self.poster2))])
        for order in [[d1, d2, d3], [d3, d2, d1], [d2, d1, d3]] {
            let state = try NoteReducer.reconstruct(order)
            XCTAssertEqual(state.pages[0].items[0].poster, Self.poster2)
            XCTAssertEqual(Set(state.blobReferences.map(\.sha256)), [Self.clip.sha256, Self.poster2.sha256])
        }
        let snap = try log.snapshot(devB, 30, from: [d1, d2, d3])
        let reset = log.delta(devA, 40, [.setItem(page: page, itemId: v.id, change: .poster(nil))])
        let state = try NoteReducer.reconstruct([snap, reset])
        XCTAssertNil(state.pages[0].items[0].poster)
        // An older write after the snapshot loses to the snapshot's clock.
        let snapJSON = String(decoding: try InkJSON.encoder().encode(snap), as: UTF8.self)
        XCTAssertTrue(snapJSON.contains("\"poster\""), "snapshot clocks list the poster register")
        XCTAssertEqual(try NoteReducer.reconstruct([snap]).pages[0].items[0].poster, Self.poster2)
    }

    func testSetPosterBuilder() throws {
        var page = Page(id: UUID(), order: "a0")
        page.items = [item(poster: nil)]
        let edit = try XCTUnwrap(try NoteOps.setPoster(item().id, to: Self.poster, on: page))
        XCTAssertEqual(edit.ops, [.setItem(page: page.id, itemId: item().id, change: .poster(Self.poster))])
        XCTAssertEqual(edit.page.items[0].poster, Self.poster)
        XCTAssertNil(try NoteOps.setPoster(item().id, to: Self.poster, on: edit.page))   // unchanged
        XCTAssertNil(try NoteOps.setPoster(UUID(), to: Self.poster, on: page))           // no such video
        XCTAssertThrowsError(try NoteOps.setPoster(item().id, to: Self.clip, on: page)) {
            guard case .invalidPoster = $0 as? AttachmentOpsError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(NoteOps.blobs(of: [item()]).map(\.sha256), [Self.clip.sha256, Self.poster.sha256])
    }

    func testPlaceVideoDefaults() throws {
        let page = Page(id: UUID(), order: "a0")
        let placed = try NoteOps.placeVideo(blob: Self.clip, info: Self.info, poster: Self.poster, on: page, pageSize: .letter)
        let f = placed.item.frame
        // 1080 × 1920 (portrait) fitted into 480 × 720: 405 × 720, centred.
        XCTAssertEqual(f.w, 405, accuracy: 0.001)
        XCTAssertEqual(f.h, 720, accuracy: 0.001)
        XCTAssertEqual(f.x, (612 - 405) / 2, accuracy: 0.001)
        XCTAssertEqual(f.y, 36)
        XCTAssertEqual(placed.item.kind, .video)
        XCTAssertEqual(placed.item.duration, 42.517)
        XCTAssertEqual(placed.item.videoRotation, 90)
        XCTAssertEqual(placed.item.codec, "hevc")
        XCTAssertEqual(placed.item.poster, Self.poster)
        XCTAssertNil(placed.item.validationError)
        let landscape = VideoInfo(mediaType: "video/mp4", duration: 1, pixelSize: Size(w: 160, h: 90), rotation: 0, codec: "h264")
        let small = try NoteOps.placeVideo(blob: Self.clip, info: landscape, on: page, pageSize: .letter).item
        XCTAssertEqual(small.frame.w, 480, accuracy: 0.001)   // small clips are shown at the default width
        XCTAssertEqual(small.frame.h, 270, accuracy: 0.001)
        XCTAssertNil(small.videoRotation)
        let sized = try NoteOps.placeVideo(blob: Self.clip, info: landscape, on: page, pageSize: .letter, at: (10, 20), width: 160).item
        XCTAssertEqual(sized.frame, Rect(x: 10, y: 20, w: 160, h: 90))
        XCTAssertThrowsError(try NoteOps.placeVideo(blob: Self.poster, info: landscape, on: page, pageSize: .letter))
        XCTAssertThrowsError(try NoteOps.placeVideo(blob: Self.clip, info: landscape, poster: Self.clip, on: page, pageSize: .letter))
    }
}

/// Writing a clip into a vault: streamed, metadata removed unless kept.
final class VideoVaultTests: VaultTestCase {
    func testWriteVideoStripsMetadataUnlessKept() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID()
        let file = VideoProbeTests.url("clip-h264.mp4")
        let original = try Data(contentsOf: file)
        let (ref, info) = try vault.writeVideo(note: note, contentsOf: file)
        XCTAssertEqual(ref.type, "video/mp4")
        XCTAssertEqual(ref.kind, .video)
        XCTAssertEqual(ref.size, Int64(original.count))
        XCTAssertEqual(info.codec, "h264")
        let stored = try vault.readBlob(note: note, ref)
        XCTAssertNil(stored.range(of: Data("48.8584".utf8)))
        XCTAssertNotEqual(ref.sha256, BlobRef(content: original, type: "video/mp4").sha256)
        XCTAssertEqual(try Vault.blobRef(contentsOf: file, type: "video/mp4", edits: VideoMetadata.strippingEdits(info)), ref)
        // The file on disk is untouched.
        XCTAssertEqual(try Data(contentsOf: file), original)
        let entries = try FileManager.default.contentsOfDirectory(atPath: vault.attURL(note).path)
        XCTAssertTrue(entries.allSatisfy { $0.hasSuffix(".video.age") }, "\(entries)")

        let (kept, _) = try vault.writeVideo(note: note, contentsOf: file, keepMetadata: true)
        XCTAssertEqual(kept, BlobRef(content: original, type: "video/mp4"))
        XCTAssertEqual(try vault.readBlob(note: note, kept), original)
    }

    /// One rule for a clip's file extension and media type, whatever the case or parameters (audit leftovers).
    func testClipExtensionAndMediaTypeIgnoreCaseAndParameters() {
        for (type, ext, essence) in [("video/mp4", "mp4", "video/mp4"), ("video/quicktime", "mov", "video/quicktime"),
                                     ("Video/QuickTime", "mov", "video/quicktime"),
                                     ("video/quicktime; codecs=\"avc1\"", "mov", "video/quicktime"),
                                     (" video/MP4 ;x=y", "mp4", "video/mp4"), ("", "mp4", "video/mp4")] {
            XCTAssertEqual(VideoIngestRules.fileExtension(forType: type), ext, type)
            XCTAssertEqual(VideoIngestRules.essence(ofClipType: type), essence, type)
        }
    }
}
