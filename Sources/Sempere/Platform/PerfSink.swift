import Foundation

/// Where the package reports timings and log lines: the app forwards them to its signposts (`Perf`) and to
/// `os.Logger` (`AppPerfSink`); `NoPerfSink` drops them (the CLI), `MemoryPerfSink` keeps them (tests).
///
/// `phase` is a stable dotted name (`writer.read`); details and messages hold counts and 8-hex id prefixes only,
/// never titles, content or paths, because the app logs them as public.
public protocol PerfSink: Sendable {
    /// Runs `body`, reporting it as `phase`.
    func measure<T>(_ phase: String, _ detail: String, _ body: () throws -> T) rethrows -> T
    /// A point event of `phase` (no duration).
    func event(_ phase: String, _ detail: String)
    /// A log line of `category` (`os.Logger`'s category in the app).
    func log(_ level: LogLevel, _ category: String, _ message: String)
    /// Starts an interval of `phase` whose detail is known only when it ends (`end`): a cache lookup's hit or
    /// miss, or one that spans several calls (a note's first render).
    func begin(_ phase: String) -> PerfInterval
    /// Ends `interval`, reporting it with `detail`.
    func end(_ interval: PerfInterval, _ detail: String)
}

/// An interval a `PerfSink` began (`begin`). `mark` is the sink's own (the app's signpost interval).
public struct PerfInterval: Sendable {
    public let phase: String
    public let mark: (any Sendable)?

    public init(phase: String, mark: (any Sendable)? = nil) {
        self.phase = phase
        self.mark = mark
    }
}

extension PerfSink {
    /// An interval reported as one event when it ends (sinks without intervals of their own).
    public func begin(_ phase: String) -> PerfInterval { PerfInterval(phase: phase) }
    public func end(_ interval: PerfInterval, _ detail: String) { event(interval.phase, detail) }
}

extension UUID {
    /// The first 8 hex digits, lowercased: how log details name a note or page.
    public var perfShort: String { String(uuidString.lowercased().prefix(8)) }
}

/// The level of a `PerfSink.log` line (`os.Logger`'s levels).
public enum LogLevel: String, Sendable, CaseIterable {
    case debug, info, notice, error, fault
}

/// A `PerfSink` that reports nothing (the CLI and tests).
public struct NoPerfSink: PerfSink {
    public init() {}
    public func measure<T>(_ phase: String, _ detail: String, _ body: () throws -> T) rethrows -> T { try body() }
    public func event(_ phase: String, _ detail: String) {}
    public func log(_ level: LogLevel, _ category: String, _ message: String) {}
}

/// A `PerfSink` that keeps what it was told, in order (tests).
public final class MemoryPerfSink: PerfSink, @unchecked Sendable {
    /// One report.
    public enum Record: Equatable, Sendable {
        /// A measured phase (recorded when it ends).
        case measured(phase: String, detail: String)
        case event(phase: String, detail: String)
        case log(LogLevel, category: String, message: String)
    }

    private let lock = NSLock()
    private var kept: [Record] = []

    public init() {}

    /// Everything reported so far.
    public var records: [Record] { lock.withLock { kept } }

    public func measure<T>(_ phase: String, _ detail: String, _ body: () throws -> T) rethrows -> T {
        defer { lock.withLock { kept.append(.measured(phase: phase, detail: detail)) } }
        return try body()
    }

    public func event(_ phase: String, _ detail: String) {
        lock.withLock { kept.append(.event(phase: phase, detail: detail)) }
    }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        lock.withLock { kept.append(.log(level, category: category, message: message)) }
    }

    public func end(_ interval: PerfInterval, _ detail: String) {
        lock.withLock { kept.append(.measured(phase: interval.phase, detail: detail)) }
    }
}

/// An error as a log line may carry it. Messages go to the unified log as public, so they hold no text an error made
/// up: `String(describing:)` and `localizedDescription` of a Foundation file error print the path and the file's
/// name (a vault folder's name is the user's own words). Only what names the failure is kept: the error's type, and
/// its domain and code (for a Swift error, the type's name and the case's number).
public enum LogSafe {
    public static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(String(reflecting: type(of: error))) \(ns.domain) \(ns.code)"
    }
}
