import Foundation
@testable import SempereAppCore
import Testing

/// Moved from the app's `MacSupportTests` (wave 6 follow-up F1), with `PointerCursor`.
struct PointerCursorTests {
    @Test func diameterFollowsWidthAndZoomWithinBounds() {
        #expect(PointerCursor.diameter(toolWidth: 10, zoom: 2) == 20)
        #expect(PointerCursor.diameter(toolWidth: 1, zoom: 1) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: 500, zoom: 4) == PointerCursor.range.upperBound)
        #expect(PointerCursor.diameter(toolWidth: .nan, zoom: 1) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: 5, zoom: 0) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: -5, zoom: 1) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: .infinity, zoom: 1) == PointerCursor.range.lowerBound)
    }
}
