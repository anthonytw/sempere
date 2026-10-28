import Foundation
import TempDirSupport
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// A remote whose writes fail as a full or broken target does: the review of #90's probe (M1), kept as a regression.
/// `budget` failures, then writes go through; `failCollections` makes folder creation fail too (so nothing succeeds
/// between two failures).
final class FullRemote: SyncRemote, @unchecked Sendable {
    private(set) var inner: any SyncRemote
    var full = false
    var budget = Int.max
    var failCollections = false
    var err: () -> Error = { FolderRemoteError.io("write x: No space left on device (errno 28)", transient: true) }
    init(_ inner: any SyncRemote) { self.inner = inner }
    var interrupt: (@Sendable () -> (any Error)?)? { get { inner.interrupt } set { inner.interrupt = newValue } }
    var location: String { inner.location }
    var capabilities: RemoteCapabilities { inner.capabilities }
    private func fail() throws { if full, budget > 0 { budget -= 1; throw err() } }
    func list(_ p: [String]) throws -> [RemoteEntry]? { try inner.list(p) }
    func listTree(_ p: [String], maxBytes: Int) throws -> RemoteTree? { try inner.listTree(p, maxBytes: maxBytes) }
    func stat(_ p: [String]) throws -> RemoteEntry? { try inner.stat(p) }
    func read(_ p: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { try inner.read(p, maxBytes: maxBytes) }
    func download(_ p: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try inner.download(p, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes, segmentBytes: segmentBytes,
                           progress: progress)
    }
    func write(_ p: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try fail()
        return try inner.write(p, body, condition: condition)
    }
    func moveNoOverwrite(_ p: [String], to d: [String]) throws -> Bool { try inner.moveNoOverwrite(p, to: d) }
    func makeCollection(_ p: [String]) throws -> CollectionResult {
        if failCollections { try fail() }
        return try inner.makeCollection(p)
    }
    func createBase() throws { try inner.createBase() }
    func delete(_ p: [String], ifETag: String?) throws -> Bool { try inner.delete(p, ifETag: ifETag) }
    func missingCollectionError(_ p: [String]) -> any Error { inner.missingCollectionError(p) }
    func requestDownload(_ paths: [[String]]) throws { try inner.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { inner.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try inner.readVersion(path, version, maxBytes: maxBytes)
    }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws { try inner.resolveConflicts(path, versions) }
    func changes() -> AsyncStream<RemoteChange>? { inner.changes() }
}

/// Review of #90, M1 and S1: a full target, an exceeded quota, an I/O error, a busy lock or a TLS failure is a lasting
/// failure (no `outcome.success`, no `synced`, never "offline"); only an unreachable remote is a cut (P8) or offline,
/// and a network failure on one file that did not end the run is still shown.
final class LastingTargetFailureTests: TempDirTestCase {
    /// A sends 3 notes; B writes 6 and syncs while its target fails writes with `err`.
    func run(_ err: @escaping () -> Error, budget: Int = Int.max, failCollections: Bool = false) throws -> (SyncReport, SyncDevice) {
        let store = MemoryStore(name: "S")
        var fulls: [String: FullRemote] = [:]
        let devs = try SyncDevices.make(root: tmp.appendingPathComponent(UUID().uuidString), count: 2, remote: { n in
            let f = FullRemote(MemoryRemote(store: store, base: ["vault"])); fulls[n] = f; return f
        }, inspector: MemoryRemote(store: store, base: ["vault"]))
        for d in devs.devices { d.tune = { $0.concurrency = 1; $0.recordSynced = true } }
        for i in 0..<3 { _ = try devs.a.newNote("a\(i)") }
        _ = try devs.a.sync()
        for i in 0..<6 { _ = try devs.b.newNote("b\(i)") }
        let f = try XCTUnwrap(fulls["B"])
        f.full = true
        f.err = err
        f.budget = budget
        f.failCollections = failCollections
        return (try devs.b.sync(), devs.b)
    }

    /// Lasting: no success, a `.failures` problem, never offline, no `synced`, never a lost link.
    func assertLasting(_ r: SyncReport, _ b: SyncDevice, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(r.outcome.success, "\(label): \(r.errors)", file: file, line: line)
        XCTAssertFalse(r.outcome.offline, label, file: file, line: line)
        XCTAssertNil(r.linkLost, label, file: file, line: line)
        XCTAssertNotEqual(r.stopReason, .connectionLost, label, file: file, line: line)
        let problems = WebDAVSyncProblem.from(report: r)
        XCTAssertFalse(problems.contains(.offline), "\(label): \(problems)", file: file, line: line)
        XCTAssertTrue(problems.contains { if case .failures = $0 { return true } else { return false } }, "\(label): \(problems)",
                      file: file, line: line)
        XCTAssertNil(try b.vault().lastSynced(device: b.vaultDevice.rawValue), "\(label): no synced recorded", file: file, line: line)
    }

    func testAFullTargetIsAFailure() throws {
        let (r, b) = try run { FolderRemoteError.io("write x: No space left on device (errno 28)", transient: true) }
        try assertLasting(r, b, "ENOSPC on every write")
    }

    func testAQuotaOnOneFileIsAFailure() throws {
        let (r, b) = try run({ FolderRemoteError.io("write x: Disc quota exceeded (errno 69)", transient: true) }, budget: 1)
        XCTAssertNil(r.stoppedEarly)
        try assertLasting(r, b, "EDQUOT on one write")
    }

    func testIOErrorsAndABusyLockAreFailures() throws {
        let (r, b) = try run { FolderRemote.ioError("write x", EIO) }
        try assertLasting(r, b, "EIO")
        let (r2, b2) = try run { FolderRemoteError.busy("/vault") }
        try assertLasting(r2, b2, "busy lock")
    }

    func testFailuresInARowOnAFullTargetNeverReadAsALostLink() throws {
        let (r, b) = try run({ FolderRemoteError.io("write x: No space left on device (errno 28)", transient: true) },
                             failCollections: true)
        try assertLasting(r, b, "ENOSPC on writes and folders")
    }

    func testATLSFailureIsAFailureNeverOffline() throws {
        let (r, b) = try run { WebDAVError.transport("An SSL error has occurred and a secure connection to the server cannot be made.") }
        try assertLasting(r, b, "TLS")
        XCTAssertEqual(URLSessionTransport.classify(URLError(.secureConnectionFailed)).isUnreachable, false)
    }

    /// S1: a network failure on one file that did not end the run is still a failure to show (a file that always times
    /// out would otherwise never surface).
    func testOneNetworkFailureThatDidNotEndTheRunIsShown() throws {
        let (r, b) = try run({ MemoryRemoteError.offline("timed out") }, budget: 1)
        XCTAssertNil(r.stoppedEarly)
        XCTAssertFalse(r.outcome.success, "\(r.errors)")
        XCTAssertNil(try b.vault().lastSynced(device: b.vaultDevice.rawValue))
    }

    /// Only the remote being unreachable counts as such.
    func testOnlyNetworkErrorsAreUnreachable() {
        XCTAssertTrue(FolderRemote.ioError("x", ENETUNREACH).isUnreachable)
        XCTAssertTrue(FolderRemote.ioError("x", ETIMEDOUT).isUnreachable)
        XCTAssertTrue(FolderRemote.ioError("x", ESTALE).isUnreachable)
        for code in [ENOSPC, EDQUOT, EIO, EBUSY, EAGAIN] {
            let e = FolderRemote.ioError("x", code)
            XCTAssertFalse(e.isUnreachable, "errno \(code)")
            XCTAssertTrue(e.isTransient, "errno \(code): a partial download is still kept")
        }
        XCTAssertFalse(FolderRemoteError.busy("x").isUnreachable)
        XCTAssertTrue(WebDAVError.offline("x").isUnreachable)
        XCTAssertFalse(WebDAVError.transport("x").isUnreachable)
        XCTAssertTrue(URLSessionTransport.classify(URLError(.timedOut)).isUnreachable)
        XCTAssertTrue(URLSessionTransport.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))).isUnreachable)
        XCTAssertTrue(MemoryRemoteError.offline("x").isUnreachable)
        XCTAssertFalse(MemoryRemoteError.unavailable("x").isUnreachable)
    }
}
