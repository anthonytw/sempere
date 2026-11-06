import Foundation
import XCTest
@testable import Sempere

/// The one revision writer (format.md §5): `Vault.apply` (the CLI, tests and package callers, a device
/// state file per call) and `NoteWriter` with a `DeviceClock` (the app, one clock per state file for the
/// process) stamp, number and place deltas the same way.
final class RevisionWriterTests: VaultTestCase {
    var stateURL: URL { tmp.appendingPathComponent("state/device.json") }

    /// A file that cannot be read at all (here: over the revision size limit, as a file still being
    /// downloaded or replaced would fail) is observed by its name, capped at the wall clock (format.md §5
    /// "What a writer observes"), so a delta written after it sorts after it. Regression: `Vault.apply`
    /// observed only the revisions that read, so its delta sorted BEFORE such a file and lost every
    /// last-writer-wins race against it, while the app's `NoteWriter` ordered it after.
    func testApplyObservesAFileThatCannotBeRead() throws {
        let vault = try makeVault(pqIdentity())
        let other = tmp.appendingPathComponent("other/device.json")
        try vault.apply(NoteOps.newNote(title: "Shared"), to: testNote, deviceState: other, app: "other")
        let wall = Date().addingTimeInterval(60)   // both writes below at this wall clock
        let w = HybridClock.wallMillis(wall)
        let stuck = RevisionName(hlc: HLC(millis: w, counter: 50)!, device: devB, seq: 1, kind: .delta)
        let handle = try FileHandle(forWritingTo: { () -> URL in
            let url = fileURL(vault, testNote, stuck)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            return url
        }())
        try handle.truncate(atOffset: UInt64(BoundedRead.maxRevisionBytes) + 1)   // sparse: no disk used
        try handle.close()
        guard case .unreadable? = try vault.loadNote(testNote).failures[stuck] else {
            return XCTFail("the planted file should be unreadable: \(try vault.loadNote(testNote).failures)")
        }
        let written = try vault.apply([.setMeta(.title("after"))], to: testNote, deviceState: stateURL, app: "t",
                                      wall: wall)
        XCTAssertGreaterThan(written.hlc, stuck.hlc)
    }

    /// A private copy of the bundled fixture (the lecture note: 4 deltas and 1 snapshot).
    func fixture() throws -> Vault {
        let copy = tmp.appendingPathComponent("sample-\(UUID().uuidString).sempere")
        try FileManager.default.copyItem(at: FixtureTests.bundled("sample.sempere"), to: copy)
        let id = try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
        return try Vault.open(at: copy, identities: [id])
    }

    func clock(_ url: URL? = nil) throws -> DeviceClock {
        try DeviceClock(url: url ?? stateURL, app: "test")
    }

    /// A clock body that writes revisions and then fails keeps its ticks (an import that stops half way):
    /// otherwise the next reading could repeat or sort before one already on disk. Regression: the app's
    /// `DeviceClock.withClock(save: true)` forgot the clock when the body threw (the CLI's import kept it).
    func testWithClockKeepsTicksWhenTheBodyThrows() async throws {
        struct Stop: Error {}
        let ahead = Date().addingTimeInterval(3600)
        let clock = try clock()
        var inside: HLC?
        do {
            inside = try await clock.withClock(save: true) { c -> HLC in
                _ = c.tick(wall: ahead)
                throw Stop()
            }
        } catch is Stop {}
        XCTAssertNil(inside)
        let next = try await clock.tick()
        XCTAssertGreaterThan(next.millis, HybridClock.wallMillis(ahead) - 1)
        // And on disk, for the next launch.
        XCTAssertGreaterThanOrEqual(try DeviceState.loadOrCreate(at: stateURL).millis, HybridClock.wallMillis(ahead))
        // Without `save` (a dry run) nothing is kept.
        let before = try DeviceState.loadOrCreate(at: stateURL)
        _ = try await clock.withClock(save: false) { c in c.tick(wall: ahead.addingTimeInterval(3600)) }
        XCTAssertEqual(try DeviceState.loadOrCreate(at: stateURL), before)
    }

    /// The same state file written by both holders in turn (the app's clock, then `Vault.apply`, then the
    /// app relaunched): one device id, readings strictly increasing, `seq` 1, 2, 3 with no gap, one
    /// revision file per call.
    func testBothHoldersShareOneMonotonicClockAndSeq() async throws {
        let vault = try makeVault(pqIdentity())
        var names: [RevisionName] = []
        do {
            let clock = try clock()
            names.append(try await NoteWriter.append(NoteOps.newNote(title: "One"), to: testNote, vault: vault, clock: clock))
        }   // the app's clock goes (a quit)
        names.append(try vault.apply([.setMeta(.title("Two"))], to: testNote, deviceState: stateURL, app: "cli").name)
        let relaunched = try clock()
        names.append(try await NoteWriter.append([.setMeta(.title("Three"))], to: testNote, vault: vault, clock: relaunched))
        XCTAssertEqual(names.map(\.seq), [1, 2, 3])
        XCTAssertEqual(Set(names.map(\.device)), [relaunched.device])
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(try vault.revisionNames(of: testNote).sorted(), names)
        XCTAssertEqual(try vault.reconstruct(noteId: testNote).meta.title, "Three")
    }

    /// While a `DeviceClock` holds a state file, `Vault.apply` on that file is refused (one clock per state
    /// file: the actor keeps the clock in memory and would save over what a second one ticked).
    func testApplyRefusesAStateFileADeviceClockHolds() async throws {
        let vault = try makeVault(pqIdentity())
        do {
            let clock = try clock()
            XCTAssertThrowsError(try vault.apply(NoteOps.newNote(title: "x"), to: testNote, deviceState: stateURL, app: "t")) {
                guard case VaultError.io = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertTrue(try vault.revisionNames(of: testNote).isEmpty)
            _ = clock.device
        }
        XCTAssertNoThrow(try vault.apply(NoteOps.newNote(title: "x"), to: testNote, deviceState: stateURL, app: "t"))
    }

    /// An editor's writer whose `seq` another writer of this device took meanwhile (a browser edit through
    /// the same clock) re-reads `seq` and retries once: no reuse, no gap, and the retried delta sorts
    /// after the one that took its `seq`. One revision file per call.
    func testATakenSeqIsReReadAndTheWriteRetriedOnce() async throws {
        let vault = try makeVault(pqIdentity())
        let clock = try clock()
        let editor = NoteWriter(vault: vault, noteID: testNote, clock: clock, nextSeq: 1, session: "s1")
        let first = try await editor.write(NoteOps.newNote(title: "Ed"))
        let browser = try await NoteWriter.append([.setMeta(.favorite(true))], to: testNote, vault: vault, clock: clock)
        XCTAssertEqual(browser.seq, 2)
        let retried = try await editor.write([.setMeta(.title("Ed 2"))])   // its next seq was 2
        XCTAssertEqual([first.seq, browser.seq, retried.seq], [1, 2, 3])
        XCTAssertGreaterThan(retried, browser)
        let again = try await editor.write([.setMeta(.title("Ed 3"))])
        XCTAssertEqual(again.seq, 4)
        let revs = try vault.loadNote(testNote).revisions
        XCTAssertEqual(revs.count, 4)
        XCTAssertEqual(revs.filter { $0.session == "s1" }.map(\.seq).sorted(), [1, 3, 4])
    }

    /// A plain append (browser ops, Save Version) decrypts each revision once (headers checked, no
    /// stroke geometry); its revision sorts after every listed name and takes the next free `seq`.
    /// (Moved from the app's `WriterReadCostTests`.)
    func testAppendReadsEachRevisionOnce() async throws {
        let vault = try fixture()
        let note = SampleFixture.lecture
        let names = try vault.revisionNames(of: note)
        let clock = try clock()
        let before = vault.revisionDecryptCount
        let written = try await NoteWriter.append([], to: note, vault: vault, clock: clock, checkpoint: Checkpoint(name: "v"))
        XCTAssertEqual(vault.revisionDecryptCount - before, names.count)
        XCTAssertTrue(names.allSatisfy { $0 < written })
        XCTAssertEqual(written.seq, 1)   // a new device
        let again = try await NoteWriter.append([.setMeta(.title("T"))], to: note, vault: vault, clock: clock)
        XCTAssertTrue(again.seq == 2 && written < again)
        XCTAssertEqual(try vault.reconstruct(noteId: note).meta.title, "T")
    }

    /// A metadata edit reads the note without stroke points and writes what the full read would; a
    /// builder that returns content ops anyway is run again on the full note (CLAUDE.md: ops built from
    /// a state without stroke points are never written). (Moved from the app's `WriterReadCostTests`.)
    func testMetadataBuilderReadsWithoutPointsAndFallsBackForContentOps() async throws {
        let vault = try fixture()
        let note = SampleFixture.lecture
        let n = try vault.revisionNames(of: note).count
        let clock = try clock()
        var before = vault.revisionDecryptCount
        let tagged = try await NoteWriter.append(to: note, vault: vault, clock: clock, detail: .withoutStrokePoints) {
            $0.flatMap { NoteOps.addTag("perf", to: $0) }.map { [$0] } ?? []
        }
        XCTAssertNotNil(tagged)
        XCTAssertEqual(vault.revisionDecryptCount - before, n)   // every revision once; seq from them, no second read
        XCTAssertTrue(try vault.reconstruct(noteId: note).meta.tags.contains("perf"))

        let full = try vault.reconstruct(noteId: note)
        let m = try vault.revisionNames(of: note).count
        before = vault.revisionDecryptCount
        let page = try XCTUnwrap(full.pages.first { !$0.strokes.isEmpty })
        let stroke = try XCTUnwrap(page.strokes.first)
        let builtFromFull = Flag()
        let removed = try await NoteWriter.append(to: note, vault: vault, clock: clock, detail: .withoutStrokePoints) { state in
            // Not a metadata op: must not be built from a state without points.
            guard let s = state?.pages.first(where: { $0.id == page.id })?.strokes.first(where: { $0.id == stroke.id }) else { return [] }
            if s.points == stroke.points { builtFromFull.set() }
            return [.removeStroke(page: page.id, strokeId: s.id)]
        }
        XCTAssertNotNil(removed)
        XCTAssertTrue(builtFromFull.isSet, "the written ops came from the full read")
        XCTAssertEqual(vault.revisionDecryptCount - before, 2 * m)   // read without points, refused, read again in full
        XCTAssertFalse(try vault.reconstruct(noteId: note).pages.flatMap(\.strokes).contains { $0.id == stroke.id })
    }

    /// A vault that has seen content of a newer version (§7.3) refuses every write of both fronts, and
    /// the writer's own read is what sees it: nothing is placed.
    func testBothFrontsRefuseAReadOnlyVault() async throws {
        let id = pqIdentity()
        let made = try makeVault(id)
        let other = tmp.appendingPathComponent("other/device.json")
        try made.apply(NoteOps.newNote(title: "Plain"), to: testNote, deviceState: other, app: "t")
        var d = NewerFixture.envelope(testNote, NewerFixture.devN, 1, NewerFormatTests.future, "delta")
        d["ops"] = [["op": "teleport"]]
        try NewerFixture.writeRaw(made, d, note: testNote,
                                  name: NewerFixture.name(NewerFixture.devN, 1, NewerFormatTests.future, .delta))
        let count = try made.revisionNames(of: testNote).count
        let app = try Vault.open(at: made.url, identities: [id])
        XCTAssertFalse(app.isReadOnly)
        let clock = try clock()
        do {
            _ = try await NoteWriter.append([.setMeta(.title("x"))], to: testNote, vault: app, clock: clock)
            XCTFail("written to a read-only vault")
        } catch VaultError.readOnly {}
        let cli = try Vault.open(at: made.url, identities: [id])
        XCTAssertThrowsError(try cli.apply([.setMeta(.title("x"))], to: testNote, deviceState: other, app: "t")) {
            guard case VaultError.readOnly = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try made.revisionNames(of: testNote).count, count)
    }

    /// Every delta is in the device's write ledger before it is placed (format.md §15.14): a write stopped
    /// right after the ledger's intent leaves the entry and no file, through either front.
    func testTheLedgerEntryComesBeforeThePlacement() async throws {
        let w = try EpochWorld(in: tmp, names: ["A"])
        var vault = try w.open("A")
        let note = try w["A"].newNote(vault, "one")
        let files = try vault.revisionNames(of: note).count
        let entries = try w["A"].ledger.entries().count
        vault.faults = EpochFaults(stop: .afterLedgerIntent)
        let clock = try clock()
        do {
            _ = try await NoteWriter.append([.setMeta(.title("two"))], to: note, vault: vault, clock: clock)
            XCTFail("the stop was not reached")
        } catch {}
        XCTAssertEqual(try w["A"].ledger.entries().count, entries + 1)
        XCTAssertEqual(try vault.revisionNames(of: note).count, files)
        XCTAssertThrowsError(try vault.apply([.setMeta(.title("three"))], to: note,
                                             deviceState: tmp.appendingPathComponent("cli/device.json"), app: "t"))
        XCTAssertEqual(try w["A"].ledger.entries().count, entries + 2)
        XCTAssertEqual(try vault.revisionNames(of: note).count, files)
    }

    /// A relaunch (a new clock on the same file) keeps the device id and never repeats a reading.
    /// (Moved from the app's `NoteEditorTests`.)
    func testClockAndDeviceLiveInTheStateFile() async throws {
        let first: HLC, device: DeviceID
        do {
            let a = try clock()
            first = try await a.tick()
            device = a.device
        }
        let b = try clock()   // a relaunch
        XCTAssertEqual(b.device, device)
        let second = try await b.tick()
        XCTAssertGreaterThan(second, first)
    }
}

/// A flag a `@Sendable` builder sets (it runs off the test's task).
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
}
