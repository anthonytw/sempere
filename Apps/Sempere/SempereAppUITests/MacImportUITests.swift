import XCTest

/// Device check c23, the part only the running app shows: during a long import from another app the window shows
/// a progress bar, the note count and Cancel; the result's report can be saved as a text file (Save… in the report
/// sheet, AppKit's save panel in another process) and is shown again from File ▸ Last Import Report…. The backup
/// is thousands of copies of the importer tests' synthetic note (no personal data), in a temporary folder.
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

    private var panelService: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService") }

    /// A folder of `count` copies of the synthetic note in nested folders: every copy is read before anything
    /// is written, so the reading phase is long enough to watch and to cancel.
    private func backup(count: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sempere-ui-import-\(UUID().uuidString)")
        let data = try Data(contentsOf: Self.fixture)
        for i in 0..<count {
            let dir = root.appendingPathComponent("Notability/Folder \(i % 20)/Sub \(i % 7)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("Copy \(i).note"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": "respiration",
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "TZ": "UTC"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        return app
    }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("MACUIDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(6000))")
        }
    }

    private func panel(_ app: XCUIApplication) -> XCUIElement? {
        for candidate in [panelService.windows.firstMatch, app.sheets.firstMatch, app.dialogs.firstMatch]
            where candidate.waitForExistence(timeout: 5) {
            return candidate
        }
        return nil
    }

    /// Goes to `dir` in an open or save panel (⇧⌘G) and confirms with Return.
    private func choose(_ dir: URL, in app: XCUIApplication) {
        guard let window = panel(app) else { dump(app, "no-panel"); XCTFail("no file panel"); return }
        window.typeKey("g", modifierFlags: [.command, .shift])
        window.typeText(dir.path + "\r")
        sleep(1)
        window.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let replace = panelService.buttons["Replace"].firstMatch
        if replace.waitForExistence(timeout: 2) { replace.click() }
    }

    /// File ▸ Import from Notability…, the backup folder, then Import in the options sheet.
    @MainActor
    private func startImport(_ app: XCUIApplication, folder: URL) {
        app.menuBarItems["File"].click()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Import from")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File ▸ Import from …")
        item.click()
        choose(folder, in: app)
        let options = app.descendants(matching: .any)["importOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 20), "the import options sheet")
        app.buttons["Import"].firstMatch.click()
    }

    @MainActor
    func testALongImportShowsProgressAndCanBeCanceled() throws {
        let folder = try backup(count: 4_000)
        let app = launch()
        defer { app.terminate() }
        startImport(app, folder: folder)
        let overlay = app.descendants(matching: .any)["importProgress"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 20), "the progress overlay")
        let count = app.staticTexts["importProgressCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 30), "a count of notes appears")
        let first = count.label
        sleep(1)
        XCTAssertNotEqual(count.exists ? count.label : "done", first, "the count moves")
        app.buttons["importCancel"].click()
        let alert = app.staticTexts["Import Canceled"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the result says it was canceled")
        if !alert.exists { dump(app, "after-cancel") }
    }

    @MainActor
    func testTheReportCanBeSavedAndShownAgain() throws {
        let folder = try backup(count: 30)
        let app = launch()
        defer { app.terminate() }
        startImport(app, folder: folder)
        let show = app.buttons["Show Report"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 60), "the result alert offers the report")
        show.click()
        XCTAssertTrue(app.descendants(matching: .any)["importReport"].waitForExistence(timeout: 10))
        let save = app.buttons["Save…"].firstMatch
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
        app.buttons["Done"].firstMatch.click()

        // Shown again from the File menu.
        app.menuBarItems["File"].click()
        app.menuItems["Last Import Report…"].click()
        XCTAssertTrue(app.descendants(matching: .any)["importReport"].waitForExistence(timeout: 10))
    }
}
