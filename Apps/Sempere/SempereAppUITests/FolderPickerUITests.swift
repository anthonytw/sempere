import XCTest

/// TestFlight 1.0.0 (6): "I can't make folders in the location picker". Every pick of a folder the app
/// writes into (New Vault's Sync With, Sync Targets' Add Folder, the backup folder, an export folder) is a
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

    private func launch(fresh: Bool, demo: Bool, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        // This device's keys in memory: the ad-hoc signed Mac build cannot use the Keychain (`DebugLaunch`).
        var env = ["TZ": "UTC", "SEMPERE_DEBUG_MEMORY_KEYS": "1"]
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
        app.launchEnvironment = env.merging(extra) { $1 }
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
    private func choose(in window: XCUIElement, _ app: XCUIApplication, button: String = "Choose") {
        let choose = window.buttons[button].firstMatch
        if choose.waitForExistence(timeout: 5) {
            let enabled = PanelSession.waitUntilEnabled(choose)
            if !enabled { attachPanel(window, "\(button) disabled") }
            XCTAssertTrue(enabled, "\(button) is enabled for the folder" + PanelSession.note)
            choose.click()
        } else {
            dump(app, "no Choose")
            window.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "the panel closed")
    }

    /// The panel's tree in the log and the screen as an attachment, when one of its buttons is disabled.
    private func attachPanel(_ window: XCUIElement, _ tag: String) {
        print("PICKERDEBUG \(tag), the panel:\n\(window.debugDescription.prefix(30000))")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "panel: \(tag)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// In the panel: New Folder is there; goes to the app's tmp, makes the folder `name` and chooses it.
    private func makeAndChoose(_ name: String, _ app: XCUIApplication) {
        guard let window = panel(app) else { return XCTFail("the folder panel") }
        let newFolder = window.buttons["New Folder"].firstMatch
        XCTAssertTrue(newFolder.waitForExistence(timeout: 10), "the panel has New Folder")
        go(to: appTemporaryFolder, in: window)
        let enabled = PanelSession.waitUntilEnabled(newFolder)
        if !enabled { attachPanel(window, "New Folder disabled") }
        XCTAssertTrue(enabled, "New Folder is enabled in the app's tmp" + PanelSession.note)
        newFolder.click()
        // The name sheet: its field starts with "untitled folder" selected.
        sleep(1)
        app.typeText(name + "\r")
        sleep(2)
        choose(in: window, app)
    }

    /// New Vault ▸ Sync With ▸ Choose Folder… (since #72 the vault lives in the app and the folder is a
    /// sync target, docs/design/device-first-sync.md §8.1) and Back Up To: New Folder in the panel, the vault's copy synced
    /// into that new folder, and the target still reachable after a relaunch, from its bookmark.
    func testNewVaultCopyFolderPanelMakesANewFolder() throws {
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
        let copyFolder = element(app, "newVault.copyFolder")
        require(copyFolder, "Sync With's Choose Folder…", in: app)
        copyFolder.click()
        makeAndChoose(folderName, app)
        let folder = element(app, "newVault.folder")
        require(folder, "the chosen folder", in: app)
        XCTAssertTrue("\(folder.label) \(folder.value ?? "")".contains(folderName), "the new folder is the copy's: \(folder.label)")
        // Back Up To through the same panel (review of #109: the panel cleared the picker's role before it delivered
        // the pick, and both choices were dropped on the Mac).
        let backupName = "Backups \(UUID().uuidString.prefix(4))"
        let chooseBackup = element(app, "newVault.chooseBackupFolder")
        // Below Sync With, which grows once a folder is chosen: out of view on the Mac's sheet until the form scrolls.
        revealInNewVault(chooseBackup, in: app)
        require(chooseBackup, "Back Up To's Choose Backup Folder…", in: app)
        chooseBackup.click()
        makeAndChoose(backupName, app)
        let backupRow = element(app, "newVault.backupFolder")
        require(backupRow, "the chosen backup folder", in: app)
        XCTAssertTrue("\(backupRow.label) \(backupRow.value ?? "")".contains(backupName), "the backup folder: \(backupRow.label)")
        revealInNewVault(folder, in: app, down: false)
        XCTAssertTrue("\(folder.label) \(folder.value ?? "")".contains(folderName), "the sync folder stays")

        let create = app.buttons["newVault.create"].firstMatch
        XCTAssertTrue(create.isEnabled)
        create.click()
        // A generated key: the receipt shows it once.
        let receipt = app.navigationBars["Vault Created"].firstMatch
        let failure = element(app, "newVault.failure")
        if !receipt.waitForExistence(timeout: 120), failure.exists { XCTFail("the vault was not created: \(failure.label)") }
        require(receipt, "the key receipt", in: app, timeout: 1)
        // The receipt's way out: the sheet's confirmation button, always in view.
        let saved = app.buttons["I Saved the Key"].firstMatch
        require(saved, "the receipt's I Saved the Key", in: app, timeout: 5)
        saved.click()

        // The vault opens unlocked (its keys are in memory), so the first-unlock notices follow: About Your Key,
        // then the quick tour. They hold the screen; close them before the menu.
        let understand = app.buttons["keyNoticeUnderstand"].firstMatch
        if understand.waitForExistence(timeout: 15) {
            understand.click()
            let skip = app.buttons["quickTourSkip"].firstMatch
            if skip.waitForExistence(timeout: 10) { skip.click() }
            XCTAssertTrue(skip.waitForNonExistence(timeout: 10), "the quick tour closed")
        }
        // The note list's sync bar: the copy was written into the new folder.
        let status = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "webdavStatus",
                                                          "Synced with the folder")).firstMatch
        require(status, "the copy synced into the new folder", in: app, timeout: 120)
        // File ▸ Sync Targets…: the target is the new folder.
        app.menuBars.menuBarItems["File"].firstMatch.click()
        let menuItem = app.menuBars.menuItems["Sync Targets…"].firstMatch
        require(menuItem, "File ▸ Sync Targets…", in: app)
        menuItem.click()
        require(element(app, "syncTargetsSheet"), "the Sync Targets sheet", in: app)
        require(text(app, containing: folderName), "the target in the new folder", in: app)
        XCTAssertFalse(text(app, containing: "permission").exists, "no permission error")
        element(app, "syncTargetsDone").click()
        sleep(2)
        // Owner's test of build 10: the `.sempere` sync folder is chosen as an item in File ▸ Open Vault… (it was
        // greyed out), and the sheet says the vault is on this Mac already.
        app.menuBars.menuBarItems["File"].firstMatch.click()
        let openItem = app.menuBars.menuItems["Open Vault…"].firstMatch
        require(openItem, "File ▸ Open Vault…", in: app)
        openItem.click()
        if let window = panel(app) {
            go(to: "\(appTemporaryFolder)/\(folderName)", in: window)
            window.typeText(vaultName)   // typing a name in the file list selects that item
            sleep(1)
            choose(in: window, app, button: "Open")
            require(element(app, "openVaultSheet"), "the Open Vault sheet for the sync folder", in: app, timeout: 20)
            require(text(app, containing: "already on this device"), "the vault is on this Mac already", in: app)
            app.buttons["Cancel"].firstMatch.click()
            sleep(1)
        } else {
            XCTFail("the open panel")
        }
        // Settings ▸ Backups: the backup folder New Vault set, with the backup's own name inside it.
        app.typeKey(",", modifierFlags: .command)
        require(element(app, "settingsForm"), "Settings", in: app)
        let backups = element(app, "settingsGroup.backups")
        require(backups, "the Backups & History group", in: app)
        backups.click()
        require(text(app, containing: "\(backupName)/\(vaultName).sempere-backup"), "the backup folder New Vault set", in: app)
        app.typeKey("w", modifierFlags: .command)
        sleep(1)
        app.terminate()

        // Relaunched: the vault reopens from the store (locked: this launch's keys were in memory), and its
        // target is still reachable from its bookmark (the panel's grant outlives the launch).
        app = launch(fresh: false, demo: false)
        defer { app.terminate() }
        let close = app.buttons["Close Vault"].firstMatch
        require(close, "the unlock sheet of the reopened vault", in: app, timeout: 90)
        close.click()
        let row = element(app, "storeVault-\(vaultName)")
        require(row, "the vault under On This Device", in: app, timeout: 30)
        // The row's status line: a bookmark that no longer opens the folder is a problem shown there.
        sleep(5)
        XCTAssertFalse(row.label.contains("Only on this device"), "the target is kept: \(row.label)")
        XCTAssertFalse(row.label.contains("can no longer be opened"), "the folder still opens: \(row.label)")
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
        require(element(app, "settingsForm"), "Settings", in: app)
        // Settings is grouped: backups are on the Backups & History page.
        let group = element(app, "settingsGroup.backups")
        require(group, "the Backups & History group", in: app)
        group.click()
        let settings = element(app, "settingsPage.backups")
        require(settings, "the Backups & History page", in: app)
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

    /// TestFlight 1.0.0 (8): "a backup is a plain folder that cannot be opened on the Mac", "a vault closed on
    /// the Mac cannot be reopened". Back Up Now into a new, empty folder writes "<vault>.sempere-backup" inside it
    /// (`BackupDestination`); File ▸ Open Vault… (the real panel) chooses that folder as an item (selected, not gone
    /// into) and opens the vault (its copy on this device: the demo is a store vault); closed, it opens again from
    /// the welcome list.
    func testBackupIsASempereFolderTheOpenPanelOpens() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #else
        let drive = "Drive \(UUID().uuidString.prefix(4))"
        let vaultName = "Sempere Demo"   // the demo's copy in the store (`SEMPERE_DEMO_STORE`)
        let app = launch(fresh: true, demo: true, extra: ["SEMPERE_DEMO_STORE": "1"])
        defer { app.terminate() }
        require(app.staticTexts["Cellular Respiration"].firstMatch, "the demo vault", in: app, timeout: 90)
        app.typeKey(",", modifierFlags: .command)
        require(element(app, "settingsForm"), "Settings", in: app)
        let group = element(app, "settingsGroup.backups")
        require(group, "the Backups & History group", in: app)
        group.click()
        let settings = element(app, "settingsPage.backups")
        require(settings, "the Backups & History page", in: app)
        clickInSettings("Choose Backup Folder…", settings, in: app)
        makeAndChoose(drive, app)
        // Even in an empty folder, the backup is a folder of its own named after the vault.
        require(text(app, containing: "\(drive)/\(vaultName).sempere-backup"), "the backup folder's path", in: app)
        clickInSettings("Back Up Now", settings, in: app)
        require(text(app, containing: "Backed up"), "Back Up Now's result", in: app, timeout: 120)
        app.typeKey("w", modifierFlags: .command)   // Settings is a window of its own on a Mac
        XCTAssertTrue(element(app, "settingsForm").waitForNonExistence(timeout: 10), "Settings closed")

        app.menuBars.menuBarItems["File"].firstMatch.click()
        let openItem = app.menuBars.menuItems["Open Vault…"].firstMatch
        require(openItem, "File ▸ Open Vault…", in: app)
        openItem.click()
        guard let window = panel(app) else { return XCTFail("the open panel") }
        // The backup is chosen as an item, without going into it (owner's test of build 10).
        go(to: "\(appTemporaryFolder)/\(drive)", in: window)
        window.typeText(vaultName)
        sleep(1)
        choose(in: window, app, button: "Open")
        require(element(app, "openVaultSheet"), "the Open Vault sheet for the backup", in: app, timeout: 20)
        require(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@",
                                                                     "Open Vault Backup", "Open Vault Backup")).firstMatch,
                "the backup's sheet title", in: app)
        element(app, "openVaultCopy").click()
        requireOpened(app, "the vault opened from the backup")

        // Closed, it opens again from the list of vaults on this device.
        app.typeKey("w", modifierFlags: [.command, .shift])
        let row = element(app, "storeVault-\(vaultName)")
        require(row, "the vault under On This Device", in: app, timeout: 30)
        row.click()
        requireOpened(app, "the vault reopened")
        #endif
    }

    /// Scrolls the New Vault sheet's form until `element` is on screen: the Mac's sheet is small, and a form does not
    /// report rows scrolled out of view (`NewVaultSheetUITests.reveal`). It scrolls at a point under the sheet's title
    /// bar, which stays put while the form moves.
    private func revealInNewVault(_ element: XCUIElement, in app: XCUIApplication, down: Bool = true) {
        let bar = app.navigationBars["New Vault"].firstMatch
        guard bar.waitForExistence(timeout: 5) else { return }
        let point = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 150))
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 1), element.isHittable { return }
            #if targetEnvironment(macCatalyst)
            point.scroll(byDeltaX: 0, deltaY: down ? -80 : 80)
            #else
            point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: down ? -150 : 150)))
            #endif
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// The vault is open: its notes (unlocked), or its unlock sheet (this launch's keys were in memory).
    private func requireOpened(_ app: XCUIApplication, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let notes = app.staticTexts["Cellular Respiration"].firstMatch
        let unlock = app.buttons["Close Vault"].firstMatch
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !notes.exists, !unlock.exists { Thread.sleep(forTimeInterval: 0.5) }
        if notes.exists || unlock.exists { return }
        dump(app, what)
        XCTFail("\(what): neither its notes nor its unlock sheet", file: file, line: line)
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
        // Sync With ▸ Choose Folder… (#72; New Vault had a Location menu before the in-app store).
        let copyFolder = element(app, "newVault.copyFolder")
        require(copyFolder, "Sync With's Choose Folder…", in: app)
        copyFolder.tap()
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
