import Age
import Foundation
import TempDirSupport
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Sync over short connection windows (offline audit, infrequent connectivity): a device online for K requests, a
/// byte budget or a few seconds at a time (`WindowRemote`). Each run must make progress after a fixed overhead,
/// stop soon once the link is gone (P8), count as a success when it moved something (P4), carry the inbox and this
/// device's own summaries before the notes backlog and this device's newest writing first (P6). `WINDOW` lines print
/// the numbers.
final class ShortWindowTests: TempDirTestCase {
    struct Stat { var requests = 0, refused = 0, moved = 0, errors = 0, threw = false, stopped = false, wasted = 0 }

    final class World {
        let devs: SyncDevices
        let wa: WindowRemote, wb: WindowRemote
        var a: SyncDevice { devs.a }
        var b: SyncDevice { devs.b }

        init(root: URL, concurrency: Int = 1) throws {
            let store = MemoryStore(name: "S")
            var wins: [String: WindowRemote] = [:]
            devs = try SyncDevices.make(root: root, count: 2, remote: { n in
                let w = WindowRemote(MemoryRemote(store: store, base: ["vault"])); wins[n] = w; return w
            }, inspector: MemoryRemote(store: store, base: ["vault"]), pull: false)
            guard let wa = wins["A"], let wb = wins["B"] else { throw SyncError.io("no window remotes") }
            self.wa = wa; self.wb = wb
            for d in devs.devices { d.tune = { $0.concurrency = concurrency; $0.recordSynced = true } }
        }

        func server() throws -> Set<String> { try SyncDevices.remoteFiles(devs.inspector) }

        func run(_ d: SyncDevice, _ w: WindowRemote, k: Int?, bytes: Int? = nil,
                 _ edit: (inout SyncOptions) -> Void = { _ in }) -> (Stat, SyncReport?) {
            w.arm(requests: k, bytes: bytes)
            var s = Stat()
            var report: SyncReport?
            do {
                let r = try d.sync(edit)
                report = r
                s.moved = r.uploaded.count + r.downloaded.count
                s.errors = r.errors.count
                s.stopped = r.stoppedEarly != nil
            } catch { s.threw = true }
            s.requests = w.requests; s.refused = w.refused; s.wasted = w.wastedBytes
            return (s, report)
        }
    }

    private func seed(_ w: World, notes: Int, blobBytes: [Int] = [], blobAtSortedIndex: Int? = nil) throws {
        for i in 0..<notes { try w.a.newNote("note \(i)") }
        let ids = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        for (i, n) in blobBytes.enumerated() {
            let i = blobAtSortedIndex ?? i
            var d = Data(count: n); for j in 0..<n { d[j] = UInt8(truncatingIfNeeded: j &* 31 &+ i) }
            try w.a.attach(ids[i % ids.count], d)
        }
    }

    /// Runs until `done` (at most `maxRuns`); the stats of each run.
    private func drive(_ w: World, _ d: SyncDevice, _ win: WindowRemote, k: Int?, bytes: Int? = nil, maxRuns: Int,
                       done: () throws -> Bool, edit: (inout SyncOptions) -> Void = { _ in }) throws -> [Stat] {
        var out: [Stat] = []
        for _ in 0..<maxRuns {
            out.append(w.run(d, win, k: k, bytes: bytes, edit).0)
            if try done() { break }
        }
        return out
    }

    private func report(_ label: String, _ s: [Stat], converged: Bool) {
        print("WINDOW \(label): runs=\(s.count) converged=\(converged) moved/run(first 8)=\(Array(s.map(\.moved).prefix(8))) "
              + "refusedAfterCut(sum)=\(s.map(\.refused).reduce(0, +)) threw=\(s.filter(\.threw).count)")
    }

    // MARK: Progress per window

    /// Every window of K requests moves files after a fixed overhead: an upload to an empty target and a pull from a
    /// full one (deep listing) converge.
    func testUploadAndPullConvergeOverShortWindows() throws {
        for k in [20, 50] {
            let w = try World(root: tmp.appendingPathComponent("up\(k)"))
            try seed(w, notes: 80)
            let want = w.a.noteFiles()
            let s = try drive(w, w.a, w.wa, k: k, maxRuns: 60) { try w.server().isSuperset(of: want) }
            let ok = try w.server().isSuperset(of: want)
            report("A-upload K=\(k) notes=80", s, converged: ok)
            XCTAssertTrue(ok, "K=\(k): the upload converges")
            XCTAssertTrue(s.dropLast().allSatisfy { $0.moved > 0 }, "K=\(k): every window moves something: \(s.map(\.moved))")

            let b = w.b
            let p = try drive(w, b, w.wb, k: k, maxRuns: 60) { b.noteFiles() == want }
            report("B-pull K=\(k) notes=80", p, converged: b.noteFiles() == want)
            XCTAssertEqual(b.noteFiles(), want, "K=\(k): the pull converges")
        }
    }

    // MARK: P8: a dead link stops the run

    /// The link dies after 30 requests: the run stops after a few failures (`SyncError.connectionLost`), instead of
    /// trying every remaining file (each a timeout of up to a minute over WebDAV).
    func testADeadLinkStopsTheRun() throws {
        let w = try World(root: tmp.appendingPathComponent("dead"))
        try seed(w, notes: 120)
        let (s, r) = w.run(w.a, w.wa, k: 30)
        print("WINDOW dead-link K=30 notes=120: requests attempted=\(s.requests) (refused after cut=\(s.refused)) "
              + "moved=\(s.moved) errors=\(s.errors) stoppedEarly=\(s.stopped)")
        XCTAssertFalse(s.threw)
        XCTAssertLessThan(s.refused, 10, "the run stops soon after the link died")
        XCTAssertEqual(r?.linkLost, true)
        XCTAssertNotNil(r?.stoppedEarly)
        XCTAssertTrue(r?.lastingErrors.isEmpty == true, "no lasting problem: \(r?.lastingErrors ?? [])")
        XCTAssertTrue(r?.outcome.success == true, "it moved files: a success")
        XCTAssertTrue(r.map { WebDAVSyncProblem.from(report: $0).isEmpty } == true)
        // The next window continues.
        let (next, _) = w.run(w.a, w.wa, k: nil)
        XCTAssertGreaterThan(next.moved, 0)
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()))
    }

    // MARK: P4: a cut run that moved something is a success

    /// Runs cut short that uploaded files come back at the active pace (30 s), never backed off as failures; a run
    /// that moved nothing over a dead link is `.offline`.
    func testAProgressingCutRunIsASuccess() throws {
        let w = try World(root: tmp.appendingPathComponent("backoff"))
        try seed(w, notes: 100)
        var schedule = SyncSchedule()
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            let (_, r) = w.run(w.a, w.wa, k: 40)
            let report = try XCTUnwrap(r)
            XCTAssertTrue(WebDAVSyncProblem.from(report: report).isEmpty, "\(report.errors.prefix(3))")
            schedule.started(at: Date())
            schedule.finished(at: Date(), outcome: report.outcome)
            delays.append(schedule.failures > 0 ? schedule.retryDelay : schedule.periodicDelay)
            if try w.server().isSuperset(of: w.a.noteFiles()) { break }
        }
        print("WINDOW backoff: next-run delay after each progressing cut run (s): \(delays)")
        XCTAssertLessThanOrEqual(delays.max() ?? 0, 30, "cut runs that uploaded files are not failures")
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()))

        // A server bound after progress: classified as such, a failure (review of #91, M1).
        for i in 0..<20 { try w.a.newNote("bound \(i)") }
        let (_, rb) = w.run(w.a, w.wa, k: nil) { $0.limits.maxEntries = 60 }
        if let rb, rb.stoppedEarly != nil {
            XCTAssertEqual(rb.stopReason, .bound)
            XCTAssertFalse(rb.outcome.success)
        }
        _ = w.run(w.a, w.wa, k: nil)
        // A window too short for anything: no progress, offline, backed off.
        try w.a.newNote("one more")
        let (_, r) = w.run(w.a, w.wa, k: 1)
        if let r {
            XCTAssertFalse(r.outcome.success)
            XCTAssertEqual(WebDAVSyncProblem.from(report: r), [.offline], "\(r.errors)")
        }
    }

    // MARK: P6: what goes first

    /// The inbox (a quick voice note) and this device's own summaries file reach the target in the first window, before
    /// the notes backlog.
    func testInboxAndOwnSummariesGoBeforeTheBacklog() throws {
        let w = try World(root: tmp.appendingPathComponent("inbox"))
        try seed(w, notes: 120)
        let cap = try w.a.captureVoiceNote(Data(repeating: 7, count: 2000))
        try w.a.publishSummaries()
        let own = PublishedSummaries.deviceFileName(w.a.vaultDevice)
        let (s, r) = w.run(w.a, w.wa, k: 30)
        let inbox = (try? w.devs.inspector.list([CaptureFile.folderName]))??.map(\.name) ?? []
        let sums = (try? w.devs.inspector.list([PublishedSummaries.deviceFolderName]))??.map(\.name) ?? []
        print("WINDOW inbox first: moved=\(s.moved) stopped=\(s.stopped) inbox@server=\(inbox) summaries@server=\(sums)")
        XCTAssertNotNil(r?.stoppedEarly, "the window ended in the notes")
        XCTAssertTrue(inbox.contains { $0.hasPrefix(cap.uuidString.lowercased()) }, "the capture is up: \(inbox)")
        XCTAssertTrue(sums.contains(own), "this device's summaries are up: \(sums)")
    }

    /// The notes this device changed go first, the newest first: an old note edited last is the first one uploaded.
    func testNewestLocalWritingGoesFirst() throws {
        let w = try World(root: tmp.appendingPathComponent("order"))
        try seed(w, notes: 30)
        _ = w.run(w.a, w.wa, k: nil)
        let ids = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let last = try XCTUnwrap(ids.last), middle = ids[ids.count / 2]
        for i in 0..<10 { try w.a.newNote("later \(i)") }
        try w.a.rename(middle, "edited before")
        try w.a.rename(last, "edited last")
        let (_, r) = w.run(w.a, w.wa, k: nil)
        let notes = (r?.uploaded ?? []).filter { $0.hasPrefix("notes/") }
        XCTAssertEqual(notes.first?.split(separator: "/")[1].description, last.uuidString.lowercased(), "\(notes.prefix(3))")
        XCTAssertEqual(notes.dropFirst().first?.split(separator: "/")[1].description, middle.uuidString.lowercased())
    }

    // MARK: P3: a large blob does not starve the rest

    /// A blob larger than the window (a PUT cannot resume) goes after every other file of the run: the other notes all
    /// reach the target over 1 MB windows, while the large one waits for a longer run.
    func testABigBlobDoesNotStarveSmallFiles() throws {
        let w = try World(root: tmp.appendingPathComponent("big"))
        try seed(w, notes: 40, blobBytes: [3_000_000], blobAtSortedIndex: 5)
        let hugeNote = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }[5]
            .uuidString.lowercased()
        let want = w.a.noteFiles()
        let small = want.filter { !$0.contains(hugeNote) }
        let s = try drive(w, w.a, w.wa, k: 60, bytes: 1_000_000, maxRuns: 30) { try w.server().isSuperset(of: small) }
        report("big blob K=60 bytes=1MB notes=40", s, converged: try w.server().isSuperset(of: small))
        let missing = small.subtracting(try w.server())
        XCTAssertTrue(missing.isEmpty, "small notes sorted after the huge blob never upload: \(missing.count) missing")
        XCTAssertLessThanOrEqual(s.count, 6, "the small files go in the first few windows: \(s.map(\.moved))")
        XCTAssertFalse(try w.server().contains { $0.contains(hugeNote) && !$0.contains("/att/") },
                       "the huge blob's note keeps its revisions until the blob is up")

        // Once a window cut it short, short runs leave it: they complete, nothing else waits, nothing is wasted.
        let (quiet, r) = w.run(w.a, w.wa, k: 60, bytes: 1_000_000)
        XCTAssertEqual(quiet.wasted, 0, "a short run does not start an upload it cannot finish")
        XCTAssertNil(r?.stoppedEarly)
        XCTAssertEqual(r?.deferred.count, 1, "\(r?.deferred ?? [])")
        XCTAssertTrue(r?.outcome.success == true)

        // A run told it has time (a background processing task, Sync Now, `--large-blobs now`) sends it, then its
        // note's revisions.
        let (_, long) = w.run(w.a, w.wa, k: nil, bytes: nil) { $0.largeBlobs = .now }
        XCTAssertEqual(long?.deferred, [])
        XCTAssertTrue(try w.server().isSuperset(of: want), "the large blob and its note are up after a long run")
        XCTAssertNil(try SyncState.load(w.a.stateURL)?.largeUploads, "nothing is left waiting")
    }

    /// P7: a vault too big for one deep listing (or a re-verify) lists its note folders in batches with their
    /// transfers, going on where the last run stopped: a short window makes progress, and the pull converges.
    func testAPullWithoutTheDeepListingConvergesOverShortWindows() throws {
        let w = try World(root: tmp.appendingPathComponent("pull"))
        try seed(w, notes: 300)
        try w.a.syncUntilQuiet()
        let want = w.a.noteFiles()
        let b = w.b
        let s = try drive(w, b, w.wb, k: 50, maxRuns: 60, done: { b.noteFiles() == want }) { $0.deepListing = false }
        report("B-pull K=50 notes=300 no deep listing", s, converged: b.noteFiles() == want)
        XCTAssertEqual(b.noteFiles(), want)
        XCTAssertTrue(s.dropLast().allSatisfy { $0.moved > 0 }, "every window moves something: \(s.map(\.moved))")
    }

    /// The large blobs go after every other file of the run, smallest first, each followed by its note's revisions,
    /// even when nothing cuts the run: the notes edited last are still uploaded first (P6), the large one last.
    func testLargeBlobsGoAfterEveryOtherFile() throws {
        let w = try World(root: tmp.appendingPathComponent("last"))
        try seed(w, notes: 12)
        let ids = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        func blob(_ n: Int, _ salt: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) ^ salt }) }
        let big = try w.a.attach(ids[3], blob(2_500_000, 1))
        let bigger = try w.a.attach(ids[0], blob(3_200_000, 2))
        _ = try w.a.attach(ids[7], blob(40_000, 3))
        let edited = ids[11]
        try w.a.rename(edited, "edited last")   // the newest writing
        let (_, r) = w.run(w.a, w.wa, k: nil)
        let up = try XCTUnwrap(r?.uploaded)
        XCTAssertEqual(r?.deferred, [])
        func at(_ p: (String) -> Bool) -> Int { up.firstIndex(where: p) ?? -1 }
        let firstNote = at { $0.hasPrefix("notes/") }
        XCTAssertTrue(up[firstNote].contains(edited.uuidString.lowercased()), "the newest writing first: \(up[firstNote])")
        let bigAt = at { $0.hasSuffix(big) }, biggerAt = at { $0.hasSuffix(bigger) }
        XCTAssertGreaterThan(bigAt, 0); XCTAssertGreaterThan(biggerAt, bigAt, "smallest first")
        let others = up.indices.filter { i in
            up[i].hasPrefix("notes/") && ![ids[3], ids[0]].contains { up[i].contains($0.uuidString.lowercased()) }
        }
        XCTAssertLessThan(others.max() ?? 0, bigAt, "every other note's files go first")
        let bigRevision = at { $0.contains(ids[3].uuidString.lowercased()) && !$0.contains("/att/") }
        XCTAssertGreaterThan(bigRevision, bigAt, "a note's revisions follow its large blob")
        XCTAssertLessThan(bigRevision, biggerAt)
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()))
    }

    /// A large blob a window cut short is left by short runs, but never for ever: after `largeRetryAfter` runs in a row
    /// that left it, a run tries it anyway (after every other file), and on a link that now lasts, it goes up. While it
    /// waits, the device does not record `synced` (a change of its own is not on the target).
    func testALeftLargeBlobIsTriedAgainAfterAFewRuns() throws {
        let w = try World(root: tmp.appendingPathComponent("retry"))
        try seed(w, notes: 6, blobBytes: [2_000_000], blobAtSortedIndex: 2)
        let want = w.a.noteFiles()
        let (cut, _) = w.run(w.a, w.wa, k: nil, bytes: 1_200_000)
        XCTAssertGreaterThan(cut.wasted, 0, "the first try is cut")
        XCTAssertNotNil(try SyncState.load(w.a.stateURL)?.largeUploads?.cutAt)
        var lefts = 0
        for i in 0..<SyncEngine.largeRetryAfter {
            let (st, r) = w.run(w.a, w.wa, k: nil)   // the link would last now, but the runs do not know it
            XCTAssertEqual(r?.deferred.count, 1, "run \(i)")
            XCTAssertEqual(st.wasted, 0)
            XCTAssertTrue(r?.outcome.success == true)
            lefts += 1
        }
        XCTAssertNil(try w.a.vault().lastSynced(device: w.a.vaultDevice.rawValue), "no synced while a change waits")
        XCTAssertEqual(try SyncState.load(w.a.stateURL)?.largeUploads?.deferredRuns, lefts)
        XCTAssertFalse(try w.server().isSuperset(of: want))
        let (_, turn) = w.run(w.a, w.wa, k: nil)
        XCTAssertEqual(turn?.deferred, [], "the turn that tries it anyway")
        XCTAssertTrue(try w.server().isSuperset(of: want))
        XCTAssertNil(try SyncState.load(w.a.stateURL)?.largeUploads, "a larger upload went through: nothing waits")
        _ = w.run(w.a, w.wa, k: nil)
        XCTAssertNotNil(try w.a.vault().lastSynced(device: w.a.vaultDevice.rawValue), "synced once nothing waits")
    }

    /// A quick voice note whose recording is large: once adopted, its note waits for a longer run with the recording,
    /// and the capture stays on the target until they go (another device can still adopt it meanwhile).
    func testACaptureStaysOnTheTargetWhileItsNoteWaitsForALargeRecording() throws {
        let w = try World(root: tmp.appendingPathComponent("capture"))
        try seed(w, notes: 3)
        let audio = Data((0..<1_800_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let cap = try w.a.captureVoiceNote(audio)
        _ = w.run(w.a, w.wa, k: nil)
        func onServer() -> [String] { ((try? w.devs.inspector.list([CaptureFile.folderName])) ?? nil)?.map(\.name) ?? [] }
        XCTAssertTrue(onServer().contains { $0.hasPrefix(cap.uuidString.lowercased()) })
        XCTAssertEqual(try w.a.adoptInbox(), 1)
        let note = CaptureAdoption.ids(for: cap).note.uuidString.lowercased()
        _ = w.run(w.a, w.wa, k: nil, bytes: 1_000_000)   // the recording's upload is cut
        let (_, left) = w.run(w.a, w.wa, k: nil, bytes: 1_000_000)
        XCTAssertEqual(left?.deferred.count, 1, "\(left?.deferred ?? [])")
        XCTAssertNil(left?.stoppedEarly)
        XCTAssertTrue(onServer().contains { $0.hasPrefix(cap.uuidString.lowercased()) }, "the capture stays")
        XCTAssertFalse(try w.server().contains { $0.contains(note) && !$0.contains("/att/") }, "its note waits")
        _ = w.run(w.a, w.wa, k: nil) { $0.largeBlobs = .now }
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()))
        _ = w.run(w.a, w.wa, k: nil)
        XCTAssertFalse(onServer().contains { $0.hasPrefix(cap.uuidString.lowercased()) }, "gone once its note is up")
    }

    /// Upload-only runs (the app's runs of a closed or locked vault, push-only) send large blobs last too.
    func testUploadOnlyRunsSendLargeBlobsLast() throws {
        let w = try World(root: tmp.appendingPathComponent("push"))
        try seed(w, notes: 10, blobBytes: [2_000_000], blobAtSortedIndex: 4)
        let hugeNote = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }[4]
            .uuidString.lowercased()
        let small = w.a.noteFiles().filter { !$0.contains(hugeNote) }
        let (cut, _) = w.run(w.a, w.wa, k: nil, bytes: 1_000_000) { $0.pushOnly = true; $0.keepServerChanges = true }
        XCTAssertGreaterThan(cut.wasted, 0, "the large blob's upload is cut")
        XCTAssertTrue(try w.server().isSuperset(of: small), "every other note went before the large blob")
        let (_, r2) = w.run(w.a, w.wa, k: nil, bytes: 1_000_000) { $0.pushOnly = true; $0.keepServerChanges = true }
        XCTAssertEqual(r2?.deferred.count, 1)
        XCTAssertTrue(r2?.errors.isEmpty == true, "\(r2?.errors ?? [])")
        let (_, r3) = w.run(w.a, w.wa, k: nil) { $0.pushOnly = true; $0.keepServerChanges = true; $0.largeBlobs = .now }
        XCTAssertEqual(r3?.deferred, [])
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()))
    }

    // MARK: P7: the batched sweep

    /// Runs that list the note folders in batches sweep the vault across short windows: a sweep that reached the last
    /// note counts as a full listing (when it started), so `skipUnchangedNotes` takes over and later runs list only
    /// what changed. The note edited here goes first in every run.
    func testABatchedSweepAcrossShortRunsCountsAsAFullListing() throws {
        let w = try World(root: tmp.appendingPathComponent("sweep"))
        try seed(w, notes: 90)
        let plain: (inout SyncOptions) -> Void = { $0.deepListing = false; $0.skipUnchangedNotes = true }
        _ = w.run(w.a, w.wa, k: nil, plain)
        // A write into a folder the server listed shows whether it keeps folder ETags current (`NoteStamps.swift`).
        let first = try XCTUnwrap(try w.a.vault().noteIDs().first)
        try w.a.rename(first, "probe")
        for _ in 0..<2 { _ = w.run(w.a, w.wa, k: nil, plain) }
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()))
        XCTAssertEqual(try SyncState.load(w.a.stateURL)?.folderETagsChange, true)
        // A day later: every note must be listed again, and no window fits all 90.
        let later = Date().addingTimeInterval(2 * 86_400)
        let stale: (inout SyncOptions) -> Void = { plain(&$0); $0.now = later }
        var starts: [Date] = []
        var requests: [Int] = []
        for _ in 0..<12 {
            let (st, r) = w.run(w.a, w.wa, k: 40, stale)
            XCTAssertNotNil(r?.stoppedEarly, "no window lists them all")
            requests.append(st.requests)
            if let p = try SyncState.load(w.a.stateURL)?.listingPass { starts.append(p.started) }
            if let full = try SyncState.load(w.a.stateURL)?.lastFullListing, full >= later { break }
        }
        let full = try XCTUnwrap(try SyncState.load(w.a.stateURL)?.lastFullListing)
        XCTAssertEqual(full, later, "the sweep counts as a full listing from when it started: \(requests)")
        // Unchanged folders are no longer listed: one window carries a whole run now.
        let ids = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        try w.a.rename(try XCTUnwrap(ids.last), "edited")
        let (st, r) = w.run(w.a, w.wa, k: 40, stale)
        XCTAssertNil(r?.stoppedEarly, "\(st.requests) requests")
        XCTAssertEqual(r?.uploaded.first { $0.hasPrefix("notes/") }?.split(separator: "/")[1].description,
                       ids.last?.uuidString.lowercased())
    }

    // MARK: Review of #97

    /// S1: what the large-blob pass uploads is recorded as held on both sides, with the bytes sent, as the note loop
    /// records its own uploads; the next run has nothing to do.
    func testTheLargePassRecordsWhatItUploads() throws {
        let w = try World(root: tmp.appendingPathComponent("record"))
        try seed(w, notes: 4, blobBytes: [1_600_000], blobAtSortedIndex: 1)
        let note = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }[1]
            .uuidString.lowercased()
        let (_, r) = w.run(w.a, w.wa, k: nil)
        let notes = (r?.uploaded ?? []).filter { $0.hasPrefix("notes/") }
        XCTAssertTrue(notes.last?.contains(note) == true, "the large note goes last: \(notes.suffix(2))")
        let state = try XCTUnwrap(try SyncState.load(w.a.stateURL))
        let mine = w.a.noteFiles().filter { $0.contains(note) }
        XCTAssertFalse(mine.isEmpty)
        for f in mine {
            let k = String(f.dropFirst("notes/".count))
            let record = try XCTUnwrap(state.files[k], "\(k) is recorded")
            if !f.contains("/att/") {
                let bytes = try Data(contentsOf: w.a.folder.appendingPathComponent(f))
                XCTAssertEqual(record.sha256, FileDigest.sha256(bytes), "\(k) is recorded with the bytes sent")
            }
        }
        let (_, next) = w.run(w.a, w.wa, k: nil)
        XCTAssertTrue(next?.isEmpty == true, "\(String(describing: next))")
    }

    /// S2: a cut is forgotten after a day; only blobs of 1 MiB or more are left for a longer run (smaller ones a cut
    /// reached go last, but go); a forced turn spends the record even when its own try did not connect; a request that
    /// never connected is no cut.
    func testACutIsBoundedInTimeSizeAndEvidence() throws {
        let w = try World(root: tmp.appendingPathComponent("cut"))
        try seed(w, notes: 3)
        let ids = try w.a.vault().noteIDs().sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        func blob(_ n: Int, _ salt: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 11) ^ salt }) }
        _ = w.run(w.a, w.wa, k: nil)
        // A connection that never opens is no cut.
        _ = try w.a.attach(ids[0], blob(400_000, 1))
        w.wa.refuseWritesOver = 300_000
        _ = w.run(w.a, w.wa, k: nil)
        XCTAssertNil(try SyncState.load(w.a.stateURL)?.largeUploads?.cutAt, "nothing was sent: not a cut")
        w.wa.refuseWritesOver = nil
        // A 400 KB upload cut mid-body is.
        _ = w.run(w.a, w.wa, k: nil, bytes: 200_000)
        XCTAssertEqual(try SyncState.load(w.a.stateURL)?.largeUploads?.cutAt.map { $0 > 300_000 }, true)
        // Blobs under 1 MiB still go (last), larger ones wait.
        _ = try w.a.attach(ids[1], blob(1_500_000, 2))
        let (_, r) = w.run(w.a, w.wa, k: nil)
        XCTAssertEqual(r?.deferred.map(\.path).count, 1, "\(r?.deferred ?? [])")
        XCTAssertTrue(r?.deferred.first?.path.contains(ids[1].uuidString.lowercased()) == true)
        XCTAssertTrue(r?.uploaded.contains { $0.contains(ids[0].uuidString.lowercased()) && $0.contains("/att/") } == true,
                      "the 400 KB blob a cut reached goes, last")
        // A day later the cut is forgotten.
        let (_, later) = w.run(w.a, w.wa, k: nil) { $0.now = Date().addingTimeInterval(25 * 3600) }
        XCTAssertEqual(later?.deferred, [])
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()))
        XCTAssertNil(try SyncState.load(w.a.stateURL)?.largeUploads)

        // A forced turn spends the record even when its try never connected.
        _ = try w.a.attach(ids[2], blob(2_200_000, 3))
        _ = w.run(w.a, w.wa, k: nil, bytes: 1_000_000)
        XCTAssertNotNil(try SyncState.load(w.a.stateURL)?.largeUploads?.cutAt)
        for _ in 0..<SyncEngine.largeRetryAfter { _ = w.run(w.a, w.wa, k: nil) }
        w.wa.refuseWritesOver = 1_000_000
        let (_, turn) = w.run(w.a, w.wa, k: nil)
        XCTAssertEqual(turn?.deferred, [], "the forced turn tries it")
        XCTAssertNil(try SyncState.load(w.a.stateURL)?.largeUploads?.cutAt, "the forced turn spent the cut")
        w.wa.refuseWritesOver = nil
        _ = w.run(w.a, w.wa, k: nil)
        XCTAssertTrue(try w.server().isSuperset(of: w.a.noteFiles()), "an ordinary run sends it now")
    }

    /// S3: a note whose folder listing failed for the network is where the next run goes on: the batched cursor never
    /// passes it, even when the run goes on.
    func testTheBatchedCursorStopsAtAFolderWhoseListingFailed() throws {
        let w = try World(root: tmp.appendingPathComponent("cursor"))
        try seed(w, notes: 60)
        let plain: (inout SyncOptions) -> Void = { $0.deepListing = false }
        _ = w.run(w.a, w.wa, k: nil, plain)
        _ = w.run(w.a, w.wa, k: nil, plain)
        let ids = try w.a.vault().noteIDs().map { $0.uuidString.lowercased() }.sorted()
        let failing = ids[3]
        // The sweep starts at the first note this run.
        var state = try XCTUnwrap(try SyncState.load(w.a.stateURL))
        state.listingPass = nil
        try state.save(w.a.stateURL)
        w.wa.failListingOnce = [[Vault.notesName, failing]]
        let (_, r) = w.run(w.a, w.wa, k: nil, plain)
        XCTAssertTrue(r?.errors.contains { $0.path == "notes/\(failing)" } == true, "\(r?.errors ?? [])")
        let pass = try SyncState.load(w.a.stateURL)?.listingPass
        XCTAssertEqual(pass?.cursor, ids[2], "the cursor stays before \(failing), the next run goes on there")
        XCTAssertEqual(pass?.clean, false)
    }
}

// MARK: - A pass over every shared file under short windows (review of #92)

final class ShortWindowComparePassTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    /// After a branch replacement every shared file is compared once (`compareShared`, key-hierarchy design §16.13).
    /// Over short windows, each run is cut before the pass ends; the files it compared are kept (`comparedShared`), so
    /// the next window goes on from them instead of reading the same first ones again, and the pass ends.
    func testTheComparePassGoesOnAcrossShortWindowsAndEnds() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "D"])
        let t = w.target("T1")
        let notes = 40
        for i in 0..<notes { try w["A"].write("note \(i)") }
        try w["A"].sync(t)
        try w["D"].syncUntilQuiet(t)
        XCTAssertEqual(try w["D"].titles().count, notes + 0)
        let log = ReadLog()
        t.reach = { _ in ListFailingRemote(base: MemoryRemote(store: t.store), failing: { _ in false }, reads: log) }
        // As `compareSharedAfterBranch` leaves it.
        let stateURL = w["D"].stateURL(t)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        json["compareShared"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)

        // Other work waiting meanwhile: a note of A's to download, one of D's to upload.
        let fromA = try w["A"].write("A, later")
        try w["A"].sync(t)
        let fromD = try w["D"].write("D, later")
        log.reset()
        func revisionReads() -> [String] {
            log.paths.filter { $0.hasPrefix("notes/") && $0.hasSuffix(".age") && !$0.contains("/att/")
                && !$0.contains(fromA.uuidString.lowercased()) && !$0.contains(fromD.uuidString.lowercased()) }
        }
        t.window = (requests: 24, bytes: nil)
        var runs = 0
        var cut = 0
        while runs < 30 {
            runs += 1
            let r = try? w["D"].sync(t)
            if r?.stoppedEarly != nil || r == nil { cut += 1 }
            if Set(revisionReads()).count >= notes { break }
        }
        let reads = revisionReads()
        XCTAssertEqual(try w["D"].titles()[fromA], "A, later", "the download got through the windows")
        XCTAssertTrue(t.paths.contains { $0.hasPrefix("notes/\(fromD.uuidString.lowercased())/") }, "the upload too")
        XCTAssertGreaterThan(cut, 1, "the windows cut the pass")
        XCTAssertEqual(Set(reads).count, notes, "every shared file compared, after \(runs) windows")
        XCTAssertEqual(reads.count, Set(reads).count, "none read twice for the pass")
        t.window = nil
        log.reset()
        try w["D"].sync(t)
        XCTAssertEqual(revisionReads(), [], "the pass goes on without reading the compared files again")
        let after = try XCTUnwrap(try SyncState.load(stateURL))
        XCTAssertNil(after.compareShared, "a complete run ends the pass")
        XCTAssertNil(after.comparedShared)
        XCTAssertEqual(try w["D"].titles().count, notes + 2)
    }

    /// A comparison that did not reach a decision is not counted as made: the target holds an unaccepted copy of a
    /// shared file under the tag D recorded (a losing branch's same-size re-seal within the second), and the PUT that
    /// replaces it fails once (the window drops it). D's next run in the pass compares it again and replaces it.
    func testAComparisonCutBeforeItsDecisionIsMadeAgain() throws {
        let second = Locked(1_900_000_000)
        var server: MockDAV?
        let t = try TransportUnderTest.mockDAV { s in
            s.secondETagClock = { second.value }
            server = s
        }
        let mock = try XCTUnwrap(server)
        let target = EpochTarget.over(t, name: "T1", seed: 1, faults: { 0 })
        let w = try EpochSyncWorld(in: tmp, names: ["A", "D"], made: [target])
        let notes = (0..<4).map { _ in UUID() }
        for (i, id) in notes.enumerated() { try w["A"].write("note \(i)", id: id) }
        try w["A"].sync(target)
        try w["D"].syncUntilQuiet(target)
        let file = try XCTUnwrap(target.paths.sorted().first { $0.hasPrefix("notes/\(notes[0].uuidString.lowercased())/") })
        let comps = file.split(separator: "/").map(String.init)
        let accepted = try XCTUnwrap(target.file(file))
        let tag = try t.inspector.stat(comps)?.etag

        // Under the tag D recorded: a copy of the same size no key here opens.
        let plain = try AgeFile.decrypt(accepted, with: try w["D"].open().identities)
        let junk = try AgeFile.encrypt(Data((0..<plain.count).map { UInt8(truncatingIfNeeded: $0 &* 13) }),
                                       to: [pqIdentity().recipient])
        XCTAssertEqual(junk.count, accepted.count)
        try t.inspector.write(comps, .data(junk), condition: .unconditional)
        XCTAssertEqual(try t.inspector.stat(comps)?.etag, tag, "the tag kept the second")
        // As `compareSharedAfterBranch` leaves it.
        let stateURL = w["D"].stateURL(target)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        json["compareShared"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)

        // The replacing PUT fails once.
        let failed = Locked(false)
        let name = comps.last ?? ""
        mock.interceptor = { r in
            guard r.method == "PUT", r.url.path.hasSuffix(name), !failed.value else { return nil }
            failed.value = true
            return WebDAVResponse(status: 503)
        }
        let first = try w["D"].sync(target)
        XCTAssertTrue(failed.value, "the replacing PUT was made and failed: \(first)")
        XCTAssertEqual(target.file(file), junk, "not replaced yet")
        let again = try w["D"].sync(target)
        XCTAssertTrue(again.replaced.contains(.init(side: "remote", path: file)), "compared again, replaced: \(again)")
        XCTAssertEqual(target.file(file), accepted)
    }
}
