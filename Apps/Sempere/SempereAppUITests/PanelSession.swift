import XCTest

/// AppKit's open and save panels in the Mac UI tests (`FolderPickerUITests`, `MacExportUITests`, `MacImportUITests`).
///
/// The panels run in the system's open-and-save-panel service. With the test session's desktop in the background
/// (Fast User Switching: another user's desktop is on the console), every run since 2026-10-26 had the panels refuse
/// everything that writes or chooses: Save and New Folder disabled in every folder (the app's container, the test
/// runner's, Documents, a folder outside any container), Choose disabled after New Folder. The same commits had passed
/// with the session on the console. `scripts/app.sh` sets `SEMPERE_SESSION_OFF_CONSOLE` (passed to the runner as
/// `TEST_RUNNER_SEMPERE_SESSION_OFF_CONSOLE`) when the console belongs to another user, and the tests name it when a
/// panel button stays disabled.
enum PanelSession {
    /// Whether `scripts/app.sh` found the console owned by another user.
    static var offConsole: Bool { ProcessInfo.processInfo.environment["SEMPERE_SESSION_OFF_CONSOLE"] == "1" }

    /// Why a panel button may be disabled, for a failure message.
    static var note: String {
        offConsole
            ? " (this session is not on the console: another user's desktop is in front, and the panels then refuse "
              + "to save, make folders or choose; switch to this user's desktop for the Mac UI tests)"
            : ""
    }

    /// Waits until `button` is enabled (the panel checks the folder before it enables Save or Choose); false when it
    /// stays disabled.
    @MainActor
    static func waitUntilEnabled(_ button: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let enabled = NSPredicate(format: "isEnabled == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: button)], timeout: timeout) == .completed
    }
}
