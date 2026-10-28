import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Samples this process's current resident set size every few
/// milliseconds on a background thread (Linux: `/proc/self/statm`; Apple
/// platforms: `task_info`; nil elsewhere) and reports the largest growth over
/// the first sample. Unlike the peak (`peakResidentBytes`), it is not hidden
/// by an earlier test of the same process that raised the peak.
public final class ResidentSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var first: Int?
    private var maximum = 0
    private let finished = DispatchSemaphore(value: 0)

    public init() {
        guard Self.current() != nil else {
            running = false
            finished.signal()
            return
        }
        let t = Thread { [self] in
            while true {
                lock.lock()
                let go = running
                if let now = Self.current() {
                    if first == nil { first = now }
                    maximum = max(maximum, now)
                }
                lock.unlock()
                if !go { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            finished.signal()
        }
        t.start()
    }

    /// Stops sampling; the largest growth over the first sample, or nil
    /// when the platform has no cheap current-RSS reading.
    public func stop() -> Int? {
        lock.lock(); running = false; lock.unlock()
        finished.wait()
        lock.lock(); defer { lock.unlock() }
        return first.map { maximum - $0 }
    }

    public static func current() -> Int? {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ")
        guard fields.count > 1, let pages = Int(fields[1]) else { return nil }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
        #elseif canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.resident_size) : nil
        #else
        return nil
        #endif
    }
}
