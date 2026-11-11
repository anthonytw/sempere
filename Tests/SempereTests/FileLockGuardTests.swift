#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Crypto
import Foundation
@testable import Sempere
import TempDirSupport
import XCTest

/// Background time faked for `FileLockGuard`: records each assertion, refuses when the system "gives no time", and lets a
/// test run the time out.
final class FakeLockAssertions: FileLockAssertions, @unchecked Sendable {
    private let lock = NSLock()
    private var grantTime = true
    private var next = 1
    private var running: [Int: @Sendable () -> Void] = [:]
    private var begunCount = 0
    private var refusedCount = 0

    /// False: the app is in the background and about to be suspended (`beginBackgroundTask` answers `.invalid`).
    var grant: Bool {
        get { lock.withLock { grantTime } }
        set { lock.withLock { grantTime = newValue } }
    }
    var begun: Int { lock.withLock { begunCount } }
    var refused: Int { lock.withLock { refusedCount } }
    /// Assertions begun and not ended yet.
    var outstanding: Int { lock.withLock { running.count } }

    func begin(name: String, expired: @escaping @Sendable () -> Void) -> Int? {
        lock.withLock {
            guard grantTime else { refusedCount += 1; return nil }
            begunCount += 1
            let token = next
            next += 1
            running[token] = expired
            return token
        }
    }

    func end(_ token: Int) { _ = lock.withLock { running.removeValue(forKey: token) } }

    /// The system takes the time back: every running assertion expires.
    func expireAll() {
        for handler in lock.withLock({ Array(running.values) }) { handler() }
    }
}

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
}
