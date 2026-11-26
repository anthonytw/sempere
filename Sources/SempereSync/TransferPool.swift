import Foundation

/// A group of work items for `TransferPool`: its `then` items start only once
/// every one of its `first` items finished (whatever their outcome). A note's
/// blobs and then its revisions, so a revision never arrives before the blobs
/// it references (format.md §8.1.4 step 4).
public struct TransferGroup<Item: Sendable>: Sendable {
    public var first: [Item]
    public var then: [Item]

    public init(first: [Item] = [], then: [Item] = []) { self.first = first; self.then = then }
}

/// Runs blocking transfers (`SyncRemote` requests) on at most `width`
/// threads at once, so that on a high-latency link the round trips of
/// several requests overlap (`SyncOptions.concurrency`).
///
/// Items start in the order given (a group's `then` items join the queue
/// when its `first` items are done). The first error an item throws stops the
/// pool: no item starts after it, the ones running finish, and `run` rethrows
/// it. Items report their own per-item failures and throw only what must stop
/// everything (a run bound, a cancellation).
///
/// With `width` 1, or a single item, everything runs in order on the calling
/// thread, exactly as a plain loop would.
public struct TransferPool: Sendable {
    /// The most transfers at once (`sempere sync webdav --jobs`).
    public static let maxWidth = 16
    /// The default number of transfers at once.
    public static let defaultWidth = 6

    /// Threads used, `1...maxWidth`.
    public let width: Int

    public init(width: Int = TransferPool.defaultWidth) {
        self.width = min(max(width, 1), Self.maxWidth)
    }

    /// Runs `body` for every item, at most `width` at once.
    public func run<Item: Sendable>(_ items: [Item], _ body: @escaping @Sendable (Item) throws -> Void) throws {
        try run(items.map { TransferGroup(first: [$0]) }, until: nil, body)
    }

    /// Runs `body` for every item of `groups`, at most `width` at once, a
    /// group's `then` items after its `first` ones.
    ///
    /// `until`: asked before each item is handed out, after the first one of this call; once it answers true no item starts, the
    /// ones running finish, and what never started is returned as groups (to run again after whatever `until` asked for: the
    /// control files, `ControlPass.swift`). The pool is drained only then, never otherwise.
    @discardableResult
    public func run<Item: Sendable>(_ groups: [TransferGroup<Item>], until pause: (@Sendable () -> Bool)? = nil,
                                    _ body: @escaping @Sendable (Item) throws -> Void) throws -> [TransferGroup<Item>] {
        let count = groups.reduce(0) { $0 + $1.first.count + $1.then.count }
        guard count > 0 else { return [] }
        if width == 1 || count == 1 {
            var started = false
            for (gi, g) in groups.enumerated() {
                for (ii, item) in g.first.enumerated() {
                    if started, pause?() == true {
                        return [TransferGroup(first: Array(g.first[ii...]), then: g.then)] + Array(groups[(gi + 1)...])
                    }
                    started = true
                    try body(item)
                }
                for (ii, item) in g.then.enumerated() {
                    if started, pause?() == true {
                        return [TransferGroup(first: [], then: Array(g.then[ii...]))] + Array(groups[(gi + 1)...])
                    }
                    started = true
                    try body(item)
                }
            }
            return []
        }
        let queue = Scheduler(groups, pause: pause)
        let work: @Sendable () -> Void = {
            while let next = queue.next() {
                var failure: Error?
                do { try body(next.item) } catch { failure = error }
                queue.finished(group: next.group, first: next.first, error: failure)
            }
        }
        let helpers = min(width, count) - 1
        let done = DispatchGroup()
        for _ in 0..<helpers {
            done.enter()
            let thread = Thread {
                work()
                done.leave()
            }
            // The calling thread's stack, not the 512 KiB of a secondary thread: items decrypt and decode.
            thread.stackSize = 8 << 20
            thread.start()
        }
        work()
        done.wait()
        if let error = queue.failure { throw error }
        return queue.remainder()
    }

    /// The queue the threads take items from.
    private final class Scheduler<Item: Sendable>: @unchecked Sendable {
        private let condition = NSCondition()
        private let groups: [TransferGroup<Item>]
        private var ready: [(item: Item, group: Int, first: Bool)] = []
        private var head = 0
        private var pendingFirst: [Int]
        private var running = 0
        private var error: Error?
        private let pause: (@Sendable () -> Bool)?
        private var handedOut = 0
        private var paused = false

        init(_ groups: [TransferGroup<Item>], pause: (@Sendable () -> Bool)?) {
            self.pause = pause
            self.groups = groups
            pendingFirst = groups.map(\.first.count)
            for (i, g) in groups.enumerated() {
                if g.first.isEmpty {
                    ready += g.then.map { ($0, i, false) }
                } else {
                    ready += g.first.map { ($0, i, true) }
                }
            }
        }

        var failure: Error? {
            condition.lock(); defer { condition.unlock() }
            return error
        }

        /// The next item to run; nil once there is none left (or the pool stopped).
        func next() -> (item: Item, group: Int, first: Bool)? {
            condition.lock(); defer { condition.unlock() }
            while true {
                if error != nil || paused { return nil }
                if head < ready.count {
                    if handedOut > 0, pause?() == true {
                        paused = true
                        condition.broadcast()
                        return nil
                    }
                    let item = ready[head]
                    head += 1
                    handedOut += 1
                    running += 1
                    return item
                }
                if running == 0 { return nil }
                // A running item may release its group's `then` items.
                condition.wait()
            }
        }

        /// What never started (after a pause), as groups in the original order; call after every item finished.
        func remainder() -> [TransferGroup<Item>] {
            condition.lock(); defer { condition.unlock() }
            guard paused else { return [] }
            var out: [TransferGroup<Item>] = []
            for (g, group) in groups.enumerated() {
                let firsts = ready[head...].filter { $0.group == g && $0.first }.map(\.item)
                var thens = ready[head...].filter { $0.group == g && !$0.first }.map(\.item)
                if !firsts.isEmpty { thens = group.then }   // not released yet: all of them wait
                if firsts.isEmpty && thens.isEmpty { continue }
                out.append(TransferGroup(first: firsts, then: thens))
            }
            return out
        }

        func finished(group: Int, first: Bool, error failure: Error?) {
            condition.lock(); defer { condition.unlock() }
            running -= 1
            if let failure, error == nil { error = failure }
            if first {
                pendingFirst[group] -= 1
                if pendingFirst[group] == 0 { ready += groups[group].then.map { ($0, group, false) } }
            }
            condition.broadcast()
        }
    }
}

/// A value handed to `TransferPool` threads that the type system cannot see
/// is safe to share: every access to its mutable state is under the owner's lock.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
