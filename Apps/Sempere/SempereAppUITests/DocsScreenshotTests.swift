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
/// Run through `scripts/screenshots.sh docs-ipad|docs-iphone`, which passes `TEST_RUNNER_SEMPERE_SHOTS_DIR`.
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

    // MARK: - Helpers

    private func demo(_ extra: [String: String]) -> [String: String] {
        var env = ["SEMPERE_DEMO": "1"]
        for (k, v) in extra { env[k] = v }
        return env
    }

    @MainActor
    private func launch(_ env: [String: String], portrait: Bool) -> XCUIApplication {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeLeft
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        // UTC: the note list shows dates, and the demo dates are fractions of a day before noon UTC.
        app.launchEnvironment = env.merging(["TZ": "UTC"]) { mine, _ in mine }
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
