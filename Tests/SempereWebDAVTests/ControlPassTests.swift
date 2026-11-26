import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// A remote that forwards to `base`, slows every upload under `notes/` (one at a time, through a gate: N notes take at least
/// N x `delay` however many transfer threads the engine uses) and calls `onNoteWrite` with the count of those uploads so far.
/// A first upload of a large vault, as the tests need it to be long.
final class SlowNotesRemote: SyncRemote, @unchecked Sendable {
    private var inner: any SyncRemote
    var base: any SyncRemote { inner }
    let delay: TimeInterval
    let onNoteWrite: @Sendable (Int) -> Void
    private let gate = NSLock(), lock = NSLock()
    private var count = 0
    init(_ base: any SyncRemote, delay: TimeInterval, onNoteWrite: @escaping @Sendable (Int) -> Void) {
        self.inner = base; self.delay = delay; self.onNoteWrite = onNoteWrite
    }
    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? { get { inner.interrupt } set { inner.interrupt = newValue } }
    func list(_ path: [String]) throws -> [RemoteEntry]? { try base.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try base.listTree(path, maxBytes: maxBytes) }
    func missingCollectionError(_ path: [String]) -> any Error { base.missingCollectionError(path) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try base.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        let got = try base.read(path, maxBytes: maxBytes)
        noteDownloaded(path)
        return got
    }
    private func noteDownloaded(_ path: [String]) {
        guard countsDownloads, path.first == Vault.notesName, path.count > 2 else { return }
        gate.withLock { Thread.sleep(forTimeInterval: delay) }
        let n = lock.withLock { count += 1; return count }
        onNoteWrite(n)
    }
    /// Count and slow the downloads of note files, as the uploads (a long pull).
    var countsDownloads = false
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        defer { noteDownloaded(path) }
        return try base.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes, segmentBytes: segmentBytes, progress: progress)
    }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        let isNote = path.first == Vault.notesName && path.count > 2
        if isNote { gate.withLock { Thread.sleep(forTimeInterval: delay) } }
        let wrote = try base.write(path, body, condition: condition)
        if isNote {
            let n = lock.withLock { count += 1; return count }
            onNoteWrite(n)
        }
        return wrote
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool { try base.moveNoOverwrite(path, to: destination) }
    func makeCollection(_ path: [String]) throws -> CollectionResult { try base.makeCollection(path) }
    func createBase() throws { try base.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { try base.delete(path, ifETag: ifETag) }
    func prepareRun() throws { try base.prepareRun() }
    /// Calls so far, and an error to throw at a call (the number of the call, from 1).
    private(set) var refreshes = 0
    var refreshFailure: (@Sendable (Int) -> (any Error)?)?
    func refreshListing() throws {
        let n = lock.withLock { refreshes += 1; return refreshes }
        if let error = refreshFailure?(n) { throw error }
        try base.refreshListing()
    }
    func checkAbsentBase(syncedBefore: Bool) throws { try base.checkAbsentBase(syncedBefore: syncedBefore) }
}

/// A join request or an approval written while a long run goes reaches the other side before the run ends, with no interrupt
/// and no second run (docs/design/1.4-cloudkit.md §17): the run looks at the control files again between its transfers.
final class ControlPassTests: TempDirTestCase {
    static let notes = 36
    static let writeAt = 6, checkFrom = 24

    /// The fixture for one transport kind: home A with `notes` new notes that a slow first upload sends, a joining device N.
    private func scenario(_ make: () throws -> TransportUnderTest, interval: TimeInterval = 0.05,
                          mid: @escaping @Sendable (EpochSyncWorld, EpochTarget, JoinRequest) throws -> Void,
                          after: @escaping @Sendable (EpochSyncWorld, EpochTarget, JoinRequest) -> Bool) throws -> (seen: Bool, report: SyncReport) {
        let t = try make()
        let target = EpochTarget.over(t, name: "T1", seed: 1, faults: { 0 })
        let w = try EpochSyncWorld(in: tmp, names: ["A"], made: [target])
        let n = EpochSyncDevice("N", root: tmp)
        try n.syncLocked(target)
        let request = try Vault.writeJoinRequest(at: n.folder, device: n.keys, name: "N", kind: "cli")
        for i in 0..<Self.notes { try w["A"].write("note \(i)") }
        let seen = Locked(false)
        let failure = Locked<Error?>(nil)
        let inner = target.reach
        let world = UncheckedSendable(w)
        target.reach = { device in
            let base = inner?(device) ?? MemoryRemote(store: target.store)
            guard device == "A" else { return base }
            return SlowNotesRemote(base, delay: 0.03) { count in
                do {
                    if count == Self.writeAt { try mid(world.value, target, request) }
                    if count >= Self.checkFrom, after(world.value, target, request) { seen.value = true }
                } catch { failure.value = error }
            }
        }
        let report = try w["A"].sync(target) { $0.controlCheckInterval = interval }
        if let error = failure.value { throw error }
        return (seen.value, report)
    }

    private func requestReachesHomeMidRun(_ make: () throws -> TransportUnderTest) throws {
        let (seen, report) = try scenario(make, mid: { _, target, request in
            // N's run puts its request on the target while A's run is uploading.
            target.put("joins/\(request.fileName)", try JSONEncoder().encode(request))
        }, after: { w, _, request in
            FileManager.default.fileExists(atPath: w["A"].folder.appendingPathComponent("joins/\(request.fileName)").path)
        })
        XCTAssertTrue(seen, "A's copy held the request before its run ended: \(report)")
        XCTAssertTrue(report.stoppedEarly == nil && report.errors.isEmpty, "\(report)")
    }

    private func approvalReachesTargetMidRun(_ make: () throws -> TransportUnderTest) throws {
        let (seen, report) = try scenario(make, mid: { w, _, request in
            // Home approves (a local write of vault.json, as the app's approval is) while its run uploads.
            var v = try w["A"].open()
            _ = try v.approveDevice(request)
        }, after: { w, target, _ in
            guard let data = target.file(Vault.manifestName), let m = try? EpochManifest.parse(data) else { return false }
            return m.devices.count == 2
        })
        XCTAssertTrue(seen, "the target held the approval's vault.json before A's run ended: \(report)")
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
    }

    func testARequestReachesHomeMidRunOnMemory() throws { try requestReachesHomeMidRun { .memory() } }
    func testARequestReachesHomeMidRunOnCloudKit() throws { try requestReachesHomeMidRun { .cloud() } }
    func testARequestReachesHomeMidRunOnAFolder() throws { try requestReachesHomeMidRun { [tmp] in .folder(tmp.appendingPathComponent("target")) } }
    func testARequestReachesHomeMidRunOnWebDAV() throws { try requestReachesHomeMidRun { try .mockDAV() } }

    func testAnApprovalReachesTheTargetMidRunOnMemory() throws { try approvalReachesTargetMidRun { .memory() } }
    func testAnApprovalReachesTheTargetMidRunOnCloudKit() throws { try approvalReachesTargetMidRun { .cloud() } }
    func testAnApprovalReachesTheTargetMidRunOnAFolder() throws { try approvalReachesTargetMidRun { [tmp] in .folder(tmp.appendingPathComponent("target")) } }
    func testAnApprovalReachesTheTargetMidRunOnWebDAV() throws { try approvalReachesTargetMidRun { try .mockDAV() } }

    /// With the pass off (an interval longer than the run) neither goes out: the tests above see the pass, not the run's end.
    func testWithoutThePassTheRequestWaitsForTheNextRun() throws {
        let (seen, _) = try scenario({ .memory() }, interval: 3600, mid: { _, target, request in
            target.put("joins/\(request.fileName)", try JSONEncoder().encode(request))
        }, after: { w, _, request in
            FileManager.default.fileExists(atPath: w["A"].folder.appendingPathComponent("joins/\(request.fileName)").path)
        })
        XCTAssertFalse(seen)
    }

    func testWithoutThePassTheApprovalWaitsForTheNextRun() throws {
        let (seen, _) = try scenario({ .memory() }, interval: 3600, mid: { w, _, request in
            var v = try w["A"].open()
            _ = try v.approveDevice(request)
        }, after: { _, target, _ in
            guard let data = target.file(Vault.manifestName), let m = try? EpochManifest.parse(data) else { return false }
            return m.devices.count == 2
        })
        XCTAssertFalse(seen)
    }

    // MARK: A server copy that moved on, a joiner's own long run, the mirror, a failing refresh

    /// A `vault.json` that someone else changed on the target mid-run (a label here; a later epoch or a home-side version change
    /// is judged the same way) is neither taken nor overwritten by the pass: the next run judges it, before the notes.
    private func foreignManifestIsLeftAlone(_ make: () throws -> TransportUnderTest) throws {
        let original = Locked<Data?>(nil), foreign = Locked<Data?>(nil)
        let (violated, report) = try scenario(make, mid: { w, target, _ in
            let local = try Data(contentsOf: w["A"].folder.appendingPathComponent(Vault.manifestName))
            original.value = local
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: local) as? [String: Any])
            json["label"] = "Changed on another device"
            let changed = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            foreign.value = changed
            target.put(Vault.manifestName, changed)
        }, after: { w, target, _ in
            let local = try? Data(contentsOf: w["A"].folder.appendingPathComponent(Vault.manifestName))
            return local != original.value || target.file(Vault.manifestName) != foreign.value
        })
        XCTAssertFalse(violated, "the pass left both copies as they were: \(report)")
        XCTAssertNotNil(foreign.value)
    }

    func testAForeignManifestIsLeftAloneOnMemory() throws { try foreignManifestIsLeftAlone { .memory() } }
    func testAForeignManifestIsLeftAloneOnCloudKit() throws { try foreignManifestIsLeftAlone { .cloud() } }
    func testAForeignManifestIsLeftAloneOnWebDAV() throws { try foreignManifestIsLeftAlone { try .mockDAV() } }
    func testAForeignManifestIsLeftAloneOnAFolder() throws { try foreignManifestIsLeftAlone { [tmp] in .folder(tmp.appendingPathComponent("target")) } }

    /// An interval of 0 (a pass due at every look) never starves the run: the pool hands out one item before each pause.
    func testAnIntervalOfZeroStillFinishesTheRun() throws {
        let (seen, report) = try scenario({ .memory() }, interval: 0, mid: { _, target, request in
            target.put("joins/\(request.fileName)", try JSONEncoder().encode(request))
        }, after: { w, _, request in
            FileManager.default.fileExists(atPath: w["A"].folder.appendingPathComponent("joins/\(request.fileName)").path)
        })
        XCTAssertTrue(seen)
        XCTAssertEqual(report.uploaded.filter { $0.hasPrefix("notes/") }.count, Self.notes, "\(report.errors)")
    }

    /// A mid-run refresh that fails: a transient error is reported once and the run goes on; an error that is not transient (the
    /// account changed) stops it.
    private func runWithFailingRefresh(_ error: any Error) throws -> (report: SyncReport, state: URL) {
        let t = TransportUnderTest.memory()
        let target = EpochTarget.over(t, name: "T1", seed: 1, faults: { 0 })
        let w = try EpochSyncWorld(in: tmp, names: ["A"], made: [target])
        for i in 0..<Self.notes { try w["A"].write("note \(i)") }
        let inner = target.reach
        target.reach = { device in
            let base = inner?(device) ?? MemoryRemote(store: target.store)
            let slow = SlowNotesRemote(base, delay: 0.02) { _ in }
            slow.refreshFailure = { n in n >= 2 ? error : nil }
            return slow
        }
        let report = try w["A"].sync(target) { $0.controlCheckInterval = 0.05 }
        return (report, w["A"].stateURL(target))
    }

    func testATransientRefreshFailureIsReportedOnceAndTheRunGoesOn() throws {
        let (report, _) = try runWithFailingRefresh(CloudRecordError.throttled(until: Date().addingTimeInterval(1)))
        let said = report.skipped.filter { $0.message.contains("control files not looked at again") }
        XCTAssertEqual(said.count, 1, "\(report.skipped)")
        XCTAssertTrue(report.uploaded.filter { $0.hasPrefix("notes/") }.count >= Self.notes, "the run finished its uploads")
    }

    /// An error that means the target is not this vault's any more (the account changed) stops the run as a bound does: the report
    /// says so and the sync state is kept.
    func testAnAccountErrorInARefreshStopsTheRunAndKeepsItsState() throws {
        let (report, state) = try runWithFailingRefresh(CloudRecordError.otherAccount)
        XCTAssertNotNil(report.stoppedEarly, "\(report)")
        XCTAssertTrue(report.uploaded.filter { $0.hasPrefix("notes/") }.count < Self.notes, "it stopped before the end")
        XCTAssertNotNil(try SyncState.load(state), "the state was saved")
    }

    /// Any other error of the refresh (a proxy's 502, a server refusing one request) is reported once; the run goes on, finishes
    /// its uploads and saves its state: one bad request must not throw away hours of progress.
    func testAnotherNonTransientRefreshErrorIsReportedOnceAndTheRunGoesOn() throws {
        let (report, state) = try runWithFailingRefresh(CloudRecordError.corrupt(path: "zone feed", reason: "502 from a proxy"))
        XCTAssertNil(report.stoppedEarly, "\(report)")
        XCTAssertEqual(report.skipped.filter { $0.message.contains("control files not looked at again") }.count, 1)
        XCTAssertEqual(report.uploaded.filter { $0.hasPrefix("notes/") }.count, Self.notes)
        XCTAssertNotNil(try SyncState.load(state), "the state was saved")
    }
}
