import Foundation
@testable import Sempere
@testable import SempereCapture
import TempDirSupport
import XCTest

/// The watch's queue (docs/design/1.1-watch.md §3.3, §3.6).
final class WatchOutboxTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    func outbox(_ clock: Clock = Clock(), limits: WatchOutbox.Limits = .init(), dir: URL? = nil) throws -> (WatchOutbox, URL, Clock) {
        let url = dir ?? makeScratch("outbox")
        return (try WatchOutbox(directory: url, limits: limits, now: { clock.now }), url, clock)
    }

    func testStatesAndPersistenceAcrossARestart() throws {
        let (box, dir, clock) = try outbox()
        let s = try WatchFixture.sealed()
        let vault = try WatchFixture.profile.vaultId
        let meta = try box.add(s, vault: vault)
        XCTAssertEqual(box.entry(meta.id)?.state, .sealed)
        XCTAssertEqual(try box.sealedData(meta.id), s.data)
        XCTAssertEqual(box.due().map(\.id), [meta.id])
        try box.markTransferring(meta.id)
        XCTAssertEqual(box.entry(meta.id)?.state, .transferring)
        XCTAssertEqual(box.entry(meta.id)?.attempts, 1)
        XCTAssertTrue(box.due().isEmpty, "waiting for the ack")

        // A restart: same state.
        let again = try WatchOutbox(directory: dir, now: { clock.now })
        XCTAssertEqual(again.entry(meta.id)?.state, .transferring)
        XCTAssertEqual(again.entry(meta.id)?.meta, meta)
        XCTAssertEqual(again.unsentCount, 1)
        XCTAssertFalse(again.recoveredIndex)
        // Adding it again is a no-op.
        XCTAssertEqual(try again.add(s, vault: vault), meta)
        XCTAssertEqual(again.all.count, 1)
    }

    func testNoDeleteWithoutAnAck() throws {
        let (box, _, clock) = try outbox()
        let meta = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        let file = box.fileURL(meta.id)
        try box.markTransferring(meta.id)
        try box.transferFailed(meta.id)
        clock.advance(100 * 24 * 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "an error, a wait or time never delete")
        XCTAssertEqual(box.unsentCount, 1)
        XCTAssertEqual(try box.acknowledge([meta.id]), [meta.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(box.entry(meta.id)?.state, .acked)
        XCTAssertEqual(box.unsentCount, 0)
        // A re-ack, and an ack of an id it never had, do nothing.
        XCTAssertEqual(try box.acknowledge([meta.id, UUID()]), [])
        XCTAssertEqual(try box.acknowledge(WatchAck(have: [UUID()])), [])
    }

    func testBackoffAndTheResendAfter24Hours() throws {
        let (box, _, clock) = try outbox()
        let meta = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        try box.markTransferring(meta.id)
        try box.transferFailed(meta.id)
        XCTAssertTrue(box.due().isEmpty, "backing off")
        XCTAssertEqual(box.due(launch: true).map(\.id), [meta.id], "every launch retries")
        clock.advance(31)
        XCTAssertEqual(box.due().map(\.id), [meta.id])
        try box.markTransferring(meta.id)
        try box.transferFailed(meta.id)
        clock.advance(31)
        XCTAssertTrue(box.due().isEmpty, "the second failure waits longer")
        clock.advance(40)
        XCTAssertEqual(box.due().count, 1)
        XCTAssertEqual(WatchOutbox.backoff(attempts: 1), 30)
        XCTAssertEqual(WatchOutbox.backoff(attempts: 2), 60)
        XCTAssertEqual(WatchOutbox.backoff(attempts: 50), 3600)

        // No ack for a day: sent again.
        try box.markTransferring(meta.id)
        clock.advance(24 * 3600 - 1)
        XCTAssertTrue(box.due().isEmpty)
        clock.advance(2)
        XCTAssertEqual(box.due().map(\.id), [meta.id])
    }

    func testCapsAndFreeSpaceRefuseOnlyANewRecording() throws {
        var limits = WatchOutbox.Limits()
        limits.maxFiles = 2
        limits.maxBytes = 1 << 20
        let (box, _, _) = try outbox(limits: limits)
        let vault = try WatchFixture.profile.vaultId
        XCTAssertNoThrow(try box.canStartRecording(freeBytes: nil))
        XCTAssertNoThrow(try box.canStartRecording(freeBytes: 2 << 30))
        XCTAssertThrowsError(try box.canStartRecording(freeBytes: 100 << 20)) { XCTAssertEqual($0 as? WatchOutboxError, .lowStorage) }
        try box.add(try WatchFixture.sealed(), vault: vault)
        XCTAssertNoThrow(try box.canStartRecording(freeBytes: nil))
        let second = try box.add(try WatchFixture.sealed(), vault: vault)
        XCTAssertThrowsError(try box.canStartRecording(freeBytes: nil)) { XCTAssertEqual($0 as? WatchOutboxError, .full) }
        // A sealed note is never refused for room.
        XCTAssertNoThrow(try box.add(try WatchFixture.sealed(), vault: vault))
        XCTAssertEqual(box.unsentCount, 3)
        // An ack frees the room.
        try box.acknowledge([second.id])
        try box.acknowledge([box.all[0].id, box.all[2].id])
        XCTAssertNoThrow(try box.canStartRecording(freeBytes: nil))

        // The byte cap.
        var bytes = WatchOutbox.Limits()
        bytes.maxBytes = 100
        let (big, _, _) = try outbox(limits: bytes)
        try big.add(try WatchFixture.sealed(audio: Data(count: 4096)), vault: vault)
        XCTAssertThrowsError(try big.canStartRecording(freeBytes: nil)) { XCTAssertEqual($0 as? WatchOutboxError, .full) }
    }

    func testACorruptIndexKeepsTheFiles() throws {
        let (box, dir, clock) = try outbox()
        let vault = try WatchFixture.profile.vaultId
        let a = try box.add(try WatchFixture.sealed(), vault: vault)
        let b = try box.add(try WatchFixture.sealed(), vault: vault)
        try box.markTransferring(a.id)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent(WatchOutbox.indexName))
        let rebuilt = try WatchOutbox(directory: dir, now: { clock.now })
        XCTAssertTrue(rebuilt.recoveredIndex)
        XCTAssertEqual(Set(rebuilt.unsent.map(\.id)), [a.id, b.id], "both files come back, unsent")
        XCTAssertEqual(rebuilt.entry(a.id)?.meta, a)
        XCTAssertEqual(rebuilt.due().count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("outbox.json.damaged-") })
        for id in [a.id, b.id] { XCTAssertTrue(FileManager.default.fileExists(atPath: rebuilt.fileURL(id).path)) }
        // And the rebuilt index is a good one.
        XCTAssertFalse(try WatchOutbox(directory: dir, now: { clock.now }).recoveredIndex)
    }

    func testAFileTheIndexMissedIsFound() throws {
        // A crash between the file and the index.
        let (box, dir, clock) = try outbox()
        let vault = try WatchFixture.profile.vaultId
        let meta = try box.add(try WatchFixture.sealed(), vault: vault)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(WatchOutbox.indexName))
        let again = try WatchOutbox(directory: dir, now: { clock.now })
        XCTAssertEqual(again.entry(meta.id)?.state, .sealed)
        XCTAssertEqual(again.unsentCount, 1)
    }

    func testAckedEntriesAreForgottenAfterAWhile() throws {
        var limits = WatchOutbox.Limits()
        limits.keepAcked = 1000
        let (box, dir, clock) = try outbox(limits: limits)
        let meta = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        try box.acknowledge([meta.id])
        clock.advance(500)
        XCTAssertNotNil(try WatchOutbox(directory: dir, limits: limits, now: { clock.now }).entry(meta.id))
        clock.advance(600)
        XCTAssertNil(try WatchOutbox(directory: dir, limits: limits, now: { clock.now }).entry(meta.id))
    }

    /// Review blocker B1: a crash after the capture file and before its sidecar, then a sweep sealing the SAME id to new bytes.
    func testASealedFileOfACrashedAddIsReplacedNotKeptUnderOtherMetadata() throws {
        let (box, dir, clock) = try outbox()
        let profile = try WatchFixture.profile
        let id = UUID()
        let a = try WatchFixture.sealed(audio: Data("first".utf8), id: id)
        let b = try WatchFixture.sealed(audio: Data("second, sealed again".utf8), id: id)
        XCTAssertNotEqual(a.data, b.data, "every seal is new bytes")
        // The crash: A's file is there, nothing else.
        try CaptureWriter.store(a, in: dir)
        let reopened = try WatchOutbox(directory: dir, now: { clock.now })
        XCTAssertNil(reopened.entry(id), "a file with no sidecar is not an entry")
        _ = box
        let meta = try reopened.add(b, vault: profile.vaultId)
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL(id)), b.data, "the bytes on disk are B's")
        XCTAssertEqual(meta.sha256, FileDigest.sha256(try Data(contentsOf: reopened.fileURL(id))))
        // And the phone accepts it.
        let intake = try WatchIntakeTests().rig()
        let result = try intake.intake.receive(file: reopened.fileURL(id), meta: meta)
        XCTAssertEqual(result.outcome, .placed(.vault))
    }

    /// A sidecar written for new bytes before a crash can sit beside an older file: it is not recovered as an entry.
    func testASidecarBesideAnOlderFileIsNotRecovered() throws {
        let (box, dir, clock) = try outbox()
        let id = UUID()
        let a = try WatchFixture.sealed(audio: Data("first".utf8), id: id)
        let b = try WatchFixture.sealed(audio: Data("second".utf8), id: id)
        try CaptureWriter.store(a, in: dir)
        let metaB = try WatchTransferMeta(sealed: b, vault: try WatchFixture.profile.vaultId)
        let enc = JSONEncoder()
        try enc.encode(metaB).write(to: dir.appendingPathComponent("\(id.uuidString.lowercased()).meta.json"))
        _ = box
        XCTAssertNil(try WatchOutbox(directory: dir, now: { clock.now }).entry(id))
    }

    /// Review N6: the acked state reaches the disk before the files go; a crash in between leaves files the next load deletes.
    func testAnAckIsSavedBeforeTheFilesGo() throws {
        let (box, dir, clock) = try outbox()
        let meta = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        let file = box.fileURL(meta.id)
        let held = try Data(contentsOf: file)
        try box.acknowledge([meta.id])
        // The crash: the index says acked, the file is still there.
        try held.write(to: file)
        let again = try WatchOutbox(directory: dir, now: { clock.now })
        XCTAssertEqual(again.entry(meta.id)?.state, .acked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "an acked entry's files go at load")
        XCTAssertEqual(again.unsentCount, 0)
    }
}
