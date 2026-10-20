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

        public var description: String {
            switch self {
            case .timedOut(let path): return "another writer holds \(path)"
            case .unavailable(let detail): return "cannot open the lock file: \(detail)"
            }
        }
    }

    /// The lock file (created, mode 0600, when first taken; never deleted).
    public let url: URL
    private let mutex = NSLock()

    private init(url: URL) {
        self.url = url
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var locks: [String: VaultFileLock] = [:]
    }
    private static let registry = Registry()

    /// The lock of the lock file `url`: the same instance for the same file within this process, so
    /// two threads of one process exclude each other before either reaches `flock`.
    public static func at(_ url: URL) -> VaultFileLock {
        let key = url.standardizedFileURL.path
        registry.lock.lock()
        defer { registry.lock.unlock() }
        if let existing = registry.locks[key] { return existing }
        let made = VaultFileLock(url: url)
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
        let deadline = timeout.map { Date().addingTimeInterval(max($0, 0)) }
        if let deadline {
            guard mutex.lock(before: deadline) else { throw LockError.timedOut(url.path) }
        } else {
            mutex.lock()
        }
        defer { mutex.unlock() }
        guard let held = try FileLock.acquire(url, exclusive: true, deadline: deadline, createParent: true) else {
            throw LockError.timedOut(url.path)
        }
        defer { held.release() }
        return try body()
    }

    /// Runs `body` holding the lock if it is free now; nil (and `body` not run) when another holder has it.
    public func withLockIfFree<T>(_ body: () throws -> T) throws -> T? {
        guard mutex.try() else { return nil }
        defer { mutex.unlock() }
        guard let held = try FileLock.acquire(url, exclusive: true, deadline: Date.distantPast, createParent: true,
                                              throwOnTimeout: false) else { return nil }
        defer { held.release() }
        return try body()
    }
}

/// A held `flock(2)` on a file or folder: released by `release()` (or when the process ends).
/// Package-wide: `VaultFileLock`, `VaultStore` leases and staging folders use it.
package final class FileLock: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        release()
    }

    /// Releases the lock (once; later calls do nothing).
    package func release() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
        fd = -1
    }

    /// Takes a `flock` on `url` (a file, created mode 0600 when missing, or an existing folder).
    ///
    /// - Parameters:
    ///   - exclusive: an exclusive lock, else a shared one.
    ///   - deadline: polls (every 20 ms) until then; nil blocks; a date in the past tries once.
    ///   - createParent: creates the file's folder first.
    ///   - throwOnTimeout: throw `VaultFileLock.LockError.timedOut` when not taken in time, else return nil.
    package static func acquire(_ url: URL, exclusive: Bool, deadline: Date?, createParent: Bool = false,
                                throwOnTimeout: Bool = true) throws -> FileLock? {
        if createParent {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            var st = stat()
            if stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                return open(path, O_RDONLY | O_CLOEXEC)
            }
            return open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            throw VaultFileLock.LockError.unavailable("\(url.path): \(String(cString: strerror(errno)))")
        }
        let operation = exclusive ? LOCK_EX : LOCK_SH
        if deadline == nil {
            while flock(fd, operation) != 0 {
                guard errno == EINTR else {
                    let code = errno
                    _ = close(fd)
                    throw VaultFileLock.LockError.unavailable("\(url.path): \(String(cString: strerror(code)))")
                }
            }
            return FileLock(fd: fd)
        }
        while true {
            if flock(fd, operation | LOCK_NB) == 0 { return FileLock(fd: fd) }
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                _ = close(fd)
                throw VaultFileLock.LockError.unavailable("\(url.path): \(String(cString: strerror(code)))")
            }
            if let deadline, Date() >= deadline {
                _ = close(fd)
                if throwOnTimeout { throw VaultFileLock.LockError.timedOut(url.path) }
                return nil
            }
            usleep(20_000)
        }
    }
}
