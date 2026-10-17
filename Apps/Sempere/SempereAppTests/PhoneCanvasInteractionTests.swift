import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The iPhone canvas (TestFlight 1.0.0 (2), the owner's iPhone): a finger draws there, so a finger
/// tap on an item used to leave a dot and select nothing, and a held finger showed no menu. A tap
/// (one finger, up within 0.4 s, within 8 points) that begins on an item now selects it; a stroke
/// still draws wherever it starts; a hold shows the item's menu. The touches themselves are in
/// `PhoneCanvasUITests` (iPhone simulator); here the decisions, on any destination
/// (`ItemSelectionController.fingersPick` stands in for the iPhone idiom).
@MainActor
struct PhoneCanvasInteractionTests {
    // MARK: Tap or stroke

    @Test func aTapStaysWithinTheSlopAndIsShort() {
        var tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        #expect(tracker.isTap(endingAt: CGPoint(x: 103, y: 104), time: 10.12))

        tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        tracker.moved(to: CGPoint(x: 100, y: 120))   // a stroke or a scroll
        #expect(tracker.failed)
        #expect(!tracker.isTap(endingAt: CGPoint(x: 100, y: 100), time: 10.1), "back where it began is still a stroke")

        tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        #expect(!tracker.isTap(endingAt: CGPoint(x: 100, y: 100), time: 10.5), "a hold is the menu's, not a tap")

        tracker = FingerTapTracker(at: CGPoint(x: 100, y: 100), time: 10)
        tracker.moved(to: CGPoint(x: 100, y: 100), touches: 2)   // a second finger: a two-finger scroll or a pinch
        #expect(!tracker.isTap(endingAt: CGPoint(x: 100, y: 100), time: 10.05))
        #expect(FingerTapTracker.maxDuration < 0.45, "under the hold's 0.45 s: a tap never races the hold")
    }

    // MARK: On the host

    static func hostWithImage(fingersPick: Bool = true) async throws -> (PageCanvasHost, NoteEditor, Item, UUID) {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let image = try editor.addItems([CanvasSelectionTests.image()], on: page)[0]
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        host.itemSelection.fingersPick = fingersPick
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        return (host, editor, image, page)
    }

    /// Canvas point of page point `p`.
    static func screen(_ p: CGPoint, _ host: PageCanvasHost) -> CGPoint {
        let z = host.canvas.zoomScale
        return CGPoint(x: p.x * z, y: p.y * z)
    }

    @Test func aFingerTapMayStartOnlyOnAnItem() async throws {
        let (host, editor, _, _) = try await Self.hostWithImage()
        // The image is at (100, 100) 200 x 100.
        #expect(host.itemSelection.fingerTapMayStart(at: Self.screen(CGPoint(x: 200, y: 150), host)))
        #expect(!host.itemSelection.fingerTapMayStart(at: Self.screen(CGPoint(x: 20, y: 600), host)),
                "off every item the recognizer fails at once: ink is not delayed")
        await editor.flush()
    }

    @Test func theIPadKeepsItsFingersForInk() async throws {
        let (host, editor, _, _) = try await Self.hostWithImage(fingersPick: false)
        #expect(!host.itemSelection.fingerTapMayStart(at: Self.screen(CGPoint(x: 200, y: 150), host)))
        #expect(!host.itemSelection.fingerTap.isEnabled, "the iPad's own tap (a paired Pencil) stays")
        await editor.flush()
    }

    @Test func readingAndSelectingLeaveTheTapAlone() async throws {
        let (host, editor, image, _) = try await Self.hostWithImage()
        let inside = Self.screen(CGPoint(x: 200, y: 150), host)
        host.drawingSuspended = true   // reading on an iPhone: a finger scrolls, nothing is picked
        #expect(!host.itemSelection.fingerTapMayStart(at: inside))
        host.drawingSuspended = false
        #expect(host.itemSelection.fingerTapMayStart(at: inside))
        host.itemSelection.pick(image.id, menu: false)   // selected: the selection's own tap takes over
        #expect(!host.itemSelection.fingerTapMayStart(at: inside))
        host.itemSelection.select(nil)
        #expect(host.itemSelection.fingerTapMayStart(at: inside))
        host.isReadOnly = true
        #expect(!host.itemSelection.fingerTapMayStart(at: inside), "a read-only note selects nothing")
        await editor.flush()
    }

    /// PencilKit's drawing waits for the tap to fail, and nothing else does: scrolling, zooming and
    /// the other picking recognizers are not delayed.
    @Test func onlyPencilKitsDrawingWaitsForTheTap() async throws {
        let (host, editor, _, _) = try await Self.hostWithImage()
        let controller = host.itemSelection
        let tap = controller.fingerTap
        #expect(controller.gestureRecognizer(tap, shouldBeRequiredToFailBy: host.canvas.drawingGestureRecognizer))
        #expect(!controller.gestureRecognizer(tap, shouldBeRequiredToFailBy: host.canvas.panGestureRecognizer))
        if let pinch = host.canvas.pinchGestureRecognizer {
            #expect(!controller.gestureRecognizer(tap, shouldBeRequiredToFailBy: pinch))
        }
        #expect(controller.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: host.canvas.panGestureRecognizer))
        #expect(tap.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)], "fingers only")
        await editor.flush()
    }

    /// A tap picks the item as the Pencil's tap does: selected, no menu, drawing off while it is
    /// selected and back once nothing is.
    @Test func aPickedItemShowsTheBarAndDrawingComesBack() async throws {
        let (host, editor, image, _) = try await Self.hostWithImage()
        #expect(host.canvas.drawingGestureRecognizer.isEnabled || host.objectEraserSelected)
        host.itemSelection.pick(image.id, menu: false)
        #expect(host.itemSelection.selectedID == image.id)
        #expect(host.transientSelection)
        #expect(!host.itemSelection.bar.isHidden == !Platform.isMac, "the selection bar is up (iPhone and iPad)")
        #expect(!host.itemSelection.bar.deleteButton.isHidden)
        #expect(!host.itemSelection.menuElements().isEmpty, "the bar's menu button offers the item's menu")
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled, "a drag on the selected item moves it, not ink")
        host.itemSelection.select(nil)   // a tap beside it
        #expect(!host.transientSelection && host.itemSelection.selectedID == nil)
        #expect(host.canvas.drawingGestureRecognizer.isEnabled || host.objectEraserSelected, "a finger draws again")
        await editor.flush()
    }

    /// The bar stays inside the page at phone width, whatever the item.
    @Test func theBarFitsAPhoneWidth() {
        let content = CGSize(width: 393, height: 1000)
        for rect in [CGRect(x: 0, y: 300, width: 40, height: 40), CGRect(x: 360, y: 300, width: 33, height: 40),
                     CGRect(x: 0, y: 0, width: 393, height: 1000)] {
            let bar = ItemSelectionBar.frame(around: rect, width: ItemSelectionBar.height * 2 + 4, in: content)
            #expect(bar.minX >= 0 && bar.maxX <= content.width && bar.minY >= 0 && bar.maxY <= content.height, "\(rect)")
        }
    }

    // MARK: Scrolling with fingers that draw

    /// One finger draws, two scroll (pages of a stack); reading mode gives the one finger back.
    @Test func twoFingersScrollWhileOneDraws() {
        #expect(PageStackHost.minimumPanTouches(drawing: true, fingersDraw: true) == 2)
        #expect(PageStackHost.minimumPanTouches(drawing: false, fingersDraw: true) == 1, "reading: one finger scrolls")
        #expect(PageStackHost.minimumPanTouches(drawing: true, fingersDraw: false) == 1, "a paired Pencil: a finger scrolls")
        let drawingTypes = PageStackHost.panTouchTypes(drawing: true, isMac: false).map(\.intValue)
        #expect(drawingTypes.contains(UITouch.TouchType.direct.rawValue))
        #expect(!drawingTypes.contains(UITouch.TouchType.pencil.rawValue), "the Pencil draws, never scrolls")
    }

    /// Finger drawing on an iPhone host is the policy `PhoneCanvasTests` checks; the tap recognizer
    /// does not turn it off.
    @Test func theTapRecognizerLeavesFingerDrawingOn() async throws {
        let (host, editor, _, _) = try await Self.hostWithImage()
        host.canvas.drawingPolicy = .anyInput
        #expect(host.canvas.drawingGestureRecognizer.isEnabled || host.objectEraserSelected)
        #expect(host.itemSelection.fingerTap.isEnabled && host.itemSelection.fingerTap.cancelsTouchesInView == false)
        await editor.flush()
    }
}
