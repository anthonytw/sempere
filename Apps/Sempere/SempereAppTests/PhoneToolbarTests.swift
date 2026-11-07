import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// GA-58: the split view's columns on a phone, and the scroll extent of a pageless note at phone size
/// (the iPhone's note toolbar: `PhoneNoteToolbarTests`, SempereAppCoreTests).
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
