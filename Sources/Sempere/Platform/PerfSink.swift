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
}
