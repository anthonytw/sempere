import Foundation

/// Background time for a held file lock: on iOS, `UIApplication.beginBackgroundTask` (the app's
/// `UIKitLockAssertions`). iOS kills an app that is suspended while it holds a `flock(2)` in the App Group
/// container (RunningBoard `0xdead10cc`), so a lock may only be held while something keeps the process running.
///
/// Implementations are called from any thread, and must call `expired` (on any thread) before the time they
/// gave runs out; `end` may then still be called and must do nothing.
public protocol FileLockAssertions: AnyObject, Sendable {
    /// Starts an assertion that keeps the process running while a lock is held, or nil when the system gives
    /// none now (the app is in the background and about to be suspended): the lock is then refused.
    func begin(name: String, expired: @escaping @Sendable () -> Void) -> Int?
    /// Ends the assertion `begin` gave.
    func end(_ token: Int)
}

/// The one rule for every file lock the package takes (`FileLock`: `VaultFileLock`, `VaultStore` leases and
/// staging folders; and a plain folder target's `.sempere-lock`): **no lock is held across a suspension**.
/// Once assertions are installed (the iOS app, at launch), each lock is taken only under an assertion of its
/// own, which ends when the lock is let go. When the system gives no time, the lock is refused
/// (`VaultFileLock.LockError.suspended`: the write fails closed, as any refused lock does). When the time
/// runs out while the lock is still held, the `flock` is let go at once and the assertion ends. The hold is then
/// lost (`FileLock.isHeld` is false): work that needs the lock to its end, such as a staging folder being filled
/// and moved into the store, checks it and stops (`.suspended`); work under a `VaultFileLock` carries on, still
/// holding that lock's in-process mutex.
///
/// **Install only in a process that is the sole taker of these locks on the device.** Letting a `flock` go at
/// expiry is safe only because nothing else can take it meanwhile: the in-process mutex keeps this process's
/// other threads out, and no other process takes these locks (on iOS the widget extensions link only
/// `SempereCaptureShared`, the intents run in the app, and neither the CLI nor Mac Catalyst installs the guard).
/// An extension or helper that links `Sempere` and takes the same locks would lose its exclusion silently.
///
/// Nothing is installed on a Mac, on Linux, or in the CLI: there the locks are taken as before. Tests install
/// fakes for their own folder only (`install(_:under:)`), so suites running side by side do not see each other's.
public enum FileLockGuard {
    /// A running installation; `cancel()` removes it.
    public final class Installation: @unchecked Sendable {
        fileprivate let id = UUID()
        public func cancel() { FileLockGuard.state.remove(id) }
    }

    fileprivate final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var global: (id: UUID, assertions: any FileLockAssertions)?
        private var scoped: [(id: UUID, prefixes: [String], assertions: any FileLockAssertions)] = []
        private var expiryLog: (@Sendable (String) -> Void)?

        func install(_ assertions: any FileLockAssertions, prefixes: [String]?, id: UUID) {
            lock.withLock {
                if let prefixes { scoped.append((id, prefixes, assertions)) } else { global = (id, assertions) }
            }
        }

        func remove(_ id: UUID) {
            lock.withLock {
                if global?.id == id { global = nil }
                scoped.removeAll { $0.id == id }
            }
        }

        func assertions(for path: String) -> (any FileLockAssertions)? {
            lock.withLock {
                if !scoped.isEmpty, let hit = scoped.first(where: { $0.prefixes.contains { path.hasPrefix($0) } }) {
                    return hit.assertions
                }
                return global?.assertions
            }
        }

        var onExpiry: (@Sendable (String) -> Void)? {
            get { lock.withLock { expiryLog } }
            set { lock.withLock { expiryLog = newValue } }
        }
    }

    fileprivate static let state = State()

    /// Installs `assertions` for every lock this process takes (the app, once, at launch; the last one wins).
    @discardableResult
    public static func install(_ assertions: any FileLockAssertions) -> Installation {
        let made = Installation()
        state.install(assertions, prefixes: nil, id: made.id)
        return made
    }

    /// Installs `assertions` for the locks under folder `root` only (tests); they take precedence over the
    /// process-wide ones there.
    public static func install(_ assertions: any FileLockAssertions, under root: URL) -> Installation {
        let made = Installation()
        let paths = Set([root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path])
        state.install(assertions, prefixes: paths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }, id: made.id)
        return made
    }

    /// Told (with the lock's kind, such as `open`, `write`, `staging` or `folder`, which its taker names: never a
    /// path, which may hold a vault id) when a lock was let go because its time ran out.
    public static var onExpiry: (@Sendable (String) -> Void)? {
        get { state.onExpiry }
        set { state.onExpiry = newValue }
    }

    static func assertions(for url: URL) -> (any FileLockAssertions)? {
        state.assertions(for: url.standardizedFileURL.path)
    }
}

/// One held lock's assertion (`FileLockGuard`): begun before the lock is taken, ended once it is let go, or
/// when the time runs out, which first lets the lock go (`attach`).
package final class LockHold: @unchecked Sendable {
    private let assertions: any FileLockAssertions
    private let kind: String
    private let lock = NSLock()
    private var token: Int?
    private var expired = false
    private var release: (@Sendable () -> Void)?

    private init(assertions: any FileLockAssertions, kind: String) {
        self.assertions = assertions
        self.kind = kind
    }

    /// The assertion for a lock on `url`, or nil when no assertions are installed (nothing to hold).
    ///
    /// - Parameter kind: what the lock is (`write`, `open`, `staging`, `folder`, …), for the expiry log.
    /// - Throws: `VaultFileLock.LockError.suspended` when the system gives no time now.
    package static func begin(for url: URL, kind: String) throws -> LockHold? {
        guard let assertions = FileLockGuard.assertions(for: url) else { return nil }
        let hold = LockHold(assertions: assertions, kind: kind)
        guard let token = assertions.begin(name: "Sempere lock (\(kind))", expired: { [weak hold] in hold?.expire() }) else {
            throw VaultFileLock.LockError.suspended(url.path)
        }
        hold.lock.withLock { if !hold.expired { hold.token = token } }
        if hold.isExpired { assertions.end(token) }   // expired before `begin` returned: nothing is held yet
        return hold
    }

    private var isExpired: Bool { lock.withLock { expired } }

    /// The time ran out: the lock was let go (or is being let go now) by the expiry, not by its holder.
    package var isLost: Bool { isExpired }

    /// The lock is taken: `release` lets it go when the time runs out. False when the time ran out already (while
    /// the lock was waited for): the caller lets the lock go and refuses it.
    package func attach(_ release: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard !expired else { return false }
            self.release = release
            return true
        }
    }

    /// The lock was let go: the assertion ends (once).
    package func end() {
        let token: Int? = lock.withLock {
            release = nil
            defer { self.token = nil }
            return self.token
        }
        if let token { assertions.end(token) }
    }

    /// The time ran out: the lock goes first, then the assertion.
    private func expire() {
        let release: (@Sendable () -> Void)? = lock.withLock {
            expired = true
            defer { self.release = nil }
            return self.release
        }
        if let release {
            FileLockGuard.onExpiry?(kind)
            release()
        }
        end()
    }
}
