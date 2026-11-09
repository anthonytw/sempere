import Foundation
@testable import SempereAppCore
import Testing

/// What a touch on the canvas does besides the palette's tool (`CanvasModes`): the text tool is one-shot
/// (TestFlight 1.0.0) and goes back to the mode it came from.
struct CanvasModesTests {
    @Test func theTextToolIsOneShotAndGoesBackToDrawing() {
        var modes = CanvasModes()
        modes.addingText = true
        #expect(modes.addingText && !modes.selectingItems)
        modes.textToolEnded(.placed)
        #expect(modes.mode == .drawing, "one box, then the palette's tool again")
        // Picking a tool ends it too; so does turning the toggle off.
        modes.addingText = true
        modes.textToolEnded(.toolPicked)
        #expect(modes.mode == .drawing)
        modes.addingText = true
        modes.addingText = false
        #expect(modes.mode == .drawing)
    }

    @Test func theTextToolGoesBackToSelectionModeWhenItCameFromThere() {
        var modes = CanvasModes()
        modes.selectingItems = true
        modes.addingText = true
        #expect(modes.addingText && !modes.selectingItems, "one mode at a time")
        modes.textToolEnded(.placed)
        #expect(modes.selectingItems)
        // A second placement from there does not remember the first.
        modes.addingText = true
        modes.selectingItems = false
        #expect(modes.addingText, "turning off a mode that is not on changes nothing")
        modes.selectingItems = true
        #expect(modes.selectingItems && !modes.addingText)
        modes.reset()
        #expect(modes.mode == .drawing && modes.returnTo == .drawing)
        modes.textToolEnded(.placed)
        #expect(modes.mode == .drawing, "nothing to end")
    }
}
