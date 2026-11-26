import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// A remote that forwards to `base`, slows every upload under `notes/` (one at a time, through a gate: N notes take at least
/// N x `delay` however many transfer threads the engine uses) and calls `onNoteWrite` with the count of those uploads so far.
/// A first upload of a large vault, as the tests need it to be long.
final class SlowNotesRemote: SyncRemote, @unchecked Sendable {
    let base: any SyncRemote
    let delay: TimeInterval
    let onNoteWrite: @Sendable (Int) -> Void
    private let gate = NSLock(), lock = NSLock()
    private var count = 0
    init(_ base: any SyncRemote, delay: TimeInterval, onNoteWrite: @escaping @Sendable (Int) -> Void) {
        self.base = base; self.delay = delay; self.onNoteWrite = onNoteWrite
    }
    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? { get { base.interrupt } set { var b = base; b.interrupt = newValue } }
    func list(_ path: [String]) throws -> [RemoteEntry]? { try base.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try base.listTree(path, maxBytes: maxBytes) }
    func missingCollectionError(_ path: [String]) -> any Error { base.missingCollectionError(path) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try base.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { try base.read(path, maxBytes: maxBytes) }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try base.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes, segmentBytes: segmentBytes, progress: progress)
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
}
