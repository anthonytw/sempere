#if DEBUG
import CoreGraphics
import Foundation
import Sempere
import UIKit

/// Debug builds only: opens the synthetic demo vault (`DemoVault`) for the App
/// Store screenshots (`scripts/screenshots.sh`, `docs/appstore/screenshots.md`).
/// Set through the launch environment (`XCUIApplication.launchEnvironment`):
///
/// - `SEMPERE_DEMO`: any value; builds the vault in the temporary directory and opens it.
/// - `SEMPERE_DEMO_LOCKED`: leave it locked, so the unlock screen shows.
/// - `SEMPERE_DEMO_PASSPHRASE`: store the key in the vault under this passphrase and leave
///   it locked: a UI test unlocks it through the unlock sheet, as a user does (`LaunchSmokeUITests`).
///   The sidebar and note choices apply once it is unlocked.
/// - `SEMPERE_DEMO_NOTE`: a `DemoVault.Spec.key` (`respiration`, `atlas`, …) to open.
/// - `SEMPERE_DEMO_SIDEBAR`: `all`, `notebook:School/Physics` or `tag:lecture`.
/// - `SEMPERE_DEMO_PAPER_PICKER`: open the paper picker over the note.
/// - `SEMPERE_DEMO_PDF`: also import a synthetic PDF as a new note and open it (Mac UI tests).
/// - `SEMPERE_DEMO_MAC_WINDOW`: `WIDTHxHEIGHT` in points, Mac Catalyst only.
/// - `SEMPERE_DEBUG_COLUMNS`: `all`, `doubleColumn`, `detailOnly`, or `stored` to keep the
///   stored (with `SEMPERE_DEBUG_FRESH`, the default) layout (`DebugLaunch`).
enum DemoLaunch {
    static var isActive: Bool { DebugLaunch.environment["SEMPERE_DEMO"] != nil }

    /// Where the vault is built: replaced on every launch.
    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("SempereDemo", isDirectory: true)
    }

    /// The sidebar item a `SEMPERE_DEMO_SIDEBAR` value names.
    static func sidebarItem(_ value: String) -> SidebarItem {
        if value.hasPrefix("notebook:") { return .notebook(String(value.dropFirst("notebook:".count))) }
        if value.hasPrefix("tag:") { return .tag(String(value.dropFirst("tag:".count))) }
        return .allNotes
    }

    @MainActor
    static func run(_ model: AppModel, keys: RememberedKeys? = nil) async {
        let env = DebugLaunch.environment
        forceLight(sceneWindows)
        applyWindowSize(env["SEMPERE_DEMO_MAC_WINDOW"])
        let passphrase = env["SEMPERE_DEMO_PASSPHRASE"]
        await model.report {
            let dir = directory
            let built = try await Task.detached { try await DemoVault.build(in: dir, passphrase: passphrase) }.value
            try await model.openVault(at: built.url)
            if passphrase != nil {
                // Unlocked by the test through the unlock sheet; then the choices below.
                await selectAfterUnlock(model, keys: keys, built: built, env: env)
                return
            }
            if env["SEMPERE_DEMO_LOCKED"] == nil { try await model.unlock(identityText: built.identityText) }
            select(model, built: built, env: env)
        }
        if env["SEMPERE_DEMO_PDF"] != nil, env["SEMPERE_DEMO_LOCKED"] == nil { await importDemoPDF(model) }
    }

    /// The `SEMPERE_DEMO_SIDEBAR` and `SEMPERE_DEMO_NOTE` choices.
    @MainActor
    static func select(_ model: AppModel, built: DemoVault.Built, env: [String: String]) {
        if let side = env["SEMPERE_DEMO_SIDEBAR"] { model.sidebarSelection = sidebarItem(side) }
        if let key = env["SEMPERE_DEMO_NOTE"], let id = built.notes[key] { model.selectedNoteID = id }
    }

    /// `SEMPERE_DEMO_PASSPHRASE`: waits (at most five minutes) until the vault
    /// is unlocked, the unlock sheet is gone (the remember-key offer answered)
    /// and the chosen note is listed, then makes the choices. Opening the note
    /// while the sheet is up kept the main thread busy under the test's
    /// queries for the offer (iPad simulator: "Timed out while evaluating UI query").
    @MainActor
    static func selectAfterUnlock(_ model: AppModel, keys: RememberedKeys?, built: DemoVault.Built,
                                  env: [String: String]) async {
        let note = env["SEMPERE_DEMO_NOTE"].flatMap { built.notes[$0] }
        for _ in 0..<1500 {
            if model.phase == .unlocked, keys?.holdsUnlockSheet(model) != true,
               note.map({ id in model.notes.contains { $0.id == id } }) ?? true {
                select(model, built: built, env: env)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// `SEMPERE_DEMO_PDF`: a synthetic two-page PDF (a red square at each
    /// page's top-left) imported as a new note through the app's own import,
    /// and opened: Mac UI tests check that its pages reach the screen.
    @MainActor
    static func importDemoPDF(_ model: AppModel) async {
        do {
            let url = try PDFPreparation.workFolder().appendingPathComponent("Demo PDF.pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            for _ in 0..<2 {
                ctx.beginPDFPage(nil)
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 792 - 200, width: 200, height: 200))   // top-left (PDF space is y up)
                ctx.endPDFPage()
            }
            ctx.closePDF()
            _ = await model.importPDF(copy: url, to: .newNote(notebook: nil), password: nil)
        } catch {
            model.errorMessage = "Demo PDF: \(error)"
        }
    }

    /// The windows of every connected scene.
    @MainActor
    static var sceneWindows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    /// Light mode whatever the system appearance: the simulator is set to light by the
    /// script, but a Mac runner's appearance is its own (the canvas is light anyway, the
    /// sidebar, list and sheets are not). Sheets inherit it from their window.
    @MainActor
    static func forceLight(_ windows: [UIWindow]) {
        for window in windows { window.overrideUserInterfaceStyle = .light }
    }

    /// Mac Catalyst: pins the window to `WIDTHxHEIGHT` points, so a screenshot has a known size.
    @MainActor
    static func applyWindowSize(_ value: String?) {
        #if targetEnvironment(macCatalyst)
        let parts = (value ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let size = CGSize(width: parts[0], height: parts[1])
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
        }
        #endif
    }
}
#endif
