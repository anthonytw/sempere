import Foundation

// MARK: - Saves that wait together go in one request (docs/design/1.4-cloudkit.md §13)
//
// Measured against the real private database: a single save takes about 0.4 s and a zone takes about 2.5 saves a second
// whatever the concurrency, while 400 small records in one request take 3.5 s. The engine's transfer pool makes saves
// from several threads at once, so they are grouped: the thread that finds no request in flight takes everything that is
// waiting (at most 400 items and 4 MiB of plain fields) and sends it; the others wait for their own item's answer. A
// lone save is sent at once (no delay is added). Each item keeps its own condition and its own result: a conflict is that
// item's, and an item that only failed because an atomic request failed for another (`batchRequestFailed`) is sent again.

final class CloudBatcher: @unchecked Sendable {
    /// What one item came to.
    enum Outcome {
        case saved(CloudRecord)
        case conflict(CloudRecord?)
        case deleted
    }

    private final class Item {
        let save: CloudSave?
        let delete: String?
        let bytes: Int
        var attempts = 0
        var result: Result<Outcome, Error>?
        init(save: CloudSave?, delete: String?) {
            self.save = save
            self.delete = delete
            // About a record's own weight beside its fields.
            bytes = 512 + (save?.fields.bytes?.count ?? 0) + (save?.fields.path?.utf8.count ?? 0)
        }
    }

    private let cond = NSCondition()
    private var queue: [Item] = []
    private var flushing = false
    /// How many requests went out and how many items they carried (tests read them).
    private(set) var requests = 0
    private(set) var items = 0
    private(set) var largest = 0

    /// Sends one request: its saves and deletes, answered in order.
    typealias Send = ([CloudSave], [String]) throws -> CloudModifyResult

    /// Queues one save (or delete) and returns its own result. `send` is the caller's way to a request; the thread that
    /// sends for the group uses its own.
    func submit(save: CloudSave? = nil, delete: String? = nil, send: Send) throws -> Outcome {
        let item = Item(save: save, delete: delete)
        cond.lock()
        queue.append(item)
        while item.result == nil {
            if flushing {
                cond.wait()
                continue
            }
            flushing = true
            let batch = take()
            cond.unlock()
            let (done, again) = run(batch, send)
            cond.lock()
            for (i, r) in done { i.result = r }
            queue.insert(contentsOf: again, at: 0)
            requests += 1
            items += batch.count
            largest = max(largest, batch.count)
            flushing = false
            cond.broadcast()
        }
        cond.unlock()
        return try item.result!.get()
    }

    /// The items for the next request, the lock held.
    private func take() -> [Item] {
        var batch: [Item] = []
        var bytes = 0
        while let next = queue.first, batch.count < CloudStoreLimits.maxItemsPerRequest,
              batch.isEmpty || bytes + next.bytes <= CloudStoreLimits.maxInlineBytesPerRequest {
            batch.append(queue.removeFirst())
            bytes += next.bytes
        }
        return batch
    }

    private func run(_ batch: [Item], _ send: Send) -> (done: [(Item, Result<Outcome, Error>)], again: [Item]) {
        let saves = batch.compactMap(\.save), deletes = batch.compactMap(\.delete)
        do {
            let r = try send(saves, deletes)
            guard r.saves.count == saves.count, r.deletes.count == deletes.count else {
                let bad = CloudStoreError(.internalError, "the answer does not match the request")
                return (batch.map { ($0, .failure(bad)) }, [])
            }
            var done: [(Item, Result<Outcome, Error>)] = []
            var again: [Item] = []
            var si = 0, di = 0
            for item in batch {
                let failure: CloudStoreError?
                var outcome: Outcome?
                if item.save != nil {
                    switch r.saves[si] {
                    case .saved(let rec): outcome = .saved(rec); failure = nil
                    case .conflict(let rec): outcome = .conflict(rec); failure = nil
                    case .failed(let e): failure = e
                    }
                    si += 1
                } else {
                    switch r.deletes[di] {
                    case .deleted: outcome = .deleted; failure = nil
                    case .failed(let e): failure = e
                    }
                    di += 1
                }
                if let outcome { done.append((item, .success(outcome))); continue }
                if let failure {
                    item.attempts += 1
                    // Innocent members of a request that failed whole are sent again, a few times.
                    if failure.code == .batchRequestFailed, item.attempts < 3 { again.append(item) } else { done.append((item, .failure(failure))) }
                }
            }
            return (done, again)
        } catch let e as CloudStoreError where e.code == .limitExceeded && batch.count > 1 {
            // Too big for the store: half and half.
            let mid = batch.count / 2
            let first = run(Array(batch[..<mid]), send), second = run(Array(batch[mid...]), send)
            return (first.done + second.done, first.again + second.again)
        } catch {
            return (batch.map { ($0, .failure(error)) }, [])
        }
    }
}
