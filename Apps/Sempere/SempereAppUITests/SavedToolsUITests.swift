import XCTest

/// Saved tools in the palette (docs/design/1.3-custom-tools.md §3.5, issue #11): save a preset from the palette's +, see
/// its button, pick another tool, then pick the preset and see it lit (it is lit exactly when the palette's tool is that ink
/// with that color, width and opacity). On the Mac the preset is picked with its shortcut, ⌃⌘1 (Tools ▸ Saved Tools). The
/// demo vault has no sync, so the tools are this device's own list; `testASavedToolGoesIntoTheVaultWithSettingsSync` turns
/// Settings ▸ Sync Settings with This Vault on first, so the tool is the vault's (its `settings.age`, which other devices
/// and `sempere tools list` read). Run by `scripts/app.sh test-ui -only-testing:SempereAppUITests/SavedToolsUITests` (iPad)
/// and `scripts/app.sh test-mac-ui` (Mac).
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

    /// The demo opened on "thoughts" with the canvas alone. `SEMPERE_DEBUG_FRESH`: the device's saved tools (preferences)
    /// start empty, which a Mac keeps between runs.
    @MainActor
    private func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_NOTE": "thoughts",
                                 "SEMPERE_DEBUG_PENCIL_ONLY": "1", "SEMPERE_DEBUG_FRESH": "1", "TZ": "UTC"]
            .merging(extra) { $1 }
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launch()
        return app
    }

    /// Annotate, then the palette's + and the editor: saves the current pen as `name` in the red swatch.
    @MainActor
    private func savePreset(_ app: XCUIApplication, name: String) {
        XCTAssertTrue(element(app, "pageCanvas").waitForExistence(timeout: 30))
        let annotate = element(app, "annotateButton")
        XCTAssertTrue(annotate.waitForExistence(timeout: 10), "the Annotate button")
        annotate.press()
        XCTAssertTrue(element(app, "Drawing-Palette").waitForExistence(timeout: 10), "the palette")

        // The full bar has the + of the Saved group; a narrow window's compact bar has the list button instead.
        let add = element(app, "palette.savedTool.add")
        if !add.waitForExistence(timeout: 5) {
            let list = element(app, "palette.savedToolsButton")
            XCTAssertTrue(list.waitForExistence(timeout: 5), "the saved tools' button")
            list.press()
            let listAdd = element(app, "savedTools.add")
            XCTAssertTrue(listAdd.waitForExistence(timeout: 5))
            listAdd.press()
        } else {
            add.press()
        }

        // The editor: a name (Save is off without one) and the red swatch.
        let editor = element(app, "savedTool.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor sheet")
        let save = element(app, "savedTool.save")
        XCTAssertFalse(save.isEnabled, "no name yet")
        let field = element(app, "savedTool.name")
        field.press()
        field.typeText(name)
        element(app, "savedTool.swatch.3").press()
        XCTAssertTrue(save.isEnabled)
        save.press()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), "the editor closed")
    }

    @MainActor
    func testSaveAPresetFromThePaletteAndPickIt() throws {
        let app = launch()
        defer { app.terminate() }
        savePreset(app, name: "Fine red pen")

        // Its button is in the palette (the full bar's Saved group; on the compact bar, in the list).
        let preset = element(app, "palette.savedTool.0")
        if !preset.waitForExistence(timeout: 5) {
            element(app, "palette.savedToolsButton").press()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fine red pen'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved tool's row")
            row.press()   // picks it and closes the list
            return
        }
        XCTAssertTrue(preset.label.contains("Fine red pen"), "its accessibility label names it: \(preset.label)")
        XCTAssertFalse(preset.isSelected, "the palette's pen is still black: the preset is not the current tool")
        let lit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: preset)
        #if targetEnvironment(macCatalyst)
        // Another tool first, so the shortcut visibly changes the palette's tool: the Marker.
        let marker = app.buttons.matching(NSPredicate(format: "label == 'Marker'")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "the palette's Marker")
        marker.press()
        XCTAssertTrue(UIWait.until(5) { marker.isSelected }, "the Marker is the palette's tool")
        // ⌃⌘1: Tools ▸ Saved Tools ▸ the first saved tool.
        app.typeKey("1", modifierFlags: [.control, .command])
        XCTAssertEqual(XCTWaiter().wait(for: [lit], timeout: 5), .completed, "⌃⌘1 picked the preset: it is lit")
        let pen = app.buttons.matching(NSPredicate(format: "label == 'Pen'")).firstMatch
        XCTAssertTrue(UIWait.until(5) { pen.isSelected && !marker.isSelected }, "the palette's tool is the Pen again")
        #else
        preset.press()
        XCTAssertEqual(XCTWaiter().wait(for: [lit], timeout: 5), .completed, "picking the preset lights it")
        #endif
    }

    /// With Settings ▸ Sync & Devices ▸ Sync Settings with This Vault on, a tool saved from the palette is the vault's: it is
    /// written into the vault's shared settings, which every device of the vault (and `sempere tools list`) reads. The demo
    /// vault is built with the throwaway `DemoDeviceKey`, so a script can read it after the run:
    /// `sempere tools list --vault <copy of the app's tmp/SempereDemo/My Notes.sempere> --identity <DemoDeviceKey.text>`
    /// lists "Synced red pen" (Mac only) (1.3 checklist o1, "appears on other devices").
    @MainActor
    func testASavedToolGoesIntoTheVaultWithSettingsSync() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac (the vault is read back from the Mac's container by sempere tools list)")
        #else
        let app = launch(["SEMPERE_DEMO_DEVICE_KEY": DemoDeviceKey.text])
        defer { app.terminate() }
        XCTAssertTrue(element(app, "pageCanvas").waitForExistence(timeout: 60))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element(app, "settingsForm").waitForExistence(timeout: 30), "Settings")
        let group = element(app, "settingsGroup.sync")
        XCTAssertTrue(group.waitForExistence(timeout: 10), "the Sync & Devices group")
        group.press()
        let toggle = element(app, "settingsSyncToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Sync Settings with This Vault")
        // A switch's value is "0"/"1" (a string on the iPad, a number on a Mac).
        func isOn() -> Bool { "\(toggle.value ?? "")" == "1" }
        XCTAssertFalse(isOn(), "sync starts off (\(String(describing: toggle.value)))")
        toggle.press()
        if !UIWait.until(5, isOn) {
            // A Form row's switch: its knob, at the right end.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press()
        }
        XCTAssertTrue(UIWait.until(10, isOn), "sync is on")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element(app, "settingsForm").waitForNonExistence(timeout: 10), "Settings closed")

        savePreset(app, name: "Synced red pen")
        let preset = element(app, "palette.savedTool.0")
        XCTAssertTrue(preset.waitForExistence(timeout: 10), "the vault's tool is in the palette")
        XCTAssertTrue(preset.label.contains("Synced red pen"), preset.label)
        #endif
    }
}
