import XCTest

/// Waits on a condition in the UI tests, in place of a fixed `Thread.sleep`: the test goes on as soon as the
/// condition holds, and a slow runner gets the whole timeout. The one poll loop of this target (the suites'
/// `waitReport` helpers poll the canvas report; everything else uses this or `waitForExistence`).
enum UIWait {
    /// Polls `condition` every `interval` seconds until it holds or `timeout` seconds pass; false on the timeout.
    @MainActor
    @discardableResult
    static func until(_ timeout: TimeInterval = 10, interval: TimeInterval = 0.1, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= end { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }

    /// Polls `value` until it reads the same `steady` times in a row (a layout or scroll that has come to rest), or
    /// `timeout` passes; returns the last value either way.
    @MainActor
    @discardableResult
    static func settled<T: Equatable>(_ timeout: TimeInterval = 10, interval: TimeInterval = 0.25, steady: Int = 3,
                                      _ value: () -> T) -> T {
        var last = value()
        var same = 1
        let end = Date().addingTimeInterval(timeout)
        while same < steady, Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            let now = value()
            same = now == last ? same + 1 : 1
            last = now
        }
        return last
    }

    /// A pause for an animation or a system process the accessibility tree and the canvas report show nothing of.
    /// Every use names what it waits for; prefer `until` whenever something can be observed.
    @MainActor
    static func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
