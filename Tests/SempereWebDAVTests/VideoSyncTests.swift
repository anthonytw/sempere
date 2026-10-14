import Age
import FuzzSupport
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// A video clip's blob (kind `video`, format.md §8.2.7) through WebDAV sync
/// (B3): a large, sparse synthetic clip goes up and comes down streamed, in
/// bounded memory, with a resumed download; its poster (kind `image`) with it.
final class VideoSyncTests: BlobSyncTestCase {
    static let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures/video")

    func testLargeVideoAndPosterSyncInBoundedMemory() throws {
        let megabytes = Int(ProcessInfo.processInfo.environment["SEMPERE_LARGE_BLOB_MB"] ?? "") ?? 150
        let total = megabytes * 1_000_000
        let storage = tmp.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let server = MockDAV(storage: storage)
        let a = try makeVault("A")
        let source = tmp.appendingPathComponent("lecture.mp4")
        try writeSparseMP4(fastStart: try Data(contentsOf: Self.video.appendingPathComponent("clip-h264-faststart.mp4")),
                           to: source, total: total)
        let (clip, info) = try a.writeVideo(note: noteID, contentsOf: source)
        try FileManager.default.removeItem(at: source)
        let poster = try a.writeBlob(note: noteID, try Data(contentsOf: Self.video.appendingPathComponent("poster.jpg")),
                                     type: "image/jpeg")
        let page = Page(id: UUID(), order: "a0")
        let placed = try NoteOps.placeVideo(blob: clip, info: info, poster: poster, on: page, pageSize: .letter)
        let seq = try a.nextSeq(noteId: noteID, device: devA)
        try a.write(Revision(noteId: noteID, device: devA, seq: seq, hlc: HLC(millis: baseMillis, counter: 0)!,
                             wall: Date(timeIntervalSince1970: Double(baseMillis) / 1000), app: "test/0",
                             body: .delta(ops: [.addPage(page)] + placed.ops)))
        let clipName = try blobFile(a, clip)
        XCTAssertTrue(clipName.hasSuffix(".video.age"))
        XCTAssertTrue(try blobFile(a, poster).hasSuffix(".image.age"))

        let sampler = ResidentSampler()
        let baseline = peakResidentBytes()
        let up = try sync("A", server)
        XCTAssertTrue(up.errors.isEmpty, "\(up)")
        XCTAssertGreaterThan(server.size("notes/\(id)/att/\(clipName)") ?? 0, total)
        // Interrupted halfway down, then resumed.
        let segment = WebDAVClient.defaultSegmentBytes
        server.cutNthGET = (clipName, total / 2 / segment + 1, segment / 2)
        XCTAssertEqual(try sync("B", server).errors.count, 1)
        let down = try sync("B", server)
        XCTAssertTrue(down.errors.isEmpty, "\(down)")
        let growth = peakResidentBytes() - baseline
        let sampled = sampler.stop()
        print("\(megabytes) MB video sync: peak RSS grew by \(growth >> 20) MiB; sampled \(sampled.map { "\($0 >> 20) MiB" } ?? "n/a")")
        XCTAssertLessThan(growth, 64 << 20, "peak RSS grew by \(growth) bytes")
        if let sampled { XCTAssertLessThan(sampled, 64 << 20, "resident set grew by \(sampled) bytes") }

        let b = try openVault("B")
        XCTAssertEqual(Set(attEntries("B")), Set(attEntries("A")))
        let state = try b.reconstruct(noteId: noteID)
        XCTAssertEqual(state.pages[0].items.first?.poster, poster)
        var count: Int64 = 0
        try b.streamBlob(note: noteID, clip) { count += Int64($0.count) }
        XCTAssertEqual(count, Int64(total))
        XCTAssertEqual(try b.readBlob(note: noteID, poster), try Data(contentsOf: Self.video.appendingPathComponent("poster.jpg")))
    }
}
