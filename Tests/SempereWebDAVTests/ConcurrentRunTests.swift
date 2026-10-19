import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Two runs on one sync-state file (the app's push still going when
/// "Download Again" or a reopen starts another) take turns: the second
/// would otherwise take the first's in-flight temporary upload for a
/// leftover and delete it, and the two would overwrite each other's state.
final class ConcurrentRunTests: BlobSyncTestCase {
    func testRunsOnOneStateFileTakeTurns() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(5000), type: "image/png")
        try referencing(a, device: devA, t: 0, [ref])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = Locked(false)
        server.interceptor = { r in
            if r.method == "PUT", r.url.path.contains("/att/.sempere-tmp-"), !blocked.value {
                blocked.value = true
                entered.signal()
                release.wait()
            }
            return nil
        }
        let first = Locked<SyncReport?>(nil), second = Locked<SyncReport?>(nil)
        let done = DispatchGroup()
        // XCTestCase is not Sendable on Linux: the runs call the test case through an unchecked box.
        nonisolated(unsafe) let test = self
        DispatchQueue.global().async(group: done) { first.value = try? test.sync("A", server) }
        XCTAssertEqual(entered.wait(timeout: .now() + 30), .success)
        let before = server.requestLog.count
        DispatchQueue.global().async(group: done) { second.value = try? test.sync("A", server) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(server.requestLog.count, before, "the second run waits for the first")
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(first.value?.errors.isEmpty, true, "\(String(describing: first.value))")
        XCTAssertEqual(second.value?.errors.isEmpty, true, "\(String(describing: second.value))")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [try blobFile(a, ref)])
    }
}
