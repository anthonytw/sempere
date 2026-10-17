import Foundation
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// The iPhone's Hand tool (owner's decision after TestFlight 1.0.0 (2)): a palette item that turns
/// selection mode on, so one finger scrolls and taps select items; any drawing tool turns it off.
/// The touches are in `PhoneCanvasUITests`; here the palette and the mode wiring, on any destination
/// (`makePicker(hand:)` stands in for the iPhone idiom).
@MainActor
struct HandToolTests {
    static func host(hand: Bool = true) -> (UIWindow, PageCanvasHost, PKToolPicker) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        let picker = ToolPalette.makePicker(compact: true, hand: hand)
        host.adopt(picker)
        return (window, host, picker)
    }

    @Test func thePhonePaletteEndsWithTheHand() {
        let picker = ToolPalette.makePicker(compact: true, hand: true)
        #expect(picker.toolItems.last?.identifier == ToolPalette.handIdentifier)
        #expect(picker.toolItems.count == ToolPalette.makePicker(compact: true, hand: false).toolItems.count + 1)
        #expect(picker.toolItems.last is PKToolPickerCustomItem)
        #expect(picker.selectedToolItemIdentifier != ToolPalette.handIdentifier, "a pen is the default")
        #expect(!ToolPalette.makePicker(compact: true, hand: false).toolItems.contains { $0.identifier == ToolPalette.handIdentifier },
                "the iPad and the Mac have no Hand: a finger already scrolls there")
        #expect(!ToolPalette.makePicker(compact: false, hand: false).toolItems.contains { $0.identifier == ToolPalette.handIdentifier })
        #expect(ToolPalette.makePicker(compact: false, hand: true).toolItems.last?.identifier == ToolPalette.handIdentifier)
    }

    /// Picking the Hand turns selection mode on; picking a drawing tool turns it off again.
    @Test func pickingTheHandSelectsAndAToolDraws() {
        let (window, host, picker) = Self.host()
        defer { window.isHidden = true }
        var picked = 0, ended = 0
        host.onHandToolPicked = { picked += 1 }
        host.onItemSelectionEnded = { ended += 1 }

        picker.selectedToolItemIdentifier = ToolPalette.handIdentifier
        host.toolPickerSelectedToolItemDidChange(picker)
        #expect(picked >= 1 && ended == 0, "picked \(picked) ended \(ended)")
        host.itemSelectionActive = true   // what the note view does with `modes.selectingItems`
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled, "one finger scrolls and taps select")
        #expect(host.itemSelection.isActive)

        let pen = picker.toolItems.first { $0 is PKToolPickerInkingItem }
        picker.selectedToolItemIdentifier = pen?.identifier ?? ""
        host.toolPickerSelectedToolItemDidChange(picker)
        #expect(ended >= 1, "a drawing tool ends selection mode")
        host.itemSelectionActive = false
        #expect(host.drawingEditable, "editable \(host.drawingEditable) transient \(host.transientSelection) tool \(String(describing: picker.selectedToolItem))")
        #expect(host.drawsInk || host.objectEraserSelected, "drawing is back")
    }

    /// Every drawing tool in the phone palette returns to drawing, the eraser and lasso too.
    @Test func everyDrawingToolReturnsToDrawing() {
        let (window, host, picker) = Self.host()
        defer { window.isHidden = true }
        for item in picker.toolItems where item.identifier != ToolPalette.handIdentifier {
            var ended = 0
            host.onItemSelectionEnded = { ended += 1 }
            host.itemSelectionActive = true
            picker.selectedToolItemIdentifier = item.identifier
            host.toolPickerSelectedToolItemDidChange(picker)
            #expect(ended >= 1, "\(item.identifier)")
            host.itemSelectionActive = false
        }
    }

    /// The overflow menu's Select toggle shows the Hand as picked; ending selection by other means
    /// (a new note, the toggle) puts the last drawing tool back instead of leaving the Hand on.
    @Test func thePaletteFollowsSelectionMode() {
        let (window, host, picker) = Self.host()
        defer { window.isHidden = true }
        let marker = picker.toolItems.first { ($0 as? PKToolPickerInkingItem)?.inkingTool.inkType == .marker }
        picker.selectedToolItemIdentifier = marker?.identifier ?? ""
        host.toolPickerSelectedToolItemDidChange(picker)

        host.itemSelectionActive = true
        host.syncHandTool()
        #expect(picker.selectedToolItemIdentifier == ToolPalette.handIdentifier)

        host.itemSelectionActive = false
        host.syncHandTool()
        #expect(picker.selectedToolItemIdentifier == marker?.identifier, "the marker comes back")
    }

    /// Without a Hand in the palette (iPad, Mac) nothing changes.
    @Test func withoutAHandNothingChanges() {
        let (window, host, picker) = Self.host(hand: false)
        defer { window.isHidden = true }
        let before = picker.selectedToolItemIdentifier
        host.itemSelectionActive = true
        host.syncHandTool()
        #expect(picker.selectedToolItemIdentifier == before)
    }

    /// One finger scrolls in selection mode, two scroll in every tool (the stack's pan).
    @Test func scrollingRules() {
        #expect(PageStackHost.minimumPanTouches(drawing: false, fingersDraw: true) == 1, "selection mode / Hand")
        #expect(PageStackHost.minimumPanTouches(drawing: true, fingersDraw: true) == 2, "a drawing tool")
    }
}
