import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Servers whose version tags follow the modification time in whole seconds (wsgidav, nginx's and lighttpd's
/// WebDAV, any server without ETags, whose stamp is `Last-Modified`): a file rewritten in place with the same size
/// within one second keeps its tag. An accepted copy replacing an unaccepted one (key-hierarchy design §5.4 step 4,
/// a writer's catch-up) is exactly such a rewrite: same body, same recipients, same size. A device that refused
/// the earlier copy must still read the replacement (J1), never skip it as "unchanged on the server".
final class SecondStampTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    override func tearDown() {
        SyncEngine.stampClock = { Date() }
        SyncEngine.stampUptime = { ProcessInfo.processInfo.systemUptime }
        super.tearDown()
    }

    /// A world of A (home), D and X on one target over the WebDAV mock whose ETags keep the second; the server's
    /// clock stands still unless a test moves it.
    private func world(server second: Locked<Int>) throws -> (EpochSyncWorld, EpochTarget, MockDAV) {
        var server: MockDAV?
        let t = try TransportUnderTest.mockDAV { s in
            s.secondETagClock = { second.value }
            server = s
        }
        let target = EpochTarget.over(t, name: "T1", seed: 1, faults: { 0 })
        let w = try EpochSyncWorld(in: tmp, names: ["A", "D", "X"], made: [target])
        return (w, target, try XCTUnwrap(server))
    }

    /// D writes while A removes X without pulling first: D's file reaches the target under the old key, A sets it
    /// aside on its first download (not sealed), D catches up and replaces the target's copy within the same second.
    private func unsealedThenReplaced(_ w: EpochSyncWorld, _ t: EpochTarget) throws -> (note: UUID, file: String) {
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        let note = try w["D"].write("D, before it saw the change")
        try w["D"].sync(t)
        let path = "notes/\(note.uuidString.lowercased())/"
        let file = try XCTUnwrap(t.paths.first { $0.hasPrefix(path) })
        let unsealed = try XCTUnwrap(t.file(file))
        let stampBefore = try XCTUnwrap(t.inspector?.stat(file.split(separator: "/").map(String.init)))?.etag

        let a1 = try w["A"].sync(t)
        XCTAssertTrue(a1.setAside.contains { $0.path == file }, "not sealed: set aside on A (\(a1))")
        XCTAssertNil(try w["A"].titles()[note])

        let d = try w["D"].sync(t)
        XCTAssertEqual(d.epoch?.taken, 2, "\(d)")
        XCTAssertTrue(d.replaced.contains(.init(side: "remote", path: file)), "\(d)")
        XCTAssertNotEqual(t.file(file), unsealed)
        // The precondition of the failure: the target shows the replacement under the tag the refused copy had.
        XCTAssertEqual(try t.inspector?.stat(file.split(separator: "/").map(String.init))?.etag, stampBefore,
                       "a same-size rewrite within the second keeps the tag")
        return (note, file)
    }

    /// The failure of the leaning interleavings over wsgidav (`EPOCH-INTERLEAVING`, J1 "A does not read D-8"),
    /// made deterministic: A's record of the set-aside copy, keyed by the target's tag, kept it from ever
    /// downloading the accepted copy.
    func testACopyReplacedWithinTheSecondOfItsRefusalIsReadAgain() throws {
        let second = Locked(1_900_000_000)
        let (w, t, _) = try world(server: second)
        let (note, _) = try unsealedThenReplaced(w, t)
        let a2 = try w["A"].sync(t)
        XCTAssertEqual(try w["A"].titles()[note], "D, before it saw the change", "J1: \(a2)")
        // Quiet afterwards.
        XCTAssertTrue(try w["A"].sync(t).downloaded.isEmpty)
    }

    /// The skip stays for what it was made for: a refused copy the target keeps is downloaded again only until a
    /// read made after the target's clock moved on found it unchanged (its tag then changes with any later rewrite).
    func testARefusedCopyIsSkippedOnceSettled() throws {
        let second = Locked(1_900_000_000)
        let now = Locked(Date(timeIntervalSince1970: 1_900_000_000))
        let up = Locked(TimeInterval(1_000))
        SyncEngine.stampClock = { now.value }
        SyncEngine.stampUptime = { up.value }
        let (w, t, server) = try world(server: second)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        let note = try w["D"].write("D, before it saw the change")
        try w["D"].sync(t)
        let file = try XCTUnwrap(t.paths.first { $0.hasPrefix("notes/\(note.uuidString.lowercased())/") })
        let name = String(file.split(separator: "/").last ?? "")
        func reads(_ run: () throws -> SyncReport) throws -> (SyncReport, Int) {
            let before = server.requests.filter { $0.method == "GET" && $0.path.hasSuffix(name) }.count
            let r = try run()
            return (r, server.requests.filter { $0.method == "GET" && $0.path.hasSuffix(name) }.count - before)
        }

        let (first, read1) = try reads { try w["A"].sync(t) }
        XCTAssertTrue(first.setAside.contains { $0.path == file }, "\(first)")
        XCTAssertEqual(read1, 1)
        // Within the settling time: read again (the copy may have been replaced under the same tag), and reported as
        // skipped (the same bytes), not set aside twice.
        let (again, read2) = try reads { try w["A"].sync(t) }
        XCTAssertEqual(read2, 1, "\(again)")
        XCTAssertTrue(again.setAside.isEmpty, "\(again)")
        XCTAssertTrue(again.skipped.contains { $0.path == file }, "\(again)")
        XCTAssertEqual(w["A"].setAside.items(vaultId: w.vaultId).filter { $0.path == file }.count, 1)
        // Later (both clocks moved on): read once more, found unchanged, and from then on skipped without a read.
        now.value += SyncEngine.stampSettleInterval + 1
        up.value += SyncEngine.stampSettleInterval + 1
        second.value += Int(SyncEngine.stampSettleInterval) + 1
        let (settling, read3) = try reads { try w["A"].sync(t) }
        XCTAssertEqual(read3, 1, "\(settling)")
        let (settled, read4) = try reads { try w["A"].sync(t) }
        XCTAssertEqual(read4, 0, "\(settled)")
        XCTAssertTrue(settled.skipped.contains { $0.path == file && $0.message.contains("set aside by an earlier run") },
                      "\(settled)")

        // A replacement after that is a rewrite in a later second: a new tag, read and taken.
        try w["D"].sync(t)
        XCTAssertEqual(try w["A"].syncUntilQuiet(t).errors, [])
        XCTAssertEqual(try w["A"].titles()[note], "D, before it saw the change")
    }

    /// The same over a copy held in place: B set D's unsealed file aside where it lies and compared the target's copy
    /// (the same bytes); D's catch-up replaces the target's copy within that second. B's record of the comparison,
    /// keyed by the tag, kept it from comparing again (the leaning interleavings' seed 57 with tags of 4-second buckets).
    func testACopyHeldInPlaceIsComparedAgainAfterAReplacementWithinTheSecond() throws {
        let second = Locked(1_900_000_000)
        let t = try TransportUnderTest.mockDAV { $0.secondETagClock = { second.value } }
        let t1 = EpochTarget("T1"), t2 = EpochTarget.over(t, name: "T2", seed: 1, faults: { 0 })
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "D", "X"], made: [t1, t2])
        try w["B"].sync(t2); try w["D"].sync(t2)
        let nd = try w["D"].write("D, offline from T1")
        try w["D"].sync(t2)
        try w["B"].sync(t2)
        XCTAssertEqual(try w["B"].titles()[nd], "D, offline from T1")
        // Home removes X without reaching T2: D's file is not sealed.
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        let b1 = try w["B"].sync(t1)
        XCTAssertEqual(b1.epoch?.taken, 2)
        XCTAssertNil(try w["B"].titles()[nd], "set aside in place")
        try w["B"].sync(t2)   // compares T2's copy: the same bytes
        let file = try XCTUnwrap(t2.paths.first { $0.hasPrefix("notes/\(nd.uuidString.lowercased())/") })
        let tag = try t2.inspector?.stat(file.split(separator: "/").map(String.init))?.etag
        let d = try w["D"].sync(t2)
        XCTAssertTrue(d.replaced.contains(.init(side: "remote", path: file)), "\(d)")
        XCTAssertEqual(try t2.inspector?.stat(file.split(separator: "/").map(String.init))?.etag, tag, "the tag kept the second")
        let b2 = try w["B"].sync(t2)
        XCTAssertTrue(b2.replaced.contains(.init(side: "local", path: file)), "\(b2)")
        XCTAssertEqual(try w["B"].titles()[nd], "D, offline from T1", "J1")
    }
}

/// The other records keyed by a version tag (key-hierarchy design §16.13 "Whole-second version tags"): published
/// summaries, inbox files and the pending files' wait. Each must not take an unchanged whole-second tag for unchanged
/// bytes until it settled. Over the WebDAV mock whose ETags keep the second, its clock standing still.
final class SecondStampInboxSummariesTests: InboxSummariesScenarioCase {
    let second = Locked(1_900_000_000)
    private(set) var server: MockDAV!
    override func transport() throws -> TransportUnderTest {
        let second = self.second
        var made: MockDAV?
        let t = try TransportUnderTest.mockDAV { s in
            s.secondETagClock = { second.value }
            // The tag of a server without ETags (`Last-Modified`, whole seconds): a published file's size varies
            // with its contents, so the summaries case would otherwise depend on two copies having one size.
            s.secondETagsWithoutSize = true
            made = s
        }
        server = made
        return t
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    override func tearDown() {
        SyncEngine.stampClock = { Date() }
        SyncEngine.stampUptime = { ProcessInfo.processInfo.systemUptime }
        super.tearDown()
    }

    private func tag(_ path: [String]) throws -> String? { try t.inspector.stat(path)?.etag }

    /// A's summaries file, published again with the same size within the second B read it: B takes the new one.
    func testASummariesFileRewrittenWithinTheSecondIsTaken() throws {
        try twoDevices()
        let a1 = try publish("A")
        try run("A"); try run("B")
        XCTAssertEqual(summaries("B")[fileA], a1)
        let before = try tag(["summaries", fileA])
        let a2 = try publish("A")
        XCTAssertNotEqual(a2, a1)
        try run("A")
        XCTAssertEqual(try tag(["summaries", fileA]), before, "the tag kept the second")
        try run("B")
        XCTAssertEqual(summaries("B")[fileA], a2, "the rewrite within the second is read")
    }

    /// An inbox file both sides hold, rewritten in place on the remote with the same size within the second B
    /// recorded it: B reads it and sees the difference instead of taking the two sides as in step.
    func testAnInboxFileRewrittenWithinTheSecondIsRead() throws {
        try twoDevices()
        let id = try capture(on: "A")
        try run("A"); try run("B")
        let name = CaptureFile.name(id, .capture)
        let path = ["inbox", name]
        let bytes = try t.inspector.read(path, maxBytes: 1 << 26).data
        let before = try tag(path)
        var other = bytes
        other[other.count - 1] ^= 0x01
        try t.inspector.write(path, .data(other), condition: .unconditional)
        XCTAssertEqual(try tag(path), before, "the tag kept the second")
        let b = try run("B")
        // Only a read of the new bytes finds the two sides differ (the flipped byte verifies under no key: neither copy
        // is replaced); a skip under the recorded tag reports nothing.
        XCTAssertTrue(b.skipped.contains { $0.path == "inbox/\(name)" && $0.message.contains("differs on the two sides") },
                      "the rewrite within the second is read: \(StressWorld.brief(b))")
    }

    /// The pending files' wait: a file that waited for a record is skipped under an unchanged tag only once a read at
    /// least `stampSettleInterval` after the first found it waiting still.
    func testThePendingWaitSkipsOnlyOnceSettled() throws {
        try twoDevices()
        let now = Locked(Date(timeIntervalSince1970: 1_900_000_000))
        let up = Locked(TimeInterval(1_000))
        SyncEngine.stampClock = { now.value }
        SyncEngine.stampUptime = { up.value }
        var o = SyncOptions(deviceLabel: "B")
        o.deviceID = device("B")
        let options = o
        // One engine per run, the state carried from one to the next as a run saves and loads it.
        var carried = SyncState()
        func run<T>(_ body: (SyncEngine) throws -> T) throws -> T {
            let e = try SyncEngine(directory: dir("B"), vault: try openVault("B"), remote: t.remote,
                                   stateURL: tmp.appendingPathComponent("state-pending.json"), options: options)
            e.state = carried
            defer { carried = e.state }
            return try body(e)
        }
        let key = "\(noteID.uuidString.lowercased())/19000000000000000-bbbbbbbb-1.delta.age"
        let path = "notes/\(key)"
        let entry = RemoteEntry(name: "19000000000000000-bbbbbbbb-1.delta.age", isCollection: false, etag: "\"1900000000-2079\"",
                                size: 2079)
        let waits = IncomingFileProblem("waits for a device-change record (its key is not known yet)", pending: true)
        try run { e in
            e.refuseIncoming(key, path: path, entry: entry, problem: waits)
            XCTAssertTrue(e.skipPendingEpoch(key, path: path, entry: entry), "a second look within the run that read it")
        }
        XCTAssertFalse(try run { $0.skipPendingEpoch(key, path: path, entry: entry) }, "not settled: read again")
        try run { $0.refuseIncoming(key, path: path, entry: entry, problem: waits) }
        XCTAssertFalse(try run { $0.skipPendingEpoch(key, path: path, entry: entry) }, "still within the settling time")
        now.value += SyncEngine.stampSettleInterval
        up.value += SyncEngine.stampSettleInterval
        try run { $0.refuseIncoming(key, path: path, entry: entry, problem: waits) }
        XCTAssertTrue(try run { $0.skipPendingEpoch(key, path: path, entry: entry) }, "settled: skipped while the tag stands")
        var moved = entry
        moved.etag = "\"1900000005-2079\""
        XCTAssertFalse(try run { $0.skipPendingEpoch(key, path: path, entry: moved) }, "a moved tag is read again")
    }
}

// MARK: - Review of #92

extension SecondStampTests {
    /// S4: the settle rule needs real time on both clocks. A wall clock stepped forward with the uptime standing still
    /// settles nothing; an uptime that moved on as far settles; an uptime lower than before (a reboot) leaves the wall
    /// clock to decide; a stamp holding no time never settles.
    func testSettlingNeedsTheUptimeTooAndATimedStamp() {
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        let first = SyncEngine.settle(nil, now: t0, uptime: 1_000)
        XCTAssertFalse(first.settled)
        XCTAssertFalse(SyncEngine.settle(first, now: t0 + 3_600, uptime: 1_001).settled, "a wall clock stepped forward")
        XCTAssertFalse(SyncEngine.settle(first, now: t0 + 1, uptime: 1_000 + SyncEngine.stampSettleInterval).settled,
                       "the wall clock must move on too")
        XCTAssertTrue(SyncEngine.settle(first, now: t0 + SyncEngine.stampSettleInterval,
                                        uptime: 1_000 + SyncEngine.stampSettleInterval).settled)
        XCTAssertTrue(SyncEngine.settle(first, now: t0 + 60, uptime: 20).settled, "rebooted in between")
        XCTAssertFalse(SyncEngine.settle(first, now: t0 - 60, uptime: 1_100).settled, "a clock set back starts again")
        XCTAssertFalse(SyncEngine.settle(first, trusted: false, now: t0 + 3_600, uptime: 5_000).settled, "a size settles nothing")
        XCTAssertFalse(SyncEngine.stampCanSettle("size:2079"))
        XCTAssertFalse(SyncEngine.stampCanSettle(nil))
        XCTAssertTrue(SyncEngine.stampCanSettle("\"1900000000-2079\""))
        XCTAssertTrue(SyncEngine.stampCanSettle("Sat, 24 Oct 2026 21:00:00 GMT"))
    }

    /// S1: after another branch's `vault.json` was replaced on the target (`compareShared`), every revision both sides
    /// hold is read once, its tag moved or not (a losing branch's re-seal within the second kept it); then no more.
    func testABranchReplacementComparesEverySharedFileOnce() throws {
        let second = Locked(1_900_000_000)
        let (w, t, server) = try world(server: second)
        let note = try w["A"].write("A's note")
        try w["A"].sync(t)
        try w["D"].sync(t)
        XCTAssertEqual(try w["D"].titles()[note], "A's note")
        let file = try XCTUnwrap(t.paths.first { $0.hasPrefix("notes/\(note.uuidString.lowercased())/") })
        let name = String(file.split(separator: "/").last ?? "")
        let gets = { server.requests.filter { $0.method == "GET" && $0.path.hasSuffix(name) }.count }
        // As `compareSharedAfterBranch` leaves it.
        let stateURL = w["D"].stateURL(t)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        json["compareShared"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)
        let before = gets()
        try w["D"].sync(t)
        XCTAssertEqual(gets() - before, 1, "compared although its tag did not move")
        let after = gets()
        try w["D"].sync(t)
        XCTAssertEqual(gets(), after, "once: the pass ended")
    }
}

extension SecondStampInboxSummariesTests {
    /// S3: the device that uploaded a capture never reads it back (settled at once: it knows the bytes it created),
    /// in that run's pass after the notes or later; a device that downloaded it reads it once more to settle it.
    func testTheUploaderNeverReadsItsCaptureBack() throws {
        let now = Locked(Date(timeIntervalSince1970: 1_900_000_000))
        let up = Locked(TimeInterval(1_000))
        SyncEngine.stampClock = { now.value }
        SyncEngine.stampUptime = { up.value }
        try twoDevices()
        let id = try capture(on: "A")
        let name = CaptureFile.name(id, .capture)
        let gets = { self.server.requests.filter { $0.method == "GET" && $0.path.hasSuffix(name) }.count }
        func later() { now.value += 10; up.value += 10; second.value += 10 }
        var before = gets()
        try run("A")
        XCTAssertEqual(gets() - before, 0, "the upload run")
        later(); before = gets()
        try run("A")
        XCTAssertEqual(gets() - before, 0, "the next run")
        before = gets()
        try run("B")
        XCTAssertEqual(gets() - before, 1, "B downloads it once in that run")
        later(); before = gets()
        try run("B")
        XCTAssertEqual(gets() - before, 1, "and reads it once more, later, to settle its tag")
        later(); before = gets()
        try run("B"); try run("A")
        XCTAssertEqual(gets() - before, 0, "then never")
    }
}

// MARK: - Build 8 sync state carries over

extension SecondStampInboxSummariesTests {
    /// A sync state as build 8 (main 48c0b9f, before #92) writes it: this change only adds optional fields (`timing` in
    /// the inbox, summaries and quarantine records, `sha256` in the quarantine record, three timing maps), so build 8's
    /// file is this one without them. It decodes with every record kept, and the first run after the upgrade only reads
    /// the timed files once more (no new refusal, nothing placed, uploaded or deleted), then settles.
    func testABuild8StateDecodesAndTheFirstRunOnlyReadsAgain() throws {
        let now = Locked(Date(timeIntervalSince1970: 1_900_000_000))
        let up = Locked(TimeInterval(1_000))
        SyncEngine.stampClock = { now.value }
        SyncEngine.stampUptime = { up.value }
        func later() { now.value += 10; up.value += 10; second.value += 10 }
        try twoDevices()
        let id = try capture(on: "A")
        _ = try publish("A")
        let forged = CaptureFile.name(UUID(), .capture)
        try plant(["inbox", forged], try Vault.encrypt(Data("SMPC junk".utf8), to: [identity.recipient]))
        try run("A"); try run("B")
        later(); try run("B")
        later(); try settle("B")

        // B's state as build 8 would have written it: the fields #92 adds removed.
        let url = tmp.appendingPathComponent("state-B.json")
        let current = try XCTUnwrap(try SyncState.load(url))
        XCTAssertFalse(current.quarantined?.isEmpty ?? true)
        XCTAssertFalse(current.inbox?.isEmpty ?? true)
        XCTAssertFalse(current.deviceSummaries?.isEmpty ?? true)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["comparedAsideTiming", "pendingEpochTiming", "verifiedRecordsTiming"] { json[key] = nil }
        func strip(_ map: String, _ fields: [String]) {
            guard var records = json[map] as? [String: [String: Any]] else { return }
            for (k, var r) in records {
                for f in fields { r[f] = nil }
                records[k] = r
            }
            json[map] = records
        }
        strip("inbox", ["timing"])
        strip("deviceSummaries", ["timing"])
        strip("quarantined", ["timing", "sha256"])
        let build8 = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        XCTAssertFalse(String(decoding: build8, as: UTF8.self).contains("\"timing\""))
        try build8.write(to: url)

        let old = try XCTUnwrap(try SyncState.load(url), "build 8's state decodes")
        XCTAssertEqual(Set(old.inbox?.keys ?? [:].keys), Set(current.inbox?.keys ?? [:].keys))
        XCTAssertEqual(old.inbox?.mapValues(\.hash), current.inbox?.mapValues(\.hash))
        XCTAssertEqual(old.deviceSummaries?.mapValues(\.hash), current.deviceSummaries?.mapValues(\.hash))
        XCTAssertEqual(old.quarantined?.mapValues(\.stamp), current.quarantined?.mapValues(\.stamp))
        XCTAssertEqual(old.files, current.files)
        XCTAssertNil(old.inbox?.values.first?.timing)

        let captureName = CaptureFile.name(id, .capture)
        let gets = { (n: String) in self.server.requests.filter { $0.method == "GET" && $0.path.hasSuffix(n) }.count }
        later()
        var before = (gets(captureName), gets(forged), gets(fileA))
        let first = try run("B")
        XCTAssertTrue(first.errors.isEmpty && first.quarantined.isEmpty && first.downloaded.isEmpty && first.uploaded.isEmpty
                      && first.deleted.isEmpty && first.replaced.isEmpty, "only reads: \(StressWorld.brief(first))")
        XCTAssertLessThanOrEqual(gets(captureName) - before.0, 1)
        XCTAssertLessThanOrEqual(gets(forged) - before.1, 1)
        XCTAssertLessThanOrEqual(gets(fileA) - before.2, 1)
        later(); try run("B")
        later()
        before = (gets(captureName), gets(forged), gets(fileA))
        let quiet = try run("B")
        XCTAssertEqual([gets(captureName) - before.0, gets(forged) - before.1, gets(fileA) - before.2], [0, 0, 0],
                       "settled again: \(StressWorld.brief(quiet))")
    }
}
