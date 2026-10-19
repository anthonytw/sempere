import Foundation
import PencilKit
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// The note view's three modes on every device (`NoteMode`, `NoteModeInput`) and its one toolbar
/// (`NoteToolbar`): pure rules, pinned for the iPhone, the iPad and the Mac on any destination.
struct NoteModeTests {
    /// The two buttons and the three modes (TestFlight build 5 on the iPhone: the Hand turned Annotate on too, so
    /// both had to be tapped to read again): a tap on the lit button goes back to reading, a tap on the other one
    /// switches straight to its mode. The same on every device.
    @Test func theTwoButtonsSwitchBetweenThreeModes() {
        #expect(NoteMode.reading.tapping(.annotate) == .annotating)
        #expect(NoteMode.reading.tapping(.hand) == .hand)
        #expect(NoteMode.annotating.tapping(.annotate) == .reading)
        #expect(NoteMode.annotating.tapping(.hand) == .hand)
        #expect(NoteMode.hand.tapping(.hand) == .reading)
        #expect(NoteMode.hand.tapping(.annotate) == .annotating)
        for mode in NoteMode.allCases {
            let lit = NoteMode.Button.allCases.filter { mode.lights($0) }
            #expect(lit.count == (mode == .reading ? 0 : 1), "at most one button is lit: \(mode)")
            for button in NoteMode.Button.allCases {
                #expect(mode.tapping(button).lights(button) == !mode.lights(button), "a tap toggles the tapped button")
                if !mode.lights(button) { #expect(mode.tapping(button).tapping(button) == .reading, "on, then off: reading") }
            }
        }
    }

    @Test func everyNoteOpensInReadingMode() {
        #expect(NoteMode.initial == .reading)
        for device in NoteDevice.allCases {
            let input = NoteModeInput.of(.initial, on: device)
            #expect(!input.showsPalette && !input.selectingItems && input.reading, "\(device)")
        }
    }

    /// A Pencil touch (an iPad, reading or Hand) and a tool picked from a menu both mean Annotate.
    @Test func aPencilTouchOrAPickedToolIsAnnotate() {
        for mode in NoteMode.allCases {
            #expect(mode.pencilTouched() == .annotating)
            #expect(mode.toolPicked() == .annotating)
        }
    }

    /// What each mode lets the canvas do, per device (the table in `NoteModeInput`).
    @Test func eachModeSaysWhatTheCanvasDoesOnEveryDevice() {
        for device in NoteDevice.allCases {
            let reading = NoteModeInput.of(.reading, on: device)
            let hand = NoteModeInput.of(.hand, on: device)
            let annotating = NoteModeInput.of(.annotating, on: device)
            // The palette only while annotating, selection only in Hand mode, Add Page never while reading.
            #expect(!reading.showsPalette && !hand.showsPalette && annotating.showsPalette, "\(device)")
            #expect(!reading.selectingItems && hand.selectingItems && !annotating.selectingItems, "\(device)")
            #expect(reading.reading && !hand.reading && !annotating.reading, "\(device)")
            #expect(!annotating.drawingSuspended && !annotating.pencilAnnotates, "\(device): annotating draws")
        }
        // An iPad's Pencil draws in every mode (and switches to Annotate); nothing else ever does outside Annotate.
        #expect(NoteModeInput.of(.reading, on: .pad).pencilAnnotates && !NoteModeInput.of(.reading, on: .pad).drawingSuspended)
        #expect(NoteModeInput.of(.hand, on: .pad).pencilAnnotates)
        for device in [NoteDevice.phone, .mac] {
            #expect(NoteModeInput.of(.reading, on: device).drawingSuspended, "\(device): reading draws nothing")
            #expect(!NoteModeInput.of(.reading, on: device).pencilAnnotates && !NoteModeInput.of(.hand, on: device).pencilAnnotates)
        }
        // Only an iPhone's finger is ink (Annotate); the iPad follows the system, the Mac has a pointer.
        #expect(NoteModeInput.of(.annotating, on: .phone).fingersDraw)
        #expect(NoteDevice.allCases.filter { d in NoteMode.allCases.contains { NoteModeInput.of($0, on: d).fingersDraw } } == [.phone])
    }

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

    @Test func aDebugLaunchCanOpenNotesInAnotherMode() {
        #expect(NoteMode.debugInitial(nil) == nil)
        #expect(NoteMode.debugInitial("annotate") == .annotating)
        #expect(NoteMode.debugInitial("Annotating") == .annotating)
        #expect(NoteMode.debugInitial("hand") == .hand)
        #expect(NoteMode.debugInitial("reading") == .reading)
        #expect(NoteMode.debugInitial("draw") == nil)
    }

    /// The Mac's Tools menu mirrors the two buttons: Annotate (⇧⌘P) and Hand (⌥⌘7), each saying "Back to
    /// Reading" while its mode is on.
    @Test func theMenuCommandsFollowTheMode() {
        var c = MenuCommand.Context()
        c.vault = .unlocked
        c.hasNote = true
        c.canEditNote = true
        c.hasPage = true
        #expect(MenuCommand.toggleAnnotate.isEnabled(in: c) && MenuCommand.toggleHand.isEnabled(in: c))
        c.noteMode = .reading
        #expect(MenuCommand.toggleAnnotate.title(in: c) == MenuCommand.toggleAnnotate.title)
        #expect(MenuCommand.toggleHand.title(in: c) == MenuCommand.toggleHand.title)
        c.noteMode = .annotating
        #expect(MenuCommand.toggleAnnotate.title(in: c) == MenuCommand.backToReading)
        #expect(MenuCommand.toggleHand.title(in: c) == MenuCommand.toggleHand.title)
        c.noteMode = .hand
        #expect(MenuCommand.toggleHand.title(in: c) == MenuCommand.backToReading)
        #expect(MenuCommand.toggleAnnotate.title(in: c) == MenuCommand.toggleAnnotate.title)
        c.canEditNote = false
        #expect(!MenuCommand.toggleAnnotate.isEnabled(in: c) && !MenuCommand.toggleHand.isEnabled(in: c), "read-only")
        #expect(MenuLayout.tools.first == [.toggleAnnotate, .toggleHand], "the modes first, as in the top bar")
    }
}

/// The note view's toolbar on every device (`NoteToolbar`, docs/iphone.md "The note view's toolbar on every
/// device"): one order, one set, placements that differ only where a device needs it.
struct NoteToolbarTests {
    private func state(_ device: NoteDevice, _ mode: NoteMode = .reading, readOnly: Bool = false, pages: Int = 3,
                       pageless: Bool = false, recordings: Bool = false, noteWindow: Bool = false) -> NoteToolbar.State {
        NoteToolbar.State(device: device, mode: mode, readOnly: readOnly, hasPage: pages > 0, pageCount: pages,
                          pageless: pageless, hasRecordings: recordings,
                          pageEntries: !PageMenu.entries(readOnly: readOnly, pageless: pageless, pageCount: pages,
                                                         hasDeletedPages: false).isEmpty,
                          noteWindow: noteWindow)
    }

    private var everyState: [NoteToolbar.State] {
        var all: [NoteToolbar.State] = []
        for device in NoteDevice.allCases {
            for mode in NoteMode.allCases {
                for readOnly in [false, true] {
                    for pages in [0, 1, 3] {
                        for pageless in [false, true] {
                            for recordings in [false, true] {
                                all.append(state(device, mode, readOnly: readOnly, pages: pages, pageless: pageless,
                                                 recordings: recordings, noteWindow: device == .mac && pages == 3))
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    /// The iPad lost its way to a note's recordings (PR #31 took out a "Recordings…" entry meant for the
    /// iPhone): "All Recordings…" is in the overflow menu on every device, in every mode, read-only too.
    @Test func everyDeviceReachesTheRecordingsList() {
        for s in everyState {
            #expect(NoteToolbar.items(.overflow, in: s).contains(.allRecordings), "\(s)")
        }
    }

    /// One order everywhere: each device's items, in any state, keep `NoteToolbar.order`, and none is placed twice.
    @Test func everyDeviceKeepsTheOneOrder() {
        for s in everyState {
            let items = NoteToolbar.items(in: s).map(\.item)
            #expect(items == NoteToolbar.order.filter(items.contains), "\(s)")
            #expect(Set(items).count == items.count)
            for placement in [NoteToolbar.Placement.bar, .overflow, .bottomBar] {
                let placed = NoteToolbar.items(placement, in: s)
                #expect(placed == NoteToolbar.order.filter(placed.contains), "\(placement) of \(s)")
            }
        }
    }

    /// The same set on every device: an item offered on one device in a state is offered on the others, besides
    /// the listed differences (the iPhone's Add Page and thumbnails live in its Pages menu; a Mac note window's
    /// idle timer follows the library window).
    @Test func everyDeviceOffersTheSameSet() {
        for mode in NoteMode.allCases {
            for readOnly in [false, true] {
                for pages in [1, 3] {
                    let pad = Set(NoteToolbar.items(in: state(.pad, mode, readOnly: readOnly, pages: pages)).map(\.item))
                    let mac = Set(NoteToolbar.items(in: state(.mac, mode, readOnly: readOnly, pages: pages)).map(\.item))
                    let phone = Set(NoteToolbar.items(in: state(.phone, mode, readOnly: readOnly, pages: pages)).map(\.item))
                    #expect(pad == mac, "\(mode) \(readOnly) \(pages)")
                    // The phone's page navigation gives way to the palette while annotating (its Pages menu turns pages).
                    let phoneOnly: Set<NoteToolbar.Item> = [.addPage, .thumbnails, .pageNavigation]
                    #expect(pad.subtracting(phoneOnly) == phone.subtracting(phoneOnly), "\(mode) \(readOnly) \(pages)")
                }
            }
        }
        let window = Set(NoteToolbar.items(in: state(.mac, noteWindow: true)).map(\.item))
        #expect(!window.contains(.keepScreenOn))
        #expect(NoteToolbar.items(in: state(.mac)).map(\.item).contains(.keepScreenOn))
    }

    /// The overflow menu is the same list on every device; the iPhone's adds, ahead of it, the bar items that do
    /// not fit its top bar.
    @Test func theOverflowMenuIsTheSameOnEveryDevice() {
        for mode in NoteMode.allCases {
            let pad = NoteToolbar.items(.overflow, in: state(.pad, mode))
            #expect(pad == NoteToolbar.items(.overflow, in: state(.mac, mode)))
            #expect(pad == [.pages, .paper, .allRecordings, .rename, .export, .saveVersion, .versionHistory, .keepScreenOn])
            let phone = NoteToolbar.items(.overflow, in: state(.phone, mode))
            #expect(Array(phone.suffix(pad.count)) == pad, "\(mode)")
            #expect(Array(phone.prefix(phone.count - pad.count)) == NoteToolbar.items(.bar, in: state(.pad, mode)).filter {
                NoteToolbar.placement(of: $0, on: .phone) == .overflow
            }, "\(mode)")
        }
    }

    /// The top bar: the two mode buttons first on every device; the iPhone's has nothing else.
    @Test func theModeButtonsLeadTheBar() {
        for device in NoteDevice.allCases {
            for mode in NoteMode.allCases {
                let bar = NoteToolbar.items(.bar, in: state(device, mode))
                #expect(Array(bar.prefix(2)) == [.annotate, .hand], "\(device) \(mode)")
            }
        }
        #expect(NoteToolbar.items(.bar, in: state(.phone, .annotating)) == [.annotate, .hand])
        #expect(NoteToolbar.items(.bar, in: state(.pad, .annotating))
                == [.annotate, .hand, .text, .eraserSize, .insert, .recordings, .favorite, .tags, .pageNavigation, .addPage, .thumbnails])
        #expect(NoteToolbar.items(.bar, in: state(.pad, .reading))
                == [.annotate, .hand, .insert, .recordings, .favorite, .tags, .pageNavigation, .addPage, .thumbnails])
    }

    /// Text and the object eraser's size are Annotate's tools on every device; there is no Select toggle (the
    /// Hand is selection mode) and no palette button (Annotate shows the palette).
    @Test func annotatesToolsOnlyWhileAnnotating() {
        for device in NoteDevice.allCases {
            for mode in NoteMode.allCases {
                let items = NoteToolbar.items(in: state(device, mode)).map(\.item)
                #expect(items.contains(.text) == (mode == .annotating), "\(device) \(mode)")
                #expect(items.contains(.eraserSize) == (mode == .annotating), "\(device) \(mode)")
            }
        }
    }

    @Test func aReadOnlyNoteOffersNoModesAndNothingThatWrites() {
        for device in NoteDevice.allCases {
            let items = NoteToolbar.items(in: state(device, readOnly: true)).map(\.item)
            for item in [NoteToolbar.Item.annotate, .hand, .text, .eraserSize, .insert, .paper, .addPage] {
                #expect(!items.contains(item), "\(device): \(item)")
            }
            #expect(!items.contains(.recordings), "nothing to play: no Recordings menu")
            #expect(NoteToolbar.items(in: state(device, readOnly: true, recordings: true)).map(\.item).contains(.recordings))
        }
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
        #expect(host.canvas.drawingGestureRecognizer.isEnabled, "the Pencil can start a stroke while reading")
        #expect(!host.itemSelection.canPick(), "reading: a tap or hold on an item picks nothing")
        if NoteDevice.current == .pad { #expect(host.canvas.drawingPolicy == .pencilOnly, "only the Pencil: a finger scrolls") }
        host.inkBegan()   // PencilKit: canvasViewDidBeginUsingTool
        #expect(annotate == 1, "the stroke's start asks for Annotate")
        host.pencilAnnotates = false   // the note is annotating now
        host.paletteVisible = true
        #expect(host.canvas.drawingGestureRecognizer.isEnabled, "the stroke goes on: drawing never went off")
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
        #expect(host.canvas.drawingGestureRecognizer.isEnabled, "the Pencil draws")
        #expect(!ItemSelectionController.selectionTouchTypes(pencilDraws: true).contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        #expect(ItemSelectionController.selectionTouchTypes(pencilDraws: false).contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        #expect(host.itemSelection.pencilDraws)
        host.inkBegan()
        #expect(annotate == 1)
        host.inkEnded()
        // The iPhone's and the Mac's Hand: nothing draws.
        host.pencilAnnotates = false
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
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
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
        host.inkBegan()
        #expect(annotate == 0)
        host.inkEnded()
    }

    /// No device's palette has a Hand: the top bar's Hand is the only one (owner, 2026-10-19).
    @Test func noPaletteHasAHand() {
        for compact in [false, true] {
            let picker = ToolPalette.makePicker(compact: compact)
            #expect(!picker.toolItems.contains { $0 is PKToolPickerCustomItem }, "compact: \(compact)")
        }
    }
}
