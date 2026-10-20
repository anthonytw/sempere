import XCTest

/// Sempere's own drawing palette (`DrawingPaletteView`), on the iPad, the iPhone and the Mac: it shows only
/// while annotating; a color and a width picked in it are the next stroke's ink; the object and pixel
/// erasers and the lasso reach the canvas; the compact and the full palette. The demo vault's "thoughts"
/// note (paged, with a picture: `SEMPERE_DEMO_ITEMS`), whose canvases report their tool, their last stroke's
/// ink and their stroke count (`PageCanvasHost.debugToolReport`).
///
/// Run by `scripts/app.sh test-ui|test-phone-ui -only-testing:SempereAppUITests/DrawingPaletteUITests` and
/// `scripts/app.sh test-mac-ui -only-testing:SempereAppUITests/DrawingPaletteUITests`.
/// `TEST_RUNNER_SEMPERE_PALETTE_SHOTS=<dir>` also writes a screenshot of each palette there.
final class DrawingPaletteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    struct Report {
        var zoom: CGFloat = 1
        var offset = CGPoint.zero
        var width: CGFloat = 0
        var palette = false
        var strokes = 0
        var tool = ""
        var lastInk = ""
        var items: [(kind: String, frame: CGRect)] = []

        init?(_ value: String) {
            guard value.hasPrefix("zoom=") else { return nil }
            var rest = Substring(value)
            if let r = value.range(of: ";typing=") { rest = value[..<r.lowerBound] }
            for field in rest.split(separator: ";", omittingEmptySubsequences: false) {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let v = pair[1]
                switch pair[0] {
                case "zoom": zoom = CGFloat(Double(v) ?? 1)
                case "offset":
                    let c = v.split(separator: ",").compactMap { Double($0) }
                    if c.count == 2 { offset = CGPoint(x: c[0], y: c[1]) }
                case "width": width = CGFloat(Double(v) ?? 0)
                case "palette": palette = v == "1"
                case "strokes": strokes = Int(v) ?? 0
                case "tool": tool = v
                case "lastInk": lastInk = v
                case "items":
                    items = v.split(separator: "|").compactMap { entry in
                        let parts = entry.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2 else { return nil }
                        let c = parts[1].split(separator: ",").compactMap { Double($0) }
                        guard c.count == 5 else { return nil }
                        return (String(parts[0]), CGRect(x: c[0], y: c[1], width: c[2], height: c[3]))
                    }
                default: break
                }
            }
        }

        func frame(_ kind: String) -> CGRect? { items.first { $0.kind == kind }?.frame }
    }

    private static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    @MainActor
    private func launch(annotating: Bool, compact: Bool = false, keepTools: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES",
                               "-Sempere.paletteCompact", compact ? "YES" : "NO"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_NOTE": "thoughts",
                   "SEMPERE_DEMO_ITEMS": "1", "SEMPERE_DEMO_MAC_WINDOW": "1000x900", "SEMPERE_DEBUG_FINGERS_DRAW": "1",
                   "TZ": "UTC"]
        if annotating { env["SEMPERE_DEBUG_NOTE_MODE"] = "annotate" }
        if keepTools { env["SEMPERE_DEMO_KEEP_TOOLS"] = "1" }   // a relaunch: the tools the last launch picked
        app.launchEnvironment = env
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
        return app
    }

    @MainActor
    private func palette(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A tool's button in the palette, by its label ("Pen", "Marker", "Object Eraser" …).
    @MainActor
    private func toolButton(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        palette(app).buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    @MainActor
    private func press(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func canvas(_ app: XCUIApplication) -> XCUIElement? {
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        // A fresh simulator clone's first launch builds the demo vault for a while: wait for a canvas first
        // (`waitForExistence` rides out a busy main thread; listing the elements fails on one).
        _ = canvases.firstMatch.waitForExistence(timeout: 120)
        for _ in 0..<60 {
            for element in canvases.allElementsBoundByIndex {
                if let r = report(element), r.frame("image") != nil { return element }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    @MainActor
    private func report(_ canvas: XCUIElement) -> Report? { (canvas.value as? String).flatMap(Report.init) }

    @MainActor
    @discardableResult
    private func waitReport(_ canvas: XCUIElement, _ what: String, timeout: TimeInterval = 8,
                            _ ok: (Report) -> Bool) -> Report? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = report(canvas), ok(r) { return r }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("\(what): canvas reports \(String(describing: canvas.value))")
        return nil
    }

    /// The screen coordinate of page point `p` (a Catalyst app in the iPad idiom is drawn at 77 %: `width`).
    @MainActor
    private func point(_ p: CGPoint, on canvas: XCUIElement, _ r: Report, app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let f = canvas.frame
        let s = r.width > 0 ? f.width / r.width : 1
        return origin.withOffset(CGVector(dx: f.minX - window.frame.minX + (p.x * r.zoom - r.offset.x) * s,
                                          dy: f.minY - window.frame.minY + (p.y * r.zoom - r.offset.y) * s))
    }

    @MainActor
    private func drag(from a: XCUICoordinate, to b: XCUICoordinate) {
        #if targetEnvironment(macCatalyst)
        a.click(forDuration: 0.15, thenDragTo: b, withVelocity: 300, thenHoldForDuration: 0.15)
        #else
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: 300, thenHoldForDuration: 0.1)
        #endif
        Thread.sleep(forTimeInterval: 1)
    }

    /// Where the tests draw: the empty page below the picture (page points).
    private func strokeStart(_ r: Report) -> CGPoint? {
        guard let f = r.frame("image") else { return nil }
        return CGPoint(x: f.minX + 10, y: f.maxY + 40)
    }

    /// Shows the selected tool's choices when they are not on screen (the compact palette's popover).
    @MainActor
    private func showChoices(_ app: XCUIApplication, needing id: String) {
        let wanted = element(app, id)
        if wanted.exists, wanted.isHittable { return }
        let choices = element(app, "palette.choices")
        XCTAssertTrue(choices.waitForExistence(timeout: 5), "the compact palette's choices button")
        press(choices)
        XCTAssertTrue(wanted.waitForExistence(timeout: 5), "\(id) in the choices: \(app.debugDescription.prefix(3000))")
    }

    /// Puts the choices' popover away (a compact palette).
    @MainActor
    private func hideChoices(_ app: XCUIApplication) {
        let panel = element(app, "palette.choicesPanel")
        guard panel.exists else { return }
        #if targetEnvironment(macCatalyst)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        #else
        // A tap outside the popover dismisses it: on the button that opened it (a full palette's inline choices
        // have no such button: the selected tool's button then).
        let choices = element(app, "palette.choices")
        if choices.exists, choices.isHittable {
            choices.tap()
        } else {
            palette(app).buttons.matching(NSPredicate(format: "selected == true")).firstMatch.tap()
        }
        #endif
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "the choices went away")
    }

    /// Picks the tool labeled `labels` unless it is the palette's tool already (a tap on the selected tool
    /// shows its choices instead).
    @MainActor
    private func pick(_ app: XCUIApplication, _ labels: [String], canvas: XCUIElement, reports prefix: String) {
        let button = toolButton(app, labels)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(labels) in the palette: \(palette(app).debugDescription.prefix(3000))")
        if report(canvas)?.tool.hasPrefix(prefix) != true { press(button) }
        waitReport(canvas, "\(labels) picked") { $0.tool.hasPrefix(prefix) }
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        // On a Mac only the app's window (the screen shows whatever else is open).
        let shot = Self.isMac ? app.windows.firstMatch.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SEMPERE_PALETTE_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private var device: String {
        #if targetEnvironment(macCatalyst)
        "mac"
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad"
        #endif
    }

    // MARK: Tests

    /// The palette is Annotate's: it shows with the pencil, and neither while reading nor with the Hand.
    @MainActor
    func testThePaletteShowsOnlyWhileAnnotating() throws {
        let app = launch(annotating: false)
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        let annotate = element(app, "annotateButton"), hand = element(app, "handButton")
        XCTAssertTrue(annotate.waitForExistence(timeout: 10) && hand.exists)
        XCTAssertFalse(palette(app).exists, "reading: no palette")
        for round in 1...2 {
            press(annotate)
            XCTAssertTrue(palette(app).waitForExistence(timeout: 8), "\(round): Annotate shows the palette")
            waitReport(canvas, "\(round): the canvas has the palette's tool") { !$0.tool.isEmpty }
            press(hand)
            XCTAssertTrue(palette(app).waitForNonExistence(timeout: 8), "\(round): the Hand puts it away")
            press(annotate)
            XCTAssertTrue(palette(app).waitForExistence(timeout: 8), "\(round): from the Hand straight to Annotate")
            press(annotate)
            XCTAssertTrue(palette(app).waitForNonExistence(timeout: 8), "\(round): reading puts it away")
        }
    }

    /// A color and a width picked in the palette are what the next stroke is drawn with.
    @MainActor
    func testAColorAndAWidthReachTheStroke() throws {
        let app = launch(annotating: true)
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        XCTAssertTrue(palette(app).waitForExistence(timeout: 10), "annotating: the palette")
        pick(app, ["Pen"], canvas: canvas, reports: "pen:")
        showChoices(app, needing: "palette.swatch.3")
        press(element(app, "palette.swatch.3"))   // red
        press(element(app, "palette.width.4"))    // the widest
        shoot(app, "palette-\(device)-pen-choices")
        hideChoices(app)
        guard let r0 = waitReport(canvas, "the pen is red and wide", { $0.tool == "pen:#FF3B30FF:10.0" }),
              let a = strokeStart(r0) else { return }
        drag(from: point(a, on: canvas, r0, app: app), to: point(CGPoint(x: a.x + 120, y: a.y + 20), on: canvas, r0, app: app))
        waitReport(canvas, "one red pen stroke") { $0.strokes == r0.strokes + 1 && $0.lastInk == "pen:#FF3B30FF" }

        // Another tool keeps its own color: the marker is not red.
        pick(app, ["Marker"], canvas: canvas, reports: "marker:")
        XCTAssertFalse(report(canvas)?.tool.hasPrefix("marker:#FF3B30") ?? true, "the marker kept its own color")
        shoot(app, "palette-\(device)-marker")
    }

    /// The object eraser takes a whole stroke; the pixel eraser and the lasso reach the canvas.
    @MainActor
    func testTheErasersAndTheLasso() throws {
        let app = launch(annotating: true)
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        XCTAssertTrue(palette(app).waitForExistence(timeout: 10), "annotating: the palette")
        pick(app, ["Pen"], canvas: canvas, reports: "pen:")
        guard let r0 = report(canvas), let a = strokeStart(r0) else { return XCTFail("no report") }
        drag(from: point(a, on: canvas, r0, app: app), to: point(CGPoint(x: a.x + 120, y: a.y), on: canvas, r0, app: app))
        guard let r1 = waitReport(canvas, "a stroke to erase", { $0.strokes == r0.strokes + 1 }) else { return }

        // The object eraser.
        let erasers = ["Object Eraser", "Pixel Eraser"]
        pick(app, erasers, canvas: canvas, reports: "eraser.")
        showChoices(app, needing: "palette.eraser.object")
        press(element(app, "palette.eraser.object"))
        waitReport(canvas, "the object eraser") { $0.tool == "eraser.object" }
        shoot(app, "palette-\(device)-eraser")
        hideChoices(app)
        guard let r2 = report(canvas) else { return }
        drag(from: point(CGPoint(x: a.x + 60, y: a.y - 30), on: canvas, r2, app: app),
             to: point(CGPoint(x: a.x + 60, y: a.y + 30), on: canvas, r2, app: app))
        waitReport(canvas, "the object eraser took the stroke") { $0.strokes == r1.strokes - 1 }

        // The pixel eraser.
        showChoices(app, needing: "palette.eraser.pixel")
        press(element(app, "palette.eraser.pixel"))
        waitReport(canvas, "the pixel eraser") { $0.tool.hasPrefix("eraser.pixel:") }
        XCTAssertTrue(toolButton(app, ["Pixel Eraser"]).exists, "the palette's eraser says which")
        hideChoices(app)
        // Back to the object eraser for whoever runs next (the mode is remembered).
        showChoices(app, needing: "palette.eraser.object")
        press(element(app, "palette.eraser.object"))
        waitReport(canvas, "the object eraser again") { $0.tool == "eraser.object" }
        hideChoices(app)

        // The lasso.
        pick(app, ["Lasso"], canvas: canvas, reports: "lasso")
        XCTAssertFalse(element(app, "palette.choices").exists, "the lasso has no choices")
        pick(app, ["Pen"], canvas: canvas, reports: "pen:")
    }

    /// The full palette lists every tool; the compact one pen, marker, eraser and lasso. An iPhone's is
    /// always the compact one.
    @MainActor
    func testTheCompactAndTheFullPalette() throws {
        let isPhone: Bool = {
            #if targetEnvironment(macCatalyst)
            false
            #else
            UIDevice.current.userInterfaceIdiom == .phone
            #endif
        }()
        for compact in [false, true] {
            let app = launch(annotating: true, compact: compact)
            guard canvas(app) != nil else { app.terminate(); return XCTFail("no canvas") }
            XCTAssertTrue(palette(app).waitForExistence(timeout: 10))
            for tool in ["Pen", "Marker", "Lasso"] {
                XCTAssertTrue(palette(app).buttons[tool].exists, "\(tool), compact \(compact)")
            }
            XCTAssertTrue(toolButton(app, ["Object Eraser", "Pixel Eraser"]).exists)
            let full = !compact && !isPhone
            XCTAssertEqual(palette(app).buttons["Fountain Pen"].exists, full,
                           "compact \(compact): \(palette(app).debugDescription.prefix(2000))")
            XCTAssertEqual(palette(app).buttons["Ruler"].exists, full)
            XCTAssertFalse(palette(app).buttons["Hand"].exists, "no Hand in any palette")
            shoot(app, "palette-\(device)-\(full ? "full" : "compact")")
            app.terminate()
        }
    }

    /// Owner, PR #51: "Every tool should remember its last settings." On the iPad: a width set with the slider (not a
    /// preset) and a custom color from the system color picker, then another tool, a relaunch, the pen again: the pen
    /// is exactly as it was, and a stroke is drawn with that ink.
    @MainActor
    func testThePenKeepsASliderWidthAndACustomColorAcrossARelaunch() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPad: the system color picker's iPad layout")
        #else
        if UIDevice.current.userInterfaceIdiom == .phone { throw XCTSkip("iPad: the system color picker's iPad layout") }
        var app = launch(annotating: true)
        guard var canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        XCTAssertTrue(palette(app).waitForExistence(timeout: 10))
        pick(app, ["Pen"], canvas: canvas, reports: "pen:")

        // A width from the slider.
        showChoices(app, needing: "palette.widthSlider")
        let slider = app.sliders["palette.widthSlider"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "the width slider")
        slider.adjust(toNormalizedSliderPosition: 0.37)
        guard let widened = waitReport(canvas, "the slider set the pen's width", { $0.tool.hasPrefix("pen:") && !$0.tool.hasSuffix(":2.7") })
        else { return }
        let width = widened.tool.split(separator: ":").last.map(String.init) ?? ""
        XCTAssertFalse(["1.0", "1.8", "2.7", "5.0", "10.0"].contains(width), "not a preset: \(width)")

        // A custom color: the system picker's spectrum.
        let well = element(app, "palette.colorPicker")
        XCTAssertTrue(well.waitForExistence(timeout: 5), "the color picker")
        well.tap()
        Thread.sleep(forTimeInterval: 2)
        shoot(app, "palette-\(device)-system-picker")
        // The picker's grid: its cells are small squares (labeled in the system's language, so found by size).
        // Read from the tree's description: the picker runs in another process, whose elements a snapshot leaves
        // out and listing them one by one races its updates.
        var cells: [CGRect] = []
        func collect(_ description: String) {
            let pattern = /Other, 0x[0-9a-f]+, \{\{([0-9.]+), ([0-9.]+)\}, \{([0-9.]+), ([0-9.]+)\}\}/
            for match in description.matches(of: pattern) {
                guard let x = Double(match.1), let y = Double(match.2), let w = Double(match.3), let h = Double(match.4),
                      abs(w - h) < 1, w > 20, w < 40 else { continue }
                cells.append(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        // The picker comes up in its own time; a tap that came too early (the popover still settling) brought
        // none up, so the well is tapped again then.
        for attempt in 0..<3 where cells.count <= 20 {
            if attempt > 0, well.exists { well.tap() }
            for _ in 0..<10 where cells.count <= 20 {
                cells = []
                collect(app.debugDescription)
                if cells.count <= 20 { Thread.sleep(forTimeInterval: 0.5) }
            }
        }
        XCTAssertGreaterThan(cells.count, 20, "the system color picker's grid: \(app.debugDescription.suffix(3000))")
        guard cells.count > 20 else { return }
        let cell = cells[cells.count / 2]   // a mid-grid color, none of the palette's swatches
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: cell.midX - window.frame.minX, dy: cell.midY - window.frame.minY)).tap()
        Thread.sleep(forTimeInterval: 1)
        shoot(app, "palette-\(device)-custom-color")
        // Away with the picker's sheet (a swipe down from its top), and the palette's choices if they are up.
        let top = cells.map(\.minY).min() ?? 600
        let window2 = app.windows.firstMatch
        let grab = window2.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window2.frame.width / 2, dy: max(top - 120, 80)))
        grab.press(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: 900)))
        Thread.sleep(forTimeInterval: 1.5)
        hideChoices(app)
        let swatches = ["#000000FF", "#8E8E93FF", "#007AFFFF", "#FF3B30FF", "#34C759FF", "#FF9500FF", "#AF52DEFF", "#FFCC00FF"]
        guard let custom = waitReport(canvas, "a custom color", {
            let color = $0.tool.split(separator: ":").dropFirst().first.map(String.init) ?? ""
            return $0.tool.hasPrefix("pen:") && !swatches.contains(color) && $0.tool.hasSuffix(":" + width)
        }) else { return }
        let penTool = custom.tool
        let penColor = penTool.split(separator: ":")[1]

        // Another tool, then a relaunch that keeps the tools.
        pick(app, ["Marker"], canvas: canvas, reports: "marker:")
        app.terminate()
        app = launch(annotating: true, keepTools: true)
        defer { app.terminate() }
        guard let again = self.canvas(app) else { return XCTFail("no canvas after the relaunch") }
        canvas = again
        XCTAssertTrue(palette(app).waitForExistence(timeout: 10))
        waitReport(canvas, "the marker is still the tool after the relaunch") { $0.tool.hasPrefix("marker:") }
        pick(app, ["Pen"], canvas: canvas, reports: "pen:")
        guard let r0 = waitReport(canvas, "the pen as it was: \(penTool)", { $0.tool == penTool }), let a = strokeStart(r0) else { return }
        drag(from: point(a, on: canvas, r0, app: app), to: point(CGPoint(x: a.x + 120, y: a.y + 20), on: canvas, r0, app: app))
        waitReport(canvas, "a stroke in the remembered ink") { $0.strokes == r0.strokes + 1 && $0.lastInk == "pen:\(penColor)" }
        #endif
    }
}
