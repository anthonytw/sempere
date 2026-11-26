import Foundation
@testable import SempereAppCore
import Testing

/// The Process Now progress model: counts, elapsed time and the estimate, with the clock passed in.
struct InsightsPassProgressTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func theEstimateWaitsForAFewNotesAndUsesTheAverage() {
        var p = InsightsPassProgress(total: 10, started: start)
        let at = start.addingTimeInterval(60)
        #expect(p.estimatedRemaining(at: at) == nil, "no notes done: rate unknown")
        p.advance(by: 2)
        #expect(p.estimatedRemaining(at: at) == nil, "two notes say too little")
        p.advance(by: 1)
        #expect(p.estimatedRemaining(at: at) == 140, "20 s a note, 7 left")
        p.advance(by: 7)
        #expect(p.estimatedRemaining(at: at) == nil, "nothing left")
    }

    @Test func noTimeSpentMeansNoRate() {
        var p = InsightsPassProgress(total: 10, started: start)
        p.advance(by: 5)
        #expect(p.estimatedRemaining(at: start) == nil)
        #expect(p.estimatedRemaining(at: start.addingTimeInterval(-5)) == nil, "a clock that went back")
        #expect(p.elapsed(at: start.addingTimeInterval(-5)) == 0)
        #expect(p.elapsed(at: start.addingTimeInterval(42)) == 42)
    }

    @Test func theCountNeverPassesTheTotalOrGoesBack() {
        var p = InsightsPassProgress(total: 5, started: start)
        p.advance(by: 4)
        p.advance(by: -3)
        #expect(p.done == 4)
        p.advance(by: 9)
        #expect(p.done == 5 && p.fraction == 1)
        #expect(InsightsPassProgress(total: -2, started: start).total == 0)
        #expect(InsightsPassProgress(total: 0, started: start).fraction == 0)
    }

    @Test func theEstimateIsRoundedToSayAbout() {
        #expect(InsightsPassProgress.rounded(3) == 10)
        #expect(InsightsPassProgress.rounded(44) == 40)
        #expect(InsightsPassProgress.rounded(200) == 180)
        #expect(InsightsPassProgress.rounded(250) == 240)
        #expect(InsightsPassProgress.rounded(4000) == 3900)
    }
}
