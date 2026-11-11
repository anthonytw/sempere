#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Age
import Crypto
import Foundation
@testable import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest

/// TestFlight 1.1 (67) was killed (RunningBoard `0xdead10cc`) in launches into the background: a write took the write
/// ledger's lock in the App Group container with no background time, and the process was suspended holding it. Every
/// `flock` the package takes now holds an assertion of its own (`FileLockGuard`), is refused without one, and is let
/// go when the time runs out.
final class FileLockGuardTests: XCTestCase {
    private var dir: URL!
    private var fake: FakeLockAssertions!
    private var installation: FileLockGuard.Installation?

    override func setUpWithError() throws {
        dir = try TestTemp.directory("lock-guard")
        fake = FakeLockAssertions()
        installation = FileLockGuard.install(fake, under: dir)
    }

    override func tearDown() {
        installation?.cancel()
    }

    /// Whether anyone holds a `flock` on `url` (an exclusive one on another descriptor is refused).
    static func held(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    func testEachLockHoldsAnAssertionOfItsOwnUntilItIsLetGo() throws {
        let url = dir.appendingPathComponent("vault.write")
        let lock = VaultFileLock.at(url)
        try lock.withLock {
            XCTAssertTrue(Self.held(url))
            XCTAssertEqual(fake.outstanding, 1, "held only under an assertion")
        }
        XCTAssertFalse(Self.held(url))
        XCTAssertEqual(fake.begun, 1)
        XCTAssertEqual(fake.outstanding, 0, "the assertion ends with the lock")

        // A store vault's lease and its write lock: one assertion each, both ended.
        let store = VaultStore(root: dir.appendingPathComponent("store"))
        let id = UUID()
        let lease = try store.lease(id)
        XCTAssertEqual(fake.outstanding, 1)
        try store.writeLock(for: id).withLock { XCTAssertEqual(fake.outstanding, 2) }
        lease.release()
        XCTAssertEqual(fake.outstanding, 0)
    }

    /// The system gives no time (the app is about to be suspended): no lock is taken, nothing waits, the work fails closed.
    func testWithoutBackgroundTimeEveryLockIsRefused() throws {
        fake.grant = false
        let url = dir.appendingPathComponent("vault.write")
        var ran = false
        XCTAssertThrowsError(try VaultFileLock.at(url).withLock { ran = true }) {
            XCTAssertEqual($0 as? VaultFileLock.LockError, .suspended(url.path))
        }
        XCTAssertFalse(ran)
        XCTAssertThrowsError(try VaultFileLock.at(url).withLockIfFree { ran = true })
        XCTAssertFalse(ran)

        let store = VaultStore(root: dir.appendingPathComponent("store"))
        XCTAssertThrowsError(try store.lease(UUID()))

        // The write ledger (crash 1: `FileWriteLedger.appendEntries` under `VaultFileLock.withLock`): the write fails.
        let ledger = FileWriteLedger(directory: dir.appendingPathComponent("Ledger"), vaultId: UUID(),
                                     key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try ledger.append([LedgerEntry(path: "notes/x/1.age", sha256: String(repeating: "0", count: 64),
                                                            epoch: 1, epochId: Data(repeating: 1, count: 32))]))
        XCTAssertEqual(fake.outstanding, 0)
        XCTAssertGreaterThan(fake.refused, 0)
    }

    /// The time runs out while a lock is held: the `flock` goes at once (another process could take it) and the
    /// assertion ends; the holder's own release later does nothing more.
    func testTheTimeRunningOutLetsTheLockGo() throws {
        let url = dir.appendingPathComponent("vault.write")
        try VaultFileLock.at(url).withLock {
            XCTAssertTrue(Self.held(url))
            fake.expireAll()
            XCTAssertFalse(Self.held(url), "let go before the time ran out")
            XCTAssertEqual(fake.outstanding, 0)
        }
        XCTAssertEqual(fake.outstanding, 0)
        // The lock works as before afterwards.
        try VaultFileLock.at(url).withLock { XCTAssertTrue(Self.held(url)) }

        // A lease too: a lease held by mistake in the background is let go, not killed for.
        let store = VaultStore(root: dir.appendingPathComponent("store"))
        let id = UUID()
        let lease = try store.lease(id)
        let open = store.root.appendingPathComponent(".locks").appendingPathComponent(id.uuidString.lowercased() + ".open")
        XCTAssertTrue(Self.held(open))
        fake.expireAll()
        XCTAssertFalse(Self.held(open))
        lease.release()
        XCTAssertEqual(fake.outstanding, 0)
    }

    /// Without assertions (a Mac, Linux, the CLI) the locks are taken as before; a test's fakes see only its own folder.
    func testOnlyTheInstalledFolderIsGuarded() throws {
        let other = try TestTemp.directory("lock-guard-other")
        fake.grant = false
        try VaultFileLock.at(other.appendingPathComponent("x.write")).withLock {}
        XCTAssertEqual(fake.refused, 0)
        installation?.cancel()
        try VaultFileLock.at(dir.appendingPathComponent("x.write")).withLock {}
        XCTAssertEqual(fake.refused, 0)
    }

    /// The expiry log and the assertion's name carry the lock's kind, as its taker names it, never a path.
    func testTheExpiryLogNamesTheKind() throws {
        let seen = Seen()
        let before = FileLockGuard.onExpiry
        FileLockGuard.onExpiry = { seen.add($0) }
        defer { FileLockGuard.onExpiry = before }
        fake.onBegin = { seen.add("begin " + $0) }
        let store = VaultStore(root: dir.appendingPathComponent("store"))
        let lease = try store.lease(UUID())
        fake.expireAll()
        lease.release()
        try store.writeLock(for: UUID()).withLock { fake.expireAll() }
        XCTAssertEqual(seen.items, ["begin Sempere lock (open)", "open", "begin Sempere lock (write)", "write"])
    }

    // MARK: - Staging folders

    private var store: VaultStore { VaultStore(root: dir.appendingPathComponent("store")) }

    /// What the store's root holds besides its own hidden folders: no vault-id folder may be left.
    private func storeFolders(_ store: VaultStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private func stagingLeftovers(_ store: VaultStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".staging").path)) ?? []
    }

    private func identity() throws -> NativeIdentity {
        try DeviceKeys.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8)).nativeIdentity
    }

    private func sampleSource() throws -> URL {
        let source = dir.appendingPathComponent("outside").appendingPathComponent("Notes.sempere")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FixtureTests.bundled("sample.sempere"), to: source)
        return source
    }

    private func assertSuspended(_ error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case .suspended? = error as? VaultFileLock.LockError else {
            return XCTFail("expected .suspended, got \(error)", file: file, line: line)
        }
    }

    /// A staging folder's lock let go at expiry (the app left the screen during a long create): `sweep` may delete
    /// the folder from then on, so the vault is never moved into the store, and nothing is left there.
    func testAStagingFolderLetGoAtExpiryIsNeverInstalled() throws {
        let store = store
        let identity = try identity()
        XCTAssertThrowsError(try store.create(name: "Late") { url -> Void in
            _ = try TestVaults.create(at: url, identities: [identity])
            let staging = url.deletingLastPathComponent()
            XCTAssertTrue(Self.held(staging))
            fake.expireAll()
            XCTAssertFalse(Self.held(staging), "let go at expiry")
        }) { assertSuspended($0) }
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertEqual(storeFolders(store), [], "no vault-id folder either")
        XCTAssertEqual(stagingLeftovers(store), [])
        XCTAssertEqual(fake.outstanding, 0)
        // With time, the same create goes through.
        let made = try store.create(name: "Late") { try TestVaults.create(at: $0, identities: [identity]) }
        XCTAssertEqual(made.entry.name, "Late")
    }

    /// A copy-in whose staging lock was let go stops at the next file instead of copying on, while a sweep (another
    /// create, a refresh) removes the folder it no longer holds; nothing is installed.
    func testACopyInStopsAtTheNextFileOnceItsStagingLockIsLetGo() throws {
        let store = store
        let source = try sampleSource()
        let copied = Seen()
        let fake = fake!
        XCTAssertThrowsError(try store.importVault(from: source, options: .init(afterEachFile: { path in
            copied.add(path)
            if copied.items.count == 1 {
                fake.expireAll()
                store.sweep()
            }
        }))) { assertSuspended($0) }
        XCTAssertEqual(copied.items.count, 1, "no file is copied after the lock was let go")
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertEqual(storeFolders(store), [])
        XCTAssertEqual(stagingLeftovers(store), [])
    }

    /// `Backup.restore` checks before each file, and stops at the first refusal with nothing placed.
    func testARestoreStopsAtTheNextFile() throws {
        let source = try sampleSource()
        let target = dir.appendingPathComponent("restore").appendingPathComponent("Notes.sempere")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let calls = Seen()
        XCTAssertThrowsError(try Backup.restore(from: source, to: target, beforeEachFile: {
            calls.add("file")
            if calls.items.count == 2 { throw VaultFileLock.LockError.suspended("staging") }
        })) { assertSuspended($0) }
        XCTAssertEqual(calls.items.count, 2, "stopped at the next file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(Vault.manifestName).path))
    }

    /// A replacing restore whose staging lock is let go as it is about to be installed: refused before the old copy
    /// is moved aside, so the store keeps the copy it had, whole.
    func testAReplaceWhoseStagingLockIsLetGoKeepsTheOldCopy() throws {
        let store = store
        let source = try sampleSource()
        let first = try store.restore(from: source).entry
        let notes = first.url.appendingPathComponent(Vault.notesName)
        let before = try FileManager.default.contentsOfDirectory(atPath: notes.path).sorted()
        // `install` takes the open lock (no lease may hold the vault) just before the move: the time runs out then.
        let fake = fake!
        fake.onBegin = { name in if name == "Sempere lock (open)" { fake.expire(kind: "staging") } }
        XCTAssertThrowsError(try store.restore(from: source, options: .init(replace: true))) { assertSuspended($0) }
        fake.onBegin = nil
        XCTAssertEqual(store.list().map(\.url), [first.url])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: notes.path).sorted(), before)
        XCTAssertEqual(VaultStore.setAside(in: first.url.deletingLastPathComponent()), [], "nothing set aside")
        XCTAssertEqual(stagingLeftovers(store), [])
        XCTAssertEqual(fake.outstanding, 0)
    }
}

/// Strings seen, from any thread.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ item: String) { lock.withLock { seen.append(item) } }
    var items: [String] { lock.withLock { seen } }
}
