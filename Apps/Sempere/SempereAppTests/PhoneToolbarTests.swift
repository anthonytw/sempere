import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// GA-58: the iPhone's note toolbar (Annotate, Hand and the overflow menu), the split view's
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

    // MARK: Toolbar (the phone's side of `NoteToolbar`; every device: `NoteToolbarTests`)

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
