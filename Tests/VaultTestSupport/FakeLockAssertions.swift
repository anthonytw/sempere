import Foundation
import Sempere

/// Background time faked for `FileLockGuard` (the app's `UIKitLockAssertions`): records each assertion, refuses when
/// the system "gives no time", and lets a test run the time out. Install it for a test's own folder only
/// (`FileLockGuard.install(_:under:)`).
public final class FakeLockAssertions: FileLockAssertions, @unchecked Sendable {
    private let lock = NSLock()
    private var grantTime = true
    private var next = 1
    private var running: [Int: (name: String, expired: @Sendable () -> Void)] = [:]
    private var begunCount = 0
    private var refusedCount = 0
    private var beginHook: (@Sendable (String) -> Void)?

    public init() {}

    /// False: the app is in the background and about to be suspended (`beginBackgroundTask` answers `.invalid`).
    public var grant: Bool {
        get { lock.withLock { grantTime } }
        set { lock.withLock { grantTime = newValue } }
    }
    public var begun: Int { lock.withLock { begunCount } }
    public var refused: Int { lock.withLock { refusedCount } }
    /// Assertions begun and not ended yet: as many locks are held.
    public var outstanding: Int { lock.withLock { running.count } }
    /// Called with each assertion's name (`Sempere lock (<kind>)`) just before it is begun, on the taker's thread.
    public var onBegin: (@Sendable (String) -> Void)? {
        get { lock.withLock { beginHook } }
        set { lock.withLock { beginHook = newValue } }
    }

    public func begin(name: String, expired: @escaping @Sendable () -> Void) -> Int? {
        onBegin?(name)
        return lock.withLock {
            guard grantTime else { refusedCount += 1; return nil }
            begunCount += 1
            let token = next
            next += 1
            running[token] = (name, expired)
            return token
        }
    }

    public func end(_ token: Int) { _ = lock.withLock { running.removeValue(forKey: token) } }

    /// The system takes the time back: every running assertion expires.
    public func expireAll() {
        for entry in lock.withLock({ Array(running.values) }) { entry.expired() }
    }

    /// The time runs out for the running assertions of the locks of `kind` only.
    public func expire(kind: String) {
        for entry in lock.withLock({ running.values.filter { $0.name == "Sempere lock (\(kind))" } }) { entry.expired() }
    }
}
