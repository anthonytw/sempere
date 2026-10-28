import Dispatch
import Foundation

/// Bounded parallelism for blocking vault work (decrypting and decoding many
/// notes) from synchronous code.
package enum Parallel {
    /// Default worker count: the active cores, at most 8. Each worker holds
    /// one note's files in memory at a time, so peak memory is about
    /// `width × the largest note`.
    package static var defaultWidth: Int { max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8)) }

    /// `items.map(transform)` on up to `width` threads. Results keep the
    /// order of `items`. `transform` must be safe to call concurrently.
    /// `done` is called after each item, from the worker that finished it
    /// (so concurrently), with the item's index.
    package static func map<T: Sendable, R: Sendable>(_ items: [T], width: Int, _ transform: @Sendable (T) -> R,
                                              done: (@Sendable (Int, R) -> Void)? = nil) -> [R] {
        let workers = max(1, min(width, items.count))
        if workers == 1 {
            return items.enumerated().map { i, item in
                let r = transform(item)
                done?(i, r)
                return r
            }
        }
        let state = SharedState<R>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while let i = state.claim() {
                let r = transform(items[i])
                state.store(r, at: i)
                done?(i, r)
            }
        }
        return state.results()
    }

    /// The next index to work on and the results so far, behind a lock.
    private final class SharedState<R>: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private let count: Int
        private var slots: [Slot?]

        /// Wrapped so an optional `R` is not flattened away.
        private struct Slot { let value: R }

        init(count: Int) {
            self.count = count
            slots = Array(repeating: nil, count: count)
        }

        func claim() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard next < count else { return nil }
            next += 1
            return next - 1
        }

        func store(_ r: R, at i: Int) {
            lock.lock(); defer { lock.unlock() }
            slots[i] = Slot(value: r)
        }

        func results() -> [R] {
            lock.lock(); defer { lock.unlock() }
            return slots.compactMap { $0 }.map(\.value)
        }
    }
}
