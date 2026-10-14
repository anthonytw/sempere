import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A one-connection-at-a-time HTTP server on 127.0.0.1 that reads each
/// request body at `bytesPerSecond` (or never, when 0) and then answers
/// with `response` (201 by default): a slow uplink, or a server that stops
/// reading, for the real `URLSessionTransport`. Request heads are kept in
/// `heads`.
final class SlowHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let bytesPerSecond: Int
    private let response: String
    private let lock = NSLock()
    private var stopped = false
    private var _heads: [String] = []
    /// Each request's head (request line and headers), in order.
    var heads: [String] { lock.lock(); defer { lock.unlock() }; return _heads }

    init(bytesPerSecond: Int = 1 << 30,
         response: String = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") throws {
        self.bytesPerSecond = bytesPerSecond
        self.response = response
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                bind(fd, p, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, p, &len) == 0
            }
        }
        guard bound else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        listener = fd
        port = UInt16(bigEndian: addr.sin_port)
        let t = Thread { [self] in serve() }
        t.start()
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func serve() {
        while !isStopped {
            let c = accept(listener, nil, nil)
            guard c >= 0 else { return }
            let t = Thread { [self] in handle(c) }
            t.start()
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var head = Data()
        var buf = [UInt8](repeating: 0, count: 16 << 10)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(c, &buf, 1)
            guard n > 0 else { return }
            head.append(buf[0])
        }
        lock.lock(); _heads.append(String(decoding: head, as: UTF8.self)); lock.unlock()
        let text = String(decoding: head, as: UTF8.self).lowercased()
        let length = text.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        if bytesPerSecond == 0 {
            while !isStopped { usleep(50_000) }
            return
        }
        var left = length
        let chunk = max(bytesPerSecond / 20, 1)
        while left > 0 {
            let n = read(c, &buf, min(chunk, left, buf.count))
            guard n > 0 else { return }
            left -= n
            usleep(useconds_t(1_000_000 * n / bytesPerSecond))
        }
        _ = response.withCString { write(c, $0, strlen($0)) }
    }
}
