import Foundation

/// Two connected in-memory `NearbyJoinConnection`s (tests, and front ends that have no link): what one sends, the other
/// receives, in order. Canceling either end ends the stream both ways.
public enum NearbyJoinPipe {
    /// A connected pair. With a `capacity`, a send returns only once at most that many bytes wait unread, as a socket's
    /// buffer does: a peer that never reads makes the sender wait (tests of a peer that stops reading).
    public static func make(capacity: Int = .max) -> (a: Connection, b: Connection) {
        let ab = Queue(capacity: capacity), ba = Queue(capacity: capacity)
        let a = Connection(inbox: ba, outbox: ab)
        let b = Connection(inbox: ab, outbox: ba)
        return (a, b)
    }

    /// Bytes one way, with the waiting receiver and the waiting sender (at most one each).
    final class Queue: @unchecked Sendable {
        let capacity: Int
        // Guarded by `lock`.
        private let lock = NSLock()
        private var bytes = Data()
        private var ended = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var sender: CheckedContinuation<Void, Never>?

        init(capacity: Int) { self.capacity = capacity }

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
            let w = waiter, s = sender
            waiter = nil
            sender = nil
            lock.unlock()
            w?.resume()
            s?.resume()
        }

        /// Up to `maximum` bytes, or nil at the end.
        func take(_ maximum: Int) -> Data? {
            lock.lock()
            if !bytes.isEmpty {
                let out = Data(bytes.prefix(maximum))
                bytes = Data(bytes.dropFirst(out.count))
                let s = bytes.count <= capacity ? sender : nil
                if s != nil { sender = nil }
                lock.unlock()
                s?.resume()
                return out
            }
            let atEnd = ended
            lock.unlock()
            return atEnd ? Data() : nil
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

        /// Returns once at most `capacity` bytes wait unread, or the stream ended (then false).
        /// True once what was put fits the capacity (it is sent, as a socket's buffered bytes are, even if the reader
        /// then ends the stream); false when the stream ended while it waited for room.
        func waitForRoom() async -> Bool {
            var fits = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if bytes.count <= capacity {
                    fits = true
                    lock.unlock()
                    c.resume()
                } else if ended {
                    lock.unlock()
                    c.resume()
                } else {
                    sender = c
                    lock.unlock()
                }
            }
            return fits || !isEnded()
        }

        private func isEnded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ended
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
        private var host: String?
        /// The address this end claims the other end came from (tests set it; `MemoryNearbyTransport.open(_:from:)`).
        public var remoteHost: String? {
            get { lock.lock(); defer { lock.unlock() }; return host }
            set { lock.lock(); host = newValue; lock.unlock() }
        }

        init(inbox: Queue, outbox: Queue) {
            self.inbox = inbox
            self.outbox = outbox
        }

        public func send(_ data: Data) async throws {
            guard outbox.put(data) else { throw NearbyJoinError.closed }
            record(data)
            guard await outbox.waitForRoom() else { throw NearbyJoinError.closed }
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
