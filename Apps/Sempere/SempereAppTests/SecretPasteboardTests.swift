import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SempereApp

/// Device check "key": `SecretPasteboard` (Copy Key) on the real Mac pasteboard. The expiry after three minutes is
/// driven end to end by `CopyKeyExpiryMacUITests`; here the quit handler is exercised in process (the notification
/// `UIApplication` posts at ⌘Q) and the markers and the change-count guard are checked.
@MainActor
final class SecretPasteboardTests: XCTestCase {
    override func setUpWithError() throws {
        UIPasteboard.general.items = []
    }

    private func requireMac() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
    }

    override func tearDown() async throws {
        UIPasteboard.general.items = []
    }

    /// What another app (or `pbpaste`, whose `NSPasteboardTypeString` is this type) reads is the concrete UTF-8 text
    /// type: the abstract `public.plain-text` alone left a pasting app (and `string` readers of other processes) with
    /// nothing (TestFlight 1.3.0 build 111, "says copied, nothing in the clipboard").
    func testCopyIsReadableAsUTF8PlainTextByAnotherApp() throws {
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        let data = try XCTUnwrap(UIPasteboard.general.data(forPasteboardType: UTType.utf8PlainText.identifier))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "AGE-SECRET-KEY-TEST")
        XCTAssertEqual(UIPasteboard.general.string, "AGE-SECRET-KEY-TEST")
        XCTAssertTrue(UIPasteboard.general.hasStrings)
        XCTAssertTrue(UIPasteboard.general.contains(pasteboardTypes: [UTType.plainText.identifier]),
                      "a reader asking for the abstract text type is served too")
        let provider = try XCTUnwrap(UIPasteboard.general.itemProviders.first)
        XCTAssertTrue(provider.canLoadObject(ofClass: NSString.self), "an item provider (a text field's paste) can load it")
    }

    /// Owner's check that Copy Key works from OUTSIDE the app: with `SEMPERE_PASTEBOARD_HOLD=1` in the test runner's
    /// environment (`TEST_RUNNER_SEMPERE_PASTEBOARD_HOLD=1 scripts/app.sh test-mac -only-testing:…`), copies a test key
    /// through `SecretPasteboard.copy` and holds 30 s, while the shell reads it (`pbpaste`, `osascript -e 'the
    /// clipboard'`, or `xcrun simctl pbpaste <udid>` on a simulator). Skipped otherwise.
    func testHoldTheCopiedKeyForAnOutsideRead() throws {
        guard let hold = ProcessInfo.processInfo.environment["SEMPERE_PASTEBOARD_HOLD"] else {
            throw XCTSkip("set SEMPERE_PASTEBOARD_HOLD=1 (TEST_RUNNER_SEMPERE_PASTEBOARD_HOLD) to hold the copy for a check")
        }
        let key = "AGE-SECRET-KEY-PQ-1HOLDCHECK" + String(UUID().uuidString.prefix(8))
        SecretPasteboard.copy(key)
        print("PASTEBOARD-HOLD copied \(key)")
        let deadline = Date().addingTimeInterval(TimeInterval(hold).map { max($0, 30) } ?? 30)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertEqual(UIPasteboard.general.string, key, "still on the pasteboard after the hold")
    }

    func testCopyKeepsTheSecretMarkersOnAnyDevice() {
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        for marker in SecretPasteboard.markers + [SecretPasteboard.ownMarker] {
            XCTAssertTrue(UIPasteboard.general.contains(pasteboardTypes: [marker]), marker)
        }
    }

    func testCopyPutsTheKeyOnThePasteboardWithTheConcealedMarkers() {
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        XCTAssertEqual(UIPasteboard.general.string, "AGE-SECRET-KEY-TEST")
        let types = UIPasteboard.general.items.first?.keys.map { $0 } ?? []
        for marker in SecretPasteboard.markers { XCTAssertTrue(types.contains(marker), "\(marker) in \(types)") }
    }

    func testQuittingClearsTheCopiedKey() throws {
        try requireMac()
        SecretPasteboard.copy("AGE-SECRET-KEY-TEST")
        NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
        XCTAssertNil(UIPasteboard.general.string, "nothing to paste after quitting")
    }

    func testQuittingLeavesSomethingElseTheUserCopiedSince() throws {
        try requireMac()
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
