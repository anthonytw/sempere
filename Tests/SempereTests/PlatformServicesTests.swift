import Foundation
@testable import Sempere
import TempDirSupport
import XCTest

/// The memory and no-op versions of the platform protocols (docs/design/thin-app.md "Rules"): what library code
/// gets in tests, in the CLI and on Linux. They must behave as the app's implementations do where the library
/// relies on it (`UserDefaults`' conversions, a released observation stops, nil means uncoordinated).
final class PlatformServicesTests: TempDirTestCase {
    // MARK: KeyValueStore

    func testMemoryStoreConvertsLikeUserDefaults() {
        let store = MemoryKeyValueStore(["flag": true, "count": 3, "ratio": 0.5, "name": "x", "blob": Data([1])])
        XCTAssertTrue(store.bool(forKey: "flag"))
        XCTAssertEqual(store.integer(forKey: "flag"), 1)
        XCTAssertEqual(store.integer(forKey: "count"), 3)
        XCTAssertEqual(store.double(forKey: "count"), 3)
        XCTAssertEqual(store.double(forKey: "ratio"), 0.5)
        XCTAssertEqual(store.string(forKey: "name"), "x")
        XCTAssertEqual(store.data(forKey: "blob"), Data([1]))
        XCTAssertFalse(store.bool(forKey: "never set"), "unset reads as false, as UserDefaults does")
        XCTAssertEqual(store.integer(forKey: "never set"), 0)
        XCTAssertNil(store.object(forKey: "never set"))
        store.removeObject(forKey: "flag")
        XCTAssertNil(store.object(forKey: "flag"))
    }

    func testObservationsSeeChangesUntilReleased() {
        let store = MemoryKeyValueStore()
        let seen = ChangeCounter()
        var observation: KeyValueObservation? = store.observeChanges { seen.add() }
        store.set(true, forKey: "a")
        store.removeObject(forKey: "a")
        XCTAssertEqual(seen.value, 2)
        observation = nil
        store.set(true, forKey: "a")
        XCTAssertEqual(seen.value, 2, "a released observation hears nothing")
        XCTAssertNil(observation)

        let kept = store.observeChanges { seen.add() }
        kept.cancel()
        kept.cancel()
        store.set(false, forKey: "a")
        XCTAssertEqual(seen.value, 2, "a cancelled observation hears nothing")
    }

    // MARK: PerfSink

    func testMemoryPerfSinkKeepsReportsInOrder() throws {
        let sink = MemoryPerfSink()
        let value = sink.measure("writer.read", "load") { 7 }
        sink.event("change.notified", "1")
        sink.log(.notice, "bundleBit", "cleared")
        XCTAssertEqual(value, 7)
        XCTAssertEqual(sink.records, [.measured(phase: "writer.read", detail: "load"),
                                      .event(phase: "change.notified", detail: "1"),
                                      .log(.notice, category: "bundleBit", message: "cleared")])
        struct Failure: Error {}
        XCTAssertThrowsError(try sink.measure("thin", "") { throw Failure() })
        XCTAssertEqual(sink.records.last, .measured(phase: "thin", detail: ""), "a phase that throws is still reported")
        XCTAssertEqual(NoPerfSink().measure("thin", "") { 1 }, 1)
    }

    // MARK: FolderBookmarks

    func testPathBookmarksRoundTripAndRefuseOthers() throws {
        let folder = tmp.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmarks = PathBookmarks()
        let resolved = try bookmarks.resolve(try bookmarks.bookmark(for: folder))
        XCTAssertEqual(resolved.url.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertFalse(resolved.isStale)
        XCTAssertThrowsError(try bookmarks.resolve(Data("not a bookmark".utf8))) {
            XCTAssertEqual($0 as? FolderBookmarkError, .unresolvable)
        }
        let gone = try bookmarks.bookmark(for: tmp.appendingPathComponent("Gone"))
        XCTAssertThrowsError(try bookmarks.resolve(gone, mounting: false)) {
            XCTAssertEqual($0 as? FolderBookmarkError, .unresolvable)
        }
        XCTAssertEqual(bookmarks.withAccess(to: folder) { 5 }, 5)
    }

    // MARK: FileCoordinating

    func testUncoordinatedFilesRunTheBodyAndPassItsError() {
        let files = UncoordinatedFiles()
        XCTAssertEqual(try files.coordinatedRead(tmp) { 1 }, 1)
        XCTAssertEqual(try files.coordinatedRead(nil) { 2 }, 2)
        XCTAssertEqual(try files.coordinatedWrite(tmp.appendingPathComponent("new")) { 3 }, 3)
        XCTAssertThrowsError(try files.coordinatedWrite(tmp) { throw VaultError.locked }) {
            XCTAssertEqual($0 as? VaultError, .locked)
        }
    }

    // MARK: PlatformServices

    @MainActor
    func testHeadlessPlatformRecordsWhatItWasAsked() {
        let platform = HeadlessPlatform(isPhone: true)
        XCTAssertFalse(platform.isMac)
        XCTAssertTrue(platform.isPhone)
        XCTAssertNil(platform.idleTimerDisabled)
        platform.setIdleTimerDisabled(true)
        platform.setIdleTimerDisabled(false)
        platform.play(.selection)
        XCTAssertEqual(platform.idleTimerSettings, [true, false])
        XCTAssertEqual(platform.played, [.selection])
        let mac = HeadlessPlatform(isMac: true)
        mac.play(.selection)
        XCTAssertEqual(mac.played, [], "a Mac has no haptics")
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
