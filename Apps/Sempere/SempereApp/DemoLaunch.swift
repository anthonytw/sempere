#if DEBUG
import CoreGraphics
import Foundation
import Sempere
import SempereAppCore
import SempereInsights
import UIKit

/// Debug builds only: opens the synthetic demo vault (`DemoVault`) for the App
/// Store screenshots (`scripts/screenshots.sh`, `docs/appstore/screenshots.md`).
/// Set through the launch environment (`XCUIApplication.launchEnvironment`):
///
/// - `SEMPERE_DEMO`: any value; builds the vault in the temporary directory and opens it.
/// - `SEMPERE_DEMO_LOCKED`: leave it locked, so the unlock screen shows.
/// - `SEMPERE_DEMO_PASSPHRASE`: store the recovery key in the vault under this passphrase and leave
///   it locked: a UI test unlocks it through the unlock sheet, as a user does (`LaunchSmokeUITests`):
///   read-only with this passphrase, or writable with the key of `SEMPERE_DEMO_DEVICE_KEY`.
///   The sidebar and note choices apply once it is unlocked.
/// - `SEMPERE_DEMO_DEVICE_KEY`: a device key file (`DeviceKeys.fileText`) to make the demo's home
///   device instead of a fresh one; a UI test pastes the same text into the unlock sheet.
/// - `SEMPERE_DEMO_NOTE`: a `DemoVault.Spec.key` (`respiration`, `atlas`, …) to open.
/// - `SEMPERE_DEMO_SIDEBAR`: `all`, `notebook:School/Physics` or `tag:lecture`.
/// - `SEMPERE_DEMO_PAPER_PICKER`: open the paper picker over the note.
/// - `SEMPERE_DEMO_ITEMS`: place an image, a text box, an equation and an audio card on the
///   "thoughts" note (`DemoVault.itemOps`), and report the canvas's items to UI tests
///   (`ItemSelectionController.debugReport`, `MacItemUITests`).
/// - `SEMPERE_DEMO_DENSE`: a stroke count; also builds the pageless note `dense` with that many
///   synthetic strokes (`DemoVault.denseOps`; with `SEMPERE_DEMO_ITEMS` it gets the items too).
/// - `SEMPERE_DEMO_SEARCH`: also builds two notes with recognized handwriting (`DemoVault.searchNoteOps`:
///   "wombat" several times on a page, on two pages and down a pageless note), and the canvases report
///   their search highlights (`ItemSelectionController.debugReport`'s `hl=`).
/// - `SEMPERE_DEMO_PDF`: also import a synthetic PDF as a new note and open it (Mac UI tests).
/// - `SEMPERE_DEMO_MAC_WINDOW`: `WIDTHxHEIGHT` in points, Mac Catalyst only.
/// - `SEMPERE_DEMO_STORE`: copy the built vault into the in-app store (`VaultStore`, replacing an earlier
///   launch's demo copy) and open that copy, so store-only controls show (Sync Targets ▸ Add WebDAV Server…,
///   Details and Repair; `LaunchSmokeUITests`). The demo data is the same.
/// - `SEMPERE_DEMO_STORE_EXTRA`: with `SEMPERE_DEMO_STORE` and `SEMPERE_DEBUG_MEMORY_KEYS` (so no Keychain items pile
///   up), a count (1 or 2): also creates that many small empty vaults in the store, "Sempere Demo B" and "Sempere Demo
///   C", through New Vault's path (`AppModel.createVault`, this device's keys saved first), before the demo opens, with
///   no recent entries, so the welcome list shows "Sempere Demo", "Sempere Demo B", "Sempere Demo C" in that order
///   (`storedVaultsByUse`: by name, none of them recorded as opened; `VaultListSwipeUITests`).
/// - `SEMPERE_DEMO_SYNC_FOLDER`: with `SEMPERE_DEMO_STORE`, also syncs the store copy with a folder in the temporary
///   directory, idle runs every that many seconds (`addSyncFolder`).
/// - `SEMPERE_DEMO_APPEARANCE`: `light` (the default) or `dark`: what the demo's windows are forced to
///   (`forceAppearance`), for the website's dark twins; the canvas's paper stays light (CLAUDE.md, `PKCanvasView`).
/// - `SEMPERE_DEMO_INSIGHTS`: `note`, `map` or `on` (unset: no insights providers at all, so no offer card; `on`: only the
///   fake providers and the text, Note Insights stays off until Settings turns it on: `LaunchSmokeUITests`): turns Note Insights on with the package's fake providers (the
///   simulator has no Apple model: it is never called), gives the demo's notes recognized text
///   (`DemoVault.insightsTexts`), runs the passes and opens the note's Note Insights sheet (`note`, over the
///   `SEMPERE_DEMO_NOTE` note) or the Map of Related Notes (`map`): `WindowSheets`.
/// - `SEMPERE_DEMO_NEARBY_JOIN`: lists one synthetic join request as having come nearby (`Demo iPhone`) for Add
///   Device, and, on a locked demo's join screen, shows the nearby link as connected.
/// - `SEMPERE_DEBUG_COLUMNS`: `all`, `doubleColumn`, `detailOnly`, or `stored` to keep the
///   stored (with `SEMPERE_DEBUG_FRESH`, the default) layout (`DebugLaunch`).
/// - `SEMPERE_DEBUG_PENCIL_ONLY`: the canvases draw with the Pencil only, as on an iPad with a
///   paired Pencil, so a simulated finger taps, holds and scrolls (`IPadCanvasUITests`).
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
    static func run(_ model: AppModel, library: VaultLibrary, keys: RememberedKeys? = nil) async {
        let env = DebugLaunch.environment
        forceAppearance(sceneWindows, env["SEMPERE_DEMO_APPEARANCE"])
        applyWindowSize(env["SEMPERE_DEMO_MAC_WINDOW"])
        let passphrase = env["SEMPERE_DEMO_PASSPHRASE"]
        let insights = insightsMode(env["SEMPERE_DEMO_INSIGHTS"])
        if insights != nil {
            // The fake providers, and a power window always open.
            // "Generated on" shows a demo day (5 Oct 2026, after the demo's newest note settled), never the day of the run.
            let generated = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 10, day: 5, hour: 18)) ?? Date()
            model.insightsNow = { generated }
            model.insightsServices = InsightsServices(model: { FakeModelProvider() }, embedder: { FakeEmbeddingProvider(dimension: 512) },
                                                      powerWindow: { true })
        } else {
            // No providers: the demo never calls Apple's model, and the note list shows no Note Insights offer.
            model.insightsServices = .none
        }
        await model.report {
            let dir = directory
            let png = env["SEMPERE_DEMO_ITEMS"] != nil ? demoImage() : nil
            let dense = env["SEMPERE_DEMO_DENSE"].flatMap { Int($0) }
            let search = env["SEMPERE_DEMO_SEARCH"] != nil
            let trust = model.trust
            let device = try env["SEMPERE_DEMO_DEVICE_KEY"].map(DeviceKeys.parse)
            try await createExtraStoreVaults(model, library: library, keys: keys, env: env)
            let built = try await Task.detached {
                try await DemoVault.build(in: dir, passphrase: passphrase, itemsImage: png, denseStrokes: dense,
                                          searchNotes: search, insightsText: insights != nil, trust: trust, device: device, app: NoteWriter.appName,
                                          perf: AppPerfSink())
            }.value
            try await model.openVault(at: try await storeCopy(of: built.url, model: model, env: env))
            if passphrase != nil {
                // Unlocked by the test through the unlock sheet; then the choices below.
                await selectAfterUnlock(model, keys: keys, built: built, env: env)
                return
            }
            if env["SEMPERE_DEMO_LOCKED"] == nil { try await model.unlock(identityText: built.identityText) }
            select(model, built: built, env: env)
            if let pace = env["SEMPERE_DEMO_SYNC_FOLDER"] { try addSyncFolder(model, pace: pace) }
            if env["SEMPERE_DEMO_NEARBY_JOIN"] != nil { try model.debugSeedNearbyRequest(name: "Demo iPhone", kind: "iphone") }
        }
        if insights == "note" || insights == "map", env["SEMPERE_DEMO_LOCKED"] == nil, passphrase == nil { await prepareInsights(model) }
        if env["SEMPERE_DEMO_NEARBY_JOIN"] != nil, env["SEMPERE_DEMO_LOCKED"] != nil { holdNearbyConnected(model) }
        if env["SEMPERE_DEMO_PDF"] != nil, env["SEMPERE_DEMO_LOCKED"] == nil { await importDemoPDF(model) }
    }

    /// The value of `SEMPERE_DEMO_INSIGHTS` (`note` or `map`), nil when unset or unknown.
    static func insightsMode(_ value: String?) -> String? {
        guard let value, ["note", "map", "on"].contains(value) else { return nil }
        return value
    }

    /// Turns Note Insights on and runs passes with the fake providers until the map and the notes' summaries are in
    /// (at most about two minutes), so the sheets show real stored insights of the demo's synthetic text.
    @MainActor
    static func prepareInsights(_ model: AppModel) async {
        await model.setInsightsEnabled(true)
        for _ in 0..<240 {
            if !model.insights.isWorking { model.requestInsightsPass(force: true) }
            if !model.insights.isWorking, !model.insightsMap.isEmpty,
               model.insights.status.map({ $0.processed >= $0.notes }) == true { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// `SEMPERE_DEMO_NEARBY_JOIN` on the locked demo: the join screen's nearby line says a device nearby has the
    /// request (the simulator has no peer), kept for a minute against the join screen's own updates.
    @MainActor
    static func holdNearbyConnected(_ model: AppModel) {
        Task { @MainActor in
            for _ in 0..<240 {
                model.debugSetNearby(joining: .connected, approving: .connected)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The store copy's name: an earlier launch's copy under it is removed first (each build has a new id).
    static let storeName = "Sempere Demo"

    /// `SEMPERE_DEMO_STORE`: the built vault copied into the model's store, the copy opened instead; else `url`.
    @MainActor
    static func storeCopy(of url: URL, model: AppModel, env: [String: String]) async throws -> URL {
        guard env["SEMPERE_DEMO_STORE"] != nil, let store = model.vaultStore else { return url }
        return try await Task.detached {
            for old in store.list() where old.name == storeName { try? store.remove(old.vaultId) }
            return try store.importVault(from: url, options: VaultStore.ImportOptions(name: storeName)).url
        }.value
    }

    /// The names of `SEMPERE_DEMO_STORE_EXTRA`'s vaults, in list order (after the demo's).
    static let extraStoreNames = ["Sempere Demo B", "Sempere Demo C"]

    /// `SEMPERE_DEMO_STORE_EXTRA` (with `SEMPERE_DEMO_STORE` and `SEMPERE_DEBUG_MEMORY_KEYS`): creates the first that
    /// many of `extraStoreNames` as New Vault does (keys saved first, then `createVault`, which opens each), and drops
    /// their recent entries, so the list orders them by name after the demo's ("Sempere Demo"). On a simulator an
    /// earlier launch's vaults of these names are removed first.
    @MainActor
    static func createExtraStoreVaults(_ model: AppModel, library: VaultLibrary, keys: RememberedKeys?,
                                       env: [String: String]) async throws {
        guard env["SEMPERE_DEMO_STORE"] != nil, env["SEMPERE_DEBUG_MEMORY_KEYS"] != nil, let keys, let count = env["SEMPERE_DEMO_STORE_EXTRA"].flatMap({ Int($0) }),
              count > 0 else { return }
        let names = Array(extraStoreNames.prefix(count))
        #if targetEnvironment(simulator)
        let store = library.vaultStore
        await Task.detached {
            for old in store.list() where names.contains(old.name) { try? store.remove(old.vaultId) }
        }.value
        await library.refreshStoredVaults()
        #endif
        var created: [UUID] = []
        for name in names {
            var request = NewVaultRequest(name: name, keySource: .generate, passphrase: nil, deviceName: "Demo Device",
                                          deviceKind: UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad")
            let device = try keys.store.generate()
            request.device = device
            try await keys.saveCreatedVaultKeys(device, vaultID: request.vaultId, vaultName: name)
            created.append(try await model.createVault(request, library: library).vaultID)
        }
        // Never opened, as far as the list goes: the list orders vaults with no recent entry by name, after the opened
        // ones, and the demo opened next (`openVault`) records none either, so the order is the names'.
        for recent in library.recents where recent.storeID.map(created.contains) == true { library.forget(recent) }
    }

    /// `SEMPERE_DEMO_SYNC_FOLDER` (with `SEMPERE_DEMO_STORE`): adds a folder in the app's temporary directory as a sync
    /// target of the demo's store copy, its idle runs every `pace` seconds (a number; else the app's 60), so UI tests see
    /// the list while runs go (`VaultListSwipeUITests`). Replaced on every launch.
    @MainActor
    static func addSyncFolder(_ model: AppModel, pace: String) throws {
        guard let vaultID = model.vault?.vaultId else { return }
        let drive = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("DemoSync", isDirectory: true)
        try? FileManager.default.removeItem(at: drive)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try model.addPickedFolderTarget(drive, to: vaultID)
        if let seconds = TimeInterval(pace), seconds > 0 {
            for session in model.syncSessions {
                session.schedule.idleInterval = seconds
                session.schedule.maxIdleInterval = seconds
                session.schedule.arrivingInterval = seconds   // the first run copies the vault: "active" after it
            }
        }
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

    /// A 4 × 3 pixel PNG, orange (the image `SEMPERE_DEMO_ITEMS` places).
    static func demoImage() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3), format: format).pngData { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
    }

    /// `SEMPERE_DEMO_PDF`: a synthetic two-page PDF (a red square at each
    /// page's top-left) imported as a new note through the app's own import,
    /// and opened: Mac UI tests check that its pages reach the screen.
    @MainActor
    static func importDemoPDF(_ model: AppModel) async {
        do {
            let url = try ImportWorkFolder.make().appendingPathComponent("Demo PDF.pdf")
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
            model.alert = .worded("Demo PDF: \(AppModel.describe(error))")
        }
    }

    /// The windows of every connected scene.
    @MainActor
    static var sceneWindows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    /// What `SEMPERE_DEMO_APPEARANCE` names: `dark`, else light (the default, also for an unknown value).
    static func appearance(_ value: String?) -> UIUserInterfaceStyle {
        value == "dark" ? .dark : .light
    }

    /// The windows forced to `SEMPERE_DEMO_APPEARANCE` (light by default) whatever the system appearance: the
    /// simulator is set by the script, but a Mac runner's appearance is its own (the canvas is light anyway, the
    /// sidebar, list and sheets are not). Sheets inherit it from their window.
    @MainActor
    static func forceAppearance(_ windows: [UIWindow], _ value: String? = nil) {
        let style = appearance(value)
        for window in windows { window.overrideUserInterfaceStyle = style }
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
