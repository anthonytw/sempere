import UIKit
import Vision
import XCTest

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
        // Saved windows are not restored: the probe reads the saved state files at launch, before any
        // window comes back, and a restored note window that closes (it brings the library up) took
        // the report's alert with it a few seconds after it appeared.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_LOCKED": "1", "SEMPERE_DEBUG_LEFTOVERS": Self.title,
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760"]
        app.launch()
        defer { app.terminate() }
        // On the Mac an alert's message is the static text's value, not its label.
        let text = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                                                        "SempereLeftovers", "SempereLeftovers")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "the launch showed its leftover report")
        let report = (text.value as? String).flatMap { $0.hasPrefix("SempereLeftovers") ? $0 : nil } ?? text.label
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
        XCTAssertEqual(counts["import"], 0, "no plaintext work copy of the imported PDF after ⌘Q: \(report)")
        XCTAssertEqual(counts["keyshare"], 0, report)
        XCTAssertEqual(counts["export"], 0, report)
        XCTAssertGreaterThan(counts["scanned"] ?? 0, 0, "the probe read the saved state and preferences: \(report)")
        XCTAssertEqual(counts["hits"], 0, "no note title in the saved window state or preferences: \(report)")
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
