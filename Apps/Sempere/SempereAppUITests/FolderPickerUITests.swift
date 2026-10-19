import XCTest

/// TestFlight 1.0.0 (6): "I can't make folders in the location picker". Every pick of a folder the app
/// writes into (New Vault's location, the backup folder, a restore's location, an export folder) is a
/// folder picker with New Folder (`FolderPicker.swift`). On a Mac that is AppKit's open panel with
/// `canCreateDirectories`, which UIKit's picker leaves off; these tests drive the real panel (in the
/// app's accessibility tree as a sheet, as `MacImportUITests` found): New Folder is there, makes a
/// folder, and the app can write into it, then and after a relaunch (its bookmark). On the iPad the
/// system document picker offers New Folder in every location (`testTheIPadFolderPickerOffersNewFolder`).
///
/// The test runner is sandboxed and cannot read or write where the app writes, so the panel works in
/// the app's own container (its tmp, emptied by the system) and the results are read from the app's UI.
/// Run by `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/FolderPickerUITests` and
/// `scripts/app.sh test-ui -only-testing:SempereAppUITests/FolderPickerUITests` (iPad).
@MainActor
final class FolderPickerUITests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The app's own temporary folder (the Mac app is sandboxed: its container), where the panel may
    /// make folders without leaving anything behind in the user's folders.
    private var appTemporaryFolder: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Containers/io.github.anthonytw.sempere/Data/tmp"
    }

    private func launch(fresh: Bool, demo: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["TZ": "UTC"]
        if fresh { env["SEMPERE_DEBUG_FRESH"] = "1" }
        if demo {
            env["SEMPERE_DEMO"] = "1"
            env["SEMPERE_DEBUG_COLUMNS"] = "all"
            env["SEMPERE_DEMO_NOTE"] = "respiration"
        }
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x900"
        #else
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launchEnvironment = env
        app.launch()
        return app
    }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        print("PICKERDEBUG \(tag):\n\(app.debugDescription.prefix(30000))")
    }

    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        dump(app, what)
        XCTFail("\(what) not found", file: file, line: line)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func text(_ app: XCUIApplication, containing part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    // MARK: - The Mac's panel

    /// The open panel (a sheet on the key window, or a window of its own), by AppKit's identifier
    /// `open-panel`: the New Vault form is a sheet too.
    private func panel(_ app: XCUIApplication) -> XCUIElement? {
        let byID = app.descendants(matching: .any).matching(identifier: "open-panel").firstMatch
        if byID.waitForExistence(timeout: 10) { return byID }
        for candidate in [app.dialogs.firstMatch] where candidate.waitForExistence(timeout: 2) {
            return candidate
        }
        dump(app, "no panel")
        return nil
    }

    /// Goes to `path` in the panel (⇧⌘G).
    private func go(to path: String, in window: XCUIElement) {
        window.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        window.typeText(path + "\r")
        sleep(2)
    }

    /// Clicks the panel's Choose (Return when it cannot be found) and waits for the panel to close.
    private func choose(in window: XCUIElement, _ app: XCUIApplication) {
        let choose = window.buttons["Choose"].firstMatch
        if choose.waitForExistence(timeout: 5) {
            XCTAssertTrue(choose.isEnabled, "Choose is enabled for the folder")
            choose.click()
        } else {
            dump(app, "no Choose")
            window.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "the panel closed")
    }

    /// In the panel: New Folder is there; goes to the app's tmp, makes the folder `name` and chooses it.
    private func makeAndChoose(_ name: String, _ app: XCUIApplication) {
        guard let window = panel(app) else { return XCTFail("the folder panel") }
        let newFolder = window.buttons["New Folder"].firstMatch
        XCTAssertTrue(newFolder.waitForExistence(timeout: 10), "the panel has New Folder")
        go(to: appTemporaryFolder, in: window)
        newFolder.click()
        // The name sheet: its field starts with "untitled folder" selected.
        sleep(1)
        app.typeText(name + "\r")
        sleep(2)
        choose(in: window, app)
    }

    /// New Vault ▸ Location ▸ Choose Folder…: New Folder in the panel, the vault created in that new
    /// folder, and opened again after a relaunch from its bookmark.
    func testNewVaultLocationPanelMakesANewFolder() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #else
        let folderName = "Vaults \(UUID().uuidString.prefix(4))"
        let vaultName = "Picked \(UUID().uuidString.prefix(4))"
        var app = launch(fresh: true, demo: false)
        let newVault = app.buttons["New Vault…"].firstMatch
        require(newVault, "the welcome screen's New Vault…", in: app, timeout: 90)
        newVault.click()
        let name = app.textFields["newVault.name"].firstMatch
        require(name, "the New Vault sheet", in: app, timeout: 60)
        name.click()
        name.typeText(vaultName)
        let location = element(app, "newVault.location")
        require(location, "the Location picker", in: app)
        location.click()
        let item = app.menuItems["Choose Folder…"].firstMatch
        require(item, "Choose Folder…", in: app)
        item.click()
        makeAndChoose(folderName, app)
        let folder = element(app, "newVault.folder")
        require(folder, "the chosen folder", in: app)
        XCTAssertTrue("\(folder.label) \(folder.value ?? "")".contains(folderName), "the new folder is the location: \(folder.label)")

        let create = app.buttons["newVault.create"].firstMatch
        XCTAssertTrue(create.isEnabled)
        create.click()
        // A generated key: the receipt shows it once.
        let saved = app.buttons["I Saved the Key"].firstMatch
        require(saved, "the key receipt (the vault was written into the new folder)", in: app, timeout: 120)
        saved.click()
        sleep(2)
        app.terminate()

        // Relaunched: the recent vault opens from its bookmark (the panel's grant outlives the launch).
        app = launch(fresh: false, demo: false)
        defer { app.terminate() }
        let recent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", vaultName)).firstMatch
        if recent.waitForExistence(timeout: 30) { recent.click() }
        let unlock = app.secureTextFields.firstMatch
        require(unlock, "the unlock sheet of the reopened vault", in: app, timeout: 60)
        XCTAssertFalse(text(app, containing: "permission").exists, "no permission error")
        #endif
    }

    /// Settings ▸ Backups ▸ Choose Backup Folder…: New Folder in the panel and Back Up Now writes there
    /// (through the folder's bookmark); a folder that cannot take the backup (here the folder holding
    /// the open vault) is an alert.
    func testBackupFolderPanelMakesANewFolderAndProblemsAreAlerts() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #else
        let app = launch(fresh: true, demo: true)
        defer { app.terminate() }
        require(app.staticTexts["Cellular Respiration"].firstMatch, "the demo vault", in: app, timeout: 90)
        app.typeKey(",", modifierFlags: .command)
        let settings = element(app, "settingsForm")
        require(settings, "Settings", in: app)
        clickInSettings("Choose Backup Folder…", settings, in: app)
        makeAndChoose("Backups \(UUID().uuidString.prefix(4))", app)
        clickInSettings("Back Up Now", settings, in: app)
        require(text(app, containing: "Backed up"), "Back Up Now's result", in: app, timeout: 120)
        XCTAssertFalse(app.staticTexts["Backup Failed"].exists)

        // The folder holding the open (demo) vault: an alert, not a line under the section.
        clickInSettings("Change Backup Folder…", settings, in: app)
        guard let window = panel(app) else { return XCTFail("the folder panel") }
        go(to: appTemporaryFolder, in: window)
        // Typing a name in the file list selects that folder.
        window.typeText("SempereDemo")
        sleep(1)
        choose(in: window, app)
        let alert = app.staticTexts["Choose Another Backup Folder"].firstMatch
        require(alert, "the alert", in: app, timeout: 20)
        // OK in the app's windows (the Touch Bar has an OK too, which cannot be clicked).
        let ok = app.windows.descendants(matching: .button).matching(NSPredicate(format: "title == %@", "OK")).firstMatch
        require(ok, "the alert's OK", in: app)
        ok.click()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "OK closed the alert")
        #endif
    }

    /// Scrolls the Settings form to the button titled `title` and clicks it (`LaunchSmokeUITests`).
    private func clickInSettings(_ title: String, _ settings: XCUIElement, in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[title].firstMatch
        func shown() -> Bool { button.exists && settings.frame.contains(button.frame) }
        for deltaY in Array(repeating: -400.0, count: 10) + Array(repeating: 400.0, count: 10) where !shown() {
            settings.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        require(button, "\(title) button", in: app, file: file, line: line)
        var frame = button.frame
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = button.frame
            if now == frame { break }
            frame = now
        }
        button.click()
    }

    // MARK: - The iPad's picker

    /// The iPad's folder picker (the system document picker, another process) offers New Folder in a
    /// location (it opens on Recents, which has none) and makes the folder.
    func testTheIPadFolderPickerOffersNewFolder() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPad only")
        #else
        let app = launch(fresh: true, demo: false)
        defer { app.terminate() }
        let newVault = app.buttons["New Vault…"].firstMatch
        require(newVault, "the welcome screen's New Vault…", in: app, timeout: 90)
        newVault.tap()
        require(app.textFields["newVault.name"].firstMatch, "the New Vault sheet", in: app, timeout: 60)
        let location = element(app, "newVault.location")
        require(location, "the Location picker", in: app)
        location.tap()
        let item = app.buttons["Choose Folder…"].firstMatch
        require(item, "Choose Folder…", in: app)
        item.tap()
        let onDevice = app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        require(onDevice, "On My iPad in the picker", in: app)
        onDevice.tap()
        let newFolder = app.buttons.matching(NSPredicate(format: "label == %@", "New Folder")).firstMatch
        require(newFolder, "the picker's New Folder", in: app, timeout: 10)
        newFolder.tap()
        // The new folder, named in place ("untitled folder").
        let made = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR identifier BEGINSWITH %@ OR label BEGINSWITH %@",
            "DOC.inlineRenameField", "untitled folder", "untitled folder")).firstMatch
        if !made.waitForExistence(timeout: 15) { print("PICKERTREE\n\(app.debugDescription)") }
        XCTAssertTrue(made.exists, "New Folder made a folder")
        #endif
    }
}
