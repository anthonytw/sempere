import Age
import Foundation
import FuzzSupport
import XCTest

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Sempere

/// Regression tests for hostile or corrupt input found by review and by the
/// fuzz harness (`SempereFuzzTests`): each must fail with a typed error,
/// never trap.
final class UntrustedInputTests: VaultTestCase {
    /// A snapshot whose `included` names `upTo == Int.max` trapped in
    /// `Included.Entry.normalize()` (`upTo + 1`).
    func testIncludedEntryAtIntMaxDoesNotTrap() throws {
        let top = Included.Entry(upTo: .max, extra: [5, .max])
        XCTAssertEqual(top, Included.Entry(upTo: .max, extra: []))
        XCTAssertTrue(top.covers(.max))
        var inc = Included([devA: top])
        inc.insert(device: devA, seq: .max)
        XCTAssertEqual(inc.union(Included([devA: .init(upTo: 3, extra: [.max])])).entries[devA], top)
        XCTAssertTrue(inc.isSuperset(of: Included([devA: .init(upTo: 3)])))
        XCTAssertEqual(Included.Entry(upTo: .max - 1, extra: [.max]), top)
    }

    /// Decoding refuses a seq above `RevisionName.maxSeq` in `included`, a
    /// revision or a file name, so `seq + 1` (`nextSeq`) cannot overflow.
    func testSeqAboveMaxSeqIsRejected() throws {
        let max = RevisionName.maxSeq
        let ok = try InkJSON.decoder().decode(Included.self, from: Data(#"{"aaaaaaaa":{"upTo":\#(max),"extra":[]}}"#.utf8))
        XCTAssertEqual(ok.entries[devA]?.upTo, max)
        for bad in [#"{"aaaaaaaa":{"upTo":9223372036854775807,"extra":[]}}"#,
                    #"{"aaaaaaaa":{"upTo":\#(max + 1),"extra":[]}}"#,
                    #"{"aaaaaaaa":{"upTo":1,"extra":[9223372036854775807]}}"#] {
            XCTAssertThrowsError(try InkJSON.decoder().decode(Included.self, from: Data(bad.utf8)), bad) { e in
                XCTAssertTrue(e is DecodingError, "\(e)")
            }
        }
        XCTAssertNotNil(RevisionName("17596320000000000-aaaaaaaa-\(max).delta.age"))
        XCTAssertNil(RevisionName("17596320000000000-aaaaaaaa-\(max + 1).delta.age"))
        XCTAssertNil(RevisionName("17596320000000000-aaaaaaaa-9223372036854775807.delta.age"))

        var log = LogBuilder()
        var rev = log.delta(devA, 0, [.deleteNote])
        rev.seq = max + 1
        let json = try InkJSON.encoder().encode(rev)
        XCTAssertThrowsError(try InkJSON.decoder().decode(Revision.self, from: json))
    }

    /// `nextSeq` after a snapshot covering `maxSeq` is `maxSeq + 1` (no
    /// overflow), and writing that revision is refused with a typed error.
    func testNextSeqAtTheLimitIsRefusedNotTrapped() throws {
        var log = LogBuilder()
        let d = log.delta(devA, 0, [.addPage(Page(order: "a"))])
        let snap = Revision(noteId: testNote, device: devB, seq: 1, hlc: HLC(millis: baseMillis + 1, counter: 0)!,
                            wall: wallAt(baseMillis + 1), app: "test/0",
                            body: .snapshot(included: Included([devA: .init(upTo: RevisionName.maxSeq)]),
                                            state: try NoteReducer.reconstruct([d])))
        XCTAssertEqual(Vault.nextSeq(from: [d, snap], device: devA), RevisionName.maxSeq + 1)

        let id = pqIdentity()
        let vault = try makeVault(id)
        var next = log.delta(devA, 5, [.deleteNote])
        next.seq = RevisionName.maxSeq + 1
        XCTAssertThrowsError(try vault.write(next)) { e in
            XCTAssertEqual(e as? VaultError, .seqOutOfRange(RevisionName.maxSeq + 1))
        }
    }

    /// `vault.json` with a date whose fraction ran to 800 digits killed the
    /// process with SIGFPE inside ICU (ISO8601DateFormatter), found by the
    /// long fuzz run. Every date in the format is now parsed by `RFC3339`.
    func testLongFractionalSecondsAreRejectedNotCrashing() throws {
        let long = "2026-10-05T13:20:16." + String(repeating: "9", count: 800) + "22Z"
        XCTAssertNil(RFC3339.parse(long))
        let json = #"{"format":"sempere/1","vaultId":"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c","created":"\#(long)","#
            + #""recipients":[],"vaultSecret":""}"#
        XCTAssertThrowsError(try VaultManifest.decode(Data(json.utf8))) { XCTAssertTrue($0 is DecodingError, "\($0)") }
        for bad in ["2026-10-05T13:20:4.9e-324Z", "2026-10-05T13:20:255Z", "2026-02-30T00:00:00Z", "2026-10-04T24:00:00Z",
                    "2026-10-04T23:59:60Z", "0000-01-01T00:00:00Z", "2026-10-04 18:20:00Z", "2026-10-04T18:20:00",
                    "2026-10-04T18:20:00.Z", "2026-10-04T18:20:00.1234567890Z", "2026-10-04T18:20:00+24:00", ""] {
            XCTAssertNil(RFC3339.parse(bad), bad)
        }
        XCTAssertEqual(RFC3339.parse("2026-10-04T18:20:00+02:00"), RFC3339.parse("2026-10-04T16:20:00Z"))
        XCTAssertEqual(RFC3339.parse("2026-10-04T16:20:00.123456789Z"), RFC3339.parse("2026-10-04T16:20:00.123Z"))
        XCTAssertEqual(RFC3339.parse("2024-02-29T00:00:00Z").map(RFC3339.string), "2024-02-29T00:00:00.000Z")
    }

    /// A local time inside 0001...9999 whose offset puts the instant outside
    /// it was accepted: `0001-01-01T00:00:00+00:01` is year 0 in UTC, which
    /// `RFC3339.string` (every writer) refuses, so a note holding such a
    /// `created` decoded but could never be snapshotted or compacted again.
    func testOffsetsCannotLeaveTheWritableYears() throws {
        for s in ["0001-01-01T00:00:00+00:01", "0001-01-01T00:59:59.999+01:00", "9999-12-31T23:59:59-00:01",
                  "9999-12-31T23:00:00-01:00"] {
            XCTAssertNil(RFC3339.parse(s), s)
        }
        XCTAssertEqual(RFC3339.parse("0001-01-01T01:00:00+01:00").flatMap(RFC3339.string), "0001-01-01T00:00:00.000Z")
        XCTAssertEqual(RFC3339.parse("9999-12-31T22:59:59.999-01:00").flatMap(RFC3339.string), "9999-12-31T23:59:59.999Z")
        var log = LogBuilder()
        let rev = log.delta(devA, 0, [.deleteNote])
        let json = String(decoding: try InkJSON.encoder().encode(rev), as: UTF8.self)
        let wall = try XCTUnwrap(RFC3339.string(from: rev.wall))
        let hostile = json.replacingOccurrences(of: wall, with: "0001-01-01T00:00:00+00:01")
        XCTAssertNotEqual(hostile, json)
        XCTAssertThrowsError(try InkJSON.decoder().decode(Revision.self, from: Data(hostile.utf8))) {
            XCTAssertTrue($0 is DecodingError, "\($0)")
        }
    }

    /// The arithmetic codec agrees with ISO8601DateFormatter for every
    /// millisecond-precise date from 1583 on, so existing files read and
    /// re-encode exactly as before.
    func testRFC3339MatchesFoundationFormatter() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var g = SplitMix64(seed: 3339)
        for _ in 0..<5000 {
            let ms = Int64.random(in: -12_000_000_000_000...253_000_000_000_000, using: &g)
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)
            let ours = try XCTUnwrap(RFC3339.string(from: date))
            XCTAssertEqual(ours, iso.string(from: date))
            let back = try XCTUnwrap(RFC3339.parse(ours))
            XCTAssertEqual(back.timeIntervalSince1970, try XCTUnwrap(iso.date(from: ours)).timeIntervalSince1970, accuracy: 1e-6)
            XCTAssertEqual(RFC3339.string(from: back), ours)
        }
    }

    /// Dates no reader can decode (NaN, beyond year 9999) and coordinates that
    /// overflow when rounded are refused or kept, never written as garbage.
    func testWritersRefuseUnreadableDatesAndKeepHugeCoordinates() throws {
        for bad in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: 1e300),
                    Date(timeIntervalSince1970: -62_135_596_801), RFC3339.end] {
            XCTAssertNil(RFC3339.string(from: bad))
            XCTAssertThrowsError(try InkJSON.encoder().encode([bad])) { XCTAssertTrue($0 is EncodingError, "\($0)") }
        }
        let vault = try makeVault(pqIdentity())
        var log = LogBuilder()
        var rev = log.delta(devA, 0, [.deleteNote])
        rev.wall = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertThrowsError(try vault.write(rev)) { XCTAssertTrue($0 is EncodingError, "\($0)") }
        XCTAssertEqual(try vault.revisionNames(of: testNote), [])

        XCTAssertEqual(InkJSON.round3(1e306), 1e306)
        XCTAssertEqual(InkJSON.round3(1.23456), 1.235)
        let big = Stroke(ink: Ink(tool: .pen, color: .black, width: 1e306), points: [StrokePoint(x: 1e306, y: -1e306, w: 1, h: 1)])
        let decoded = try InkJSON.decoder().decode(Stroke.self, from: InkJSON.encoder().encode(big))
        XCTAssertEqual(decoded.points[0].x, 1e306)
    }

    /// A snapshot listing 100 000 `extra` seqs plus 500 deltas: restore points
    /// re-merged every snapshot and scanned every extra with a linear
    /// `covers` per point (cubic: 203 s for only 10 000 extras and 100 deltas).
    /// `covers` is now a binary search and `Completeness` one sweep.
    func testHistoryOfHugeIncludedIsFast() throws {
        var log = LogBuilder()
        let page = UUID()
        let first = log.delta(devA, 0, [.addPage(Page(id: page, order: "a"))])
        let strokes = (0..<2000).map { i in
            Stroke(id: UUID(), ink: Ink(tool: .pen, color: .black, width: 1), points: [StrokePoint(x: 1, y: 2, w: 1, h: 1)],
                   origin: "17596320000000000-bbbbbbbb-\(2 * i + 200_010)-0")
        }
        let snap = Revision(noteId: testNote, device: devC, seq: 1, hlc: HLC(millis: baseMillis + 5, counter: 0)!,
                            wall: wallAt(baseMillis + 5), app: "x",
                            body: .snapshot(included: Included([devB: .init(upTo: 1, extra: Array(stride(from: 3, to: 200_003, by: 2))),
                                                                devA: .init(upTo: 1)]),
                                            state: NoteState(meta: NoteMeta(created: wallAt(0)),
                                                             pages: [Page(id: page, order: "a", strokes: strokes)])))
        let deltas = (0..<500).map { i in log.delta(devA, Int64(10 + i), [.setMeta(.title("t\(i)"))]) }
        let t0 = Date()
        let points = NoteHistory.restorePoints([first, snap] + deltas)
        _ = try NoteReducer.reconstruct([first, snap] + deltas)
        XCTAssertEqual(points.count, 502)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
    }

    /// A snapshot whose `included` lists 300 000 `extra` seqs that a later
    /// snapshot folds into `upTo`, with 2 000 deltas in between: the sweep
    /// still counted the known extras that are also files with a linear scan
    /// per restore point and device (points × extras, 6·10⁸ set lookups,
    /// over a minute in a debug build). That count is now kept per merged
    /// snapshot state and looked up by binary search.
    func testRestorePointsBetweenHugeSnapshotsAreFast() throws {
        let n = 300_000
        var log = LogBuilder()
        let b1 = log.delta(devB, 1, [.setMeta(.title("b1"))])
        let b2 = log.delta(devB, 2, [.setMeta(.title("b2"))])
        func snapshot(_ seq: Int, at ms: Int64, _ entry: Included.Entry) -> Revision {
            Revision(noteId: testNote, device: devC, seq: seq, hlc: HLC(millis: baseMillis + ms, counter: 0)!,
                     wall: wallAt(baseMillis + ms), app: "x",
                     body: .snapshot(included: Included([devB: entry]), state: NoteState(meta: NoteMeta(created: wallAt(0)))))
        }
        let early = snapshot(1, at: 5, Included.Entry(upTo: 1, extra: Array(3...n)))
        let deltas = (0..<2000).map { i in log.delta(devA, Int64(10 + i), [.setMeta(.title("a\(i)"))]) }
        let late = snapshot(2, at: 100_000, Included.Entry(upTo: n))
        let all = [b1, b2, early, late] + deltas
        let t0 = Date()
        let points = NoteHistory.restorePoints(all)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
        XCTAssertEqual(points.count, all.count)
        XCTAssertTrue(points.allSatisfy(\.complete))
    }

    /// The one-sweep `Completeness` agrees with the per-point definition it
    /// replaced, on adversarial logs with revisions dropped (compacted) and
    /// some marked unreadable.
    func testCompletenessMatchesReference() throws {
        var rng = FuzzRNG(seed: 99)
        for _ in 0..<300 {
            var revs = SempereFuzzTests.adversarialLog(&rng)
            // Unique (device, seq), as a vault directory holds them.
            var seen = Set<String>()
            revs = revs.filter { seen.insert("\($0.device)-\($0.seq)").inserted }
            var kept: [Revision] = [], unreadable: [RevisionName] = []
            for r in revs {
                switch rng.below(5) {
                case 0: continue                       // compacted away
                case 1: unreadable.append(r.name)
                default: kept.append(r)
                }
            }
            let points = kept.map(\.name).sorted()
            let fast = Completeness(kept, unreadable: unreadable).isComplete(at: points)
            let slow = points.map { Self.referenceIsComplete(kept, unreadable: unreadable, at: $0) }
            XCTAssertEqual(fast, slow, "\(revs.map(\.name))")
        }
    }

    /// The definition `Completeness` implemented before it became a sweep.
    static func referenceIsComplete(_ revisions: [Revision], unreadable: [RevisionName], at point: RevisionName) -> Bool {
        let listed = revisions.map(\.name) + unreadable
        var present: [DeviceID: Set<Int>] = [:]
        for n in listed { present[n.device, default: []].insert(n.seq) }
        var snapshots: [(name: RevisionName, included: Included)] = []
        var covered = Included()
        for r in revisions {
            guard case .snapshot(let included, _) = r.body else { continue }
            snapshots.append((r.name, included))
            covered = covered.union(included)
        }
        if unreadable.contains(where: { $0 <= point || $0.kind == .snapshot }) { return false }
        let before = snapshots.filter { $0.name <= point }.reduce(Included()) { $0.union($1.included) }
        var firstAtOrAfter: [DeviceID: Int] = [:]
        for n in listed where n >= point { firstAtOrAfter[n.device] = min(firstAtOrAfter[n.device] ?? .max, n.seq) }
        for (device, all) in covered.entries {
            let have = present[device] ?? []
            let known = before.entries[device] ?? Included.Entry()
            let limit = firstAtOrAfter[device] ?? .max
            func needs(_ seq: Int) -> Bool { seq < limit && !have.contains(seq) && !known.covers(seq) }
            if all.extra.contains(where: needs) { return false }
            let top = min(all.upTo, limit - 1)
            if known.upTo < top {
                let length = top - known.upTo
                let filled = have.count { $0 > known.upTo && $0 <= top }
                    + known.extra.count { $0 > known.upTo && $0 <= top && !have.contains($0) }
                if filled < length { return false }
            }
        }
        return true
    }

    /// Files from a shared folder or sync server can be any size or kind:
    /// readers refuse an oversized file before holding it, and refuse a FIFO
    /// (whose open would otherwise block forever) instead of hanging.
    func testBoundedReadsRefuseHugeFilesAndFIFOs() throws {
        let big = tmp.appendingPathComponent("big")
        try Data(count: 4097).write(to: big)
        XCTAssertEqual(try BoundedRead.contents(of: big, maxBytes: 4097).count, 4097)
        XCTAssertThrowsError(try BoundedRead.contents(of: big, maxBytes: 4096)) {
            XCTAssertEqual($0 as? VaultError, .fileTooLarge(big.path, limit: 4096))
        }
        let fifo = tmp.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let t0 = Date()
        XCTAssertThrowsError(try BoundedRead.contents(of: fifo, maxBytes: 10)) { XCTAssertTrue($0 is VaultError) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)

        // Through the vault: an oversized vault.json and a revision that is a FIFO.
        let id = pqIdentity()
        let vault = try makeVault(id)
        let rev = sampleLog()[0]
        try vault.write(rev)
        let file = fileURL(vault, rev.noteId, rev.name)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try vault.readRevision(noteId: rev.noteId, name: rev.name)) { e in
            guard case RevisionReadError.unreadable? = e as? RevisionReadError else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(vault.verify().isHealthy)
        let manifest = vault.url.appendingPathComponent("vault.json")
        try (Data("{".utf8) + Data(repeating: 0x20, count: BoundedRead.maxManifestBytes)).write(to: manifest)
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [id])) { e in
            guard case VaultError.fileTooLarge? = e as? VaultError else { return XCTFail("\(e)") }
        }
    }

    /// A notebook name of 200 000 levels made `NotebookNode.tree` recurse once
    /// per level (a stack overflow); the sidebar tree stops at `maxDepth`.
    func testDeepNotebookPathDoesNotRecurseWithoutBound() {
        let deep = String(repeating: "a/", count: 200_000)
        let t0 = Date()
        var nodes = NotebookNode.tree([deep, "a/b"])
        var depth = 0
        while let first = nodes.first { depth += 1; nodes = first.children }
        XCTAssertEqual(depth, NotebookNode.maxDepth)
        XCTAssertEqual(NotebookPath.components(deep).count, 200_000)
        XCTAssertTrue(NotebookPath.name(deep, isWithin: "a/a"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
    }
    // MARK: - Unknown fields kept verbatim (JSONValue)

    /// Runs `body` on a thread with the 512 KiB stack of an iOS
    /// cooperative-pool thread, where the app decodes notes.
    private func onSmallStack(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { body(); done.signal() }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var error: (any Error)?
        private var finished = false
        func set(_ e: (any Error)?) { lock.lock(); error = e; finished = true; lock.unlock() }
        var value: (finished: Bool, error: (any Error)?) { lock.lock(); defer { lock.unlock() }; return (finished, error) }
    }

    /// An unknown item field nested a few hundred deep overflowed a 512 KiB
    /// stack (SIGSEGV from about 250 levels): decoding recursed once per level.
    func testDeeplyNestedUnknownFieldIsRefusedNotAStackOverflow() throws {
        let page = UUID()
        var log = LogBuilder()
        let rev = log.delta(devA, 0, [.addItem(page: page, item: .text(TextContent(size: 12, color: .black, runs: [TextRun("x")]),
                                                                       frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a"))])
        let plain = String(decoding: try InkJSON.encoder().encode(rev), as: UTF8.self)
        XCTAssertTrue(plain.contains(#""z":"a""#))
        let depth = 500
        let nested = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        let hostile = Data(plain.replacingOccurrences(of: #""z":"a""#, with: #""x":\#(nested),"z":"a""#).utf8)
        let outcome = Outcome()
        onSmallStack {
            do { _ = try InkJSON.decoder().decode(Revision.self, from: hostile); outcome.set(nil) } catch { outcome.set(error) }
        }
        XCTAssertTrue(outcome.value.finished)
        XCTAssertTrue(outcome.value.error is DecodingError, "\(String(describing: outcome.value.error))")
        // A shallow unknown field is still kept.
        let shallow = Data(plain.replacingOccurrences(of: #""z":"a""#, with: #""x":{"a":[1,{"b":null}]},"z":"a""#).utf8)
        XCTAssertNoThrow(try InkJSON.decoder().decode(Revision.self, from: shallow))
        // JSONValue on its own: nesting beyond the limit is refused.
        let tooDeep = String(repeating: "[", count: JSONValue.maxDepth + 2) + String(repeating: "]", count: JSONValue.maxDepth + 2)
        XCTAssertThrowsError(try InkJSON.decoder().decode(JSONValue.self, from: Data(tooDeep.utf8)))
        let deepest = String(repeating: "[", count: JSONValue.maxDepth) + String(repeating: "]", count: JSONValue.maxDepth)
        XCTAssertNoThrow(try InkJSON.decoder().decode(JSONValue.self, from: Data(deepest.utf8)))
    }

    /// Every unknown value costs several trial decodes, each O(depth): a
    /// 600 KB field took 11 minutes in a debug build. Decoding stops at
    /// `JSONValue.maxValues` values per file.
    func testAHugeUnknownFieldIsRefusedQuickly() throws {
        let depth = JSONValue.maxDepth - 2
        let leaves = Array(repeating: #""""#, count: JSONValue.maxValues + 10).joined(separator: ",")
        let input = Data((String(repeating: "[", count: depth) + leaves + String(repeating: "]", count: depth)).utf8)
        let start = Date()
        XCTAssertThrowsError(try InkJSON.decoder().decode(JSONValue.self, from: input)) { XCTAssert($0 is DecodingError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
        // Within the budget it decodes; a fresh decoder has a fresh budget.
        let fits = Array(repeating: "1", count: JSONValue.maxValues - 1).joined(separator: ",")
        XCTAssertNoThrow(try InkJSON.decoder().decode(JSONValue.self, from: Data("[\(fits)]".utf8)))
        XCTAssertNoThrow(try InkJSON.decoder().decode(JSONValue.self, from: Data("[\(fits)]".utf8)))
    }

    // MARK: - App crash audit: item and highlight geometry the app draws

    /// A frame decodes when its size is positive, so `[1.7e308, 0, 1.7e308, 10]`
    /// gets through; its corners are NaN, and Core Animation raises on a layer
    /// placed there. The app leaves such items out (`ItemFrames.isDrawable`).
    func testItemGeometryThatOverflowsIsNotDrawable() throws {
        let json = Data(#"[1.7e308, 0, 1.7e308, 10]"#.utf8)
        let frame = try InkJSON.decoder().decode(Rect.self, from: json)
        XCTAssertTrue(frame.hasPositiveSize, "the format accepts it")
        XCTAssertTrue(ItemFrames.corners(frame, rotation: nil).contains { $0.x.isNaN })
        XCTAssertFalse(ItemFrames.isDrawable(frame, rotation: nil))
        XCTAssertFalse(ItemFrames.isDrawable(Rect(x: 0, y: 0, w: 1e20, h: 1), rotation: nil))
        XCTAssertFalse(ItemFrames.isDrawable(Rect(x: 0, y: 0, w: 10, h: 10), rotation: .infinity))
        XCTAssertFalse(ItemFrames.isDrawable(Rect(x: 0, y: 150_000, w: 190_000, h: 10), rotation: 90))
        XCTAssertTrue(ItemFrames.isDrawable(Rect(x: 0, y: 150_000, w: 190_000, h: 10), rotation: nil))
        XCTAssertTrue(ItemFrames.isDrawable(Rect(x: 10, y: 20, w: 300, h: 200), rotation: 1e308))
        // What the canvas does not draw cannot be tapped and selected either.
        let hidden = Item(kind: .text, frame: Rect(x: 0, y: 0, w: 1e20, h: 1e20), z: "b")
        let shown = Item(kind: .text, frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a")
        XCTAssertEqual(ItemFrames.item(at: .init(x: 50, y: 50), in: [hidden, shown])?.id, shown.id)
        XCTAssertNil(ItemFrames.item(at: .init(x: 500, y: 500), in: [hidden, shown]))
    }

    /// `1e308 * .pi` is infinite and a rotation by it all NaN: angles are
    /// reduced to one turn before they become radians.
    func testHugeRotationsBecomeFiniteRadians() {
        for d in [1e308, -1e308, Double.greatestFiniteMagnitude, 1e20] {
            let r = ItemFrames.radians(d)
            XCTAssertTrue(r.isFinite && abs(r) < 2 * .pi, "\(d)")
        }
        XCTAssertEqual(ItemFrames.radians(nil), 0)
        XCTAssertEqual(ItemFrames.radians(.nan), 0)
        XCTAssertEqual(ItemFrames.radians(90), .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(ItemFrames.radians(450), .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(ItemFrames.radians(-90), -.pi / 2, accuracy: 1e-12)
    }

    /// A recorded stroke with points at ±1.7e308 had an infinite box, and the
    /// playback highlight's layer a NaN position.
    func testARecordedStrokeTooWideToDrawHasNoPlaybackBox() {
        func stroke(_ pts: [(Double, Double)], width: Double = 2) -> Stroke {
            Stroke(ink: Ink(tool: .pen, color: .black, width: width),
                   points: pts.map { StrokePoint(x: $0.0, y: $0.1, w: width, h: width) },
                   rec: RecordingLink(id: UUID(), at: 1))
        }
        XCTAssertNil(RecordingSync.box(of: stroke([(-1.7e308, 0), (1.7e308, 10)])))
        XCTAssertNil(RecordingSync.box(of: stroke([(0, 0), (10, 10)], width: 1e300)))
        XCTAssertNotNil(RecordingSync.box(of: stroke([(0, 0), (10, 10)])))
        XCTAssertTrue(RecordingSync.hit(x: 0, y: 0, in: [stroke([(-1.7e308, 0), (1.7e308, 10)])]).isEmpty)
    }

    /// An audio card turned by 1e308 degrees put its play badge at NaN
    /// (`1e308 * .pi` is infinite), and the app's button with it.
    func testAHugeRotationLeavesTheAudioBadgeFinite() {
        let card = AudioCard(frame: Rect(x: 0, y: 0, w: 300, h: 96))
        let plain = card.badge(rotation: nil), turned = card.badge(rotation: 1e308)
        XCTAssertTrue(turned.center.x.isFinite && turned.center.y.isFinite)
        XCTAssertEqual(turned.diameter, plain.diameter)
        XCTAssertFalse(card.controlContains(x: .nan, y: 0, rotation: 1e308))
        let c = card.badge(rotation: 360 * 1e10 + 90).center, q = card.badge(rotation: 90).center
        XCTAssertEqual(c.x, q.x, accuracy: 1e-6)
        XCTAssertEqual(c.y, q.y, accuracy: 1e-6)
    }
}
