import ImageIO
import XCTest

/// Mac Catalyst behaviour that only a running app shows (TestFlight build 6
/// feedback, docs/mac.md): a note opened in a new window gets a window of its
/// own, and the new-note sheet's notebook combo box suggests notebooks.
/// Launches the synthetic demo vault (`DemoLaunch`); skipped on the iPad.
/// Run by `scripts/app.sh test-mac-ui` (CI on `main` and on dispatch).
final class MacWindowUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
    }

    @MainActor
    private func launch(note: String = "respiration", extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // No windows from an earlier run: the test counts them.
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": note,
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "TZ": "UTC"]
            .merging(extra) { _, new in new }
        app.launch()
        return app
    }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        // One snapshot of the tree (querying elements one by one takes seconds each).
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("MACUIDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(8000))")
        }
    }

    /// File > Open Note in New Window (⌥⌘N) opens a window showing that note,
    /// not a second library window.
    @MainActor
    func testOpenNoteInNewWindowOpensANoteWindow() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        // The library window has the focus (the menu acts on the focused window's selection).
        app.cells.containing(NSPredicate(format: "label == %@", "Cellular Respiration")).firstMatch.click()
        app.typeKey("n", modifierFlags: [.command, .option])
        assertOneNoteWindow(app, "shortcut")
    }

    /// The same from the note list's context menu.
    @MainActor
    func testTheContextMenuOpensANoteWindow() throws {
        let app = launch()
        defer { app.terminate() }
        // The note list's row (the open note's title is also in the canvas toolbar).
        let row = app.cells.containing(NSPredicate(format: "label == %@", "Cellular Respiration")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        let item = app.menuItems["Open in New Window"].firstMatch
        // The list may still be settling when the first click lands: try again a couple of times.
        for _ in 0..<3 where !item.exists {
            row.rightClick()
            if item.waitForExistence(timeout: 5) { break }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(item.exists, "the context menu offers a new window")
        item.click()
        assertOneNoteWindow(app, "context menu")
    }

    /// A double-click on a row of the note list opens the note in its own
    /// window, as the context menu does (TestFlight build 7: it did nothing).
    @MainActor
    func testADoubleClickOpensANoteWindow() throws {
        let app = launch()
        defer { app.terminate() }
        let row = app.cells.containing(NSPredicate(format: "label == %@", "Cellular Respiration")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.doubleClick()
        assertOneNoteWindow(app, "double-click")
    }

    /// The File menu has no system New Window or Open… beside the app's commands.
    @MainActor
    func testTheFileMenuHasNoSystemDuplicates() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        let file = app.menuBars.menuBarItems["File"]
        file.click()
        let titles = file.menuItems.allElementsBoundByIndex.map(\.title)
        let identifiers = file.menuItems.allElementsBoundByIndex.map(\.identifier)
        print("MACUIDEBUG file menu: \(titles) \(identifiers)")
        for menu in ["Edit", "View", "Note", "Tools"] {
            let items = app.menuBars.menuBarItems[menu].menuItems.allElementsBoundByIndex.map(\.title)
            print("MACUIDEBUG \(menu) menu: \(items)")
        }
        XCTAssertTrue(titles.contains("New Note…"))
        XCTAssertTrue(titles.contains("Open Vault…"))
        XCTAssertTrue(titles.contains("Open Note in New Window"))
        // Build 7: import, insert and export, the same paths as the toolbars.
        for title in ["Import PDF as New Note…", "Import from Notability…", "Insert PDF Pages…", "Insert Photo…", "Export…"] {
            XCTAssertTrue(titles.contains(title), "File has \(title): \(titles)")
        }
        XCTAssertEqual(titles.filter { $0 == "Export…" }.count, 1, "one Export… item")
        XCTAssertFalse(titles.contains("Export"), "not the iPad's Export submenu too (Export to Folder or Zip… is the bulk export, #109)")
        XCTAssertFalse(identifiers.contains("new_window"), "no system New Window")
        XCTAssertFalse(identifiers.contains("duplicate:"), "no document commands")
        XCTAssertFalse(identifiers.contains("open:"), "no system Open…")
        XCTAssertEqual(titles.filter { $0 == "Open Recent" }.count, 1, "one Open Recent")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let edit = app.menuBars.menuBarItems["Edit"]
        edit.click()
        let editTitles = edit.menuItems.allElementsBoundByIndex.map(\.title)
        XCTAssertTrue(editTitles.contains("Find Notes"), "\(editTitles)")
        XCTAssertFalse(editTitles.contains("Find…"), "no system Find")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    @MainActor
    private func assertOneNoteWindow(_ app: XCUIApplication, _ how: String) {
        let opened = app.descendants(matching: .any)["noteWindow"].waitForExistence(timeout: 20)
        if !opened { dump(app, how) }
        XCTAssertTrue(opened, "\(how): a note window opened")
        let libraries = app.descendants(matching: .any).matching(identifier: "libraryWindow").count
        XCTAssertEqual(libraries, 1, "\(how): one library window (windows: \(app.windows.count))")
    }

    /// PDF pages reach the screen on a Mac (TestFlight build 6: blank): a PDF
    /// imported through the app (`SEMPERE_DEMO_PDF`, red squares at the pages'
    /// top-left) is opened on the canvas, and the window shows red.
    @MainActor
    func testPDFPagesAreDrawnOnTheCanvas() throws {
        let app = launch(extra: ["SEMPERE_DEMO_PDF": "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Demo PDF"].firstMatch.waitForExistence(timeout: 60), "the PDF note opened")
        var red = 0
        for _ in 0..<10 {   // tiles are drawn asynchronously
            Thread.sleep(forTimeInterval: 2)
            red = Self.redPixels(app.windows.firstMatch.screenshot().pngRepresentation)
            if red > 2000 { break }
        }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "pdf-canvas"
        shot.lifetime = .keepAlways
        add(shot)
        print("MACUIDEBUG pdf red pixels: \(red)")
        XCTAssertGreaterThan(red, 2000, "the PDF page's red square is on screen")
    }

    /// A mouse drag on the canvas draws a stroke (docs/mac.md "Mouse and
    /// trackpad"): with "Smooth Mouse Strokes" at its default (Light) the app,
    /// not PencilKit, draws pointer strokes, so this fails if its gesture never
    /// gets the drag. The pen is picked first (the app tests, which share this
    /// container, leave PencilKit's saved palette on another tool), the drags
    /// go inside the visible part of a page's canvas, and the pixels that
    /// changed there are counted.
    @MainActor
    func testAMouseDragDrawsASmoothedStroke() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        let window = app.windows.firstMatch
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        XCTAssertTrue(canvases.firstMatch.waitForExistence(timeout: 30), "a page canvas")
        app.typeKey("1", modifierFlags: [.command, .option])   // Tools > Pen
        Thread.sleep(forTimeInterval: 3)   // the page's ink and tiles settle
        // The largest visible part of a page canvas, in screen points.
        let frame = window.frame
        var visible: CGRect?
        for element in canvases.allElementsBoundByIndex {
            let part: CGRect = element.frame.intersection(frame)
            guard !part.isNull, part.width > 100, part.height > 100 else { continue }
            let size: CGFloat = part.width * part.height
            if let best = visible, best.width * best.height >= size { continue }
            visible = part
        }
        guard let area = visible else {
            dump(app, "mouse-stroke")
            XCTFail("no page canvas on screen")
            return
        }
        print("MACUIDEBUG mouse stroke window \(frame) canvas \(area)")
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let left: CGFloat = area.minX - frame.minX
        let top: CGFloat = area.minY - frame.minY
        func at(_ fx: CGFloat, _ fy: CGFloat) -> XCUICoordinate {
            let dx: CGFloat = left + area.width * fx
            let dy: CGFloat = top + area.height * fy
            return origin.withOffset(CGVector(dx: dx, dy: dy))
        }
        let before = window.screenshot().pngRepresentation
        at(0.2, 0.55).press(forDuration: 0.1, thenDragTo: at(0.8, 0.6), withVelocity: 300, thenHoldForDuration: 0.1)
        at(0.8, 0.65).press(forDuration: 0.1, thenDragTo: at(0.2, 0.7), withVelocity: 300, thenHoldForDuration: 0.1)
        var changed = 0
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 1)
            changed = Self.changedPixels(before, window.screenshot().pngRepresentation)
            if changed > 300 { break }
        }
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "mouse-stroke"
        shot.lifetime = .keepAlways
        add(shot)
        print("MACUIDEBUG mouse stroke changed pixels: \(changed)")
        XCTAssertGreaterThan(changed, 300, "the two drags drew ink")
    }

    /// RGBA pixels of a PNG, with its width and height.
    static func pixels(_ png: Data) -> (data: [UInt8], w: Int, h: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (data, w, h) : nil
    }

    /// Pixels that differ clearly between two screenshots of one size.
    static func changedPixels(_ a: Data, _ b: Data) -> Int {
        guard let p = pixels(a), let q = pixels(b), p.w == q.w, p.h == q.h else { return 0 }
        var count = 0
        for i in stride(from: 0, to: p.data.count, by: 4) {
            let r: Int = abs(Int(p.data[i]) - Int(q.data[i]))
            let g: Int = abs(Int(p.data[i + 1]) - Int(q.data[i + 1]))
            let b: Int = abs(Int(p.data[i + 2]) - Int(q.data[i + 2]))
            if max(r, g, b) > 60 { count += 1 }
        }
        return count
    }

    /// Pixels that are clearly red (the PDF's squares; nothing else in the demo is).
    static func redPixels(_ png: Data) -> Int {
        // From the PNG: on a Mac the screenshot's image is an NSImage behind a UIImage type.
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return 0 }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) where p[i] > 200 && p[i + 1] < 70 && p[i + 2] < 70 { count += 1 }
        return count
    }

    /// ⌘, opens the app's Settings (TestFlight build 7: Catalyst's generated
    /// pane with touch alternatives only), and the app menu has one Settings….
    @MainActor
    func testCommandCommaOpensTheAppsSettings() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        app.typeKey(",", modifierFlags: .command)
        let opened = app.descendants(matching: .any)["settingsForm"].waitForExistence(timeout: 20)
        if !opened { dump(app, "settings") }
        XCTAssertTrue(opened, "the app's Settings window opened")
        XCTAssertFalse(app.staticTexts["Touch Alternatives"].exists, "not Catalyst's generated pane")
    }

    /// The new-note sheet's notebook field lists matching notebooks while typing.
    @MainActor
    func testNewNoteSheetSuggestsNotebooks() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        app.typeKey("n", modifierFlags: .command)   // File > New Note…
        let field = app.textFields["notebookField"]
        let found = field.waitForExistence(timeout: 20)
        if !found { dump(app, "new-note-sheet") }
        XCTAssertTrue(found, "the notebook field")
        guard found else { return }
        field.click()
        field.typeText("Phys")
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Physics")).firstMatch
        let shown = suggestion.waitForExistence(timeout: 10)
        if !shown { dump(app, "new-note") }
        XCTAssertTrue(shown, "School › Physics is suggested")
        // The chevron opens the whole list without typing.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        let toggle = app.buttons["notebookChoices"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the notebook list button")
        toggle.click()
        // The first notebooks in order (the list shows eight), on screen: the sheet scrolled them into view.
        let first = app.buttons["Personal"].firstMatch
        let listed = first.waitForExistence(timeout: 10)
        if !listed { dump(app, "new-note-list") }
        XCTAssertTrue(listed, "the chevron lists the notebooks")
        // Every row shown is inside the sheet's window (XCUI's isHittable is unreliable in Mac sheets).
        let sheet = app.windows.containing(.textField, identifier: "notebookField").firstMatch.frame
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Personal", "School"))
            .allElementsBoundByIndex
        let visible = !rows.isEmpty && rows.allSatisfy { $0.frame.maxY <= sheet.maxY + 0.5 }
        if !visible { print("MACUIDEBUG sheet \(sheet) rows \(rows.map(\.frame))") }
        XCTAssertTrue(visible, "the list is inside the sheet's window")
    }
}
