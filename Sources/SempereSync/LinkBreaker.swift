import Foundation

// MARK: - A dead link stops the run (offline audit P8)
//
// A device that is online only now and then often loses the link in the middle of a run. Each request after
// that fails on its own (a timeout of up to a minute over WebDAV), and a run that keeps going tries every file
// it has left: hundreds of requests, most of an hour, during which no new run (the network coming back) can
// start. The run's requests go through `LinkBreaker`: after `threshold` requests in a row fail for the network
// (a `TransientRemoteError` whose `isUnreachable` is set: no network, a timeout, a cut connection; never a full
// disk or a TLS failure), it trips, and every request after it fails with `SyncError.connectionLost`, a run bound: the run
// stops as it does at its time bound (`stoppedEarly`), keeps what it did, and the next run continues. Any
// request that succeeds resets the count. The descriptions of the network failures it saw are kept, so the
// report can tell them from lasting problems (`SyncReport.Issue.kind`).

/// Counts consecutive network failures of one run's requests; trips after `threshold` of them.
final class LinkBreaker: @unchecked Sendable {
    /// How many requests in a row may fail for the network before the run stops.
    static let defaultThreshold = 3

    private let lock = NSLock()
    private let threshold: Int
    private var consecutive = 0
    private var tripped: String?
    private var seen = Set<String>()
    private var total = 0

    init(threshold: Int = LinkBreaker.defaultThreshold) { self.threshold = max(threshold, 1) }

    /// True for a failure that says only that the remote cannot be reached now (`TransientRemoteError.isUnreachable`):
    /// never a full disk, a quota, an I/O error, a busy lock or a TLS failure (review of #90, M1).
    static func isNetworkFailure(_ error: Error) -> Bool {
        (error as? any TransientRemoteError)?.isUnreachable == true
    }

    /// The error every request gets once the breaker tripped, nil before.
    var trippedError: SyncError? {
        lock.lock(); defer { lock.unlock() }
        return tripped.map { SyncError.connectionLost($0) }
    }

    /// Network failures this run met.
    var failures: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    /// Whether `message` (as `SyncEngine.describe` words it) is one of the network failures this run met.
    func sawNetworkFailure(_ message: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.contains(message)
    }

    /// Runs one request through the breaker.
    func run<T>(_ body: () throws -> T) throws -> T {
        if let e = trippedError { throw e }
        do {
            let value = try body()
            lock.lock(); consecutive = 0; lock.unlock()
            return value
        } catch {
            note(error)
            throw error
        }
    }

    private func note(_ error: Error) {
        guard Self.isNetworkFailure(error) else {
            // An answer from the remote (a refusal, a missing file) says the link works.
            if !(error is SyncError) { lock.lock(); consecutive = 0; lock.unlock() }
            return
        }
        let text = SyncEngine.describe(error)
        lock.lock()
        consecutive += 1
        total += 1
        seen.insert(text)
        if consecutive >= threshold, tripped == nil { tripped = "\(consecutive) requests in a row failed: \(text)" }
        lock.unlock()
    }
}
