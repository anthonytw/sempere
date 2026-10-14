import UIKit
import Vision
import XCTest

/// Device check c28: sharing a key on the Mac copies no key. Opens the demo vault (unlocked
/// by the app), the key window (⌥⌘K), Save Key… on this device's key, then Share…, with the
/// owner check answered by `SEMPERE_DEBUG_OWNER_CHECK` (XCTest cannot give Touch ID).
/// Run by `scripts/app.sh test-mac-ui`; takes the screen. Skipped on the iPad.
final class KeyShareMacUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    @MainActor
    private func launch(ownerCheck: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": "respiration",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "SEMPERE_DEBUG_OWNER_CHECK": ownerCheck]
        app.launch()
        return app
    }

    /// Vault Keys ▸ this device's key ▸ Save Key… ▸ (owner check) ▸ the Save Key sheet.
    @MainActor
    private func openSaveKey(_ app: XCUIApplication) {
        let row = app.cells.containing(NSPredicate(format: "label == %@", "Cellular Respiration")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the demo vault is open")
        let keys = app.descendants(matching: .any)["keysWindow"].firstMatch
        for _ in 0..<4 where !keys.exists {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            app.typeKey("k", modifierFlags: [.command, .option])
            _ = keys.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(keys.exists, "the key window opened")
        let save = app.buttons["Save Key…"].firstMatch
        if !save.waitForExistence(timeout: 10) { dump(app, "no Save Key in the key window") }
        XCTAssertTrue(save.exists, "the key window offers Save Key… on this device's key")
        save.click()
    }

    /// With the owner check passed: Share… opens the system share menu, and its Copy puts no key
    /// on the pasteboard (c28: a secret key never goes to the general pasteboard, which has no
    /// expiry and reaches the user's other devices through Universal Clipboard).
    ///
    /// On macOS 27 the menu is drawn by the ShareSheetUI service, out of process and outside the
    /// app's accessibility tree (XCTest cannot attach to the service, and keys do not reach its
    /// menu), and it lists Copy whatever `excludedActivityTypes` says (screenshot `key-share-menu`).
    /// So the test finds Copy on a screenshot (Vision text recognition), clicks it, and checks that
    /// the pasteboard holds no key.
    @MainActor
    func testSharingAKeyFromTheKeyWindowCopiesNothing() throws {
        let app = launch(ownerCheck: "pass")
        defer { app.terminate() }
        openSaveKey(app)
        let share = app.buttons["Share…"].firstMatch
        if !share.waitForExistence(timeout: 20) { dump(app, "no Share in Save Key") }
        XCTAssertTrue(share.exists, "Save Key… shows Share… once the owner check passed")
        UIPasteboard.general.string = "sempere-ui-test-sentinel"
        share.click()
        Thread.sleep(forTimeInterval: 3)   // the service draws its menu
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "key-share-menu"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let copy = Self.locate("Copy", on: shot, screenWidth: app.menuBars.firstMatch.frame.width) else {
            return XCTFail("no Copy in the share menu (screenshot key-share-menu)")
        }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: copy.x - window.frame.minX, dy: copy.y - window.frame.minY)).click()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertNil(Self.locate("Copy", on: XCUIScreen.main.screenshot(),
                                   screenWidth: app.menuBars.firstMatch.frame.width), "the click chose Copy (the menu closed)")
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "after-copy"
        after.lifetime = .keepAlways
        add(after)
        let pb = UIPasteboard.general
        print("MACUIDEBUG pasteboard after Copy: types=\(pb.types) "
              + "sentinel=\(pb.string == "sempere-ui-test-sentinel") urls=\(pb.urls ?? []) strlen=\(pb.string?.count ?? -1)")
        // Copy still runs (it empties the pasteboard) but is handed nothing: without `SecretItem` it put
        // the staged key file's URL and path on the pasteboard (measured 2026-10-14).
        XCTAssertFalse(pb.hasURLs, "no key file on the pasteboard: \(pb.types)")
        XCTAssertFalse(pb.hasStrings && pb.string != "sempere-ui-test-sentinel", "no key text or path on the pasteboard: \(pb.types)")
        XCTAssertTrue(pb.types.allSatisfy { $0.hasPrefix("public.utf8-plain-text") || $0 == "public.plain-text" }
                      || pb.types.isEmpty, "nothing else on the pasteboard: \(pb.types)")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    /// The middle of the line of text reading exactly `text` on a screenshot of the main screen
    /// (`screenWidth` points wide), in screen points; nil when there is none.
    static func locate(_ text: String, on shot: XCUIScreenshot, screenWidth: CGFloat) -> CGPoint? {
        guard let cg = shot.image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        // The image is in pixels; the menu bar spans the screen, so its width gives the points.
        let size = CGSize(width: screenWidth, height: screenWidth * CGFloat(cg.height) / CGFloat(cg.width))
        for observation in request.results ?? [] {
            guard observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) == text else { continue }
            let box = observation.boundingBox   // normalized, origin at the bottom left
            return CGPoint(x: box.midX * size.width, y: (1 - box.midY) * size.height)
        }
        return nil
    }

    /// A failed owner check shows why and no key, Share… or Save to Files….
    @MainActor
    func testAFailedOwnerCheckShowsNoKey() throws {
        let app = launch(ownerCheck: "fail")
        defer { app.terminate() }
        openSaveKey(app)
        let failure = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "could not confirm it is you")).firstMatch
        if !failure.waitForExistence(timeout: 20) { dump(app, "no failure text") }
        XCTAssertTrue(failure.exists, "the sheet says the check failed")
        XCTAssertFalse(app.buttons["Share…"].exists)
        XCTAssertFalse(app.buttons["Save to Files…"].exists)
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }

    @MainActor
    private func dump(_ app: XCUIApplication, _ tag: String) {
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("MACUIDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(8000))")
        }
    }
}

/// Device check c27: quitting the Mac app (⌘Q) leaves no decrypted attachment in
/// `Caches/Sempere/Blobs` and no note title in the saved window state. The test runner cannot
/// read the app's container (macOS App Data protection, as the owner found with Terminal), so
/// the next launch looks for itself (`SEMPERE_DEBUG_LEFTOVERS`, before anything is purged)
/// and shows the counts in its alert. A kill (no `applicationWillTerminate`) shows that the
/// probe does see the files, and that the launch after it purges them.
/// Run by `scripts/app.sh test-mac-ui`; takes the screen. Skipped on the iPad.
final class QuitPurgeMacUITests: XCTestCase {
    /// The demo PDF note: imported at launch and opened, so its pages' blobs are decrypted.
    private static let title = "Demo PDF"

    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    /// A fresh launch that imports and opens the demo PDF and opens it in a note window too
    /// (its title then names a window), then waits for the pages to be drawn.
    @MainActor
    private func launchWithAttachmentOpen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_PDF": "1", "SEMPERE_DEBUG_FRESH": "1",
                                 "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_MAC_WINDOW": "1100x760"]
        app.launch()
        XCTAssertTrue(app.staticTexts[Self.title].firstMatch.waitForExistence(timeout: 90), "the PDF note opened")
        let row = app.cells.containing(NSPredicate(format: "label == %@", Self.title)).firstMatch
        if row.waitForExistence(timeout: 10) {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            app.typeKey("n", modifierFlags: [.command, .option])
            _ = app.descendants(matching: .any)["noteWindow"].waitForExistence(timeout: 20)
        }
        Thread.sleep(forTimeInterval: 6)   // page tiles are drawn (and their blobs fetched) asynchronously
        return app
    }

    /// The next launch's report: `SempereLeftovers blobs=N import=N keyshare=N export=N scanned=N hits=N …`.
    @MainActor
    private func leftovers() -> (report: String, counts: [String: Int]) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_LOCKED": "1", "SEMPERE_DEBUG_LEFTOVERS": Self.title,
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760"]
        app.launch()
        defer { app.terminate() }
        let text = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "SempereLeftovers")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "the launch showed its leftover report")
        let report = text.label
        print("MACUIDEBUG \(report)")
        var counts: [String: Int] = [:]
        for part in report.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let n = Int(pair[1]) { counts[String(pair[0])] = n }
        }
        return (report, counts)
    }

    @MainActor
    func testQuitLeavesNoDecryptedFilesOrTitles() throws {
        let app = launchWithAttachmentOpen()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "⌘Q quit the app")
        let (report, counts) = leftovers()
        XCTAssertEqual(counts["blobs"], 0, "no decrypted attachment after ⌘Q: \(report)")
        XCTAssertEqual(counts["keyshare"], 0, report)
        XCTAssertEqual(counts["export"], 0, report)
        XCTAssertGreaterThan(counts["scanned"] ?? 0, 0, "the probe read the saved state and preferences: \(report)")
        XCTAssertEqual(counts["hits"], 0, "no note title in the saved window state or preferences: \(report)")
        // Not asserted: `import`, the import's plaintext work copy of the PDF, which only the next
        // launch purges (`PDFPreparation.purge`); reported for the record.
    }

    /// A kill skips `applicationWillTerminate`: the files are there at the next launch (so the
    /// probe sees them), and that launch purges them before any vault opens.
    @MainActor
    func testAKilledRunsFilesArePurgedAtTheNextLaunch() throws {
        let app = launchWithAttachmentOpen()
        app.terminate()   // SIGKILL-like: no applicationWillTerminate
        let first = leftovers()
        XCTAssertGreaterThan(first.counts["blobs"] ?? 0, 0, "a killed run leaves decrypted files: \(first.report)")
        let second = leftovers()
        XCTAssertEqual(second.counts["blobs"], 0, "the launch after the kill purged them: \(second.report)")
    }
}
