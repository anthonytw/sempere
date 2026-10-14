import Foundation
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// Gap audit GA-15 and GA-16: the iPhone's page actions, swipe to turn pages, search highlights
/// at phone size and the paper picker's compact layout. The rules are plain values and run on
/// every destination; the view checks follow the destination's idiom (`Platform.isPhone`), so the
/// iPhone simulator run exercises the phone side.
struct PhonePageMenuTests {
    @Test func aPagedEditableNoteOffersEveryPageAction() {
        let entries = PhonePageMenu.entries(readOnly: false, pageless: false, pageCount: 3, hasDeletedPages: false)
        #expect(entries == [.addAfter, .addAtEnd, .insertPDF, .duplicate, .delete, .thumbnails, .layout])
    }

    @Test func undoDeleteAppearsOnlyAfterADeletion() {
        let entries = PhonePageMenu.entries(readOnly: false, pageless: false, pageCount: 3, hasDeletedPages: true)
        #expect(entries.contains(.undoDelete))
        #expect(entries.firstIndex(of: .undoDelete)! > entries.firstIndex(of: .delete)!)
    }

    @Test func aPagelessNoteOnlyOffersTheWayBackToPages() {
        #expect(PhonePageMenu.entries(readOnly: false, pageless: true, pageCount: 1, hasDeletedPages: true) == [.layout])
        #expect(PhonePageMenu.entries(readOnly: true, pageless: true, pageCount: 1, hasDeletedPages: false).isEmpty)
    }

    @Test func aReadOnlyNoteMayShowThumbnailsButChangesNothing() {
        #expect(PhonePageMenu.entries(readOnly: true, pageless: false, pageCount: 4, hasDeletedPages: true) == [.thumbnails])
        #expect(PhonePageMenu.entries(readOnly: true, pageless: false, pageCount: 1, hasDeletedPages: false).isEmpty)
    }
}

struct PhoneSwipeTests {
    @Test func aSwipeTurnsPagesOnlyWhileReadingAFittedPagedNote() {
        #expect(PhoneReading.swipeTurnsPages(isPhone: true, drawingSuspended: true, zoomed: false, pageCount: 3))
        #expect(!PhoneReading.swipeTurnsPages(isPhone: true, drawingSuspended: false, zoomed: false, pageCount: 3), "annotating")
        #expect(!PhoneReading.swipeTurnsPages(isPhone: true, drawingSuspended: true, zoomed: true, pageCount: 3), "zoomed: pans")
        #expect(!PhoneReading.swipeTurnsPages(isPhone: true, drawingSuspended: true, zoomed: false, pageCount: 1), "one page")
        #expect(!PhoneReading.swipeTurnsPages(isPhone: false, drawingSuspended: true, zoomed: false, pageCount: 3), "iPad and Mac")
    }

    @Test func leftIsForwardRightIsBackAndTheEndsStay() {
        #expect(PhoneReading.pageAfterSwipe(from: 1, towardsLeft: true, pageCount: 3) == 2)
        #expect(PhoneReading.pageAfterSwipe(from: 1, towardsLeft: false, pageCount: 3) == 0)
        #expect(PhoneReading.pageAfterSwipe(from: 2, towardsLeft: true, pageCount: 3) == nil)
        #expect(PhoneReading.pageAfterSwipe(from: 0, towardsLeft: false, pageCount: 3) == nil)
        #expect(PhoneReading.pageAfterSwipe(from: 7, towardsLeft: false, pageCount: 3) == nil, "an index outside the note")
        #expect(PhoneReading.pageAfterSwipe(from: 0, towardsLeft: true, pageCount: 0) == nil)
    }
}

@MainActor
struct PhonePageSwipeStackTests {
    static let phone = CGSize(width: 390, height: 844)

    @Test func theStackTurnsPagesBySwipeOnAPhoneOnly() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let (window, stack) = StackTS.stack(editor, size: Self.phone, drawingSuspended: true)
        defer { window.isHidden = true }
        let names = stack.scroller.gestureRecognizers?.compactMap(\.name) ?? []
        #expect(names.contains("pageSwipeLeft") && names.contains("pageSwipeRight"))
        #expect(stack.swipeTurnsPages == Platform.isPhone)
        stack.turnPage(towardsLeft: true)
        #expect(editor.pageIndex == (Platform.isPhone ? 1 : 0))
        stack.turnPage(towardsLeft: false)
        #expect(editor.pageIndex == 0)
        stack.turnPage(towardsLeft: false)
        #expect(editor.pageIndex == 0, "the first page stays")
    }

    @Test func annotatingTurnsTheSwipeOff() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let (window, stack) = StackTS.stack(editor, size: Self.phone, drawingSuspended: false)
        defer { window.isHidden = true }
        #expect(!stack.swipeTurnsPages)
        stack.turnPage(towardsLeft: true)
        #expect(editor.pageIndex == 0)
    }

    /// Search hits are highlighted on the phone through the same canvas code as on the iPad
    /// (the highlight layer sits in the page canvas, whether or not fingers draw).
    @Test func aSearchMatchIsHighlightedAtPhoneSizeWhileReading() async throws {
        let editor = try await StackTS.savedEditor(pages: 6)
        let (window, stack) = StackTS.stack(editor, size: Self.phone, drawingSuspended: true)
        defer { window.isHidden = true }
        var pages = editor.pages
        let box = Recognition.Box(x: 120, y: 300, w: 80, h: 20)
        pages[4].recognition = Recognition(engine: "t", text: "wombat", words: [.init(text: "wombat", box: box)])
        editor.searchCursor = try #require(SearchMatchCursor(query: "wombat", pages: pages))
        editor.showPage(id: pages[4].id)
        editor.revealToken &+= 1
        StackTS.refresh(stack, editor)
        #expect(editor.pageIndex == 4)
        let slot = try StackTS.slot(stack, editor, page: 4)
        #expect(slot.host.highlights == [HighlightBox(box: box, isCurrent: true)])
        let page = stack.layout.pageFrame(4, scale: Double(stack.scale))
        let s = Double(stack.scale)
        let word = CGRect(x: Double(page.minX) + box.x * s, y: Double(page.minY) + box.y * s, width: box.w * s, height: box.h * s)
        #expect(stack.visibleContentRect.contains(word), "\(word) in \(stack.visibleContentRect)")
    }
}

struct PaperPickerLayoutTests {
    @Test func aPhoneGetsTheCompactLayout() {
        let phone = PaperPickerLayout(horizontal: .compact, vertical: .regular)
        #expect(phone.compact && phone.kindsInStrip && !phone.sideBySide && !phone.defaultButtonPinned)
        #expect(phone.previewMaxHeight != nil)
        #expect(phone.restsAtHalfHeight(page: true))
        #expect(!phone.restsAtHalfHeight(page: false), "a new note's picker has no page behind it")
    }

    @Test func aPhoneInLandscapeStaysCompactEvenAtRegularWidth() {
        #expect(PaperPickerLayout(horizontal: .regular, vertical: .compact).compact)
        #expect(PaperPickerLayout(horizontal: .compact, vertical: .compact).compact)
        #expect(PaperPickerLayout(horizontal: nil, vertical: nil).compact, "unknown: the safe layout")
    }

    @Test func theiPadAndMacKeepTheirLayout() {
        let wide = PaperPickerLayout(horizontal: .regular, vertical: .regular)
        #expect(!wide.compact && !wide.kindsInStrip && wide.sideBySide && wide.defaultButtonPinned)
        #expect(wide.previewMaxHeight == nil)
        #expect(!wide.restsAtHalfHeight(page: true))
    }
}

@MainActor
struct PaperPickerPhoneHostTests {
    /// The picker laid out at iPhone sizes (both orientations): it renders and fills the window.
    @Test func thePickerLaysOutAtPhoneSizes() {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 375, height: 667), CGSize(width: 844, height: 390)] {
            let picker = PaperPickerView(paper: .ruled, purpose: .page(number: 1, count: 3)) { _, _ in }
            let controller = UIHostingController(rootView: picker)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = controller
            window.isHidden = false
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            #expect(controller.view.bounds.size == size, "\(size)")
            window.isHidden = true
        }
    }
}
