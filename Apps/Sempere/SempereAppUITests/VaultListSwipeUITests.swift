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
    /// Each window must see sync runs finish (`DebugSyncRuns`), or the test skips: a window with no runs proves nothing.
    @MainActor
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
        reveal(Self.vaultName, in: app)
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

    /// Cancel keeps the vault (owner, build 112: the row vanished at the tap and Cancel left the list showing the wrong
    /// vaults, and a second swipe locked it): the row is still there after Cancel, a second swipe and Cancel keep it,
    /// and the vault still opens.
    @MainActor
    func testCancelKeepsTheRow() throws {
        let app = launch()
        defer { app.terminate() }
        closeVault(in: app)
        let content = app.descendants(matching: .any)["storeVault-\(Self.vaultName)"].firstMatch
        let row = app.cells.containing(.any, identifier: "storeVault-\(Self.vaultName)").firstMatch
        reveal(Self.vaultName, in: app)
        require(row, "the vault's row on the welcome list", in: app)
        for round in 1...2 {
            row.swipeLeft()
            let swipeDelete = app.collectionViews.buttons["Delete from This Device…"].firstMatch
            require(swipeDelete, "the swipe's Delete from This Device… (round \(round))", in: app, timeout: 10)
            swipeDelete.tap()
            let alert = app.alerts.firstMatch
            require(alert, "the Delete confirmation (round \(round))", in: app, timeout: 10)
            alert.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "the confirmation closed (round \(round))")
            // The row is there and shows this vault, at once and a moment later (a deferred removal or swap).
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(content.exists && row.exists, "the vault's row is still listed after Cancel (round \(round))")
        }
        content.tap()
        XCTAssertTrue(app.buttons["sidebar-more"].firstMatch.waitForExistence(timeout: 60)
                      || app.buttons["Show Sidebar"].firstMatch.exists, "the vault still opens after two Cancels")
    }

    // MARK: - Several vaults (owner, build 112: Cancel or Delete on the first row showed the wrong vaults, then locked
    // the list until a relaunch)

    /// Three vaults: Cancel on the first row, twice, then on the middle one. After each Cancel the three rows are there
    /// with their own names in order, and each still answers a swipe; then the first row still opens its own vault (its
    /// unlock sheet).
    @MainActor
    func testCancelWithThreeVaultsKeepsEveryRow() throws {
        let app = launch(extraVaults: 2)
        defer { app.terminate() }
        closeVault(in: app)
        let all = [Self.vaultName] + Self.extraNames
        expectRows(all, in: app, "at the start")
        for (round, name) in [Self.vaultName, Self.vaultName, Self.extraNames[0]].enumerated() {
            swipeDelete(name, in: app, answer: "Cancel", "Cancel round \(round + 1)")
            Thread.sleep(forTimeInterval: 2)   // a deferred removal or swap shows by now
            expectRows(all, in: app, "after Cancel round \(round + 1) on \(name)")
            for row in all { expectSwipeAnswers(row, in: app, "after Cancel round \(round + 1)") }
        }
        // This launch remembers no key of the demo's (it is unlocked once with its identity, and with no sync folder
        // nothing keeps that key once it is closed), so its own unlock sheet is what a tap on its row opens.
        expectOpens(Self.vaultName, in: app, orItsUnlockSheet: true)
    }

    /// Three vaults: delete the first. The other two stay with their own names, a swipe on the new first row shows
    /// its button and a Cancel keeps it; then delete the last one, and the remaining vault opens.
    @MainActor
    func testDeleteFirstOfThreeKeepsTheOthers() throws {
        let app = launch(extraVaults: 2)
        defer { app.terminate() }
        closeVault(in: app)
        expectRows([Self.vaultName] + Self.extraNames, in: app, "at the start")
        swipeDelete(Self.vaultName, in: app, answer: "Delete", "delete the first")
        XCTAssertTrue(storeRow(Self.vaultName, in: app).waitForNonExistence(timeout: 30), "the deleted vault left the list")
        Thread.sleep(forTimeInterval: 2)
        expectRows(Self.extraNames, in: app, "after deleting the first")
        swipeDelete(Self.extraNames[0], in: app, answer: "Cancel", "Cancel on the new first row")
        Thread.sleep(forTimeInterval: 2)
        expectRows(Self.extraNames, in: app, "after Cancel on the new first row")
        swipeDelete(Self.extraNames[1], in: app, answer: "Delete", "delete the last")
        XCTAssertTrue(storeRow(Self.extraNames[1], in: app).waitForNonExistence(timeout: 30), "the last vault left the list")
        Thread.sleep(forTimeInterval: 2)
        expectRows([Self.extraNames[0]], in: app, "after deleting the last")
        expectSwipeAnswers(Self.extraNames[0], in: app, "after deleting the last")
        expectOpens(Self.extraNames[0], in: app)
    }

    /// Two vaults: delete the first; the other stays, answers a swipe and opens.
    @MainActor
    func testDeleteFirstOfTwoKeepsTheOther() throws {
        let app = launch(extraVaults: 1)
        defer { app.terminate() }
        closeVault(in: app)
        let other = Self.extraNames[0]
        expectRows([Self.vaultName, other], in: app, "at the start")
        swipeDelete(Self.vaultName, in: app, answer: "Delete", "delete the first")
        XCTAssertTrue(storeRow(Self.vaultName, in: app).waitForNonExistence(timeout: 30), "the deleted vault left the list")
        Thread.sleep(forTimeInterval: 2)
        expectRows([other], in: app, "after deleting the first")
        expectSwipeAnswers(other, in: app, "after deleting the first")
        expectOpens(other, in: app)
    }

    /// One vault: delete it; its row leaves the list (other tests' vaults may stay) and New Vault… still opens its
    /// sheet.
    @MainActor
    func testDeleteTheOnlyVault() throws {
        let app = launch(extraVaults: 0)
        defer { app.terminate() }
        closeVault(in: app)
        expectRows([Self.vaultName], in: app, "at the start")
        swipeDelete(Self.vaultName, in: app, answer: "Delete", "delete the only vault")
        XCTAssertTrue(storeRow(Self.vaultName, in: app).waitForNonExistence(timeout: 30), "the vault left the list")
        Thread.sleep(forTimeInterval: 2)
        expectRows([], in: app, "after deleting the only vault")
        let newVault = app.buttons["New Vault…"].firstMatch
        if !newVault.waitForExistence(timeout: 5) { scrollList(in: app, up: false) }
        require(newVault, "New Vault…", in: app, timeout: 10)
        newVault.tap()
        XCTAssertTrue(app.textFields["newVault.name"].firstMatch.waitForExistence(timeout: 15), "New Vault… opens its sheet")
    }

    // MARK: - Helpers

    /// `DemoLaunch.extraStoreNames`. Other UI tests may leave vaults in the simulator's store (the App Group container,
    /// which `SEMPERE_DEBUG_FRESH` keeps): the checks look only at the vaults these tests own.
    private static let extraNames = ["Sempere Demo B", "Sempere Demo C"]

    /// A store vault's row content (`storeVault-<name>`).
    @MainActor
    private func storeRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["storeVault-\(name)"].firstMatch
    }

    /// Of the vaults these tests own (the demo's and `extraNames`), exactly `names` are listed, top to bottom; other
    /// tests' leftover vaults are ignored. Each of `names` is scrolled into view first.
    @MainActor
    private func expectRows(_ names: [String], in app: XCUIApplication, _ when: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        for name in names { reveal(name, in: app) }
        let owned = Set([Self.vaultName] + Self.extraNames)
        let ids = owned.map { "storeVault-\($0)" }
        let listed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ids))
        if !names.isEmpty { _ = listed.firstMatch.waitForExistence(timeout: 10) }
        let rows = listed.allElementsBoundByIndex.filter(\.exists)
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("storeVault-".count)) }
        let everyRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'storeVault-'"))
            .allElementsBoundByIndex.map { String($0.identifier.dropFirst("storeVault-".count)) }
        print("SWIPE store rows \(when): \(everyRow)")
        XCTAssertEqual(rows, names, "the welcome list's own vaults \(when)", file: file, line: line)
        for name in names {
            XCTAssertTrue(storeRow(name, in: app).label.hasPrefix(name), "the row of \(name) shows its name \(when): "
                          + storeRow(name, in: app).label, file: file, line: line)
        }
    }

    /// Swipes `name`'s row, taps Delete from This Device… and answers the confirmation with `answer`.
    @MainActor
    private func swipeDelete(_ name: String, in app: XCUIApplication, answer: String, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let row = storeRow(name, in: app)
        reveal(name, in: app)
        require(row, "the row of \(name) (\(what))", in: app, timeout: 10, file: file, line: line)
        row.swipeLeft()
        let button = app.collectionViews.buttons["Delete from This Device…"].firstMatch
        require(button, "the swipe's Delete from This Device… on \(name) (\(what))", in: app, timeout: 10, file: file, line: line)
        button.tap()
        let alert = app.alerts.firstMatch
        require(alert, "the Delete confirmation for \(name) (\(what))", in: app, timeout: 10, file: file, line: line)
        XCTAssertTrue(alert.label.contains("“\(name)”"), "the confirmation names \(name) (\(what)): \(alert.label)",
                      file: file, line: line)
        alert.buttons[answer].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "the confirmation closed (\(what))", file: file, line: line)
    }

    /// The row of `name` answers a swipe (its button shows) and a swipe back (the button goes, the row stays).
    @MainActor
    private func expectSwipeAnswers(_ name: String, in app: XCUIApplication, _ when: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let row = storeRow(name, in: app)
        reveal(name, in: app)
        row.swipeLeft()
        let button = app.collectionViews.buttons["Delete from This Device…"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "a swipe on \(name) shows its button \(when)",
                      file: file, line: line)
        row.swipeRight()
        XCTAssertTrue(button.waitForNonExistence(timeout: 10), "a swipe back on \(name) hides its button \(when)",
                      file: file, line: line)
        XCTAssertTrue(row.exists, "the row of \(name) stays after a swipe back \(when)", file: file, line: line)
    }

    /// Scrolls the welcome list until `name`'s row can be touched: down the list first, then back up (other tests'
    /// leftover vaults may come before it, or push it below the screen).
    @MainActor
    private func reveal(_ name: String, in app: XCUIApplication) {
        let row = storeRow(name, in: app)
        if row.waitForExistence(timeout: 5) && row.isHittable { return }
        for up in [true, false] {
            for _ in 0..<6 {
                if row.exists && row.isHittable { return }
                scrollList(in: app, up: up)
            }
        }
    }

    /// One slow swipe on the welcome list: `up` moves the content up (shows rows further down).
    @MainActor
    private func scrollList(in app: XCUIApplication, up: Bool) {
        let list = app.collectionViews.containing(NSPredicate(format: "identifier BEGINSWITH 'storeVault-'")).firstMatch
        let target = list.exists ? list : app.collectionViews.firstMatch
        if up { target.swipeUp(velocity: .slow) } else { target.swipeDown(velocity: .slow) }
    }

    /// A tap on `name`'s row opens that vault (the sidebar's title is its name); with `orItsUnlockSheet`, its unlock
    /// sheet ("Unlock <name>") is enough, for a vault whose key this launch does not remember.
    @MainActor
    private func expectOpens(_ name: String, in app: XCUIApplication, orItsUnlockSheet: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) {
        reveal(name, in: app)
        storeRow(name, in: app).tap()
        if orItsUnlockSheet, app.navigationBars["Unlock \(name)"].firstMatch.waitForExistence(timeout: 30) { return }
        let more = app.buttons["sidebar-more"].firstMatch
        if !more.waitForExistence(timeout: 60) {
            let show = app.buttons["Show Sidebar"].firstMatch
            if show.exists { show.tap() }
        }
        XCTAssertTrue(more.waitForExistence(timeout: 10), "a tap on \(name) opens a vault", file: file, line: line)
        XCTAssertTrue(app.navigationBars[name].firstMatch.waitForExistence(timeout: 10), "the vault opened is \(name)",
                      file: file, line: line)
    }

    @MainActor
    private func closeVault(in app: XCUIApplication) {
        let more = app.buttons["sidebar-more"].firstMatch
        if !more.waitForExistence(timeout: 60) {
            let show = app.buttons["Show Sidebar"].firstMatch
            if show.exists { show.tap() }
        }
        require(more, "the sidebar's More menu", in: app)
        more.tap()
        let close = app.buttons["Close Vault"].firstMatch
        require(close, "Close Vault", in: app)
        close.tap()
    }

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

    /// The demo's store copy; with `extraVaults` (0, 1 or 2) also "Sempere Demo B" and "Sempere Demo C"
    /// (`SEMPERE_DEMO_STORE_EXTRA`) and no sync folder, else the demo syncing with a folder every two seconds.
    @MainActor
    private func launch(extraVaults: Int? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO": "1", "SEMPERE_DEMO_STORE": "1",
                                 "SEMPERE_DEMO_SYNC_FOLDER": "2", "SEMPERE_DEBUG_COLUMNS": "all",
                                 "SEMPERE_DEBUG_MEMORY_KEYS": "1", "SEMPERE_DEBUG_SYNC_RUNS": "1", "TZ": "UTC"]
        if let extraVaults {
            app.launchEnvironment["SEMPERE_DEMO_SYNC_FOLDER"] = nil
            app.launchEnvironment["SEMPERE_DEMO_STORE_EXTRA"] = String(extraVaults)
        }
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
