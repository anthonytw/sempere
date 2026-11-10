import Darwin
import Foundation

/// The one place the app tests put temporary files (CLAUDE.md "Temp files in tests").
///
/// Every test that needs a scratch folder builds it under `TestTemp.root` instead of the bare temporary
/// directory. The root is a single folder per test process, `sempere-test-<pid>-<uuid>`: it is removed when the
/// process exits, and the first use in a later process removes the roots of processes that are gone (a killed or
/// crashed run). So a run leaves nothing behind, and a leak can never pile up one folder per test in the app
/// container's tmp (APFS allows 65,535 subfolders per folder; a pile of 195,000 broke every Mac Catalyst test).
///
/// `TestTemp.directory(_:)` and `TestTemp.with(_:_:)` hand out folders the caller can also remove early.
enum TestTemp {
    private static let prefix = "sempere-test-"

    /// The real temporary directory (for the tests that assert on what production code leaves in it).
    static var systemTemporaryDirectory: URL { FileManager.default.temporaryDirectory }

    /// This process's scratch root, created on first use.
    static var root: URL { state.root }

    /// A fresh, uniquely named path under the root (nothing is created there).
    static func url(_ name: String = "scratch") -> URL {
        root.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    /// A fresh, created directory under the root.
    static func directory(_ name: String = "scratch") throws -> URL {
        let dir = url(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs `body` with a fresh directory and removes it afterwards, even when `body` throws.
    static func with<T>(_ name: String = "scratch", _ body: (URL) throws -> T) throws -> T {
        let dir = try directory(name)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    /// `with` for async bodies.
    static func with<T>(_ name: String = "scratch", _ body: (URL) async throws -> T) async throws -> T {
        let dir = try directory(name)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    private final class State: @unchecked Sendable {
        let root: URL
        init() {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            TestTemp.sweepStale(in: tmp)
            root = tmp.appendingPathComponent("\(TestTemp.prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            atexit { TestTemp.removeRoot() }
        }
    }

    private static let state = State()

    private static func removeRoot() {
        try? FileManager.default.removeItem(at: state.root)
    }

    /// Removes the roots of test processes that no longer run.
    private static func sweepStale(in tmp: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let pid = rest.split(separator: "-").first.flatMap({ Int32($0) }) else { continue }
            if pid != getpid(), kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }
}
