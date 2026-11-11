import UIKit
import XCTest
@testable import SempereApp

/// Device check "key": `SecretPasteboard` (Copy Key) on the real Mac pasteboard. The expiry after three minutes is
/// driven end to end by `CopyKeyExpiryMacUITests`; here the quit handler is exercised in process (the notification
/// `UIApplication` posts at ⌘Q) and the markers and the change-count guard are checked.
@MainActor
final class SecretPasteboardTests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        UIPasteboard.general.items = []
    }

    override func tearDown() async throws {
        UIPasteboard.general.items = []
    }

    func testCopyPutsTheKeyOnThePasteboardWithTheConcealedMarkers() {
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        XCTAssertEqual(UIPasteboard.general.string, "AGE-SECRET-KEY-TEST")
        let types = UIPasteboard.general.items.first?.keys.map { $0 } ?? []
        for marker in SecretPasteboard.markers { XCTAssertTrue(types.contains(marker), "\(marker) in \(types)") }
    }

    func testQuittingClearsTheCopiedKey() {
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
        XCTAssertNil(UIPasteboard.general.string, "nothing to paste after quitting")
    }

    func testQuittingLeavesSomethingElseTheUserCopiedSince() {
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        UIPasteboard.general.string = "shopping list"
        NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(UIPasteboard.general.string, "shopping list")
    }

    func testCopyCarriesSemperesOwnMarker() {
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        XCTAssertTrue(UIPasteboard.general.contains(pasteboardTypes: [SecretPasteboard.ownMarker]))
    }

    func testLaunchClearsAStaleMarkedItem() {
        #if targetEnvironment(macCatalyst)
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        SecretPasteboard.clearStaleAtLaunch()
        XCTAssertNil(UIPasteboard.general.string, "a key left by a killed run is gone")
        #endif
    }

    func testLaunchLeavesUnmarkedItemsAlone() {
        #if targetEnvironment(macCatalyst)
        UIPasteboard.general.string = "shopping list"
        SecretPasteboard.clearStaleAtLaunch()
        XCTAssertEqual(UIPasteboard.general.string, "shopping list")

        // Another app's concealed item has the nspasteboard.org marker but not Sempere's.
        UIPasteboard.general.setItems([["public.utf8-plain-text": "hunter2",
                                        "org.nspasteboard.ConcealedType": Data([0])]])
        SecretPasteboard.clearStaleAtLaunch()
        XCTAssertEqual(UIPasteboard.general.string, "hunter2")
        #endif
    }
}
