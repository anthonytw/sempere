#if canImport(UIKit)
import UIKit
#endif
import XCTest

/// Screenshots for the user guide on the project website (the site's /docs pages), from the same
/// synthetic demo vault as the App Store shots (`ScreenshotTests`, docs/appstore/screenshots.md).
/// Unlike those, some of these shots tap their way to a screen (the New Vault sheet, the palette's
/// choices, a Settings page, a search), so a shot can fail when the UI moves: the test keeps going and
/// still writes what was on screen, and the log says which shot never reached its screen.
///
/// Run through `scripts/screenshots.sh docs-ipad|docs-iphone`, which passes `TEST_RUNNER_SEMPERE_SHOTS_DIR` and, for
/// the dark twins (`SEMPERE_SHOTS_APPEARANCE=dark`, docs/design/1.2-screenshots.md §3.3), the appearance.
/// Nothing here comes from real notes.
final class DocsScreenshotTests: XCTestCase {
    #if targetEnvironment(macCatalyst)
    private static let isMac = true
    #else
    private static let isMac = false
    #endif

    private var isPhone: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    private var directory: URL? {
        ProcessInfo.processInfo.environment["SEMPERE_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPad and iPhone simulators")
        #else
        continueAfterFailure = true
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        #endif
    }

    // MARK: - Shots

    /// The first launch: the welcome screen, then the New Vault sheet.
    @MainActor
    func testWelcomeAndNewVault() {
        let app = launch(["SEMPERE_DEBUG_FRESH": "1"], portrait: true)
        defer { app.terminate() }
        let newVault = app.buttons["New Vault…"].firstMatch
        wait(newVault, "the welcome screen's New Vault…", in: app, timeout: 90)
        settle()
        shoot(app, "docs-welcome")
        guard newVault.exists else { return }
        newVault.tap()
        wait(app.textFields["newVault.name"].firstMatch, "the New Vault sheet", in: app)
        settle()
        shoot(app, "docs-new-vault")
    }

    /// A note open for annotating, with the palette's choices (colors, widths) for the selected tool.
    @MainActor
    func testPaletteChoices() {
        var env = demo(["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEBUG_NOTE_MODE": "annotate"])
        if !isPhone { env["SEMPERE_DEBUG_COLUMNS"] = "detailOnly" }
        let app = launch(env, portrait: true)
        defer { app.terminate() }
        let palette = element(app, "Drawing-Palette")
        wait(palette, "the drawing palette", in: app, timeout: 90)
        settle()
        shoot(app, "docs-palette")
        let choices = element(app, "palette.choices")
        if choices.exists, choices.isHittable {
            choices.tap()
        } else {
            // A full palette: a tap on the selected tool shows its choices.
            palette.buttons.matching(NSPredicate(format: "selected == true")).firstMatch.tap()
        }
        wait(element(app, "palette.choicesPanel"), "the palette's choices", in: app, timeout: 10)
        settle(2)
        shoot(app, "docs-palette-choices")
    }

    /// Settings: the list of groups, then the Sync and Backups pages.
    @MainActor
    func testSettings() {
        var env = demo(["SEMPERE_DEMO_SETTINGS": "1"])
        if !isPhone { env["SEMPERE_DEBUG_COLUMNS"] = "all" }
        let app = launch(env, portrait: true)
        defer { app.terminate() }
        wait(element(app, "settingsForm"), "Settings", in: app, timeout: 90)
        settle(2)
        shoot(app, "docs-settings")
        for group in ["general", "sync", "backups"] {
            let row = element(app, "settingsGroup.\(group)")
            wait(row, "the \(group) group", in: app)
            guard row.exists else { continue }
            row.tap()
            wait(element(app, "settingsPage.\(group)"), "the \(group) page", in: app)
            settle(2)
            shoot(app, "docs-settings-\(group)")
            let back = app.navigationBars.buttons["Settings"].firstMatch
            if back.waitForExistence(timeout: 5) { back.tap() }
            settle(1)
        }
    }

    /// A search: the results for a handwritten word, then a hit open with its words highlighted.
    /// The demo's search notes carry stored recognition (`SEMPERE_DEMO_SEARCH`), so no recognizer runs.
    /// Portrait: `XCUIScreen` stores a landscape iPad screenshot rotated.
    @MainActor
    func testSearch() {
        var env = demo(["SEMPERE_DEMO_SEARCH": "1"])
        if !isPhone {
            env["SEMPERE_DEBUG_COLUMNS"] = "all"
            env["SEMPERE_DEMO_SIDEBAR"] = "notebook:Search"
        }
        let app = launch(env, portrait: true)
        defer { app.terminate() }
        let field = app.searchFields.firstMatch
        if isPhone, !field.waitForExistence(timeout: 60) {
            let notebook = element(app, "sidebar-notebook-Search")
            if notebook.waitForExistence(timeout: 10) { notebook.tap() }
        }
        wait(field, "the search field", in: app, timeout: 60)
        guard field.exists else { return }
        field.tap()
        field.typeText("wombat\n")   // Return: the keyboard goes away
        let hit = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Wombat field notes")).firstMatch
        wait(hit, "the search hit", in: app)
        settle(2)
        shoot(app, "docs-search")
        guard hit.exists else { return }
        hit.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        wait(element(app, "noteEditor"), "the note", in: app)
        settle()
        shoot(app, "docs-search-highlight")
    }

    /// Add Device on home with one request that came nearby (`SEMPERE_DEMO_NEARBY_JOIN`: a synthetic "Demo iPhone"):
    /// its six words, Nearby, They Match and Decline. Through Settings ▸ Sync & Devices ▸ Devices ▸ Add Device.
    @MainActor
    func testNearbyJoinRequest() {
        var env = demo(["SEMPERE_DEMO_SETTINGS": "1", "SEMPERE_DEMO_NEARBY_JOIN": "1"])
        if !isPhone { env["SEMPERE_DEBUG_COLUMNS"] = "all" }
        let app = launch(env, portrait: true)
        defer { app.terminate() }
        wait(element(app, "settingsForm"), "Settings", in: app, timeout: 90)
        let sync = element(app, "settingsGroup.sync")
        wait(sync, "the sync group", in: app)
        guard sync.exists else { return }
        sync.tap()
        let devices = element(app, "settings.devices")
        for _ in 0..<4 where !(devices.exists && devices.isHittable) { app.swipeUp() }
        wait(devices, "the Devices link", in: app)
        guard devices.exists else { return }
        devices.tap()
        wait(element(app, "devicesView"), "Devices", in: app)
        let add = app.buttons["Add Device…"].firstMatch
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp() }
        wait(add, "Add Device…", in: app)
        guard add.exists else { return }
        add.tap()
        wait(element(app, "addDevice.nearbyRequest"), "the nearby request row", in: app, timeout: 60)
        // They Match waits 1.5 s before it enables; the rows settle.
        settle(5)
        shoot(app, "docs-nearby-join")
    }

    /// The new device's join screen waiting for its approval: its six words and QR code, the delivery line and the
    /// line that says a device nearby has the request (`SEMPERE_DEMO_NEARBY_JOIN` on the locked demo; the in-memory
    /// keys of `SEMPERE_DEBUG_MEMORY_KEYS` stand in for the Keychain, which an unsigned build cannot use).
    @MainActor
    func testJoinWaiting() {
        let app = launch(demo(["SEMPERE_DEMO_LOCKED": "1", "SEMPERE_DEMO_NEARBY_JOIN": "1", "SEMPERE_DEBUG_MEMORY_KEYS": "1",
                               "SEMPERE_DEBUG_COLUMNS": "all"]), portrait: true)
        defer { app.terminate() }
        let join = element(app, "unlock.join")
        wait(join, "Join This Device…", in: app, timeout: 90)
        guard join.exists else { return }
        join.tap()
        let ask = element(app, "join.start")
        wait(ask, "Ask to Join", in: app)
        guard ask.exists else { return }
        ask.tap()
        wait(element(app, "join.nearby"), "the nearby line", in: app, timeout: 60)
        settle(4)
        shoot(app, "docs-join-waiting")
        // The iPad's form sheet is short: scroll it so the delivery and nearby lines show too (the phone's shows them above).
        guard !isPhone else { return }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        settle(3)
        shoot(app, "docs-join-waiting-nearby")
    }

    /// iCloud (CloudKit), 1.4: Sync Targets with the iCloud target Synced (the demo's store vault, an in-memory database:
    /// `SEMPERE_DEMO_CLOUDKIT=targets`, which opens the sheet once the target has run).
    @MainActor
    func testICloudTargets() {
        var env = demo(["SEMPERE_DEMO_STORE": "1", "SEMPERE_DEMO_CLOUDKIT": "targets", "SEMPERE_DEMO_NOTE": "respiration"])
        if !isPhone { env["SEMPERE_DEBUG_COLUMNS"] = "doubleColumn" }
        let app = launch(env, portrait: true)
        defer { app.terminate() }
        wait(element(app, "syncTargetsSheet"), "Sync Targets", in: app, timeout: 150)
        wait(element(app, "syncTargetRemove"), "the iCloud target's row", in: app, timeout: 30)
        settle(6)
        shoot(app, "docs-icloud-targets")
    }

    /// The New Vault sheet with Sync with iCloud on, scrolled so the toggle shows (`SEMPERE_DEMO_CLOUDKIT`: the toggle
    /// shows when the build has CloudKit services).
    @MainActor
    func testICloudNewVault() {
        let app = launch(["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO_CLOUDKIT": "1"], portrait: true)
        defer { app.terminate() }
        let newVault = app.buttons["New Vault…"].firstMatch
        wait(newVault, "the welcome screen's New Vault…", in: app, timeout: 90)
        guard newVault.exists else { return }
        newVault.tap()
        wait(app.textFields["newVault.name"].firstMatch, "the New Vault sheet", in: app)
        let toggle = element(app, "newVault.iCloud")
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        wait(toggle, "the Sync with iCloud toggle", in: app)
        guard toggle.exists else { return }
        // A switch: its right end is the control (the row's middle is its label).
        if (toggle.value as? String) != "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        settle(3)
        // Room for the toggle's footer below it.
        app.swipeUp()
        settle(2)
        shoot(app, "docs-icloud-new-vault")
    }

    /// Open from iCloud… on the welcome screen: the account's vaults (`SEMPERE_DEMO_CLOUDKIT`, three made-up ones).
    @MainActor
    func testOpenFromICloud() {
        let app = launch(["SEMPERE_DEBUG_FRESH": "1", "SEMPERE_DEMO_CLOUDKIT": "1"], portrait: true)
        defer { app.terminate() }
        let open = element(app, "openICloud")
        wait(open, "Open from iCloud…", in: app, timeout: 90)
        guard open.exists else { return }
        open.tap()
        wait(element(app, "openFromICloudSheet"), "the Open from iCloud sheet", in: app)
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Field Journal")).firstMatch, "the account's vaults", in: app)
        settle(3)
        shoot(app, "docs-open-from-icloud")
    }

    /// Settings ▸ General ▸ Appearance ▸ Note Pages ▸ Dark (`-Sempere.notePages dark`): a note with dark paper and the
    /// ink's lightness inverted, for the page that explains the setting (docs/design/1.2-screenshots.md, question 1).
    @MainActor
    func testDarkNotePages() {
        var env = demo(["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEBUG_NOTE_MODE": "annotate"])
        if !isPhone { env["SEMPERE_DEBUG_COLUMNS"] = "detailOnly" }
        let app = launch(env, portrait: true, arguments: ["-Sempere.notePages", "dark"])
        defer { app.terminate() }
        wait(element(app, "Drawing-Palette"), "the drawing palette", in: app, timeout: 90)
        settle(6)
        shoot(app, "docs-pages-dark")
    }

    // MARK: - Helpers

    private func demo(_ extra: [String: String]) -> [String: String] {
        var env = ["SEMPERE_DEMO": "1"]
        for (k, v) in extra { env[k] = v }
        return env
    }

    @MainActor
    private func launch(_ env: [String: String], portrait: Bool, arguments: [String] = []) -> XCUIApplication {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeLeft
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"] + arguments
        // UTC: the note list shows dates, and the demo dates are fractions of a day before noon UTC.
        app.launchEnvironment = env.merging(["TZ": "UTC"]) { mine, _ in mine }
        // The dark twins (`scripts/screenshots.sh` with SEMPERE_SHOTS_APPEARANCE=dark): the demo's windows follow it.
        let appearance = ProcessInfo.processInfo.environment["SEMPERE_SHOTS_APPEARANCE"] == "dark" ? "dark" : "light"
        app.launchEnvironment["SEMPERE_DEMO_APPEARANCE"] = appearance
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func wait(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30) {
        if element.waitForExistence(timeout: timeout) { return }
        let labels = app.descendants(matching: .any).allElementsBoundByIndex.prefix(80).map(\.label).filter { !$0.isEmpty }
        print("SHOTDEBUG \(what): \(labels)")
        XCTFail("never showed \(what)")
    }

    /// PencilKit draws its tiles asynchronously; sheets and popovers animate in.
    private func settle(_ seconds: TimeInterval = 5) { Thread.sleep(forTimeInterval: seconds) }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory else { return }
        do {
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("\(name): could not write the PNG: \(error)")
        }
    }
}
