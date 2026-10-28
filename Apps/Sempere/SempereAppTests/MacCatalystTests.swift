import Foundation
import Sempere
import SempereRender
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import SempereApp

/// The Mac fixes from TestFlight build 6 (docs/mac.md "Fixed after build 6").
/// These run on the iPad simulator in every `app` job and on Mac Catalyst in
/// `scripts/app.sh test-mac` (CI on `main` and on dispatch), where the bugs
/// showed: a PDF page item must reach the screen, a dragged note must hand
/// out its PDF file.
@MainActor
struct MacCatalystPDFTests {
    /// A one-page PDF note in the fixture vault, through the import the app uses.
    static func pdfNote() async throws -> (AppModel, UUID, NoteState) {
        let model = try await BrowserTests.unlockedFixtureModel()
        // A cache folder of this test's own: tests run in parallel, and each model empties its cache when done.
        model.blobCacheFolder = TestTemp.root.appendingPathComponent(UUID().uuidString)
        let vault = try #require(model.vault)
        let url = try PDFImportTests.makePDF(pages: 1)
        guard case .done(let id) = await model.importPDF(copy: url, to: .newNote(notebook: nil), password: nil) else {
            Issue.record("not imported: \(model.errorMessage ?? "")")
            throw CancellationError()
        }
        return (model, id, try vault.reconstruct(noteId: id))
    }

    /// The blob cache can place files where it keeps them on this platform
    /// (file protection attributes, the sandboxed temporary directory).
    @Test func theBlobCacheWritesItsFilesOnThisPlatform() async throws {
        let (model, id, state) = try await Self.pdfNote()
        let ref = try #require(state.pages.first?.items.first?.blob)
        let cache = try #require(model.attachmentCache())
        let url = try await cache.acquire(note: id, ref: ref)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect(size?.int64Value == ref.size)
        #expect(PDFDocumentBox(url: url) != nil, "Core Graphics opens the cached PDF")
        await cache.release(note: id, ref: ref)
    }

    /// The whole display path: the item layer opens the PDF, shows the page
    /// in a tile layer, and Core Animation draws it (red square top-left).
    @Test func aPDFPageReachesTheScreen() async throws {
        let (model, id, state) = try await Self.pdfNote()
        let page = try #require(state.pages.first)
        let item = try #require(page.items.first)
        // A window of the host app's scene, as the canvas has (a window without one is never drawn on a Mac).
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 612, height: 792)
        let root = UIViewController()
        window.rootViewController = root
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        layer.backgroundColor = .white
        root.view.addSubview(layer)
        window.isHidden = false
        layer.setZoom(1)
        layer.show(page.items, note: id, paper: .blank, source: model.itemLayerSource)
        let tiled = await TS.waitUntil(timeout: .seconds(20)) { layer.tiledItemIDs.contains(item.id) }
        #expect(tiled, "the page is drawn in tiles; shown instead: \(String(describing: layer.picture(of: item.id)))")
        let tile = try #require(layer.tileLayer(of: item.id))
        // What a tile draws, in a y-down context (iOS) and a y-up one (a Mac layer's own).
        for flipped in [true, false] {
            let image = try #require(Self.draw(tile.content, size: CGSize(width: 612, height: 792), flipped: flipped))
            let p = try #require(ImageInsertTests.pixel(image, x: 20, y: 20))
            #expect(p.r > 200 && p.g < 80, "tile drawing (flipped \(flipped)): red at the top-left, got \(p)")
        }
        // Core Animation asks the tile layer for its tiles.
        let asked = await TS.waitUntil(timeout: .seconds(20)) { tile.content.drawCount > 0 }
        #expect(asked, "Core Animation drew tiles (scale \(tile.contentsScale), bounds \(tile.bounds), transform \(tile.affineTransform()), scene \(scene != nil))")
        // What the window shows once Core Animation has drawn the tiles.
        var shown: (r: Int, g: Int, b: Int)?
        let drawn = await TS.waitUntil(timeout: .seconds(20)) {
            let renderer = UIGraphicsImageRenderer(bounds: layer.bounds)
            let image = renderer.image { _ in _ = layer.drawHierarchy(in: layer.bounds, afterScreenUpdates: true) }
            shown = image.cgImage.flatMap { ImageInsertTests.pixel($0, x: Int(20 * image.scale), y: Int(20 * image.scale)) }
            return shown.map { $0.r > 200 && $0.g < 80 } ?? false
        }
        #expect(drawn, "the window shows the page: \(String(describing: shown)), tiles drawn \(tile.content.drawCount)")
        window.isHidden = true
    }

    /// The canvas shows a page's items before its view is in a window (its
    /// display scale is then 0 on a Mac, or not the window's): the tiles are
    /// drawn again at the window's scale once it is (TestFlight build 6: PDF
    /// pages stayed blank on the Mac).
    @Test func aPDFPageShownBeforeItsWindowReachesTheScreen() async throws {
        let (model, id, state) = try await Self.pdfNote()
        let page = try #require(state.pages.first)
        let item = try #require(page.items.first)
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        layer.backgroundColor = .white
        let scaleBefore = layer.traitCollection.displayScale
        layer.setZoom(1)
        layer.show(page.items, note: id, paper: .blank, source: model.itemLayerSource)
        #expect(await TS.waitUntil(timeout: .seconds(20)) { layer.tiledItemIDs.contains(item.id) })
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 612, height: 792)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(layer)
        window.isHidden = false
        let tile = try #require(layer.tileLayer(of: item.id))
        print("PDF-SCALE before window \(scaleBefore), in window \(layer.traitCollection.displayScale), tile \(tile.contentsScale)")
        #expect(tile.contentsScale == layer.traitCollection.displayScale, "tiles at the window's scale")
        var shown: (r: Int, g: Int, b: Int)?
        let drawn = await TS.waitUntil(timeout: .seconds(20)) {
            let renderer = UIGraphicsImageRenderer(bounds: layer.bounds)
            let image = renderer.image { _ in _ = layer.drawHierarchy(in: layer.bounds, afterScreenUpdates: true) }
            shown = image.cgImage.flatMap { ImageInsertTests.pixel($0, x: Int(20 * image.scale), y: Int(20 * image.scale)) }
            return shown.map { $0.r > 200 && $0.g < 80 } ?? false
        }
        #expect(drawn, "the page is drawn once in a window: \(String(describing: shown)), tiles drawn \(tile.content.drawCount)")
        window.isHidden = true
    }

    /// Draws `content` the way a tile thread does, into a bitmap whose user
    /// space is y down (`flipped`) or y up, and returns it top row first.
    static func draw(_ content: PDFTileContent, size: CGSize, flipped: Bool) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if flipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        content.draw(in: ctx)
        return ctx.makeImage()
    }
}

/// Dragging a note to the Finder (docs/mac.md "Drag a note out as PDF"): the
/// drop's request for the file is a file promise on a Mac, which may arrive
/// while the main thread waits for it, so it must be served without the main
/// actor once the drag has begun.
@MainActor
struct MacDragOutTests {
    static let lecture = AppModelTests.lecture

    /// Holds what a file request delivered (the URL is valid only inside the callback).
    final class Delivery: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var data: Data?
        var name: String?
        var error: (any Error)?

        /// Blocks the calling thread (the main thread in these tests) until delivered or `seconds` pass.
        nonisolated func wait(seconds: Double) -> Bool {
            done.wait(timeout: .now() + seconds) == .success
        }
    }

    @Test func theFileIsDeliveredWhileTheMainThreadWaits() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        let prepare = NoteFileDrag.prepare(Self.lecture, model: model)
        _ = try await prepare.value   // the drag began a moment before the drop
        let delivery = Delivery()
        NoteFileDrag.load(prepare) { url, error in
            delivery.data = url.flatMap { try? Data(contentsOf: $0) }
            delivery.name = url?.lastPathComponent
            delivery.error = error
            delivery.done.signal()
        }
        // Block the main thread, as a file promise's writer may: the PDF still arrives.
        let delivered = delivery.wait(seconds: 60)
        #expect(delivered, "delivered without the main thread")
        #expect(delivery.error == nil)
        #expect(delivery.name == "Fixture lecture.pdf")
        #expect(delivery.data?.starts(with: Data("%PDF-".utf8)) == true)
    }

    @Test func theProviderOffersThePDFFirstUnderTheNotesName() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        let prepare = NoteFileDrag.prepare(Self.lecture, model: model)
        let provider = DragPayload.notes([Self.lecture]).provider { provider in
            NoteFileDrag.register(on: provider, title: "Fixture lecture", prepare: prepare)
        }
        #expect(provider.registeredTypeIdentifiers.first == UTType.pdf.identifier, "other apps see the PDF first")
        #expect(provider.suggestedName == "Fixture lecture")
        let delivery = Delivery()
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
            delivery.data = url.flatMap { try? Data(contentsOf: $0) }
            delivery.error = error
            delivery.done.signal()
        }
        let delivered = await Task.detached { delivery.wait(seconds: 60) }.value
        #expect(delivered)
        #expect(delivery.error == nil)
        #expect(delivery.data?.starts(with: Data("%PDF-".utf8)) == true)
    }

    @Test func aFileOnlyProviderOffersJustTheFile() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        let prepare = NoteFileDrag.prepare(Self.lecture, model: model)
        let provider = DragPayload.notes([Self.lecture]).provider(includePayload: false) { provider in
            NoteFileDrag.register(on: provider, title: "Fixture lecture", prepare: prepare)
        }
        #expect(provider.registeredTypeIdentifiers == [UTType.pdf.identifier])
        prepare.cancel()
    }

    @Test func theDragControlHandsBackItsFileAtOnce() async throws {
        let folder = try TestTemp.directory("drag-control")
        let provider = NSItemProvider()
        NoteFileDrag.registerControl(on: provider, folder: folder, tag: "test")
        #expect(provider.registeredTypeIdentifiers == [UTType.plainText.identifier])
        #expect(provider.suggestedName == "Sempere drag control")
        let delivery = Delivery()
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.plainText.identifier) { url, error in
            delivery.data = url.flatMap { try? Data(contentsOf: $0) }
            delivery.error = error
            delivery.done.signal()
        }
        let delivered = await Task.detached { delivery.wait(seconds: 30) }.value
        #expect(delivered)
        #expect(delivery.error == nil)
        #expect(delivery.data.map { String(decoding: $0, as: UTF8.self).hasPrefix("Sempere drag control") } == true)
    }

    @Test func aLoggedDragErrorKeepsOnlyItsClassifierPublic() {
        let path = "/Users/someone/Secret plans.pdf"
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "Secret plans could not be saved"])
        let kind = DragLog.classify(error)
        #expect(kind.contains("domain=\(NSCocoaErrorDomain)"))
        #expect(kind.contains("code=\(NSFileWriteNoPermissionError)"))
        #expect(!kind.contains("Secret"), "no title or path in the public part")
        #expect(DragLog.classify(NoteFileDrag.DragError.timedOut).contains("DragError"))
    }

    @Test func eachDragTestRunWritesItsSwitchesAndOffRemovesThem() throws {
        let name = "drag-runs-\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(name))
        defer { TestDefaults.remove(name) }
        for run in NoteDragTestRun.allCases {
            run.apply(to: defaults)
            let read = NoteDragDebug.load(from: defaults, environment: [:])
            #expect(read == run.switches, "\(run)")
            #expect(NoteDragTestRun.matching(read) == run)
        }
        NoteDragTestRun.off.apply(to: defaults)
        #expect(defaults.object(forKey: NoteDragDebug.styleKey) == nil)
        #expect(defaults.object(forKey: NoteDragDebug.controlKey) == nil)
        #expect(defaults.object(forKey: NoteDragDebug.fileOnlyKey) == nil)
    }

    @Test func switchesNoRunSetsAreClearedSoOffWorks() throws {
        let name = "drag-unmatched-\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(name))
        defer { TestDefaults.remove(name) }
        defaults.set("uikit", forKey: NoteDragDebug.styleKey)
        defaults.set(true, forKey: NoteDragDebug.controlKey)   // uikit + control: no run sets this
        #expect(NoteDragTestRun.matching(NoteDragDebug.load(from: defaults, environment: [:])) == nil)
        #expect(NoteDragTestRun.settled(in: defaults) == .off)
        #expect(defaults.object(forKey: NoteDragDebug.styleKey) == nil)
        #expect(defaults.object(forKey: NoteDragDebug.controlKey) == nil)
        NoteDragTestRun.b.apply(to: defaults)
        #expect(NoteDragTestRun.settled(in: defaults) == .b, "a run's own switches stay")
    }

    @Test func fiveQuickClicksOrAnOptionClickRevealTheDiagnostics() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var clicks = RevealClicks()
        let option = clicks.click(at: t0, option: true)
        #expect(option)
        let quick = (0..<5).map { clicks.click(at: t0.addingTimeInterval(10 + Double($0) * 0.3), option: false) }
        #expect(quick == [false, false, false, false, true])
        let slow = (0..<5).map { clicks.click(at: t0.addingTimeInterval(100 + Double($0) * 2), option: false) }
        #expect(!slow.contains(true), "clicks far apart start the count again")
    }

    @Test func notesDragAsShippedUnlessTheHiddenDefaultsSayOtherwise() throws {
        #expect(NoteDragStyle.shipped == .onDrag)
        let name = "drag-debug-\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(name))
        defer { TestDefaults.remove(name) }
        #expect(NoteDragDebug.load(from: defaults, environment: [:]) == NoteDragDebug())
        defaults.set("uikit", forKey: NoteDragDebug.styleKey)
        defaults.set(true, forKey: NoteDragDebug.controlKey)
        defaults.set(true, forKey: NoteDragDebug.fileOnlyKey)
        #expect(NoteDragDebug.load(from: defaults, environment: [:]) == NoteDragDebug(style: .uikit, control: true, fileOnly: true))
        defaults.set("sideways", forKey: NoteDragDebug.styleKey)
        #expect(NoteDragDebug.load(from: defaults, environment: [:]).style == nil, "an unknown style is the shipped one")
    }

    @Test func aDragFromAClosedVaultWritesNothing() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let prepared = try await model.prepareExport(noteID: Self.lecture)
        model.close()
        #expect(throws: CancellationError.self) { _ = try prepared.write() }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: model.exportFolder.path)) ?? []
        #expect(left.isEmpty, "no plaintext PDF after the vault closed")
    }

    @Test func droppedFilesAreNamedAfterTheTitle() {
        #expect(NoteFileDrag.suggestedName(title: "Lab: week 3/4") == "Lab week 3 4")
        #expect(NoteFileDrag.suggestedName(title: "") == "Untitled")
    }
}

/// Re-check of the #46 menus against the code merged since: File > Export
/// acts on the focused window's notes and its sheet opens in that window.
@MainActor
struct MacMenuRecheckTests {
    @Test func anExportSheetShowsInTheWindowThatAskedForIt() {
        let library = UUID(), note = UUID()
        let fromNoteWindow = ExportRequest(noteIDs: [UUID()], format: .pdf, window: note)
        #expect(ExportRequest.shown(fromNoteWindow, in: note, canvasWindow: library) == fromNoteWindow)
        #expect(ExportRequest.shown(fromNoteWindow, in: library, canvasWindow: library) == nil)
        let unattributed = ExportRequest(noteIDs: [UUID()], format: .png)
        #expect(ExportRequest.shown(unattributed, in: library, canvasWindow: library) == unattributed)
        #expect(ExportRequest.shown(unattributed, in: note, canvasWindow: library) == nil)
        #expect(ExportRequest.shown(nil, in: library, canvasWindow: library) == nil)
    }

    @Test func theExportMenuUsesTheFocusedWindowsNotes() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let window = UUID()
        model.requestExport(.pdf, ids: [AppModelTests.lecture], window: window)
        #expect(model.exportRequest?.noteIDs == [AppModelTests.lecture])
        #expect(model.exportRequest?.window == window)
    }

    /// The search bar's ⌘G / ⇧⌘G (find next / previous match) are not menu commands; no menu shortcut takes them.
    @Test func searchMatchShortcutsAreFree() {
        let taken = MenuCommand.allCases.compactMap(\.shortcut)
        #expect(!taken.contains(MenuCommand.Shortcut("g")))
        #expect(!taken.contains(MenuCommand.Shortcut("g", [.command, .shift])))
    }
}

/// The Mac menu bar keeps the app's commands and drops UIKit's duplicates
/// (`MacMenus`): New Window, Open… (⌘O) and Find… (⌘F) collided with them.
@MainActor
struct MacMenuBarTests {
    @Test func systemCommandsArePrunedAndTheAppsKept() {
        #expect(!MacMenus.isAppElement(UICommand(title: "Open…", action: Selector(("open:")))))
        #expect(!MacMenus.isAppElement(UIKeyCommand(title: "Find…", action: Selector(("find:")), input: "f",
                                                    modifierFlags: .command)))
        #expect(MacMenus.isAppElement(UIKeyCommand(title: "Open Vault…", action: Selector(("_performMainMenuShortcutKeyCommand:")),
                                                   input: "o", modifierFlags: .command)))
        #expect(MacMenus.isAppElement(UIAction(title: "Export") { _ in }))
        #expect(MacMenus.isAppElement(UIMenu(title: "Open Recent", children: [])))
    }

    /// ⌘O and ⌘F are UIKit's own items, renamed, run by the focused window's router.
    @Test func nativeItemsRunTheirWindowsRouterWhenEnabled() async throws {
        let open = MacMenus.nativeItem(.openVault)
        #expect(open.title == "Open Vault…" && open.input == "o" && open.modifierFlags == .command)
        #expect(open.propertyList as? String == MenuCommand.openVault.rawValue)
        #expect(MacMenus.nativeItem(.find).input == "f")
        // The host app's scene connects after launch, later when the app starts in the
        // background (a Mac in use): wait for it rather than read it once.
        var found: UIWindowScene?
        for _ in 0..<100 where found == nil {
            found = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let scene = try #require(found)
        let window = UIWindow(windowScene: scene)
        #expect(window.target(forAction: #selector(UIWindow.sempereMenuCommand(_:)), withSender: open) != nil,
                "the window takes the item")
        var ran: [MenuCommand] = []
        var context = MenuCommand.Context()
        context.window = .library
        let previous = MenuRouting.shared.router(for: scene)
        defer { MenuRouting.shared.set(previous, for: scene) }
        MenuRouting.shared.set(CommandRouter(context: context, perform: { ran.append($0) }), for: scene)
        window.sempereMenuCommand(open)
        #expect(ran == [.openVault], "Open Vault… runs in a library window")
        window.sempereMenuCommand(MacMenus.nativeItem(.find))
        #expect(ran == [.openVault], "Find Notes needs an unlocked vault")
        context.window = .note
        context.vault = .unlocked
        MenuRouting.shared.set(CommandRouter(context: context, perform: { ran.append($0) }), for: scene)
        window.sempereMenuCommand(open)
        window.sempereMenuCommand(MacMenus.nativeItem(.find))
        #expect(ran == [.openVault], "a note window has no vault picker or note list")
    }

    /// On a Mac, the menu bar holds every app command, and File and Edit no UIKit duplicates.
    @Test func theFileAndEditMenusAreTheApps() async throws {
        guard Platform.isMac else { return }
        UIMenuSystem.main.setNeedsRebuild()
        _ = await TS.waitUntil(timeout: .seconds(10)) { !SempereAppDelegate.lastTree.isEmpty }
        let tree = SempereAppDelegate.lastTree.joined(separator: "\n")
        // Every app menu: a group refused for a taken shortcut would be missing as a whole.
        for title in ["New Note…", "Open Note in New Window", "New Vault…", "Open Vault…", "Close Vault", "Reload Vault",
                      "Find Notes", "Rename Note…", "Pen", "Zoom In", "Library", "Vault Keys", "Settings…"] {
            #expect(tree.contains("|\(title)"), "\(title) is in the menu bar:\n\(tree)")
        }
        for action in ["requestNewScene:", "|open:", "|find:", "duplicate:", "export:"] {
            #expect(!tree.contains(action), "UIKit's \(action) is gone")
        }
    }

    /// ⌘, is the app's Settings…, in the app menu: UIKit's own item (Catalyst's
    /// generated pane, touch alternatives only) is gone (TestFlight build 7).
    @Test func settingsInTheAppMenuAreTheApps() async throws {
        guard Platform.isMac else { return }
        UIMenuSystem.main.setNeedsRebuild()
        _ = await TS.waitUntil(timeout: .seconds(10)) { !SempereAppDelegate.lastTree.isEmpty }
        let tree = SempereAppDelegate.lastTree
        #expect(MacMenus.built.contains { $0 == "preferences → Settings…" || $0 == "Settings… added" }, "\(MacMenus.built)")
        #expect(!tree.joined(separator: "\n").contains("orderFrontPreferencesPanel"), "UIKit's Settings… is gone")
        let settings = tree.filter { $0.contains("|key|Settings…|") }
        #expect(settings.count == 1, "one Settings… item: \(settings)")
        #expect(settings.first?.hasSuffix("|,") == true, "on ⌘,: \(settings)")
    }

    /// On a Mac, the menu bar as built has no shortcut twice.
    @Test func theBuiltMenuBarHasEveryShortcutOnce() async throws {
        guard Platform.isMac else { return }
        UIMenuSystem.main.setNeedsRebuild()
        let built = await TS.waitUntil(timeout: .seconds(10)) { !SempereAppDelegate.lastShortcuts.isEmpty }
        #expect(built, "the app delegate built the menu bar")
        let all = SempereAppDelegate.lastShortcuts
        let repeated = Dictionary(grouping: all, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        print("SempereMenus test: \(MacMenus.built), \(all.count) shortcuts")
        #expect(repeated.isEmpty, "shortcuts used twice: \(repeated)")
    }
}
