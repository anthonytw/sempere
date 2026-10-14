import Age
import Foundation
import XCTest
@testable import Sempere

/// Tags as an observed-remove set keyed by tag key (format.md §5.4.1):
/// concurrent adds all survive, a remove only removes the instances it
/// observed (add wins), and spelling is the earliest live instance's.
final class TagMergeTests: VaultTestCase {
    private func tags(_ revisions: [Revision]) throws -> [String] {
        try NoteReducer.reconstruct(revisions).meta.tags
    }

    /// The origin of the `addTag` at `index` in `delta`: what a remover observes.
    private func instance(_ delta: Revision, _ index: Int = 0) -> Origin { Origin(delta.name, op: index) }

    /// Every order of `revisions` gives `expected`, and so does every order
    /// with each revision duplicated (idempotence).
    private func assertEveryOrder(_ revisions: [Revision], _ expected: [String],
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        for order in permutations(revisions) {
            XCTAssertEqual(try tags(order), expected, "\(order.map(\.name.filename))", file: file, line: line)
            XCTAssertEqual(try tags(order + order.reversed()), expected, file: file, line: line)
        }
    }

    private func permutations(_ xs: [Revision]) -> [[Revision]] {
        guard xs.count > 1 else { return [xs] }
        return xs.indices.flatMap { i -> [[Revision]] in
            var rest = xs
            let x = rest.remove(at: i)
            return permutations(rest).map { [x] + $0 }
        }
    }

    // MARK: - Concurrent adds

    /// The bug this rule fixes: the iPad adds "exam" while the Mac adds
    /// "math" to the same note. Both survive, in any order, through snapshots
    /// of either side, and after compaction.
    func testConcurrentAddsOnTwoDevicesBothSurvive() throws {
        var log = LogBuilder()
        let base = log.delta(devA, 0, NoteOps.newNote(title: "Lecture", tags: ["fall"]))
        let ipad = log.delta(devA, 100, [.addTag("exam")])
        let mac = log.delta(devB, 100, [.addTag("math")])
        try assertEveryOrder([base, ipad, mac], ["fall", "exam", "math"])

        // Each device snapshots what it has; any mix of snapshots and deltas agrees.
        let snapIpad = try log.snapshot(devA, 200, from: [base, ipad])
        let snapMac = try log.snapshot(devB, 200, from: [base, mac])
        try assertEveryOrder([snapIpad, mac], ["fall", "exam", "math"])
        try assertEveryOrder([snapIpad, snapMac], ["fall", "exam", "math"])
        try assertEveryOrder([snapMac, base, ipad], ["fall", "exam", "math"])

        // Compaction: a snapshot of everything, then every delta deleted.
        let all = try log.snapshot(devC, 300, from: [snapIpad, snapMac])
        XCTAssertEqual(try tags([all]), ["fall", "exam", "math"])
        XCTAssertEqual(try NoteReducer.reconstruct([all]).tagSet,
                       try NoteReducer.reconstruct([base, ipad, mac]).tagSet)
    }

    /// "Math" on one device and "math" on the other are one tag. Its
    /// spelling is the earliest instance's, on every device.
    func testCaseVariantSpellingsAreOneTagWithTheFirstSpelling() throws {
        var log = LogBuilder()
        let a = log.delta(devA, 100, [.addTag("Math")])
        let b = log.delta(devB, 150, [.addTag("math")])
        try assertEveryOrder([a, b], ["Math"])
        let snapB = try log.snapshot(devB, 200, from: [b])
        try assertEveryOrder([snapB, a], ["Math"])
        // Same HLC: the device id orders them (aaaaaaaa < bbbbbbbb).
        let c = log.delta(devC, 100, [.addTag("MATH")])
        try assertEveryOrder([c, b, a], ["Math"])

        // Removing it by any spelling, observing every instance, removes the key.
        let state = try NoteReducer.reconstruct([a, b, c])
        XCTAssertEqual(state.tagSet.instances(of: "mAtH").count, 3)
        let rm = log.delta(devA, 300, [try XCTUnwrap(NoteOps.removeTag("mAtH", from: state))])
        try assertEveryOrder([a, b, c, rm], [])
    }

    /// A respelling (remove every instance, add the new spelling in one delta)
    /// changes the displayed spelling everywhere.
    func testRespellingReplacesTheSpelling() throws {
        var log = LogBuilder()
        let a = log.delta(devA, 100, [.addTag("math")])
        let state = try NoteReducer.reconstruct([a])
        let ops = NoteOps.setTags(["Math"], on: state)
        XCTAssertEqual(ops, [.removeTag("math", observed: [instance(a)]), .addTag("Math")])
        let respell = log.delta(devB, 200, ops)
        try assertEveryOrder([a, respell], ["Math"])
    }

    // MARK: - Add and remove of the same key

    /// Add wins: a remove only removes what its writer had seen, even when
    /// its clock is later than a concurrent add it had not seen.
    func testConcurrentAddAndRemoveOfTheSameTagAddWins() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 100, [.addTag("exam")])
        // The Mac saw A's add and removes the tag at 300.
        let rm = log.delta(devB, 300, [.removeTag("exam", observed: [instance(add)])])
        // Meanwhile device C, which had not seen either, added "Exam" at 200.
        let concurrent = log.delta(devC, 200, [.addTag("Exam")])
        try assertEveryOrder([add, rm], [])
        try assertEveryOrder([add, rm, concurrent], ["Exam"])

        // Same through snapshots on either side.
        let snapRm = try log.snapshot(devB, 400, from: [add, rm])
        try assertEveryOrder([snapRm, concurrent], ["Exam"])
        let snapAdd = try log.snapshot(devC, 400, from: [concurrent])
        try assertEveryOrder([snapAdd, add, rm], ["Exam"])

        // A later re-add after a remove is a new instance and stays.
        let reAdd = log.delta(devA, 500, [.addTag("exam")])
        try assertEveryOrder([add, rm, reAdd], ["exam"])
    }

    /// A removed instance stays removed: a late copy of its add, a snapshot
    /// that still holds it, or compaction never bring it back.
    func testRemovalIsPermanentThroughSnapshotsAndCompaction() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 100, [.addTag("x"), .addTag("y")])
        let held = try log.snapshot(devC, 150, from: [add])       // saw the add, not the remove
        let rm = log.delta(devB, 200, [.removeTag("X", observed: [instance(add, 0)])])
        try assertEveryOrder([add, held, rm], ["y"])
        let snap = try log.snapshot(devB, 300, from: [add, rm])
        let removed = try XCTUnwrap(NoteReducer.reconstruct([snap]).tagSet.removed)
        XCTAssertEqual(removed, [TagSet.Removal(key: "x", origin: instance(add, 0))])
        // The add's revision arrives again after the remove was compacted away.
        try assertEveryOrder([snap, add], ["y"])
        try assertEveryOrder([snap, held], ["y"])
        // Instances of other keys are never affected, even if listed.
        let wrongKey = log.delta(devC, 400, [.removeTag("z", observed: [instance(add, 1)])])
        try assertEveryOrder([snap, wrongKey], ["y"])
    }

    /// A remove naming an instance whose add has not arrived yet still
    /// removes it once it does (the removal is recorded in snapshots).
    func testRemoveBeforeItsAddArrives() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 100, [.addTag("x")])
        let rm = log.delta(devB, 200, [.removeTag("x", observed: [instance(add)])])
        let snap = try log.snapshot(devB, 300, from: [rm])
        XCTAssertEqual(try tags([snap]), [])
        try assertEveryOrder([snap, add], [])
    }

    // MARK: - Algebra

    /// Applying the same revision sets in different orders, groupings
    /// (snapshots of any subset, by any device) and with duplicates converges.
    func testIdempotentAndCommutativeAcrossSnapshots() throws {
        var log = LogBuilder()
        let r1 = log.delta(devA, 100, [.addTag("a"), .addTag("b")])
        let r2 = log.delta(devB, 150, [.addTag("c"), .addTag("B")])
        let r3 = log.delta(devC, 200, [.removeTag("a", observed: [instance(r1, 0)])])
        let r4 = log.delta(devA, 250, [.removeTag("c", observed: [instance(r2, 0)]), .addTag("d")])
        let r5 = log.delta(devB, 260, [.addTag("C")])
        let all = [r1, r2, r3, r4, r5]
        let reference = try NoteReducer.reconstruct(all)
        XCTAssertEqual(reference.meta.tags, ["b", "d", "C"])   // listed by earliest live instance
        try assertEveryOrder(all, reference.meta.tags)
        // Every split into two snapshots (by different devices) of the two halves.
        for mask in 1..<(1 << all.count) - 1 {
            let left = all.indices.filter { mask & (1 << $0) != 0 }.map { all[$0] }
            let right = all.indices.filter { mask & (1 << $0) == 0 }.map { all[$0] }
            var l = log
            let sl = try l.snapshot(devA, 1000, from: left)
            let sr = try l.snapshot(devB, 1000, from: right)
            let merged = try NoteReducer.reconstruct([sl, sr])
            XCTAssertEqual(merged.meta.tags, reference.meta.tags, "mask \(mask)")
            XCTAssertEqual(merged.tagSet, reference.tagSet, "mask \(mask)")
            XCTAssertEqual(try NoteReducer.reconstruct([sr, sl] + left), merged, "mask \(mask)")
        }
    }

    /// Hardening: a blank or unnormalized `addTag` (a buggy or hostile
    /// writer) never shows an empty tag, and reads normalized everywhere.
    func testBlankAndUnnormalisedAddTagFromAWriter() throws {
        var log = LogBuilder()
        let d = log.delta(devA, 100, [.addTag(""), .addTag("  \t "), .addTag("  Fall\n  Term ")])
        XCTAssertEqual(try tags([d]), ["Fall Term"])
        let snap = try log.snapshot(devB, 200, from: [d])
        XCTAssertEqual(try NoteReducer.reconstruct([snap]).tagSet.instances.map(\.tag), ["Fall Term"])
        XCTAssertEqual(try tags([snap, d]), ["Fall Term"])
    }

    // MARK: - Wire format

    func testOpsAndTagSetRoundTripJSON() throws {
        let o = Origin(hlc: HLC("17596320000000003")!, device: devA, seq: 12, op: 4)
        let base = Origin(hlc: HLC("17596310000000000")!, device: devB, seq: 1, op: 1)
        let ops: [Op] = [.addTag("Math"), .removeTag("math", observed: [o, base])]
        let json = String(decoding: try InkJSON.encoder().encode(ops), as: UTF8.self)
        XCTAssertEqual(json, #"[{"op":"addTag","tag":"Math"},{"observed":["17596320000000003-aaaaaaaa-12-4","#
                       + #""17596310000000000-bbbbbbbb-1-1"],"op":"removeTag","tag":"math"}]"#)
        XCTAssertEqual(try InkJSON.decoder().decode([Op].self, from: Data(json.utf8)), ops)
        XCTAssertThrowsError(try InkJSON.decoder().decode(Op.self, from: Data(
            #"{"op":"removeTag","tag":"x","observed":["nope"]}"#.utf8)))
        // Instance origins name real revisions: seq 0 is malformed.
        XCTAssertThrowsError(try InkJSON.decoder().decode(Op.self, from: Data(
            #"{"op":"removeTag","tag":"x","observed":["17596310000000000-bbbbbbbb-0-1"]}"#.utf8)))
        // Tags are not a setMeta field.
        XCTAssertThrowsError(try InkJSON.decoder().decode(Op.self, from: Data(
            #"{"op":"setMeta","field":"tags","value":["x"]}"#.utf8)))

        let set = TagSet(instances: [.init(tag: "Math", origin: o)], removed: [.init(key: "fall", origin: base)])
        let setJSON = try InkJSON.encoder().encode(set)
        XCTAssertEqual(try InkJSON.decoder().decode(TagSet.self, from: setJSON), set)
        // An empty set is still written: snapshot state requires it.
        let state = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)), tagSet: TagSet())
        let stateJSON = String(decoding: try InkJSON.encoder().encode(state), as: UTF8.self)
        XCTAssertTrue(stateJSON.contains(#""tagSet":{"instances":[],"removed":[]}"#), stateJSON)
        XCTAssertEqual(try InkJSON.decoder().decode(NoteState.self, from: Data(stateJSON.utf8)).tagSet, TagSet())
        let noTagSet = stateJSON.replacingOccurrences(of: #","tagSet":{"instances":[],"removed":[]}"#, with: "")
        XCTAssertNotEqual(noTagSet, stateJSON)
        XCTAssertThrowsError(try InkJSON.decoder().decode(NoteState.self, from: Data(noTagSet.utf8)))
    }

    /// Snapshots keep `meta.tags` readable for stock-CLI recovery; tags have
    /// no register clock.
    func testSnapshotCarriesDerivedTagsForRecovery() throws {
        var log = LogBuilder()
        let a = log.delta(devA, 100, [.addTag("exam"), .addTag("math")])
        let snap = try log.snapshot(devA, 200, from: [a])
        guard case .snapshot(_, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(state.meta.tags, ["exam", "math"])
        XCTAssertNil(state.clocks?["tags"])
        XCTAssertEqual(state.tagSet.instances.map(\.origin), [instance(a, 0), instance(a, 1)])
    }

    // MARK: - Vault

    /// Writers through the vault: new notes add one instance per tag, the
    /// helpers add and remove by key.
    func testVaultWritersUsePerTagOps() throws {
        let vault = try makeVault(pqIdentity())
        let device = tmp.appendingPathComponent("device.json")
        let note = UUID()
        let created = try vault.apply(NoteOps.newNote(title: "T", tags: ["Math", " math ", "Fall   Term"]), to: note,
                                      deviceState: device, app: "t")
        XCTAssertTrue(created.ops.contains { if case .addTag = $0 { return true } else { return false } })
        XCTAssertEqual(try vault.summary(of: note).tags, ["Math", "Fall Term"])
        var state = try vault.reconstruct(noteId: note)
        try vault.apply([try XCTUnwrap(NoteOps.addTag("exam", to: state))], to: note, deviceState: device, app: "t")
        state = try vault.reconstruct(noteId: note)
        try vault.apply([try XCTUnwrap(NoteOps.removeTag("MATH", from: state))], to: note, deviceState: device, app: "t")
        XCTAssertEqual(try vault.summary(of: note).tags, ["Fall Term", "exam"])
        XCTAssertNil(NoteOps.removeTag("math", from: try vault.reconstruct(noteId: note)))
    }
}
