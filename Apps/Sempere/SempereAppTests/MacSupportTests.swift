import Foundation
import Testing
@testable import SempereApp
import SempereAppCore

struct PointerCursorTests {
    @Test func diameterFollowsWidthAndZoomWithinBounds() {
        #expect(PointerCursor.diameter(toolWidth: 10, zoom: 2) == 20)
        #expect(PointerCursor.diameter(toolWidth: 1, zoom: 1) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: 500, zoom: 4) == PointerCursor.range.upperBound)
        #expect(PointerCursor.diameter(toolWidth: .nan, zoom: 1) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: 5, zoom: 0) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: -5, zoom: 1) == PointerCursor.range.lowerBound)
    }
}
