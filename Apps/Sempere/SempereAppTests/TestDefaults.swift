import Darwin
import Foundation
import XCTest

/// The one place the app tests make `UserDefaults` suites (docs/ci.md "Temp-folder guard").
///
/// `UserDefaults(suiteName:)` writes `<suite>.plist` into the app container's `Library/Preferences`, and nothing
/// ever removes it: four days of runs once left about 21,000 of them there and made the machine choppy. Make every
/// suite with `TestDefaults.suite(_:)` (same signature as the initializer, so `try #require(...)` and `!` still work).
/// Each suite is registered, and at process exit its domain and plist file are removed. Two things make that hold up:
///
/// - `removePersistentDomain` makes cfprefsd write an empty plist back a moment after the call, so `removeStorage`
///   flushes, deletes the file, and checks again until it stays gone.
/// - The runner ends the host without running exit handlers (a full `test-mac` left the last ~70 suites). So a suite
///   not asked for again within `staleAfter` (15 minutes) is removed by the next `suite(_:)` call, and every name is
///   also written to a ledger file named for the process id (`Library/Caches/TestDefaultsLedger/<pid>`) before the
///   suite is made. The first use in a later process, and `scripts/app.sh` after a run, remove the suites of
///   ledgers whose process is gone, like `TestTemp`'s sweep of dead roots.
///
/// A test can call `TestDefaults.remove(_:)` early. `scripts/check-test-defaults.sh` fails on a raw
/// `UserDefaults(suiteName:`.
enum TestDefaults {
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String: Date] = [:]
        private var swept = false
        /// Registers `name` (or refreshes its time); true the first time anything is registered in this process.
        func add(_ name: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let first = !swept
            swept = true
            names[name] = Date()
            return first
        }
        func take() -> [String] { lock.lock(); defer { lock.unlock() }; let n = Array(names.keys); names = [:]; return n }
        func drop(_ name: String) { lock.lock(); names[name] = nil; lock.unlock() }
        /// Takes the suites not registered again for `age` seconds.
        func takeOlder(than age: TimeInterval) -> [String] {
            lock.lock(); defer { lock.unlock() }
            let old = names.filter { Date().timeIntervalSince($0.value) > age }.map(\.key)
            for n in old { names[n] = nil }
            return old
        }
    }

    private static let registry = Registry()
    private static let exitHook: Void = { atexit { TestDefaults.removeAll() } }()

    /// A suite lives for one test; one not asked for again in this long is done with, and a killed host would
    /// otherwise leave it. (Suites are made afresh by every `suite(_:)` call, fixed names included.) Kept well above
    /// any one test's length so a slow test never has its suite removed under it; the ledger sweep (the next host,
    /// `scripts/app.sh`) removes what a run leaves inside this window.
    private static let staleAfter: TimeInterval = 900

    /// A defaults suite that is removed (domain and plist file) when the test process exits.
    static func suite(_ name: String) -> UserDefaults? {
        _ = exitHook
        if registry.add(name) { sweepDeadLedgers() }
        for old in registry.takeOlder(than: staleAfter) { removeStorage(old) }
        record(name)
        return UserDefaults(suiteName: name)
    }

    /// Removes a suite's domain and plist file now.
    static func remove(_ name: String) {
        registry.drop(name)
        removeStorage(name)
    }

    private static func removeAll() {
        let names = registry.take()
        for name in names { removeStorage(name) }
        settle(names)
        // The ledger stays: cfprefsd may write the emptied domains back as the process ends, so whoever sees this
        // process gone (the next host, or scripts/app.sh) removes the files once more and then the ledger.
    }

    /// cfprefsd writes emptied domains back some time after the call, later still under load (87 suites in one run
    /// outlived a per-file check): delete again until a few passes in a row find none, for at most about 10 seconds.
    private static func settle(_ names: [String]) {
        let fm = FileManager.default
        guard let dir = preferencesDirectory, !names.isEmpty else { return }
        var clean = 0
        for _ in 0..<40 where clean < 3 {
            Thread.sleep(forTimeInterval: 0.25)
            var found = false
            for name in names {
                let f = dir.appendingPathComponent("\(name).plist")
                if fm.fileExists(atPath: f.path) { found = true; try? fm.removeItem(at: f) }
            }
            clean = found ? 0 : clean + 1
        }
    }

    private static var preferencesDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Preferences")
    }

    private static func removeStorage(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        guard let file = preferencesDirectory?.appendingPathComponent("\(name).plist") else { return }
        let fm = FileManager.default
        // cfprefsd writes the emptied domain back asynchronously: delete until the file stays gone.
        for _ in 0..<10 {
            try? fm.removeItem(at: file)
            Thread.sleep(forTimeInterval: 0.05)
            if !fm.fileExists(atPath: file.path) { break }
        }
    }

    // MARK: ledger of suites per process

    private static func ledgerDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("TestDefaultsLedger")
    }

    private static func ledger(pid: Int32) -> URL {
        (ledgerDirectory() ?? FileManager.default.temporaryDirectory).appendingPathComponent("\(pid)")
    }

    private static func record(_ name: String) {
        guard let dir = ledgerDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = ledger(pid: getpid())
        guard let handle = FileHandle(forWritingAtPath: file.path) ?? {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            return FileHandle(forWritingAtPath: file.path)
        }() else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((name + "\n").utf8))
        try? handle.close()
    }

    /// Removes the suites of test processes that no longer run (killed before their exit handler).
    private static func sweepDeadLedgers() {
        let fm = FileManager.default
        guard let dir = ledgerDirectory() else { return }
        for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard let pid = Int32(entry), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            let file = dir.appendingPathComponent(entry)
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                for name in text.split(separator: "\n") { removeStorage(String(name)) }
            }
            try? fm.removeItem(at: file)
        }
    }
}
