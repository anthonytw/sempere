import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Review of PR #165 (W1): progress must stay monotone and within its total when
/// a run resumes partial blobs and the server answers the resumed GET with 200
/// (it ignores `Range`), and a canceled run must not count unfinished downloads as done.
extension ConcurrentTransferTests {
    func testReviewProgressMonotoneWhenResumeGets200() throws {
        let server = MockDAV()
        try serverVault(server, blobs: 2, blobSize: 200_000)
        slowDown(server, InFlight(), millis: 2)
        let stop = Recorder<Bool>()
        let first = try pull("B", server) {
            $0.concurrency = 6
            $0.blobSegmentBytes = 16_384
            $0.progress = { p in if p.stage == .downloading && p.bytesDone > p.bytesTotal / 3 { stop.append(true) } }
            $0.isCancelled = { !stop.all.isEmpty }
        }
        XCTAssertEqual(first.stoppedEarly, "sync run canceled")
        XCTAssertFalse(partials("B").isEmpty, "precondition: partial blobs to resume")
        let placed = first.downloaded.filter { $0.hasPrefix("notes/") }.count
        let fp = try XCTUnwrap(first.progress)
        XCTAssertEqual(fp.filesDone, placed, "a cancelled run's filesDone counts only files that finished")

        server.honoursRange = false
        let seen = Recorder<WebDAVSyncProgress>()
        let second = try pull("B", server) {
            $0.concurrency = 6
            $0.blobSegmentBytes = 16_384
            $0.progress = { seen.append($0) }
        }
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        let bytes = seen.all.filter { $0.stage == .downloading }.map(\.bytesDone)
        XCTAssertEqual(bytes, bytes.sorted(), "bytes done never goes back")
        XCTAssertTrue(seen.all.allSatisfy { $0.stage == .listing || $0.bytesDone <= $0.bytesTotal },
                      "max overshoot: \(seen.all.map { $0.bytesDone - $0.bytesTotal }.max() ?? 0)")
    }
}
