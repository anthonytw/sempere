import XCTest

/// Device check c23, the part only the running app shows: during a long import from another app the window shows
/// a progress bar, the note count and Cancel; the result's report can be saved as a text file (Save… in the report
/// sheet, AppKit's save panel in another process) and is shown again from File ▸ Last Import Report…. The backup
/// is thousands of copies of the importer tests' synthetic note (no personal data), which the app writes into its
/// own temporary folder and takes as the picked folder (`SEMPERE_DEBUG_IMPORT_PICK`): the open panel cannot choose
/// a folder in the test runner's container (macOS keeps Open disabled there, measured 2026-10-14), and the app
/// cannot read that container either. `testImportFromOpensTheOpenPanel` checks the panel itself.
/// Run by `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/MacImportUITests`.
@MainActor
final class MacImportUITests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/SempereTests/Fixtures/notability/synthetic.note")

    // AppKit's open and save panels run in `com.apple.appkit.xpc.openAndSavePanelService`, but that service is no
    // app XCTest can attach to (`XCUIApplication(bundleIdentifier:)` throws "could not be found"); the panel is
    // shown in the app's accessibility tree, as a sheet on its window, and is driven from there.

    @MainActor
    /// `copies` > 0: File ▸ Import from … takes that many copies of the synthetic note instead of the open panel.
    private func launch(copies: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": "respiration",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "TZ": "UTC"]
        if copies > 0 { app.launchEnvironment["SEMPERE_DEBUG_IMPORT_PICK"] = "\(copies):\(Self.fixture.path)" }
        app.launch()
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        return app
    }

    /// A button in the app's windows: the Touch Bar repeats some (Show Report, Import), and its copies cannot be clicked.
    private func button(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.windows.descendants(matching: .button).matching(identifier: name).firstMatch
    }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("MACUIDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(6000))")
        }
    }

    private func panel(_ app: XCUIApplication) -> XCUIElement? {
        for candidate in [app.sheets.firstMatch, app.dialogs.firstMatch]
            where candidate.waitForExistence(timeout: 5) {
            return candidate
        }
        return nil
    }

    /// Goes to `dir` in a save panel (⇧⌘G) and confirms with Return.
    private func choose(_ dir: URL, in app: XCUIApplication) {
        guard let window = panel(app) else { dump(app, "no-panel"); XCTFail("no file panel"); return }
        window.typeKey("g", modifierFlags: [.command, .shift])
        window.typeText(dir.path + "\r")
        sleep(1)
        // Return presses Save, which the panel enables once it has checked the folder.
        let saveButton = window.buttons["Save"].firstMatch
        if saveButton.waitForExistence(timeout: 5) {
            XCTAssertTrue(PanelSession.waitUntilEnabled(saveButton), "the save panel's Save is enabled" + PanelSession.note)
        }
        window.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let replace = app.windows.descendants(matching: .button).matching(identifier: "Replace").firstMatch
        if replace.waitForExistence(timeout: 2) { replace.click() }
    }

    /// File ▸ Import from Notability….
    @MainActor
    private func importFromMenu(_ app: XCUIApplication) {
        app.menuBarItems["File"].click()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Import from")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File ▸ Import from …")
        item.click()
    }

    /// File ▸ Import from Notability… (the launch's copies, `launch(copies:)`), then Import in the options sheet.
    @MainActor
    private func startImport(_ app: XCUIApplication) {
        importFromMenu(app)
        let options = app.descendants(matching: .any)["importOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 20), "the import options sheet")
        button(app, "Import").click()
    }

    /// Without the launch's copies the menu opens AppKit's open panel (in the app's tree as a sheet); Escape closes it.
    @MainActor
    func testImportFromOpensTheOpenPanel() throws {
        let app = launch()
        defer { app.terminate() }
        importFromMenu(app)
        guard let window = panel(app) else { dump(app, "no-panel"); return XCTFail("the open panel") }
        window.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "Escape closed the panel")
        XCTAssertFalse(app.descendants(matching: .any)["importOptions"].exists, "nothing to import")
    }

    @MainActor
    func testALongImportShowsProgressAndCanBeCanceled() throws {
        let app = launch(copies: 12_000)
        defer { app.terminate() }
        startImport(app)
        let overlay = app.descendants(matching: .any)["importProgress"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 20), "the progress overlay")
        let count = app.descendants(matching: .any)["importProgressCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 30), "a count of notes appears")
        let first = count.label
        sleep(1)
        XCTAssertNotEqual(count.exists ? count.label : "done", first, "the count moves")
        button(app, "importCancel").click()
        let alert = app.staticTexts["Import Canceled"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the result says it was canceled")
        if !alert.exists { dump(app, "after-cancel") }
    }

    @MainActor
    func testTheReportCanBeSavedAndShownAgain() throws {
        let app = launch(copies: 30)
        defer { app.terminate() }
        startImport(app)
        let show = button(app, "Show Report")
        XCTAssertTrue(show.waitForExistence(timeout: 60), "the result alert offers the report")
        show.click()
        XCTAssertTrue(app.descendants(matching: .any)["importReport"].waitForExistence(timeout: 10))
        let save = button(app, "Save…")
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save… in the report")
        save.click()
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sempere-ui-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        choose(out, in: app)
        var saved: [String] = []
        for _ in 0..<40 where saved.isEmpty {
            saved = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.filter { $0.hasSuffix(".txt") } ?? []
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(saved.count, 1, "the report was saved")
        if let name = saved.first {
            let text = try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("Copy 0.note"), "every file is in the report")
        }
        button(app, "Done").click()

        // Shown again from the File menu.
        app.menuBarItems["File"].click()
        app.menuItems["Last Import Report…"].click()
        XCTAssertTrue(app.descendants(matching: .any)["importReport"].waitForExistence(timeout: 10))
    }
}
