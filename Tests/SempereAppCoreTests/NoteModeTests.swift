import Foundation
import Sempere
@testable import SempereAppCore
import Testing

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

    @Test func aDebugLaunchCanOpenNotesInAnotherMode() {
        #expect(NoteMode.debugInitial(nil) == nil)
        #expect(NoteMode.debugInitial("annotate") == .annotating)
        #expect(NoteMode.debugInitial("Annotating") == .annotating)
        #expect(NoteMode.debugInitial("hand") == .hand)
        #expect(NoteMode.debugInitial("reading") == .reading)
        #expect(NoteMode.debugInitial("draw") == nil)
    }

    @MainActor @Test func theDeviceComesFromThePlatform() {
        #expect(NoteDevice.of(HeadlessPlatform(isMac: true)) == .mac)
        #expect(NoteDevice.of(HeadlessPlatform(isPhone: true)) == .phone)
        #expect(NoteDevice.of(HeadlessPlatform()) == .pad)
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
    /// the listed differences (the iPhone's Add Page and thumbnails live in its Pages menu; the Mac's Drawing
    /// Tools stand in for the palette PencilKit does not show there; a Mac note window's idle timer follows the
    /// library window).
    @Test func everyDeviceOffersTheSameSet() {
        for mode in NoteMode.allCases {
            for readOnly in [false, true] {
                for pages in [1, 3] {
                    let pad = Set(NoteToolbar.items(in: state(.pad, mode, readOnly: readOnly, pages: pages)).map(\.item))
                    var mac = Set(NoteToolbar.items(in: state(.mac, mode, readOnly: readOnly, pages: pages)).map(\.item))
                    #expect(mac.contains(.drawingTools) == (mode == .annotating && !readOnly), "\(mode) \(readOnly)")
                    mac.remove(.drawingTools)
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
                == [.annotate, .hand, .undo, .redo, .text, .eraserSize, .insert, .recordings, .favorite, .tags, .pageNavigation, .addPage, .thumbnails])
        #expect(NoteToolbar.items(.bar, in: state(.pad, .reading))
                == [.annotate, .hand, .undo, .redo, .insert, .recordings, .favorite, .tags, .pageNavigation, .addPage, .thumbnails])
        #expect(NoteToolbar.items(.bar, in: state(.mac, .annotating)).prefix(5) == [.annotate, .hand, .undo, .redo, .drawingTools])
    }

    /// Undo and Redo (issue #8): in the bar on the iPad and the Mac, first in the iPhone's overflow menu, after
    /// the modes in the one order; offered in every mode of a writable note with a page, never read-only.
    @Test func undoAndRedoFollowTheModesAndOpenTheOverflowOnAPhone() {
        #expect(NoteToolbar.order.firstIndex(of: .undo) == NoteToolbar.order.firstIndex(of: .hand)! + 1)
        #expect(NoteToolbar.order.firstIndex(of: .redo) == NoteToolbar.order.firstIndex(of: .undo)! + 1)
        for mode in NoteMode.allCases {
            for device in NoteDevice.allCases {
                let placed = NoteToolbar.items(in: state(device, mode)).filter { $0.item == .undo || $0.item == .redo }
                #expect(placed.map(\.item) == [.undo, .redo], "\(device) \(mode)")
                #expect(placed.allSatisfy { $0.placement == (device == .phone ? .overflow : .bar) }, "\(device) \(mode)")
                if device == .phone {
                    #expect(Array(NoteToolbar.items(.overflow, in: state(device, mode)).prefix(2)) == [.undo, .redo], "\(mode)")
                }
                #expect(!NoteToolbar.items(in: state(device, mode, readOnly: true)).map(\.item).contains(.undo), "\(device) \(mode)")
                #expect(!NoteToolbar.items(in: state(device, mode, pages: 0)).map(\.item).contains(.redo), "\(device) \(mode)")
            }
        }
    }

    /// `isEnabled` follows the focused canvas's undo manager for Undo and Redo, and is true for every other item.
    @Test func undoAndRedoAreEnabledByTheManagersState() {
        var s = state(.pad, .annotating)
        #expect(!NoteToolbar.isEnabled(.undo, in: s) && !NoteToolbar.isEnabled(.redo, in: s), "disabled at first")
        s.undo = UndoAvailability(canUndo: true)
        #expect(NoteToolbar.isEnabled(.undo, in: s) && !NoteToolbar.isEnabled(.redo, in: s))
        s.undo = UndoAvailability(canUndo: false, canRedo: true, redoName: "Move")
        #expect(!NoteToolbar.isEnabled(.undo, in: s) && NoteToolbar.isEnabled(.redo, in: s))
        for item in NoteToolbar.Item.allCases where item != .undo && item != .redo {
            #expect(NoteToolbar.isEnabled(item, in: s), "\(item)")
        }
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

/// The Pages menu (the overflow menu's "Pages", on every device; GA-15).
struct PageMenuTests {
    @Test func aPagedEditableNoteOffersEveryPageAction() {
        let entries = PageMenu.entries(readOnly: false, pageless: false, pageCount: 3, hasDeletedPages: false)
        #expect(entries == [.addAfter, .addAtEnd, .insertPDF, .duplicate, .delete, .thumbnails, .layout])
    }

    @Test func undoDeleteAppearsOnlyAfterADeletion() {
        let entries = PageMenu.entries(readOnly: false, pageless: false, pageCount: 3, hasDeletedPages: true)
        #expect(entries.contains(.undoDelete))
        #expect(entries.firstIndex(of: .undoDelete)! > entries.firstIndex(of: .delete)!)
    }

    @Test func aPagelessNoteOnlyOffersTheWayBackToPages() {
        #expect(PageMenu.entries(readOnly: false, pageless: true, pageCount: 1, hasDeletedPages: true) == [.layout])
        #expect(PageMenu.entries(readOnly: true, pageless: true, pageCount: 1, hasDeletedPages: false).isEmpty)
    }

    @Test func aReadOnlyNoteMayShowThumbnailsButChangesNothing() {
        #expect(PageMenu.entries(readOnly: true, pageless: false, pageCount: 4, hasDeletedPages: true) == [.thumbnails])
        #expect(PageMenu.entries(readOnly: true, pageless: false, pageCount: 1, hasDeletedPages: false).isEmpty)
    }
}

/// GA-58: the iPhone's note toolbar (Annotate, Hand and the overflow menu): the phone's side of `NoteToolbar`.
struct PhoneNoteToolbarTests {
    private func phone(_ mode: NoteMode, readOnly: Bool = false, pages: Int = 1, entries: Bool = false) -> NoteToolbar.State {
        NoteToolbar.State(device: .phone, mode: mode, readOnly: readOnly, hasPage: pages > 0, pageCount: pages,
                          pageEntries: entries)
    }

    @Test func theHandButtonIsOfferedForAWritableNoteWithAPage() {
        for mode in NoteMode.allCases {
            #expect(NoteToolbar.items(.bar, in: phone(mode)) == [.annotate, .hand], "\(mode)")
            #expect(NoteToolbar.items(.bar, in: phone(mode, readOnly: true, pages: 3)).isEmpty, "read-only: none")
            #expect(NoteToolbar.items(.bar, in: phone(mode, pages: 0)).isEmpty, "no page to select on")
        }
    }

    @Test func readingANoteOffersNoWritingAids() {
        for mode in [NoteMode.reading, .hand] {
            let overflow = NoteToolbar.items(.overflow, in: phone(mode))
            #expect(overflow.contains(.insert) && overflow.contains(.paper) && overflow.contains(.recordings))
            #expect(!overflow.contains(.text) && !overflow.contains(.eraserSize), "the drawing aids wait for Annotate")
            #expect(!overflow.contains(.pages) && NoteToolbar.items(.bottomBar, in: phone(mode)).isEmpty,
                    "one page needs no page controls")
        }
        let deleted = NoteToolbar.items(in: phone(.reading, readOnly: true)).map(\.item)
        #expect(!deleted.contains(.annotate) && !deleted.contains(.insert) && !deleted.contains(.paper),
                "a read-only note has no Annotate button and no writing entries")
        #expect(deleted.contains(.allRecordings), "its recordings can still be listed and played")
    }

    @Test func pagesAreInTheBottomBarWhileReadingAndInTheMenuWhileAnnotating() {
        #expect(NoteToolbar.items(.bottomBar, in: phone(.reading, pages: 3)) == [.pageNavigation])
        #expect(NoteToolbar.items(.bottomBar, in: phone(.hand, pages: 3)) == [.pageNavigation], "no palette in Hand mode: the bar stays")
        #expect(NoteToolbar.items(.bottomBar, in: phone(.annotating, pages: 3)).isEmpty, "the bar would sit on the palette")
        #expect(NoteToolbar.items(.overflow, in: phone(.annotating, pages: 3)).contains(.pages))
        #expect(NoteToolbar.items(.bottomBar, in: phone(.reading, readOnly: true, pages: 3)) == [.pageNavigation],
                "a read-only note can still page")
        // A note that became read-only while annotating is read: the page bar, no writing aids.
        let readOnlyAnnotating = phone(.annotating, readOnly: true, pages: 3)
        #expect(NoteToolbar.items(.bottomBar, in: readOnlyAnnotating) == [.pageNavigation])
        #expect(!NoteToolbar.items(.overflow, in: readOnlyAnnotating).contains(.text))
    }

    @Test func annotatingAddsTheDrawingAids() {
        let overflow = NoteToolbar.items(.overflow, in: phone(.annotating, entries: true))
        #expect(overflow.contains(.text) && overflow.contains(.eraserSize))
        #expect(overflow.contains(.pages), "the menu holds Add Page, so a one-page note has it too")
        #expect(!NoteToolbar.items(.overflow, in: phone(.annotating, readOnly: true)).contains(.pages),
                "read-only with one page: nothing to go to or add")
    }

    @Test func pageEntriesKeepThePagesMenuWhileReading() {
        let state = phone(.reading, pages: 3, entries: true)
        #expect(NoteToolbar.items(.overflow, in: state).contains(.pages) && NoteToolbar.items(.bottomBar, in: state) == [.pageNavigation],
                "the menu holds the page actions, the bar turns pages")
    }

    /// Every combination: the page bar is only for when the palette is away, the aids follow Annotate.
    @Test func pageBarIsOnlyForReading() {
        for readOnly in [false, true] {
            for mode in NoteMode.allCases {
                for count in 0...3 {
                    let s = phone(mode, readOnly: readOnly, pages: count)
                    let bar = NoteToolbar.items(.bottomBar, in: s)
                    let overflow = NoteToolbar.items(.overflow, in: s)
                    #expect(!(mode == .annotating && !readOnly && !bar.isEmpty), "\(readOnly) \(mode) \(count)")
                    #expect(overflow.contains(.text) == (mode == .annotating && !readOnly && count > 0))
                }
            }
        }
    }

    /// Annotate is what turns finger drawing on: the toolbar's mode and the canvas agree.
    @Test func theAnnotateToggleDecidesWhetherTheCanvasDraws() {
        #expect(NoteModeInput.of(NoteMode.initial, on: .phone).drawingSuspended)
        #expect(!NoteModeInput.of(.annotating, on: .phone).drawingSuspended)
        #expect(NoteModeInput.of(.annotating, on: .phone).fingersDraw)
    }
}
