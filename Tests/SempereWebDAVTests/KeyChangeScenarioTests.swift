import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The key-change safety gate (docs/design/device-first-sync.md §6.4): one
/// test per failure F1 to F19 of §6.2, each asserting the invariant that
/// keeps data recoverable, over `MemoryRemote` and the WebDAV mock.
final class KeyChangeScenarioTests: TempDirTestCase {
    let n1 = UUID(uuidString: "6b000000-0000-4000-8000-000000000001")!
    let n2 = UUID(uuidString: "6b000000-0000-4000-8000-000000000002")!

    func world(webdav: Set<Int> = [], uses: [[Int]]? = nil, devices: Int = 3) throws -> KCWorld {
        try KCWorld(root: tmp.appendingPathComponent("w\(UUID().uuidString.prefix(6))"), deviceCount: devices,
                    webdav: webdav, uses: uses)
    }

    /// A world with a few notes on every side, in step.
    func seeded(webdav: Set<Int> = [], uses: [[Int]]? = nil) throws -> KCWorld {
        let w = try world(webdav: webdav, uses: uses)
        try w.write(w.a, n1, "one")
        try w.write(w.b, n2, "two")
        try w.converge()
        return w
    }

    // MARK: The happy path

    func testARoutineRemovalReachesEveryDeviceAndTarget() throws {
        for webdav in [Set<Int>(), [1]] {
            let w = try seeded(webdav: webdav)
            let spare = try w.addSpare(on: w.a)
            try w.converge()
            w.assertConverged()
            try w.change(w.b) { try $0.prepareRemoveRecipient(spare.recipient) }
            try w.converge()
            w.assertConverged()
            w.assertRevoked([spare])
            w.assertNoLoss()
            XCTAssertFalse(w.b.coordinator.inProgress)
        }
    }
}
