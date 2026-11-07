import Foundation
import PencilKit
import SempereAppCore
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// The note view's modes as the canvas applies them (`PageCanvasHost`); the rules themselves (`NoteMode`,
/// `NoteModeInput`, `NoteToolbar`) are pinned in SempereAppCoreTests (`NoteModeTests`, `NoteToolbarTests`).
struct NoteModeCanvasTests {
    /// The canvas's drawing policy per device and mode (`PageCanvasHost.drawingPolicy`).
    @Test func theDrawingPolicyFollowsTheDeviceAndTheMode() {
        #expect(PageCanvasHost.drawingPolicy(device: .phone, phoneFingersDraw: true, pencilAnnotates: false) == .anyInput)
        #expect(PageCanvasHost.drawingPolicy(device: .phone, phoneFingersDraw: false, pencilAnnotates: false) == .pencilOnly)
        #expect(PageCanvasHost.drawingPolicy(device: .mac, phoneFingersDraw: false, pencilAnnotates: false) == .anyInput)
        #expect(PageCanvasHost.drawingPolicy(device: .pad, phoneFingersDraw: false, pencilAnnotates: true) == .pencilOnly,
                "an iPad reading or in Hand mode: the Pencil only")
        #expect(PageCanvasHost.drawingPolicy(device: .pad, phoneFingersDraw: false, pencilAnnotates: false) == .default,
                "an iPad annotating: as the system says")
        #expect(PageCanvasHost.drawingPolicy(device: .pad, phoneFingersDraw: false, pencilAnnotates: false,
                                             pencilOnlyDefault: true) == .pencilOnly, "the UI tests' paired Pencil")
    }
}

/// An iPad's Pencil in reading or Hand mode (`NoteModeInput.pencilAnnotates`): PencilKit's drawing stays on for
/// the Pencil only, the selection leaves the Pencil alone, and the stroke's start switches the note to Annotate.
/// XCUITest cannot touch with a Pencil, so the wiring is checked on the canvas itself, on any destination (the
/// policy only on an iPad).
@MainActor
@Suite(.serialized)
struct PencilAnnotatesTests {
    static func host() -> (UIWindow, PageCanvasHost) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.apply(paper: .blank, pageSize: PageSize(width: 612, height: 792, infinite: true, breakHeight: 792))
        host.layoutIfNeeded()
        return (window, host)
    }

    @Test func aPencilStrokeWhileReadingSwitchesToAnnotateAndDraws() {
        let (window, host) = Self.host()
        defer { window.isHidden = true }
        var annotate = 0
        host.onPencilAnnotate = { annotate += 1 }
        host.paletteVisible = false
        host.pencilAnnotates = true
        #expect(host.drawsInk, "the Pencil can start a stroke while reading")
        #expect(!host.itemSelection.canPick(), "reading: a tap or hold on an item picks nothing")
        if NoteDevice.current == .pad { #expect(host.canvas.drawingPolicy == .pencilOnly, "only the Pencil: a finger scrolls") }
        host.inkBegan()   // PencilKit: canvasViewDidBeginUsingTool
        #expect(annotate == 1, "the stroke's start asks for Annotate")
        host.pencilAnnotates = false   // the note is annotating now
        host.paletteVisible = true
        #expect(host.drawsInk, "the stroke goes on: drawing never went off")
        #expect(host.itemSelection.canPick(), "annotating: items can be picked while drawing")
        host.inkEnded()
        if NoteDevice.current == .pad { #expect(host.canvas.drawingPolicy != .pencilOnly || PageCanvasHost.debugPencilOnly) }
        host.inkBegan()
        #expect(annotate == 1, "annotating: a stroke asks for nothing")
        host.inkEnded()
    }

    @Test func handModeLeavesThePencilDrawingAndTheFingersSelecting() {
        let (window, host) = Self.host()
        defer { window.isHidden = true }
        var annotate = 0
        host.onPencilAnnotate = { annotate += 1 }
        host.pencilAnnotates = true
        host.itemSelectionActive = true
        #expect(host.itemSelection.isActive, "fingers select")
        #expect(host.drawsInk, "the Pencil draws")
        #expect(!ItemSelectionController.selectionTouchTypes(pencilDraws: true).contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        #expect(ItemSelectionController.selectionTouchTypes(pencilDraws: false).contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        #expect(host.itemSelection.pencilDraws)
        host.inkBegan()
        #expect(annotate == 1)
        host.inkEnded()
        // The iPhone's and the Mac's Hand: nothing draws.
        host.pencilAnnotates = false
        #expect(!host.drawsInk)
        #expect(!host.itemSelection.pencilDraws)
        host.itemSelectionActive = false
    }

    @Test func aReadOnlyNoteNeverSwitchesToAnnotate() {
        let (window, host) = Self.host()
        defer { window.isHidden = true }
        var annotate = 0
        host.onPencilAnnotate = { annotate += 1 }
        host.isReadOnly = true
        host.pencilAnnotates = true
        #expect(!host.drawsInk)
        host.inkBegan()
        #expect(annotate == 0)
        host.inkEnded()
    }

    /// No device's palette has a Hand: the top bar's Hand is the only one (owner, 2026-10-19).
    @Test func noPaletteHasAHand() {
        let palettes = [DrawingToolState.fullTools] + DrawingTool.allCases.map { DrawingToolState.compactTools(selected: $0) }
        for tools in palettes {
            #expect(tools.allSatisfy { $0.isInk || $0 == .eraser || $0 == .lasso }, "\(tools)")
        }
    }
}
