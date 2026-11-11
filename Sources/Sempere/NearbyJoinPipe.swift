import Foundation

/// Two connected in-memory `NearbyJoinConnection`s (tests, and front ends that have no link): what one sends, the other
/// receives, in order. Canceling either end ends the stream both ways.
public enum NearbyJoinPipe {
    /// A connected pair.
    public static func make() -> (a: Connection, b: Connection) {
        let ab = Queue(), ba = Queue()
        let a = Connection(inbox: ba, outbox: ab)
        let b = Connection(inbox: ab, outbox: ba)
        return (a, b)
    }

    /// Bytes one way, with the waiting receiver (at most one).
    final class Queue: @unchecked Sendable {
        // Guarded by `lock`.
        private let lock = NSLock()
        private var bytes = Data()
        private var ended = false
        private var waiter: CheckedContinuation<Void, Never>?

        func put(_ data: Data) -> Bool {
            lock.lock()
            guard !ended else { lock.unlock(); return false }
            bytes.append(data)
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume()
            return true
        }

        func end() {
            lock.lock()
            ended = true
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume()
        }

        /// Up to `maximum` bytes, or nil at the end.
        func take(_ maximum: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            if !bytes.isEmpty {
                let out = Data(bytes.prefix(maximum))
                bytes = Data(bytes.dropFirst(out.count))
                return out
            }
            return ended ? Data() : nil
        }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if !bytes.isEmpty || ended {
                    lock.unlock()
                    c.resume()
                } else {
                    waiter = c
                    lock.unlock()
                }
            }
        }
    }

    /// One end.
    public final class Connection: NearbyJoinConnection, @unchecked Sendable {
        let inbox: Queue
        let outbox: Queue
        /// Bytes this end sent (tests look at what went over the link).
        public var sent: Data {
            lock.lock()
            defer { lock.unlock() }
            return sentBytes
        }
        private let lock = NSLock()
        private var sentBytes = Data()

        init(inbox: Queue, outbox: Queue) {
            self.inbox = inbox
            self.outbox = outbox
        }

        public func send(_ data: Data) async throws {
            guard outbox.put(data) else { throw NearbyJoinError.closed }
            record(data)
        }

        private func record(_ data: Data) {
            lock.lock()
            sentBytes.append(data)
            lock.unlock()
        }

        public func receive(maximum: Int) async throws -> Data {
            while true {
                if let got = inbox.take(max(1, maximum)) { return got }
                await inbox.wait()
            }
        }

        public func cancel() {
            inbox.end()
            outbox.end()
        }
    }
}
