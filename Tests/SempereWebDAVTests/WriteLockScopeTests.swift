import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// F7: a run never holds the vault's write lock across a request. A server that hangs while the run reads the
/// mutable files, or while it uploads them, does not block another writer of the vault on this device.
final class WriteLockScopeTests: SyncTestCase {
    struct World {
        let remote: MemoryRemote
        let a: Vault
        let b: Vault
    }

    func world() throws -> World {
        let a = try makeVault("A")
        try delta(a, device: devA, t: 1, title: "first")
        let remote = MemoryRemote(store: MemoryStore(name: "lock-scope"), base: ["dav", "v"])
        XCTAssertTrue(try run("A", a, remote).errors.isEmpty)
        try FileManager.default.copyItem(at: dir("A"), to: dir("B"))
        let b = try openVault("B")
        XCTAssertTrue(try run("B", b, remote).errors.isEmpty)
        return World(remote: remote, a: a, b: b)
    }

    var lock: VaultFileLock { VaultFileLock.at(tmp.appendingPathComponent("B.write")) }

    @discardableResult
    func run(_ name: String, _ vault: Vault, _ remote: any SyncRemote, locked: Bool = false) throws -> SyncReport {
        var options = SyncOptions(deviceLabel: name)
        if locked { options.localWriteLock = lock }
        return try SyncEngine(directory: dir(name), vault: vault, remote: remote,
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: options).run()
    }

    func changeSettings(_ vault: Vault, _ value: String) throws {
        var settings = try vault.readSharedSettings() ?? SharedSettings()
        try settings.set(SettingSlotKey("eraser.mode"), to: .string(value), type: .mac,
                         now: Date(timeIntervalSince1970: Double(baseMillis) / 1000 + Double(value.count)))
        try vault.writeSharedSettings(settings)
    }

    /// Runs B's sync on another thread against a remote that stops at the first `verb` of `file` until the test
    /// releases it; meanwhile the test takes the write lock, as an edit would.
    func assertLockFreeWhileStalled(_ w: World, verb: StallingRemote.Verb, file: String,
                                    line: UInt = #line) throws -> SyncReport {
        let stalled = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let remote = StallingRemote(base: w.remote, verb: verb, file: file, stalled: stalled, release: release)
        let b = w.b
        final class Box: @unchecked Sendable { var report: SyncReport?; var error: (any Error)? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let engine = SyncEngine(directory: dir("B"), vault: b, remote: remote,
                                stateURL: tmp.appendingPathComponent("state-B.json"),
                                options: { var o = SyncOptions(deviceLabel: "B"); o.localWriteLock = lock; return o }())
        nonisolated(unsafe) let unsafeEngine = engine
        Thread.detachNewThread {
            do { box.report = try unsafeEngine.run() } catch { box.error = error }
            done.signal()
        }
        XCTAssertEqual(stalled.wait(timeout: .now() + 30), .success, "the run reached the stalled request", line: line)
        // The run is stuck in a request: a local writer gets the lock at once.
        var took = false
        XCTAssertNoThrow(try lock.withLock(timeout: 2) { took = true }, "the write lock is free during the request", line: line)
        XCTAssertTrue(took, line: line)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success, line: line)
        if let error = box.error { throw error }
        return try XCTUnwrap(box.report, line: line)
    }

    func testAServerStalledWhileTheRunReadsSettingsDoesNotHoldTheLock() throws {
        let w = try world()
        try changeSettings(w.a, "pixel")
        try run("A", w.a, w.remote)
        let report = try assertLockFreeWhileStalled(w, verb: .read, file: SharedSettings.fileName)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(report.downloaded.contains(SharedSettings.fileName))
    }

    func testAServerStalledWhileTheRunUploadsDoesNotHoldTheLock() throws {
        let w = try world()
        var b = w.b
        try b.setLabel("Renamed on B")
        let report = try assertLockFreeWhileStalled(w, verb: .write, file: Vault.manifestName)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(report.uploaded.contains(Vault.manifestName))
        XCTAssertEqual(w.remote.store.file(w.remote.base + [Vault.manifestName]), try vaultJSON("B"), "uploaded after the lock")
        // In step: the next run has nothing to do with it.
        let again = try run("B", try openVault("B"), w.remote, locked: true)
        XCTAssertFalse(again.uploaded.contains(Vault.manifestName))
        XCTAssertFalse(again.downloaded.contains(Vault.manifestName))
    }

    /// The server's copy changed between the read before the lock and the upload after it: the upload's
    /// precondition fails, nothing is recorded for it, and the file is read and judged again under the lock in the
    /// same run: here both sides changed the settings, so they merge (format.md §13) and end in step.
    func testAnUploadRefusedBecauseTheServerMovedOnIsJudgedAgain() throws {
        let w = try world()
        try changeSettings(w.b, "pixel")
        try changeSettings(w.a, "object")
        let store = w.remote.store, path = w.remote.base + [SharedSettings.fileName]
        let fired = CallCounter()
        let aSettings = try BoundedRead.contents(of: dir("A").appendingPathComponent(SharedSettings.fileName), maxBytes: 1 << 20)
        let racing = InterposedRemote(base: w.remote) { written in
            // A uploads its own settings just before B's upload lands.
            if written == [SharedSettings.fileName], fired.next() == 1 { store.putDirect(path, aSettings) }
        }
        let report = try run("B", w.b, racing, locked: true)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        // A's change is the later one for the same setting: the merge is A's copy, taken here; nothing is
        // skipped, and the two sides end in step.
        XCTAssertTrue(report.downloaded.contains(SharedSettings.fileName) || report.merged.contains(SharedSettings.fileName), "\(report)")
        XCTAssertFalse(report.skipped.contains { $0.path == SharedSettings.fileName }, "\(report.skipped)")
        XCTAssertEqual(store.file(path), try BoundedRead.contents(of: dir("B").appendingPathComponent(SharedSettings.fileName), maxBytes: 1 << 20))
    }
}

extension WriteLockScopeTests {
    /// Every request of every kind, over runs that take, merge, keep and upload the mutable files, finds the
    /// write lock free: the tripwire for any request added under the lock later (F7). Conflict versions are a
    /// folder provider's local files (WebDAV has none), so those three verbs are not network requests.
    func testNoRequestIsMadeUnderTheLock() throws {
        let w = try world()
        let watch = { (remote: any SyncRemote) in LockWatchingRemote(base: remote, lock: self.lock) }
        func check(_ label: String, _ r: LockWatchingRemote, _ report: SyncReport) {
            XCTAssertTrue(r.violations.isEmpty, "\(label): requests under the write lock: \(r.violations)")
            XCTAssertGreaterThan(r.requests, 0, label)
            XCTAssertTrue(report.errors.isEmpty, "\(label): \(report.errors)")
        }
        // Server moved on (settings, label): taken.
        try changeSettings(w.a, "pixel")
        var a = w.a
        try a.setLabel("Renamed on A")
        try run("A", a, w.remote)
        var r = watch(w.remote)
        check("pull", r, try run("B", w.b, r, locked: true))
        // Only this side changed: uploaded after the lock.
        try changeSettings(w.b, "object")
        r = watch(w.remote)
        check("push", r, try run("B", try openVault("B"), r, locked: true))
        // Both sides changed: merged under the lock, uploaded after it.
        try changeSettings(w.a, "tip")
        try run("A", try openVault("A"), w.remote)
        try changeSettings(w.b, "ink")
        r = watch(w.remote)
        check("merge", r, try run("B", try openVault("B"), r, locked: true))
        // Nothing changed: in step.
        r = watch(w.remote)
        check("in step", r, try run("B", try openVault("B"), r, locked: true))
        // The server's copy moves between the read and the upload: judged again, still never under the lock.
        try changeSettings(w.b, "late")
        try changeSettings(w.a, "later")
        let store = w.remote.store, path = w.remote.base + [SharedSettings.fileName]
        let aSettings = try BoundedRead.contents(of: dir("A").appendingPathComponent(SharedSettings.fileName), maxBytes: 1 << 20)
        let fired = CallCounter()
        let racing = InterposedRemote(base: w.remote) { written in
            if written == [SharedSettings.fileName], fired.next() == 1 { store.putDirect(path, aSettings) }
        }
        r = watch(racing)
        check("refused upload", r, try run("B", try openVault("B"), r, locked: true))
    }
}

/// A remote that records every request made while `lock` is held by the caller (a lock-free `try` fails then).
final class LockWatchingRemote: SyncRemote, @unchecked Sendable {
    var base: any SyncRemote
    let lock: VaultFileLock
    private let guardLock = NSLock()
    private var _violations: [String] = []
    private var _requests = 0
    var violations: [String] { guardLock.withLock { _violations } }
    var requests: Int { guardLock.withLock { _requests } }

    init(base: any SyncRemote, lock: VaultFileLock) { self.base = base; self.lock = lock }

    private func note(_ verb: String, _ path: [String]) {
        let free = (try? lock.withLockIfFree { true }) ?? nil
        guardLock.withLock {
            _requests += 1
            if free != true { _violations.append("\(verb) \(path.joined(separator: "/"))") }
        }
    }

    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { base.interrupt }
        set { base.interrupt = newValue }
    }
    func list(_ path: [String]) throws -> [RemoteEntry]? { note("list", path); return try base.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { note("listTree", path); return try base.listTree(path, maxBytes: maxBytes) }
    func stat(_ path: [String]) throws -> RemoteEntry? { note("stat", path); return try base.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { note("read", path); return try base.read(path, maxBytes: maxBytes) }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                  segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        note("download", path)
        return try base.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                                 segmentBytes: segmentBytes, progress: progress)
    }
    func requestDownload(_ paths: [[String]]) throws { note("requestDownload", paths.first ?? []); try base.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { base.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try base.readVersion(path, version, maxBytes: maxBytes)
    }
    func changes() -> AsyncStream<RemoteChange>? { base.changes() }
    func missingCollectionError(_ path: [String]) -> any Error { base.missingCollectionError(path) }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        note("write", path); return try base.write(path, body, condition: condition)
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        note("move", path); return try base.moveNoOverwrite(path, to: destination)
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult { note("mkcol", path); return try base.makeCollection(path) }
    func createBase() throws { note("createBase", []); try base.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { note("delete", path); return try base.delete(path, ifETag: ifETag) }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {
        try base.resolveConflicts(path, versions)
    }
}

/// A remote that stops at the first `verb` of root file `file`, signalling `stalled` and waiting for `release`.
struct StallingRemote: SyncRemote {
    enum Verb { case read, write }
    var base: any SyncRemote
    let verb: Verb
    let file: String
    let stalled: DispatchSemaphore
    let release: DispatchSemaphore
    private let calls = CallCounter()

    init(base: any SyncRemote, verb: Verb, file: String, stalled: DispatchSemaphore, release: DispatchSemaphore) {
        self.base = base; self.verb = verb; self.file = file; self.stalled = stalled; self.release = release
    }

    private func stall(_ v: Verb, _ path: [String]) {
        guard v == verb, path == [file], calls.next() == 1 else { return }
        stalled.signal()
        release.wait()
    }

    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { base.interrupt }
        set { base.interrupt = newValue }
    }

    func list(_ path: [String]) throws -> [RemoteEntry]? { try base.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try base.listTree(path, maxBytes: maxBytes) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try base.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        stall(.read, path)
        return try base.read(path, maxBytes: maxBytes)
    }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                  segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try base.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                          segmentBytes: segmentBytes, progress: progress)
    }
    func requestDownload(_ paths: [[String]]) throws { try base.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { base.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try base.readVersion(path, version, maxBytes: maxBytes)
    }
    func changes() -> AsyncStream<RemoteChange>? { base.changes() }
    func missingCollectionError(_ path: [String]) -> any Error { base.missingCollectionError(path) }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        stall(.write, path)
        return try base.write(path, body, condition: condition)
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try base.moveNoOverwrite(path, to: destination)
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult { try base.makeCollection(path) }
    func createBase() throws { try base.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { try base.delete(path, ifETag: ifETag) }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {
        try base.resolveConflicts(path, versions)
    }
}
