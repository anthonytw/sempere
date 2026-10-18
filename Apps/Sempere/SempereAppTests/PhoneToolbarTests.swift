import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// GA-58: the iPhone's note toolbar (Annotate and the overflow menu), the split view's
/// columns on a phone, and the scroll extent of a pageless note at phone size.
/// Run by `scripts/app.sh test-phone`; the rules are pure, so they also pass on the iPad.
struct PhoneToolbarTests {
    // MARK: Columns

    /// A wide landscape iPhone (Pro Max) shows columns: the system decides, a layout
    /// stored by an iPad or a Mac never hides its list.
    @Test func aPhoneLeavesTheColumnsToTheSystemWhateverIsStored() {
        for stored in ["all", "doubleColumn", "detailOnly", "", "garbage"] {
            #expect(ColumnLayout.visibility(from: stored, isPhone: true) == .automatic, "\(stored)")
        }
    }

    @Test func otherDevicesKeepTheStoredColumns() {
        #expect(ColumnLayout.visibility(from: "detailOnly", isPhone: false) == .detailOnly)
        #expect(ColumnLayout.visibility(from: "doubleColumn", isPhone: false) == .doubleColumn)
        #expect(ColumnLayout.visibility(from: "all", isPhone: false) == .all)
        #expect(ColumnLayout.visibility(from: "anything else", isPhone: false) == .all)
    }

    @Test func aPhoneNeverStoresAColumnLayout() {
        // The system collapsing or showing columns on a phone leaves the stored choice alone.
        for visibility in [NavigationSplitViewVisibility.detailOnly, .doubleColumn, .all, .automatic] {
            #expect(ColumnLayout.storing(visibility, over: "all", isPhone: true) == "all")
            #expect(ColumnLayout.storing(visibility, over: "doubleColumn", isPhone: true) == "doubleColumn")
        }
    }

    @Test func otherDevicesStoreWhatTheSplitViewChoseToShow() {
        #expect(ColumnLayout.storing(.detailOnly, over: "all", isPhone: false) == "detailOnly")
        #expect(ColumnLayout.storing(.doubleColumn, over: "all", isPhone: false) == "doubleColumn")
        #expect(ColumnLayout.storing(.all, over: "detailOnly", isPhone: false) == "all")
        #expect(ColumnLayout.stored(ColumnLayout.visibility(from: "doubleColumn")) == "doubleColumn")
    }

    // MARK: Toolbar

    @Test func theHandButtonIsOfferedForAWritableNoteWithAPage() {
        for mode in PhoneCanvasMode.allCases {
            #expect(PhoneToolbar.items(readOnly: false, mode: mode, pageCount: 1, hasPage: true).handButton, "\(mode)")
            #expect(!PhoneToolbar.items(readOnly: true, mode: mode, pageCount: 3, hasPage: true).handButton, "read-only: none")
            #expect(!PhoneToolbar.items(readOnly: false, mode: mode, pageCount: 0, hasPage: false).handButton, "no page to select on")
        }
    }

    /// The two buttons and the three modes (TestFlight build 5: the Hand turned Annotate on too, so both had to be
    /// tapped to read again, and the pencil turned off with the Hand on left a finger drawing): a tap on the lit
    /// button goes back to reading, a tap on the other one switches straight to its mode.
    @Test func theTwoButtonsSwitchBetweenThreeModes() {
        #expect(PhoneCanvasMode.reading.tapping(.annotate) == .annotating)
        #expect(PhoneCanvasMode.reading.tapping(.hand) == .hand)
        #expect(PhoneCanvasMode.annotating.tapping(.annotate) == .reading)
        #expect(PhoneCanvasMode.annotating.tapping(.hand) == .hand)
        #expect(PhoneCanvasMode.hand.tapping(.hand) == .reading)
        #expect(PhoneCanvasMode.hand.tapping(.annotate) == .annotating)
        for mode in PhoneCanvasMode.allCases {
            let lit = PhoneCanvasMode.Button.allCases.filter { mode.lights($0) }
            #expect(lit.count == (mode == .reading ? 0 : 1), "at most one button is lit: \(mode)")
            for button in PhoneCanvasMode.Button.allCases {
                #expect(mode.tapping(button).lights(button) == !mode.lights(button), "a tap toggles the tapped button")
                if !mode.lights(button) { #expect(mode.tapping(button).tapping(button) == .reading, "on, then off: reading") }
            }
        }
    }

    /// What each mode lets a finger do, derived from the one value.
    @Test func eachModeSaysWhatAFingerDoes() {
        #expect(!PhoneCanvasMode.reading.fingersDraw && !PhoneCanvasMode.reading.selectingItems && !PhoneCanvasMode.reading.showsPalette)
        #expect(!PhoneCanvasMode.hand.fingersDraw && PhoneCanvasMode.hand.selectingItems && !PhoneCanvasMode.hand.showsPalette)
        #expect(PhoneCanvasMode.annotating.fingersDraw && !PhoneCanvasMode.annotating.selectingItems && PhoneCanvasMode.annotating.showsPalette)
    }

    /// The palette's Hand item (only reachable while annotating) is Hand mode; the canvas re-picking it to
    /// keep the palette in step changes nothing in the other modes.
    @Test func thePalettesHandItemMovesToHandMode() {
        #expect(PhoneCanvasMode.annotating.handToolPicked() == .hand)
        #expect(PhoneCanvasMode.hand.handToolPicked() == .hand)
        #expect(PhoneCanvasMode.reading.handToolPicked() == .reading)
    }

    @Test func readingANoteOffersNoWritingEntries() {
        for mode in [PhoneCanvasMode.reading, .hand] {
            let single = PhoneToolbar.items(readOnly: false, mode: mode, pageCount: 1, hasPage: true)
            #expect(single.writes, "Annotate, Paper, Insert and Recordings are in the toolbar and its overflow menu")
            #expect(!single.writingTools, "the drawing aids wait for Annotate")
            #expect(!single.pagesMenu && !single.pageBar, "one page needs no page controls")
        }
        let deleted = PhoneToolbar.items(readOnly: true, mode: .reading, pageCount: 1, hasPage: true)
        #expect(deleted == PhoneToolbar.Items(), "a read-only note has no Annotate button and no overflow entries")
    }

    @Test func pagesAreInTheBottomBarWhileReadingAndInTheMenuWhileAnnotating() {
        let reading = PhoneToolbar.items(readOnly: false, mode: .reading, pageCount: 3, hasPage: true)
        #expect(reading.pageBar && !reading.pagesMenu)
        let hand = PhoneToolbar.items(readOnly: false, mode: .hand, pageCount: 3, hasPage: true)
        #expect(hand.pageBar && !hand.pagesMenu, "no palette in Hand mode: the bar stays")
        let annotating = PhoneToolbar.items(readOnly: false, mode: .annotating, pageCount: 3, hasPage: true)
        #expect(annotating.pagesMenu && !annotating.pageBar, "the bar would sit on the palette")
        let readOnly = PhoneToolbar.items(readOnly: true, mode: .reading, pageCount: 3, hasPage: true)
        #expect(readOnly.pageBar && !readOnly.writes, "a read-only note can still page")
        // A note that became read-only while annotating is read: the page bar, no writing aids.
        let readOnlyAnnotating = PhoneToolbar.items(readOnly: true, mode: .annotating, pageCount: 3, hasPage: true)
        #expect(readOnlyAnnotating.pageBar && !readOnlyAnnotating.writingTools)
    }

    @Test func annotatingAddsTheDrawingAidsAndAPagesMenuEvenForOnePage() {
        let items = PhoneToolbar.items(readOnly: false, mode: .annotating, pageCount: 1, hasPage: true)
        #expect(items.writes && items.writingTools)
        #expect(items.pagesMenu, "the menu holds Add Page, so a one-page note has it too")
        #expect(!items.pageBar)
        let single = PhoneToolbar.items(readOnly: true, mode: .annotating, pageCount: 1, hasPage: true)
        #expect(!single.pagesMenu, "read-only with one page: nothing to go to or add")
    }

    @Test func pageEntriesKeepThePagesMenuWhileReading() {
        let reading = PhoneToolbar.items(readOnly: false, mode: .reading, pageCount: 3, hasPage: true, pageEntries: true)
        #expect(reading.pagesMenu && reading.pageBar, "the menu holds the page actions, the bar turns pages")
    }

    /// Every combination: the page bar is only for when the palette is away, the aids follow Annotate.
    @Test func pageBarIsOnlyForReading() {
        for readOnly in [false, true] {
            for mode in PhoneCanvasMode.allCases {
                for count in 0...3 {
                    let items = PhoneToolbar.items(readOnly: readOnly, mode: mode, pageCount: count, hasPage: count > 0)
                    #expect(!(mode == .annotating && !readOnly && items.pageBar), "\(readOnly) \(mode) \(count)")
                    #expect(!items.writingTools || items.writes)
                    #expect(items.writingTools == (mode == .annotating && !readOnly))
                }
            }
        }
    }

    /// Annotate is what turns finger drawing on (`PhoneReading`): the toolbar's mode and the canvas agree.
    @Test func theAnnotateToggleDecidesWhetherTheCanvasDraws() {
        #expect(PhoneReading.drawingSuspended(isPhone: true, mode: PhoneReading.modeAfterNoteChange()))
        #expect(!PhoneReading.drawingSuspended(isPhone: true, mode: .annotating))
    }
}

/// A pageless note at iPhone sizes: it scrolls one screen beyond its stored height
/// (`PageExtent.scrollHeight`), and a finite page ends with its height (or the screen).
@MainActor
@Suite(.serialized)
struct PhonePagelessTests {
    static func host(size: CGSize, pageSize: PageSize) -> (UIWindow, PageCanvasHost) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.apply(paper: .blank, pageSize: pageSize)
        host.layoutIfNeeded()
        return (window, host)
    }

    @Test func aPagelessNoteScrollsOneScreenBeyondItsStoredHeight() {
        let infinite = PageSize(width: 612, height: 792, infinite: true)
        for size in PhoneCanvasTests.sizes {
            let (window, host) = Self.host(size: size, pageSize: infinite)
            let z = host.canvas.zoomScale
            #expect(abs(z - size.width / 612) < 0.0005, "\(size)")
            // (stored height + one screen in page points) at the zoom = stored height * z + the screen.
            let expected = 792 * z + size.height
            #expect(abs(host.canvas.contentSize.height - expected) < 1, "\(size): \(host.canvas.contentSize.height) vs \(expected)")
            #expect(host.canvas.contentSize.height > size.height, "there is always room to keep writing")
            window.isHidden = true
        }
    }

    @Test func aFinitePageEndsAtItsHeightOrTheScreen() {
        let letter = PageSize(width: 612, height: 792, infinite: false, breakHeight: 792)
        for size in PhoneCanvasTests.sizes {
            let (window, host) = Self.host(size: size, pageSize: letter)
            let z = host.canvas.zoomScale
            let expected = max(792 * z, size.height)
            #expect(abs(host.canvas.contentSize.height - expected) < 1, "\(size)")
            window.isHidden = true
        }
    }

    @Test func theScrollExtentRuleIsTheSameWithoutAView() {
        let infinite = PageSize(width: 612, height: 792, infinite: true)
        // A phone's screen in page points at the fitted zoom: 956 / (440 / 612).
        let viewport = 956.0 / (440.0 / 612.0)
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: nil, viewportHeight: viewport) == 792 + viewport)
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: 3000, viewportHeight: viewport) == 3000 + viewport,
                "past the stored height the ink decides")
    }
}
