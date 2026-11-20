import XCTest

/// The welcome list's "On This Device" rows keep their swipe action and their Delete confirmation open while the
/// vault's sync target runs (owner, TestFlight 1.3.0 build 111, iPad and iPhone: "delete still does the annoying
/// thing where it closes the delete dialog often, you have to swipe or click the button multiple times and be quick
/// about clicking the button before it disappears").
///
/// The demo's store copy syncs with a folder every two seconds (`SEMPERE_DEMO_SYNC_FOLDER`, `DemoLaunch`), and keeps
/// syncing (upload-only) once it is closed. Run by `scripts/app.sh test-phone-ui
/// -only-testing:SempereAppUITests/VaultListSwipeUITests` (iPhone) and `scripts/app.sh test-ui
/// -only-testing:SempereAppUITests/VaultListSwipeUITests` (iPad).
final class VaultListSwipeUITests: XCTestCase {
    private static let vaultName = "Sempere Demo"

    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone and iPad: the Mac's list has no swipe actions")
        #else
        continueAfterFailure = false
        #endif
    }

    /// Swipe the vault's row and let several runs go by with Delete from This Device… showing; tap it and let several
    /// more go by with the confirmation up; then delete: the row leaves the list.
    @MainActor
    /// Each window must see sync runs finish (`DebugSyncRuns`), or the test skips: a window with no runs proves nothing.
    func testSwipeAndConfirmationStayOpenWhileSyncRuns() throws {
        let app = launch()
        defer { app.terminate() }
        let more = app.buttons["sidebar-more"].firstMatch
        if !more.waitForExistence(timeout: 60) {
            // iPad: the columns may open on the list with the sidebar hidden.
            let show = app.buttons["Show Sidebar"].firstMatch
            if show.exists { show.tap() }
        }
        require(more, "the sidebar's More menu", in: app)
        more.tap()
        let close = app.buttons["Close Vault"].firstMatch
        require(close, "Close Vault", in: app)
        close.tap()

        let content = app.descendants(matching: .any)["storeVault-\(Self.vaultName)"].firstMatch
        let row = app.cells.containing(.any, identifier: "storeVault-\(Self.vaultName)").firstMatch
        require(row, "the vault's row on the welcome list", in: app)
        // A finished run of the closed vault first, so the runs that follow are the idle ones the owner met.
        XCTAssertTrue(UIWait.until(60, { content.label.contains("Synced with") }), "the closed vault syncs: \(content.label)")
        let runs = app.descendants(matching: .any)["debugSyncRuns"].firstMatch
        require(runs, "the debug sync-run probe", in: app, timeout: 10)

        row.swipeLeft()
        let swipeDelete = app.collectionViews.buttons["Delete from This Device…"].firstMatch
        require(swipeDelete, "the swipe's Delete from This Device…", in: app, timeout: 10)
        // Runs go every two seconds: about five of them, each watched (a closed button is noticed at once).
        let swipe = watch(10, runs: runs) { !swipeDelete.exists }
        XCTAssertNil(swipe.closedAfter, "the swipe stayed open while sync ran (closed after \(swipe.closedAfter ?? 0) s)")
        if swipe.runs == 0 { throw XCTSkip("no sync runs during the window (the swipe's): nothing was proved") }
        swipeDelete.tap()

        let alert = app.alerts.firstMatch
        require(alert, "the Delete confirmation", in: app, timeout: 10)
        let confirmation = watch(10, runs: runs) { !alert.exists }
        XCTAssertNil(confirmation.closedAfter,
                     "the confirmation stayed up while sync ran (closed after \(confirmation.closedAfter ?? 0) s)")
        if confirmation.runs == 0 { throw XCTSkip("no sync runs during the window (the confirmation's): nothing was proved") }
        print("SWIPE runs seen: \(swipe.runs) with the swipe open, \(confirmation.runs) with the confirmation up")
        alert.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "the vault left the list")
    }

    // MARK: - Helpers

    /// Watches for `seconds` (every 0.2 s or so) whether `closed` became true, and how many sync runs finished meanwhile:
    /// the times `runs` (`DebugSyncRuns`, the last success) changed its label. A window with no run proves nothing.
    @MainActor
    private func watch(_ seconds: TimeInterval, runs: XCUIElement, closed: () -> Bool) -> (closedAfter: TimeInterval?, runs: Int) {
        let start = Date()
        var last = runs.label, changes = 0
        while Date().timeIntervalSince(start) < seconds {
            if closed() { return (Date().timeIntervalSince(start), changes) }
            let now = runs.label
            if now != last { changes += 1; last = now }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (nil, changes)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO": "1", "SEMPERE_DEMO_STORE": "1",
                                 "SEMPERE_DEMO_SYNC_FOLDER": "2", "SEMPERE_DEBUG_COLUMNS": "all",
                                 "SEMPERE_DEBUG_MEMORY_KEYS": "1", "SEMPERE_DEBUG_SYNC_RUNS": "1", "TZ": "UTC"]
        app.launch()
        return app
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }
}
