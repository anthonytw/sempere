import Foundation

/// How far a "Process Now" pass has got, for the Insights screen: notes done of the notes to process (counted when the pass
/// began), the time it has run and an estimate of the time left. Pure value, with the clock passed in, so the math is tested
/// without a device; the view only draws it.
public struct InsightsPassProgress: Equatable, Sendable {
    /// Notes the pass set out to process.
    public let total: Int
    /// Notes processed so far; never more than `total`.
    public private(set) var done = 0
    /// When the pass began.
    public let started: Date

    /// The estimate waits for this many notes: fewer say too little about the rate.
    public static let notesBeforeEstimate = 3

    public init(total: Int, started: Date) {
        self.total = max(0, total)
        self.started = started
    }

    /// `count` more notes are processed (never past `total`, never backwards).
    public mutating func advance(by count: Int) {
        done = min(total, done + max(0, count))
    }

    /// Done over total, 0...1 (0 when there is nothing to process).
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// Time the pass has run at `now` (never negative).
    public func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(started)) }

    /// Seconds left at `now`, from the average per note so far; nil until `notesBeforeEstimate` notes are done, when the
    /// rate is unknown (no time has passed) or nothing is left.
    public func estimatedRemaining(at now: Date) -> TimeInterval? {
        let spent = elapsed(at: now)
        guard done >= Self.notesBeforeEstimate, done < total, spent > 0 else { return nil }
        return spent / Double(done) * Double(total - done)
    }

    /// `seconds` rounded for saying "about …": 10-second steps under a minute (at least 10), whole minutes under an hour,
    /// 5-minute steps after that.
    public static func rounded(_ seconds: TimeInterval) -> TimeInterval {
        let s = max(0, seconds)
        if s < 60 { return max(10, (s / 10).rounded() * 10) }
        if s < 3600 { return (s / 60).rounded() * 60 }
        return (s / 300).rounded() * 300
    }
}
