import AVFoundation
import Foundation
import Sempere
import SempereRender
import Testing
import UniformTypeIdentifiers
@testable import SempereApp

/// Video clips in the app (format.md §8.2.7, docs/attachments.md §14 G2):
/// preparing a clip (the shared probe, the privacy setting's metadata
/// removal, a poster taken with AVFoundation, conversion of what the format
/// does not take), adding it through the editor (poster blob, clip blob, one
/// delta), drawing it as its poster under the play mark, fetching only the
/// poster with the page, and playing it from a verified private file (a clip
/// without a poster gets one then). Synthetic clips from
/// `Tests/SempereTests/Fixtures/video` (ffmpeg's test pattern).
@MainActor
@Suite(.serialized)
struct VideoTests {
    static let lecture = AppModelTests.lecture

    /// A work copy of a fixture clip, as a picker or drop would hand over.
    static func clip(_ name: String) throws -> URL {
        let bundle = Bundle(for: VideoBundleToken.self)
        let fixtures = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
        return try VideoPreparation.copyPicked(fixtures.appendingPathComponent("video").appendingPathComponent(name))
    }

    static let location = Data("48.8584".utf8)

    // MARK: Preparation

    @Test func aClipIsProbedGivenAPosterAndLosesItsLocation() async throws {
        let file = try Self.clip("clip-h264.mp4")
        defer { VideoPreparation.discard(file) }
        let prepared = try await VideoPreparation.prepare(file, privacy: true)
        #expect(prepared.info.codec == "h264")
        #expect(prepared.info.mediaType == "video/mp4")
        #expect(prepared.info.pixelSize == Size(w: 160, h: 90))
        #expect(!prepared.edits.isEmpty, "the privacy setting removes the location")
        let poster = try #require(prepared.poster, "AVFoundation took a frame")
        #expect(poster.mediaType == "image/jpeg")
        #expect(poster.pixelSize == Size(w: 160, h: 90))
        // With the setting off nothing is removed.
        let kept = try await VideoPreparation.prepare(file, privacy: false)
        #expect(kept.edits.isEmpty)
    }

    @Test func aRotatedClipHasAnUprightPoster() async throws {
        let file = try Self.clip("clip-h264-rotated.mp4")
        defer { VideoPreparation.discard(file) }
        let prepared = try await VideoPreparation.prepare(file, privacy: true)
        #expect(prepared.info.rotation == 270)
        #expect(prepared.info.pixelSize == Size(w: 90, h: 160))
        let poster = try #require(prepared.poster)
        #expect(poster.pixelSize == Size(w: 90, h: 160), "the track matrix applied")
    }

    @Test func aCodecTheFormatDoesNotTakeIsConverted() async throws {
        let file = try Self.clip("clip-mpeg4.mp4")
        defer { VideoPreparation.discard(file) }
        let prepared = try await VideoPreparation.prepare(file, privacy: true)
        #expect(["h264", "hevc"].contains(prepared.info.codec))
        #expect(prepared.info.mediaType == "video/mp4")
        #expect(prepared.file != file)
        #expect(FileManager.default.fileExists(atPath: prepared.file.path))
    }

    @Test func somethingThatIsNotAVideoIsRefused() async throws {
        let dir = try PDFPreparation.workFolder()
        let file = dir.appendingPathComponent("notes.mp4")
        try Data("not a video at all".utf8).write(to: file)
        defer { VideoPreparation.discard(file) }
        await #expect(throws: (any Error).self) { try await VideoPreparation.prepare(file, privacy: true) }
    }

    // MARK: Into the note

    /// Poster blob, clip blob (metadata gone, streamed), one delta; the item
    /// is placed on screen with the clip's display size.
    @Test func insertingWritesTwoBlobsAndOneDelta() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let file = try Self.clip("clip-h264.mp4")
        let item = try #require(await model.insertVideo(file: file, into: editor,
                                                        visible: CGRect(x: 0, y: 200, width: 612, height: 400), privacy: true))
        await editor.flush()
        #expect(model.errorMessage == nil)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 1)
        #expect(item.kind == .video)
        #expect(item.codec == "h264")
        #expect(item.duration.map { abs($0 - 1) < 0.1 } == true)
        #expect(abs(item.frame.w / item.frame.h - 16.0 / 9) < 0.01, "the clip's aspect")
        let clip = try #require(item.blob)
        #expect(clip.kind == .video)
        let stored = try vault.readBlob(note: Self.lecture, clip)
        #expect(stored.range(of: Self.location) == nil)
        let poster = try #require(item.poster)
        #expect(poster.kind == .image)
        _ = try vault.readBlob(note: Self.lecture, poster)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the work copy is removed")
        // The stored note has it.
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.flatMap(\.items).contains { $0.id == item.id && $0.poster == poster })
        // The unused-attachments index takes the open editor's hashes as the note's current state:
        // the poster is in use, not held by history.
        #expect(editor.blobHashes.contains(poster.sha256))
        #expect(editor.blobHashes == Set(state.blobReferences.map(\.sha256)))
    }

    // MARK: Drawing and fetching

    @Test func aVideoIsDrawnAsItsPosterAndWithoutOneUnderThePlayMark() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let file = try Self.clip("clip-h264.mp4")
        defer { VideoPreparation.discard(file) }
        let prepared = try await VideoPreparation.prepare(file, privacy: true)
        let poster = try #require(prepared.poster)
        let posterRef = try vault.writeBlob(note: Self.lecture, poster.data, type: poster.mediaType)
        let clipRef = try vault.writeBlob(note: Self.lecture, contentsOf: prepared.file, type: prepared.info.mediaType)
        let page = Page(id: UUID(), order: "a0")
        let frame = Rect(x: 0, y: 0, w: 160, h: 90)
        let withPoster = try NoteOps.placeVideo(blob: clipRef, info: prepared.info, poster: posterRef, on: page,
                                                pageSize: .letter, frame: frame).item
        let cache = ItemLayerTests.cache(vault)
        guard case .image(let cg, _) = await ItemRendering.render(ItemRenderKey(withPoster, scale: 1, paper: .blank),
                                                                  note: Self.lecture, cache: cache) else {
            Issue.record("a video with a poster is drawn")
            return
        }
        #expect(cg.width == 160 && cg.height == 90)
        // The play mark's white triangle at the centre.
        let centre = try #require(ImageInsertTests.pixel(cg, x: 80, y: 45))
        #expect(centre.r > 200 && centre.g > 200 && centre.b > 200, "\(centre)")
        // Without a poster: the placeholder with the play mark, drawn (not the canvas's loading frame).
        var bare = withPoster
        bare.poster = nil
        guard case .image = await ItemRendering.render(ItemRenderKey(bare, scale: 1, paper: .blank), note: Self.lecture,
                                                       cache: cache) else {
            Issue.record("a video without a poster is drawn with the play mark")
            return
        }
        // Only the poster comes down with the page; the clip waits until it plays.
        let prefetched = BlobFetchPolicy.prefetch(for: [withPoster])
        #expect(prefetched == [posterRef])
        #expect(!BlobFetchPolicy.fetchesWithPage(.video))
    }

    // MARK: Playing

    @Test func playingReadsTheVerifiedClipAndGivesAPosterlessClipAPoster() async throws {
        let model = try await RecordingTests.model()
        let editor = try #require(model.editor)
        let vault = try #require(model.vault)
        let page = try #require(editor.currentPage).id
        let file = try Self.clip("clip-h264-faststart.mp4")
        defer { VideoPreparation.discard(file) }
        let info = try VideoProbe.probe(file: file)
        let clip = try vault.writeBlob(note: Self.lecture, contentsOf: file, type: info.mediaType)
        let item = try editor.addItems([NoteOps.placeVideo(blob: clip, info: info, on: try #require(editor.currentPage),
                                                           pageSize: editor.pageSize).item], on: page)[0]
        #expect(item.poster == nil)

        let url = try await model.acquireVideo(item, note: Self.lecture)
        #expect(try Data(contentsOf: url) == vault.readBlob(note: Self.lecture, clip))
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        #expect(try await asset.load(.isPlayable), "AVFoundation plays the cached file without an extension")
        await model.addPosterIfMissing(item, page: page, editor: editor, file: url)
        model.releaseVideo(item, note: Self.lecture)
        let updated = try #require(editor.item(item.id, on: page))
        let poster = try #require(updated.poster, "the first play gives it a poster")
        #expect(poster.kind == .image)
        // Once it has one, nothing more is written.
        await editor.flush()
        let before = try vault.loadNote(Self.lecture).revisions.count
        await model.addPosterIfMissing(updated, page: page, editor: editor, file: url)
        await editor.flush()
        #expect(try vault.loadNote(Self.lecture).revisions.count == before)
    }

    @Test func dropsTakeClips() {
        #expect(CanvasDrop.typeIdentifiers.contains(UTType.movie.identifier))
    }
}

private final class VideoBundleToken {}
