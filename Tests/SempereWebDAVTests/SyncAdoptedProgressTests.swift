import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// A file the server already holds, byte for byte, is recorded as in step without being sent (an earlier, interrupted run sent it): the
/// run's progress counts it as `adopted`, so the app's "Uploading X of M" can count it done (the app counts M from what the target
/// had not confirmed).
final class SyncAdoptedProgressTests: SyncTestCase {
    func testFilesTheServerHeldAlreadyAreAdoptedNotUploaded() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        _ = try delta(a, device: devA, t: 5, title: "two")
        try sync("A", server)
        // This device lost its record of the run (an interrupted one never saved it): the server holds the same files.
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("state-A.json"))
        let seen = Seen()
        let engine = SyncEngine(directory: dir("A"), vault: try openVault("A"), client: try client(server),
                                stateURL: tmp.appendingPathComponent("state-A.json"),
                                options: {
                                    var o = SyncOptions(deviceLabel: "A")
                                    o.progress = { p in seen.set(p) }
                                    return o
                                }())
        let report = try engine.run()
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        let last = try XCTUnwrap(seen.last)
        XCTAssertEqual(last.adopted, 2, "both revisions were found in step, not sent: \(last)")
        XCTAssertEqual(last.uploaded, 0)
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var p: SyncProgress?
        var last: SyncProgress? { lock.withLock { p } }
        func set(_ x: SyncProgress) { lock.withLock { p = x } }
    }
}
