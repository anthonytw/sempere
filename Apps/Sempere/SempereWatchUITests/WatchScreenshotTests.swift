import XCTest

/// The Watch page's screenshots for the project website (docs/design/1.2-screenshots.md §3.2): the watch app's one screen
/// in the states the page describes, started the way `WatchStatesUITests` starts it (a debug state, a fake recorder, no
/// WatchConnectivity), at the simulator's native watch size. Run through `scripts/screenshots.sh docs-watch`, which
/// passes `TEST_RUNNER_SEMPERE_SHOTS_DIR` (and, for the dark twins, `SEMPERE_SHOTS_APPEARANCE`; the watch is dark either
/// way, so a dark run saves the same screens under its own name). The shots are also attached to the result bundle, where
/// the script takes them from when the runner cannot write into the checkout. Nothing is asserted but that each screen
/// showed. The vault's name on the screen is the demo vault's, "My Notes" (as on the iPhone and iPad shots).
/// "Saved" stays up only two seconds in the app, less than a screenshot takes, so the run holds it for ten.
final class WatchScreenshotTests: XCTestCase {
    private var directory: URL? {
        ProcessInfo.processInfo.environment["SEMPERE_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    private func launch(unsent: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["SEMPERE_WATCH_DEBUG"] = "1"
        app.launchEnvironment["SEMPERE_WATCH_DEBUG_PROFILE"] = "1"
        app.launchEnvironment["SEMPERE_WATCH_DEBUG_VAULT_NAME"] = "My Notes"   // DemoVault.folderName without ".sempere"
        app.launchEnvironment["SEMPERE_WATCH_DEBUG_SAVED_SECONDS"] = "10"
        if unsent > 0 { app.launchEnvironment["SEMPERE_WATCH_DEBUG_UNSENT"] = "\(unsent)" }
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String, after delay: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: delay)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory else { return }
        do {
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        } catch {
            // The runner may be sandboxed; the script then reads the result bundle's attachments.
            print("SHOTDEBUG \(name): could not write the PNG: \(error)")
        }
    }

    private func expect(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        let labels = app.descendants(matching: .any).allElementsBoundByIndex.prefix(40).map { $0.label }.filter { !$0.isEmpty }
        print("SHOTDEBUG \(what): \(labels)")
        XCTFail("never showed \(what)")
        return false
    }

    /// Ready to record, then recording, then saved, and Ready again with the note counted as waiting for the iPhone.
    func testReadyRecordingAndSaved() {
        let app = launch()
        defer { app.terminate() }
        let record = app.buttons["watch.record"]
        guard expect(record, "Record", in: app) else { return }
        shoot(app, "01-ready")
        record.tap()
        guard expect(app.staticTexts["watch.elapsed"], "the elapsed time", in: app) else { return }
        // A few seconds on the clock, so the time reads like a recording in progress.
        Thread.sleep(forTimeInterval: 4)
        shoot(app, "02-recording")
        let stop = app.buttons["watch.stop"]
        guard expect(stop, "Stop", in: app) else { return }
        stop.tap()
        // Saved stays for ten seconds here; a short pause lets the check mark settle, well inside that.
        if expect(app.staticTexts["watch.saved"], "Saved", in: app, timeout: 15) { shoot(app, "03-saved", after: 0.5) }
        // Then Ready again, with the note counted as waiting. (Before, Saved lasted two seconds and the 03 shot, taken
        // 1.5 seconds after it showed, caught this screen: 03 and 04 were the same PNG.)
        if expect(record, "Record again", in: app, timeout: 30), expect(app.staticTexts["watch.unsent"], "the unsent count", in: app, timeout: 15) {
            shoot(app, "04-unsent")
        }
    }
}
