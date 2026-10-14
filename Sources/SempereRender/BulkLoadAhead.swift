import Foundation

/// Bytes that notes loaded ahead of a bulk export may hold in memory, so that overlapping
/// loading with rendering stays bounded by size and not by the number of notes.
///
/// The caller reserves a note's estimated size before reading it and releases it once the
/// note has been rendered (the note being rendered counts too, so current plus prefetched
/// never exceed `limit`, except for a single note larger than `limit` that is read on its
/// own, `force`d).
///
/// Thread-safe.
public final class ByteBudget: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var used = 0

    public init(limit: Int) { self.limit = max(0, limit) }

    /// Bytes reserved now.
    public var reserved: Int { lock.lock(); defer { lock.unlock() }; return used }

    /// Reserves `bytes` if they fit under `limit` with what is reserved already.
    public func tryReserve(_ bytes: Int) -> Bool {
        let b = max(0, bytes)
        lock.lock(); defer { lock.unlock() }
        guard used + b <= limit else { return false }
        used += b
        return true
    }

    /// Reserves `bytes` whether or not they fit (a note that is read inline, on its own).
    public func force(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        used += max(0, bytes)
    }

    public func release(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        used = max(0, used - max(0, bytes))
    }
}

/// What a look-ahead read produced for one job.
public enum LoadAheadResult<Value: Sendable>: Sendable {
    /// The read ran (or found the job needs none); `bytes` is what it reserved in the budget.
    case ready(Value, bytes: Int)
    /// Nothing was read ahead because the job did not fit the budget: the consumer reads it
    /// itself, in turn (reserving it first, `ByteBudget.force`). The reads after it wait until
    /// the consumer calls `schedule(after:)` for it, so nothing else is reserved before the
    /// consumer has reserved this job; then they go on.
    case declined
    /// There was nothing to read for the job (it is failed or skipped without being read): the
    /// consumer decides that itself, in turn. Later reads go on.
    case nothing
}

/// Reads the jobs of a bulk export ahead of the consumer, in job order and one at a time
/// (so iCloud downloads happen in the order the jobs run), while the consumer renders the
/// current one. Only jobs after the one just taken, at most `depth` of them, are started.
///
/// ```swift
/// let ahead = LoadAhead(count: jobs.count, depth: 2) { index in … }   // produce(index)
/// for index in jobs.indices {
///     let early = await ahead.take(index)       // nil, .declined: reserve it and read it inline
///     ahead.schedule(after: index)              // loads index + 1 ... while this one renders
///     …
/// }
/// await ahead.cancelAndWait()
/// ```
///
/// `produce` must not touch anything the consumer's own thread mutates (the export session's
/// outcomes); it reserves in a `ByteBudget` for what it holds. Thread-safe.
public final class LoadAhead<Value: Sendable>: @unchecked Sendable {
    public typealias Produce = @Sendable (Int) async -> LoadAheadResult<Value>

    private let count: Int
    private let depth: Int
    private let produce: Produce
    private let lock = NSLock()
    private var tasks: [Int: Task<LoadAheadResult<Value>, Never>] = [:]
    private var cancelled = false
    /// The highest index the consumer has moved past (`schedule(after:)`), and reads waiting for one.
    private var passed = -1
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    public init(count: Int, depth: Int, produce: @escaping Produce) {
        self.count = count; self.depth = max(0, depth); self.produce = produce
    }

    /// Starts the reads of the `depth` jobs after `index` that are not started. Each waits for
    /// the read before it to finish first.
    public func schedule(after index: Int) {
        lock.lock()
        passed = max(passed, index)
        let ready = waiters.filter { $0.key <= index }
        for k in ready.keys { waiters[k] = nil }
        lock.unlock()
        for c in ready.values.joined() { c.resume() }
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, depth > 0 else { return }
        var j = index + 1
        while j <= index + depth, j < count {
            if tasks[j] == nil {
                let previous = tasks[j - 1]
                let produce = self.produce, at = j
                tasks[j] = Task {
                    // After a read that did not fit, wait for the consumer to have reserved that job.
                    if case .declined? = await previous?.value { await self.waitUntilPassed(at - 1) }
                    if Task.isCancelled { return .declined }
                    return await produce(at)
                }
            }
            j += 1
        }
    }

    private func waitUntilPassed(_ index: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if passed >= index || cancelled { lock.unlock(); c.resume(); return }
            waiters[index, default: []].append(c)
            lock.unlock()
        }
    }

    /// The result of the read of job `index`, waiting for it if it is running; nil when none was started.
    public func take(_ index: Int) async -> LoadAheadResult<Value>? {
        return await removeTask(index)?.value
    }

    private func removeTask(_ index: Int) -> Task<LoadAheadResult<Value>, Never>? {
        lock.lock(); defer { lock.unlock() }
        return tasks.removeValue(forKey: index)
    }

    private func removeAll() -> [Task<LoadAheadResult<Value>, Never>] {
        lock.lock()
        cancelled = true
        let running = Array(tasks.values)
        tasks = [:]
        let all = Array(waiters.values.joined())
        waiters = [:]
        lock.unlock()
        for c in all { c.resume() }
        return running
    }

    /// Cancels the reads in flight (they stop at their next check); `take` then returns what they ended with.
    public func cancel() {
        lock.lock()
        for t in tasks.values { t.cancel() }
        let all = Array(waiters.values.joined())
        waiters = [:]
        lock.unlock()
        for c in all { c.resume() }
    }

    /// Cancels the reads in flight and waits for them to end, so none runs on after the export.
    /// What they reserved is not released: the budget goes with the run.
    public func cancelAndWait() async {
        let running = removeAll()
        for t in running { t.cancel() }
        for t in running { _ = await t.value }
    }
}
