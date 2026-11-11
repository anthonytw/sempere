import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A lock on one vault's files, shared by every writer of that vault on this device
/// (docs/design/device-first-sync.md §4, §4.2): the app's own writes, a sync engine replacing a
/// mutable file, the vault store installing or removing the vault, and the `sempere` CLI on the same
/// working copy.
///
/// It is two locks taken in order: an in-process mutex (one instance per lock file per process,
/// `at(_:)`), then a cross-process `flock(2)` on the lock file. Each vault has its own lock file
/// (`VaultStore.writeLock(for:)`), so writers of different vaults never wait for each other.
///
/// Not reentrant: a thread that holds the lock and asks for it again waits until its timeout.
public final class VaultFileLock: @unchecked Sendable {
    /// Why the lock was not taken.
    public enum LockError: Error, Equatable, Sendable, CustomStringConvertible {
        /// Another writer held it for the whole wait.
        case timedOut(String)
        /// The lock file could not be created or opened.
        case unavailable(String)
        /// The app is in the background and the system gives no time to hold a lock: one held now could be held
        /// across the suspension, which iOS punishes with a kill (`FileLockGuard`).
        case suspended(String)

        public var description: String {
            switch self {
            case .timedOut(let path): return "another writer holds \(path)"
            case .unavailable(let detail): return "cannot open the lock file: \(detail)"
            case .suspended(let path): return "no background time to lock \(path)"
            }
        }
    }

    /// The lock file (created, mode 0600, when first taken; never deleted).
    public let url: URL
    /// What the lock is, for the log of a lock let go at expiry (`FileLockGuard.onExpiry`).
    public let kind: String
    private let mutex = NSLock()

    private init(url: URL, kind: String) {
        self.url = url
        self.kind = kind
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var locks: [String: VaultFileLock] = [:]
    }
    private static let registry = Registry()

    /// The lock of the lock file `url`: the same instance for the same file within this process, so
    /// two threads of one process exclude each other before either reaches `flock`.
    ///
    /// - Parameter kind: what the lock is (`write`, `ledger`, `folder`, …; never a name or a path), for the
    ///   expiry log; the first caller's is kept.
    public static func at(_ url: URL, kind: String = "write") -> VaultFileLock {
        let key = url.standardizedFileURL.path
        registry.lock.lock()
        defer { registry.lock.unlock() }
        if let existing = registry.locks[key] { return existing }
        let made = VaultFileLock(url: url, kind: kind)
        registry.locks[key] = made
        return made
    }

    /// Runs `body` holding the lock.
    ///
    /// - Parameter timeout: how long to wait for another holder (in this process or another); nil
    ///   waits for ever.
    /// - Throws: `LockError.timedOut` when the wait ran out, `.unavailable` when the lock file cannot
    ///   be opened, or what `body` throws.
    public func withLock<T>(timeout: TimeInterval? = nil, _ body: () throws -> T) throws -> T {
        try withLock(timeout: timeout, createParent: true, whileWaiting: nil, unavailable: nil, body)
    }

    /// `withLock(timeout:_:)`, calling `whileWaiting` (which may throw to give up) while another holder has the lock;
    /// without `createParent` a missing folder of the lock file is an error, never made. `unavailable` turns a failed
    /// `open` or `flock` (with its errno) into the caller's error; nil throws `.unavailable`.
    package func withLock<T>(timeout: TimeInterval?, createParent: Bool, whileWaiting: (() throws -> Void)?,
                             unavailable: (@Sendable (FileLockOSError) -> any Error)?,
                             _ body: () throws -> T) throws -> T {
        let deadline = timeout.map { Date().addingTimeInterval(max($0, 0)) }
        if let whileWaiting {
            while !mutex.lock(before: Date().addingTimeInterval(0.02)) {
                try whileWaiting()
                if let deadline, Date() >= deadline { throw LockError.timedOut(url.path) }
            }
        } else if let deadline {
            guard mutex.lock(before: deadline) else { throw LockError.timedOut(url.path) }
        } else {
            mutex.lock()
        }
        defer { mutex.unlock() }
        guard let held = try FileLock.acquire(url, kind: kind, exclusive: true, deadline: deadline,
                                              createParent: createParent, whileWaiting: whileWaiting,
                                              unavailable: unavailable) else {
            throw LockError.timedOut(url.path)
        }
        defer { held.release() }
        return try body()
    }

    /// Runs `body` holding the lock if it is free now; nil (and `body` not run) when another holder has it.
    public func withLockIfFree<T>(_ body: () throws -> T) throws -> T? {
        guard mutex.try() else { return nil }
        defer { mutex.unlock() }
        guard let held = try FileLock.acquire(url, kind: kind, exclusive: true, deadline: Date.distantPast,
                                              createParent: true, throwOnTimeout: false) else { return nil }
        defer { held.release() }
        return try body()
    }
}

/// An `open(2)` or `flock(2)` of a lock file that failed, with its errno, so a caller can tell an unreachable
/// share from a lasting error (`FolderRemote.ioError`).
package struct FileLockOSError: Error, Sendable, CustomStringConvertible {
    /// `open` or `lock`.
    package let operation: String
    package let path: String
    package let code: Int32

    package var description: String { "\(path): \(String(cString: strerror(code)))" }
}

/// A held `flock(2)` on a file or folder: released by `release()` (or when the process ends).
/// Package-wide: `VaultFileLock`, `VaultStore` leases and staging folders use it. Each is held under an
/// assertion of its own where `FileLockGuard` has one installed (iOS: never held across a suspension).
package final class FileLock: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()
    private let hold: LockHold?

    private init(fd: Int32, hold: LockHold?) {
        self.fd = fd
        self.hold = hold
    }

    deinit {
        release()
    }

    /// Whether the lock is still held: false once released, and once its background time ran out
    /// (`FileLockGuard`), from the moment the expiry begins to let it go. Work that must hold the lock to its
    /// end (a staging folder) checks it before each step and before it commits.
    package var isHeld: Bool {
        guard lock.withLock({ fd >= 0 }) else { return false }
        return !(hold?.isLost ?? false)
    }

    /// Releases the lock (once; later calls do nothing).
    package func release() {
        let released: Bool = lock.withLock {
            guard fd >= 0 else { return false }
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            fd = -1
            return true
        }
        // The assertion ends outside `lock`: UIKit runs an expiry (which releases, taking `lock`) on the main
        // thread, so ending it while holding `lock` could wait on a main thread that waits on `lock`.
        if released { hold?.end() }
    }

    /// A taken `fd` becomes a held lock, unless its background time ran out while it was waited for.
    private static func held(_ fd: Int32, _ hold: LockHold?, _ url: URL) throws -> FileLock {
        let made = FileLock(fd: fd, hold: hold)
        guard let hold else { return made }
        guard hold.attach({ [weak made] in made?.release() }) else {
            made.release()
            throw VaultFileLock.LockError.suspended(url.path)
        }
        return made
    }

    /// Takes a `flock` on `url` (a file, created mode 0600 when missing, or an existing folder).
    ///
    /// - Parameters:
    ///   - exclusive: an exclusive lock, else a shared one.
    ///   - deadline: polls (every 20 ms) until then; nil blocks; a date in the past tries once.
    ///   - createParent: creates the file's folder first.
    ///   - throwOnTimeout: throw `VaultFileLock.LockError.timedOut` when not taken in time, else return nil.
    ///   - kind: what the lock is (`open`, `staging`, …; never a name or a path), for the expiry log.
    ///   - whileWaiting: called between tries while another holder has it; may throw to give up.
    ///   - unavailable: the error for a failed `open` or `flock`; nil throws `VaultFileLock.LockError.unavailable`.
    /// - Throws: `.suspended` when `FileLockGuard`'s assertions give no time now (nothing is opened or locked).
    package static func acquire(_ url: URL, kind: String, exclusive: Bool, deadline: Date?, createParent: Bool = false,
                                throwOnTimeout: Bool = true, whileWaiting: (() throws -> Void)? = nil,
                                unavailable: (@Sendable (FileLockOSError) -> any Error)? = nil) throws -> FileLock? {
        // The assertion first: a lock is never held, even for a moment, without one.
        let hold = try LockHold.begin(for: url, kind: kind)
        do {
            guard let taken = try take(url, exclusive: exclusive, deadline: deadline, createParent: createParent,
                                       throwOnTimeout: throwOnTimeout, whileWaiting: whileWaiting) else {
                hold?.end()
                return nil
            }
            return try held(taken, hold, url)
        } catch let failed as FileLockOSError {
            hold?.end()
            throw unavailable?(failed) ?? VaultFileLock.LockError.unavailable(failed.description)
        } catch {
            hold?.end()
            throw error
        }
    }

    /// Opens `url` and takes the `flock`: the descriptor, or nil when not taken in time (and not `throwOnTimeout`).
    /// Never follows a symbolic link (format.md §9): a link named `url` fails to open (`ELOOP`).
    ///
    /// - Throws: `FileLockOSError` when it cannot be opened or locked.
    private static func take(_ url: URL, exclusive: Bool, deadline: Date?, createParent: Bool,
                             throwOnTimeout: Bool, whileWaiting: (() throws -> Void)?) throws -> Int32? {
        if createParent {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            return open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { throw FileLockOSError(operation: "open", path: url.path, code: errno) }
        let operation = exclusive ? LOCK_EX : LOCK_SH
        if deadline == nil, whileWaiting == nil {
            while flock(fd, operation) != 0 {
                guard errno == EINTR else {
                    let code = errno
                    _ = close(fd)
                    throw FileLockOSError(operation: "lock", path: url.path, code: code)
                }
            }
            return fd
        }
        while true {
            if flock(fd, operation | LOCK_NB) == 0 { return fd }
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                _ = close(fd)
                throw FileLockOSError(operation: "lock", path: url.path, code: code)
            }
            if let deadline, Date() >= deadline {
                _ = close(fd)
                if throwOnTimeout { throw VaultFileLock.LockError.timedOut(url.path) }
                return nil
            }
            do { try whileWaiting?() } catch {
                _ = close(fd)
                throw error
            }
            usleep(20_000)
        }
    }
}
