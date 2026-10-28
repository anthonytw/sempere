import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// A background task's expiry cancels a run between files (`SyncOptions.isCancelled`, P8): the run saves its
/// sync state before it stops, so the next run continues and transfers nothing twice (review of #74, B3).
final class CancelledRunStateTests: SyncTestCase {
    func testACancelledRunSavesItsStateAndTheNextContinues() throws {
        let vault = try makeVault("A")
        for i in 0..<40 { try delta(vault, device: devA, t: Int64(i), title: "note \(i)", note: UUID()) }
        let remote = MemoryRemote(store: MemoryStore(name: "cancel"), base: ["dav", "cancel"])
        let stateURL = tmp.appendingPathComponent("state-A.json")

        // Cancelled once a few notes went up (polled before each request and each note).
        let uploads = Locked(0)
        var options = SyncOptions(deviceLabel: "A")
        options.concurrency = 1
        options.progress = { p in uploads.value = p.notesSynced }
        options.isCancelled = { uploads.value >= 10 }
        let first = try SyncEngine(directory: dir("A"), vault: vault, remote: remote, stateURL: stateURL,
                                   options: options).run()
        XCTAssertNotNil(first.stoppedEarly, "the run stopped early")
        XCTAssertFalse(first.uploaded.isEmpty, "some files went up before the cancel")
        let saved = try XCTUnwrap(try SyncState.load(stateURL), "the state was saved before stopping")
        // The notes the run finished are recorded (state keys are relative to `notes/`); files it uploaded
        // ahead of the cancel (pre-upload) are on the server, where the next run finds them.
        let recorded = Set(saved.files.keys.map { "notes/" + $0 })
        XCTAssertGreaterThanOrEqual(recorded.count, 10, "the notes done before the cancel are recorded")
        XCTAssertTrue(recorded.isSubset(of: Set(first.uploaded)))

        let second = try SyncEngine(directory: dir("A"), vault: vault, remote: remote, stateURL: stateURL,
                                    options: SyncOptions(deviceLabel: "A")).run()
        XCTAssertNil(second.stoppedEarly)
        XCTAssertTrue(second.errors.isEmpty, "\(second.errors)")
        let twice = Set(first.uploaded).intersection(second.uploaded)
            .filter { $0.hasPrefix("notes/") }
        XCTAssertTrue(twice.isEmpty, "uploaded twice: \(twice.sorted().prefix(5))")
        let third = try SyncEngine(directory: dir("A"), vault: vault, remote: remote, stateURL: stateURL,
                                   options: SyncOptions(deviceLabel: "A")).run()
        XCTAssertTrue(third.uploaded.isEmpty && third.downloaded.isEmpty, "in step after the second run")
    }
}
