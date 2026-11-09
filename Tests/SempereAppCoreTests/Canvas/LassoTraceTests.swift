import Foundation
@testable import Sempere
@testable import SempereAppCore
import XCTest

/// The loop a Convert to Math lasso collects (`LassoTrace`); the pan recognizer and the dashed outline are the app's.
final class LassoTraceTests: XCTestCase {
    typealias P = InkLasso.Point

    func testMovesCloserThanTwoPointsAreDropped() {
        var t = LassoTrace()
        t.begin(at: P(x: 0, y: 0))
        t.move(to: P(x: 1, y: 1))      // 1.41 away
        t.move(to: P(x: 1.9, y: 0))    // 1.9
        XCTAssertEqual(t.points, [P(x: 0, y: 0)])
        t.move(to: P(x: 2, y: 0))      // exactly 2 is kept
        t.move(to: P(x: 3, y: 0))      // 1 from the last kept point
        t.move(to: P(x: 2, y: 3))      // 3
        XCTAssertEqual(t.points, [P(x: 0, y: 0), P(x: 2, y: 0), P(x: 2, y: 3)])
    }

    func testTheLoopStopsGrowingAtTheCapButTheEndPointStillCounts() {
        var t = LassoTrace()
        t.begin(at: P(x: 0, y: 0))
        for i in 1...(LassoTrace.maxPoints + 100) { t.move(to: P(x: Double(i) * 3, y: 0)) }
        XCTAssertEqual(t.points.count, LassoTrace.maxPoints)
        let loop = t.finish(at: P(x: 1, y: 1), zoom: 1)
        XCTAssertEqual(loop.count, LassoTrace.maxPoints + 1)
        XCTAssertEqual(loop.last, P(x: 1, y: 1))
        XCTAssertTrue(t.points.isEmpty, "finishing clears the trace")
    }

    func testFinishingDividesByTheZoomAndNeverByZero() {
        var t = LassoTrace()
        t.begin(at: P(x: 10, y: 20))
        t.move(to: P(x: 40, y: 20))
        XCTAssertEqual(t.finish(at: P(x: 40, y: 80), zoom: 2), [P(x: 5, y: 10), P(x: 20, y: 10), P(x: 20, y: 40)])
        t.begin(at: P(x: 1, y: 1))
        let tiny = t.finish(at: P(x: 1, y: 1), zoom: 0)
        XCTAssertEqual(tiny[0].x, 1 / 0.0001, accuracy: 1e-6, "a zero or negative zoom counts as 0.0001")
        t.begin(at: P(x: 1, y: 1))
        XCTAssertEqual(t.finish(at: P(x: 1, y: 1), zoom: -3)[0].x, 1 / 0.0001, accuracy: 1e-6)
    }

    func testBeginStartsOverAndClearDropsTheLoop() {
        var t = LassoTrace()
        t.begin(at: P(x: 0, y: 0))
        t.move(to: P(x: 10, y: 0))
        t.begin(at: P(x: 5, y: 5))
        XCTAssertEqual(t.points, [P(x: 5, y: 5)])
        t.clear()
        XCTAssertEqual(t.points, [])
        t.move(to: P(x: 100, y: 100))
        XCTAssertEqual(t.points, [], "a move with no begin keeps nothing")
    }
}
