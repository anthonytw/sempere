import Foundation

// MARK: - Platform services the library declares and the app implements (docs/design/thin-app.md "Rules")
//
// Library code reaches the platform only through these protocols, so it runs on Linux and in the CLI with the
// memory or no-op versions here, and in the app with the implementations in `Apps/Sempere/SempereApp/
// PlatformServices.swift`.

/// Small settings kept by key: what the app keeps in `UserDefaults` (the app makes `UserDefaults` conform, so
/// `UserDefaults.standard` is passed as it is). The requirements are `UserDefaults`' own methods, with its
/// conversions (`bool(forKey:)` of a key never set is false); `MemoryKeyValueStore` is the tests' and the CLI's.
public protocol KeyValueStore: AnyObject, Sendable {
    /// The stored value, nil when never set.
    func object(forKey key: String) -> Any?
    /// The value as a `Bool` (false when unset or not a number or Boolean).
    func bool(forKey key: String) -> Bool
    /// The value as an `Int` (0 when unset or not a number).
    func integer(forKey key: String) -> Int
    /// The value as a `Double` (0 when unset or not a number).
    func double(forKey key: String) -> Double
    /// The value when it is a string.
    func string(forKey key: String) -> String?
    /// The value when it is data.
    func data(forKey key: String) -> Data?
    /// Stores `value` (a property-list value) under `key`; nil removes it.
    func set(_ value: Any?, forKey key: String)
    /// Removes the value of `key`.
    func removeObject(forKey key: String)
    /// Calls `handler` after every change to the store (any key), on the thread that made the change, until
    /// the observation is cancelled or released.
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> KeyValueObservation
}

/// A running `KeyValueStore.observeChanges`: it stops at `cancel()` or when released.
public final class KeyValueObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    /// An observation that runs `onCancel` once, when it is cancelled or released.
    public init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    /// Stops the observation (only the first call does anything).
    public func cancel() {
        let run = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onCancel = nil }
            return onCancel
        }
        run?()
    }

    deinit { cancel() }
}

/// A `KeyValueStore` in memory (tests, the CLI). Values convert as `UserDefaults` converts property-list
/// numbers: a stored `Bool`, `Int` or `Double` reads back as any of the three.
public final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// A store holding `values`.
    public init(_ values: [String: Any] = [:]) { self.values = values }

    public func object(forKey key: String) -> Any? { lock.withLock { values[key] } }

    public func bool(forKey key: String) -> Bool {
        switch object(forKey: key) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased())
        default: return false
        }
    }

    public func integer(forKey key: String) -> Int {
        switch object(forKey: key) {
        case let i as Int: return i
        case let d as Double: return d.isFinite && abs(d) < 1e18 ? Int(d) : 0
        case let b as Bool: return b ? 1 : 0
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    public func double(forKey key: String) -> Double {
        switch object(forKey: key) {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let b as Bool: return b ? 1 : 0
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    public func string(forKey key: String) -> String? { object(forKey: key) as? String }

    public func data(forKey key: String) -> Data? { object(forKey: key) as? Data }

    public func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
        notify()
    }

    public func removeObject(forKey key: String) { set(nil, forKey: key) }

    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> KeyValueObservation {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return KeyValueObservation { [weak self] in
            guard let self else { return }
            _ = self.lock.withLock { self.observers.removeValue(forKey: id) }
        }
    }

    private func notify() {
        let handlers = lock.withLock { Array(observers.values) }
        for handler in handlers { handler() }
    }
}
