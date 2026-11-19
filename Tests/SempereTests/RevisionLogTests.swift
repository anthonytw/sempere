import Foundation
import XCTest
@testable import Sempere

/// `RevisionLog` (`sempere notes revisions`): which revision set `deleted`, and a log that does not merge.
final class RevisionLogTests: XCTestCase {
    func testNamesTheRevisionThatSetDeletedAndASnapshotsClock() throws {
        var log = LogBuilder()
        let create = log.delta(devA, 0, [.setMeta(.title("x")), .addTag("t"), .addTag("u")])
        let del = log.delta(devB, 100, [.deleteNote])
        let snap = try log.snapshot(devA, 200, from: [create, del])
        let out = RevisionLog(note: testNote, loaded: LoadedNote(revisions: [snap, del, create], failures: [:]))
        XCTAssertTrue(out.deleted)
        XCTAssertNil(out.problem)
        XCTAssertEqual(out.deletedClock, Stamp(hlc: del.hlc, device: devB).description)
        XCTAssertEqual(out.deletedBy, del.name.filename)
        XCTAssertEqual(out.revisions.map(\.revision), [create, del, snap].map(\.name.filename))
        XCTAssertEqual(out.revisions[0].ops, ["setMeta title", "addTag ×2"])
        XCTAssertEqual(out.revisions[2].deleted, true)
        XCTAssertEqual(out.revisions[2].deletedClock, out.deletedClock)
        // Compacted: only the snapshot's recorded clock carries it.
        let compacted = RevisionLog(note: testNote, loaded: LoadedNote(revisions: [snap], failures: [:]))
        XCTAssertTrue(compacted.deleted)
        XCTAssertNil(compacted.deletedBy)
    }

    /// Two different revisions with one device and seq (two installs sharing a device state file): the note does not
    /// merge, which the app lists as not deleted; the log still lists every revision and says why.
    func testALogThatDoesNotMergeIsListedWithItsProblem() throws {
        var log = LogBuilder()
        let create = log.delta(devA, 0, [.setMeta(.title("x"))])
        let del = log.delta(devA, 100, [.deleteNote])
        let twin = Revision(noteId: testNote, device: devA, seq: del.seq, hlc: HLC(millis: del.hlc.millis + 50, counter: 0)!,
                            wall: del.wall, app: "other install", body: .delta(ops: [.setMeta(.favorite(true))]))
        let out = RevisionLog(note: testNote, loaded: LoadedNote(revisions: [create, del, twin], failures: [:]))
        XCTAssertEqual(out.revisions.count, 3)
        XCTAssertFalse(out.deleted)
        XCTAssertTrue(out.problem?.contains("cannot reconstruct") == true, out.problem ?? "nil")
    }
}
