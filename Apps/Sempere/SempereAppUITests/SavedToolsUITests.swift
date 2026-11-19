import XCTest

/// Saved tools in the palette (docs/design/1.3-custom-tools.md §3.5, issue #11): save a preset from the palette's +, see
/// its button, pick another tool, then pick the preset and see it lit (it is lit exactly when the palette's tool is that ink
/// with that color, width and opacity). The demo vault has no sync, so the tools are this device's own list. Run by
/// `scripts/app.sh test-ui -only-testing:SempereAppUITests/SavedToolsUITests`.
final class SavedToolsUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .phone { throw XCTSkip("the iPhone's compact palette: PhoneParityUITests") }
        #endif
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testSaveAPresetFromThePaletteAndPickIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_NOTE": "thoughts",
                                 "SEMPERE_DEBUG_PENCIL_ONLY": "1", "TZ": "UTC"]
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(element(app, "pageCanvas").waitForExistence(timeout: 30))
        let annotate = element(app, "annotateButton")
        XCTAssertTrue(annotate.waitForExistence(timeout: 10), "the Annotate button")
        annotate.tap()
        XCTAssertTrue(element(app, "Drawing-Palette").waitForExistence(timeout: 10), "the palette")

        // The full bar has the + of the Saved group; a narrow window's compact bar has the list button instead.
        let add = element(app, "palette.savedTool.add")
        if !add.waitForExistence(timeout: 5) {
            let list = element(app, "palette.savedToolsButton")
            XCTAssertTrue(list.waitForExistence(timeout: 5), "the saved tools' button")
            list.tap()
            let listAdd = element(app, "savedTools.add")
            XCTAssertTrue(listAdd.waitForExistence(timeout: 5))
            listAdd.tap()
        } else {
            add.tap()
        }

        // The editor: a name (Save is off without one) and the red swatch.
        let editor = element(app, "savedTool.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor sheet")
        let save = element(app, "savedTool.save")
        XCTAssertFalse(save.isEnabled, "no name yet")
        let field = element(app, "savedTool.name")
        field.tap()
        field.typeText("Fine red pen")
        element(app, "savedTool.swatch.3").tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), "the editor closed")

        // Its button is in the palette (the full bar's Saved group; on the compact bar, in the list).
        let preset = element(app, "palette.savedTool.0")
        if !preset.waitForExistence(timeout: 5) {
            element(app, "palette.savedToolsButton").tap()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fine red pen'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved tool's row")
            row.tap()   // picks it and closes the list
            return
        }
        XCTAssertTrue(preset.label.contains("Fine red pen"), "its accessibility label names it: \(preset.label)")
        XCTAssertFalse(preset.isSelected, "the palette's pen is still black: the preset is not the current tool")
        preset.tap()
        let lit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: preset)
        XCTAssertEqual(XCTWaiter().wait(for: [lit], timeout: 5), .completed, "picking the preset lights it")
    }
}
