import Foundation
@testable import Sempere
@testable import SempereCapture
import TempDirSupport
import XCTest

// The ack state machine for notes the phone holds (acked / held / released), docs/design/1.1-watch.md §3.6.

extension WatchOutboxTests {
    /// A note the phone only holds stays on the watch (counted against the caps, never resent, never "unsent"), and goes when
    /// the phone releases it as `acked`.
    func testAHeldNoteStaysUntilTheReleaseAndCountsAgainstTheCaps() throws {
        var limits = WatchOutbox.Limits()
        limits.maxFiles = 1
        let (box, dir, clock) = try outbox(limits: limits)
        let meta = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        try box.markTransferring(meta.id)
        XCTAssertEqual(try box.apply(WatchAck(held: [meta.id])), [])
        XCTAssertEqual(box.entry(meta.id)?.state, .held)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.fileURL(meta.id).path), "the only other copy")
        XCTAssertEqual(box.unsentCount, 1)
        XCTAssertEqual(box.awaitingPhoneCount, 0, "held is not unsent")
        XCTAssertThrowsError(try box.canStartRecording(freeBytes: nil), "a held note counts against the cap")
        clock.advance(100 * 24 * 3600)
        XCTAssertTrue(box.due(launch: true).isEmpty, "never sent again on its own")
        // It survives a restart as held.
        XCTAssertEqual(try WatchOutbox(directory: dir, limits: limits, now: { clock.now }).entry(meta.id)?.state, .held)
        // A repeated mark does nothing; the release (acked) drops it.
        XCTAssertEqual(try box.markHeld([meta.id]), [])
        XCTAssertEqual(try box.apply(WatchAck(acked: [meta.id])), [])
        XCTAssertEqual(box.entry(meta.id)?.state, .acked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.fileURL(meta.id).path))
        XCTAssertNoThrow(try box.canStartRecording(freeBytes: nil))
    }

    /// The phone's app was reinstalled: its complete list no longer has the note, so it is sent again; one it lists stays;
    /// a message that is not a complete list changes nothing.
    func testAHeldNoteThePhoneNoLongerListsIsSentAgain() throws {
        let (box, _, _) = try outbox()
        let a = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        let b = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        try box.markHeld([a.id, b.id])
        XCTAssertEqual(try box.apply(WatchAck(held: [b.id])), [], "not complete: nothing is lost")
        XCTAssertEqual(try box.apply(WatchAck(held: [b.id], heldAll: true)), [a.id])
        XCTAssertEqual(box.entry(a.id)?.state, .sealed)
        XCTAssertEqual(box.entry(b.id)?.state, .held)
        XCTAssertEqual(box.due().map(\.id), [a.id], "due at once, no backoff")
        // An empty complete list (a phone that lost everything) re-arms the rest.
        XCTAssertEqual(try box.apply(WatchAck(heldAll: true)), [b.id])
        // An id released in the same message is not re-armed.
        try box.markHeld([a.id])
        XCTAssertEqual(try box.apply(WatchAck(acked: [a.id], heldAll: true)), [])
        XCTAssertEqual(box.entry(a.id)?.state, .acked)
    }

    /// Only `held` notes are re-armed by a complete list; a transferring note the phone lists becomes held.
    func testACompleteListLeavesOtherStatesAlone() throws {
        let (box, _, _) = try outbox()
        let meta = try box.add(try WatchFixture.sealed(), vault: try WatchFixture.profile.vaultId)
        try box.markTransferring(meta.id)
        XCTAssertEqual(try box.apply(WatchAck(heldAll: true)), [])
        XCTAssertEqual(box.entry(meta.id)?.state, .transferring)
        XCTAssertEqual(try box.apply(WatchAck(held: [meta.id], heldAll: true)), [])
        XCTAssertEqual(box.entry(meta.id)?.state, .held)
    }

    /// The wire form: a 1.2 reader needs `acked`/`have` only, and a message of the new keys alone reads as nothing to it.
    func testTheAckDictionaryKeepsTheOldKeys() throws {
        let id = UUID(), other = UUID()
        let ack = WatchAck(acked: [id], have: [other], held: [other], heldAll: true)
        let d = ack.dictionary
        XCTAssertEqual(d["acked"] as? [String], [id.uuidString.lowercased()])
        XCTAssertEqual(d["have"] as? [String], [other.uuidString.lowercased()])
        XCTAssertEqual(WatchAck(dictionary: d), ack)
        // What a 1.2 watch decodes: no `held`, no `heldAll`.
        let old = d.filter { $0.key == "acked" || $0.key == "have" }
        XCTAssertEqual(WatchAck(dictionary: old), WatchAck(acked: [id], have: [other]))
        let onlyNew: [String: Any] = ["held": [id.uuidString.lowercased()], "heldAll": true]
        XCTAssertNil(onlyNew["acked"] ?? onlyNew["have"], "nothing a 1.2 watch would act on")
        XCTAssertEqual(WatchAck(dictionary: onlyNew), WatchAck(held: [id], heldAll: true))
        XCTAssertEqual(WatchAck(heldAll: true).dictionary["heldAll"] as? Bool, true)
        XCTAssertFalse(WatchAck(heldAll: true).isEmpty)
        XCTAssertNil(WatchAck(dictionary: [:]))
    }
}

extension WatchIntakeTests {
    /// A note held on the phone is acknowledged as HELD (the watch keeps its copy), a repeat of it stays held (never a
    /// duplicate, which the watch would drop on), `have` leaves it out and lists it under `held`; once the user adds it the
    /// repeat is a duplicate and `have` has it.
    func testAHeldNoteIsNeverAcknowledgedAsDuplicateAndIsListedAsHeld() throws {
        let r = try rig()
        r.delivery.enabled = false
        let (file, meta, _) = try transfer(r)
        let first = try r.intake.receive(file: file, meta: meta)
        guard case .held(let reason) = first.outcome else { return XCTFail("\(first)") }
        XCTAssertTrue(first.isHeld)
        XCTAssertTrue(first.acknowledged)
        // The watch sends it again (its held ack was lost, or the phone was reinstalled but this one was not).
        let again = try r.intake.receive(file: file, meta: meta)
        XCTAssertEqual(again.outcome, .held(reason), "still held, not a duplicate")
        XCTAssertEqual(try XCTUnwrap(r.intake.held).list().count, 1, "not held twice")
        let have = r.intake.have()
        XCTAssertFalse(have.have.contains(meta.id), "the watch must keep it")
        XCTAssertEqual(have.held, [meta.id])
        XCTAssertTrue(have.heldAll)
        // The user adds it: released. A repeat is now a duplicate (the watch drops on it), and `have` lists it.
        r.delivery.enabled = true
        let item = try XCTUnwrap(r.intake.held?.list().first)
        XCTAssertEqual(try r.intake.addHeld(item), .vault)
        let after = r.intake.have()
        XCTAssertTrue(after.have.contains(meta.id))
        XCTAssertTrue(after.held.isEmpty)
        XCTAssertTrue(after.heldAll, "an empty list is a statement: the phone holds nothing")
        XCTAssertEqual(try r.intake.receive(file: file, meta: meta).outcome, .duplicate)
    }

    /// After a reinstall of the phone's app the held store is gone: the watch's repeat is judged afresh and held again, and
    /// the complete list it gets before that lists nothing, so the watch sends the note.
    func testAReinstalledPhoneHoldsTheRepeatAgain() throws {
        let r = try rig()
        r.delivery.enabled = false
        let (file, meta, _) = try transfer(r)
        XCTAssertTrue(try r.intake.receive(file: file, meta: meta).isHeld)
        // A new install: no held store content, no received set.
        let fresh = WatchIntake(received: WatchReceivedSet(url: nil), delivery: r.delivery,
                                held: WatchHeldStore(root: r.dir.appendingPathComponent("held-new")))
        XCTAssertEqual(fresh.have(), WatchAck(held: [], heldAll: true))
        XCTAssertTrue(try fresh.receive(file: file, meta: meta).isHeld, "held again")
        XCTAssertEqual(fresh.have().held, [meta.id])
    }

    /// A delivery without a held store (the CLI's `--held` absent) lists no held notes and claims no complete list.
    func testNoHeldStoreMeansNoCompleteList() throws {
        let d = FakeDelivery()
        let intake = WatchIntake(received: WatchReceivedSet(url: nil), delivery: d, held: nil)
        XCTAssertFalse(intake.have().heldAll)
    }
}
