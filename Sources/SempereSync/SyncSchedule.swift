import Foundation

/// When a two-way sync of one (vault, target) runs (docs/design/device-first-sync.md §4, docs/io.md
/// "Sync targets in the app"). Pure logic: the caller tells it what happened and asks when the next
/// run is due.
///
/// - after a local write: `writeDelay` after the last one;
/// - on demand (unlock, the app becoming active, "Sync Now"): at once;
/// - otherwise periodically: every `arrivingInterval` while the last run brought something or left
///   something arriving, then `idleInterval`, doubling with each run that changed nothing up to
///   `maxIdleInterval`;
/// - after a failure: `firstRetry`, doubling up to `maxRetry` (a write or a demand still runs sooner);
/// - never while a run is going: one that ends with writes or a demand behind it is followed by another.
public struct SyncSchedule: Sendable, Equatable {
    public var writeDelay: TimeInterval = 10
    public var arrivingInterval: TimeInterval = 30
    public var idleInterval: TimeInterval = 300
    public var maxIdleInterval: TimeInterval = 900
    public var firstRetry: TimeInterval = 30
    public var maxRetry: TimeInterval = 900

    /// A run is going.
    public private(set) var running = false
    /// Consecutive failed runs.
    public private(set) var failures = 0
    /// Consecutive successful runs that changed nothing on either side.
    public private(set) var idleRuns = 0
    /// The last successful run brought changes or left files arriving.
    public private(set) var active = false
    /// When the last run started.
    public private(set) var lastAttempt: Date?
    /// When the last run that succeeded ended.
    public private(set) var lastSuccess: Date?
    /// The last local write not yet covered by a run that started after it.
    public private(set) var pendingWrite: Date?
    /// A run was asked for and has not started yet.
    public private(set) var demanded = false

    public init() {}

    /// A write to the local copy happened.
    public mutating func noteWrite(at date: Date) {
        pendingWrite = date
        idleRuns = 0
    }

    /// Ask for a run as soon as possible.
    public mutating func demand() { demanded = true }

    /// Forget the backoff of earlier failures (the network came back): the next automatic run is at the
    /// normal pace again.
    public mutating func resetBackoff() { failures = 0 }

    /// A run starts now.
    public mutating func started(at date: Date) {
        running = true
        lastAttempt = date
        demanded = false
        // Writes up to here are in this run (a run lists the folder as it goes).
        if let w = pendingWrite, w <= date { pendingWrite = nil }
    }

    /// The run ended. `changed`: it transferred or deleted something, or left files arriving.
    public mutating func finished(at date: Date, success: Bool, changed: Bool = false) {
        running = false
        guard success else {
            failures = min(failures + 1, 32)
            return
        }
        failures = 0
        lastSuccess = date
        active = changed
        idleRuns = changed ? 0 : min(idleRuns + 1, 32)
    }

    /// The wait before an automatic retry after `failures` failures.
    public var retryDelay: TimeInterval {
        guard failures > 0 else { return 0 }
        let factor = pow(2.0, Double(min(failures - 1, 20)))
        return min(firstRetry * factor, maxRetry)
    }

    /// The wait between two periodic runs now.
    public var periodicDelay: TimeInterval {
        if active { return arrivingInterval }
        let factor = pow(2.0, Double(min(max(idleRuns - 1, 0), 20)))
        return min(idleInterval * factor, max(maxIdleInterval, idleInterval))
    }

    /// When the next run is due; nil while one is running.
    public func nextRun(now: Date) -> Date? {
        guard !running else { return nil }
        if demanded || lastAttempt == nil { return now }
        var due: Date
        if failures > 0, let last = lastAttempt {
            due = last.addingTimeInterval(retryDelay)
        } else {
            due = (lastAttempt ?? now).addingTimeInterval(periodicDelay)
        }
        if let w = pendingWrite { due = min(due, w.addingTimeInterval(writeDelay)) }
        return max(due, now)
    }

    /// True when a run should start now.
    public func isDue(now: Date) -> Bool {
        guard let next = nextRun(now: now) else { return false }
        return next <= now
    }
}
