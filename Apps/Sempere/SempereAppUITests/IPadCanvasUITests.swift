import XCTest

/// The canvas with a finger on the iPad (TestFlight 1.0.0, the owner's iPad): a tap selects an
/// item and shows no menu; a held finger shows the item's menu, not PencilKit's "Select All /
/// Insert Space" bar; a tap elsewhere dismisses it; the selection's bar deletes; the text tool
/// places one box and goes back; an audio card is selected, not played, by a tap; a tap on the
/// canvas brings the palette back. (The pinch detent is tested on the stack itself,
/// `IPadCanvasTests.aPinchOnThePagesSettlesOnTheFit`: XCTest's synthesized pinch does not reach
/// the page stack on the simulator.) The demo vault's
/// "thoughts" note has a text box, an image, an equation and an audio card (`SEMPERE_DEMO_ITEMS`),
/// and its canvas reports them, the selection, whether a menu or the selection bar is up and
/// whether it has the palette (`ItemSelectionController.debugReport`).
/// Run by `scripts/app.sh test-ui -only-testing:SempereAppUITests/IPadCanvasUITests`; skipped on a Mac.
final class IPadCanvasUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPad only")
        #endif
        continueAfterFailure = false
    }

    /// What the canvas reports (`debugReport`).
    struct Report {
        var zoom: CGFloat = 1
        var offset = CGPoint.zero
        var edits = 0
        var selected = "none"
        var menu = false
        var bar = false
        /// The selection bar's frame, canvas content points.
        var barFrame = CGRect.zero
        var menus = 0
        var palette = false
        /// How many strokes the page's ink has.
        var strokes = 0
        var typing: String?
        var items: [(kind: String, frame: CGRect)] = []

        init?(_ value: String) {
            guard value.hasPrefix("zoom=") else { return nil }
            var rest = Substring(value)
            if let r = value.range(of: ";typing=") {
                typing = String(value[r.upperBound...])
                rest = value[..<r.lowerBound]
            }
            for field in rest.split(separator: ";", omittingEmptySubsequences: false) {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let v = pair[1]
                switch pair[0] {
                case "zoom": zoom = CGFloat(Double(v) ?? 1)
                case "offset":
                    let c = v.split(separator: ",").compactMap { Double($0) }
                    if c.count == 2 { offset = CGPoint(x: c[0], y: c[1]) }
                case "edits": edits = Int(v) ?? 0
                case "selected": selected = v
                case "menu": menu = v == "1"
                case "bar": bar = v == "1"
                case "menus": menus = Int(v) ?? 0
                case "barFrame":
                    let c = v.split(separator: ",").compactMap { Double($0) }
                    if c.count == 4 { barFrame = CGRect(x: c[0], y: c[1], width: c[2], height: c[3]) }
                case "palette": palette = v == "1"
                case "strokes": strokes = Int(v) ?? 0
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

    @MainActor
    private func launch(columns: String = "detailOnly", pencilOnly: Bool = true, landscape: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": columns, "SEMPERE_DEMO_NOTE": "thoughts",
                   "SEMPERE_DEMO_ITEMS": "1", "TZ": "UTC"]
        if pencilOnly { env["SEMPERE_DEBUG_PENCIL_ONLY"] = "1" }
        app.launchEnvironment = env
        // Portrait: the page is narrower, so every demo item is on screen at the fitted width.
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        #endif
        app.launch()
        return app
    }

    /// The page canvas whose report lists an item of `kind`.
    @MainActor
    private func canvas(_ app: XCUIApplication, holding kind: String = "image") -> XCUIElement? {
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        for _ in 0..<60 {
            for element in canvases.allElementsBoundByIndex {
                if let r = report(element), r.frame(kind) != nil { return element }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    @MainActor
    private func report(_ canvas: XCUIElement) -> Report? {
        (canvas.value as? String).flatMap(Report.init)
    }

    /// The screen coordinate of page point `p` on `canvas`.
    @MainActor
    private func point(_ p: CGPoint, on canvas: XCUIElement, _ r: Report, app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let f = canvas.frame
        return origin.withOffset(CGVector(dx: f.minX - window.frame.minX + p.x * r.zoom - r.offset.x,
                                          dy: f.minY - window.frame.minY + p.y * r.zoom - r.offset.y))
    }

    /// The screen coordinate of canvas content point `p` (screen points of the canvas's content).
    @MainActor
    private func canvasPoint(_ p: CGPoint, on canvas: XCUIElement, _ r: Report, app: XCUIApplication) -> XCUICoordinate {
        point(CGPoint(x: p.x / r.zoom, y: p.y / r.zoom), on: canvas, r, app: app)
    }

    /// The middle of item `kind` on screen.
    @MainActor
    private func middle(of kind: String, on canvas: XCUIElement, app: XCUIApplication) -> XCUICoordinate? {
        guard let r = report(canvas), let f = r.frame(kind) else { return nil }
        return point(CGPoint(x: f.midX, y: f.midY), on: canvas, r, app: app)
    }

    @MainActor
    @discardableResult
    private func waitReport(_ canvas: XCUIElement, _ what: String, timeout: TimeInterval = 6,
                            _ ok: (Report) -> Bool) -> Report? {
        let end = Date().addingTimeInterval(timeout)
        var last: Report?
        while Date() < end {
            last = report(canvas)
            if let r = last, ok(r) { return r }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("\(what): canvas reports \(String(describing: canvas.value))")
        return nil
    }

    /// The toolbar toggle titled `title` (Select, Text).
    @MainActor
    private func toolbarToggle(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let candidates = [app.buttons[title], app.switches[title], app.toggles[title]]
        for c in candidates where c.firstMatch.waitForExistence(timeout: 2) { return c.firstMatch }
        return app.buttons[title].firstMatch
    }

    /// Whether PencilKit's own edit bar is up.
    @MainActor
    private func systemCanvasMenuShown(_ app: XCUIApplication) -> Bool {
        let tree = app.debugDescription.split(separator: "\n")
            .filter { $0.contains("Select All") || $0.contains("Insert Space") || $0.contains("Duplicate") || $0.contains("MenuItem") }
        print("MENUTREE\n" + tree.prefix(30).joined(separator: "\n"))
        return ["Insert Space", "Select All"].contains { title in
            app.menuItems[title].exists || app.buttons[title].exists || app.staticTexts[title].exists
        }
    }

    /// An empty spot of the page, left of the equation and under the text box.
    private static let emptySpot = CGPoint(x: 120, y: 600)

    // MARK: Tests

    /// Selection mode: a tap selects with no menu and shows the bar; a held finger shows the
    /// item's menu (with Delete) and not PencilKit's; a tap on the empty page dismisses it.
    @MainActor
    func testATapSelectsAndAHoldShowsTheItemMenu() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        toolbarToggle(app, "Select").tap()
        Thread.sleep(forTimeInterval: 1)
        guard let image = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image.tap()
        waitReport(canvas, "a tap selects without a menu") { $0.selected == "image" && $0.bar }
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(report(canvas)?.menu, false, "a tap shows no menu")
        XCTAssertGreaterThan(report(canvas)?.barFrame.width ?? 0, 0, "the selection bar is up")

        image.press(forDuration: 1.0)
        _ = systemCanvasMenuShown(app)
        waitReport(canvas, "a held finger shows the item's menu") { $0.menu && $0.selected == "image" }
        XCTAssertFalse(systemCanvasMenuShown(app), "not PencilKit's Select All / Insert Space")

        guard let r = report(canvas) else { return }
        point(Self.emptySpot, on: canvas, r, app: app).tap()
        waitReport(canvas, "a tap elsewhere dismisses the menu and the selection") { !$0.menu && $0.selected == "none" }
    }

    /// Drawing (a paired Pencil: fingers do not draw): a held finger on an item shows its menu, not
    /// PencilKit's bar; a finger tap on the audio card selects it and plays nothing.
    @MainActor
    func testWhileDrawingAHoldShowsTheItemMenuAndATapSelects() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        guard let image = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image.press(forDuration: 1.0)
        waitReport(canvas, "a held finger picks the image with its menu") { $0.selected == "image" && $0.menu }
        XCTAssertFalse(systemCanvasMenuShown(app), "not PencilKit's Select All / Insert Space")
        guard let r = report(canvas) else { return }
        point(Self.emptySpot, on: canvas, r, app: app).tap()
        waitReport(canvas, "a tap beside it drops it") { $0.selected == "none" && !$0.menu }

        guard let card = middle(of: "audio", on: canvas, app: app) else { return XCTFail("no audio card") }
        card.tap()
        waitReport(canvas, "a tap selects the card") { $0.selected == "audio" }
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(report(canvas)?.menu, false, "no menu on a tap")
        XCTAssertFalse(app.descendants(matching: .any)["playerBar"].exists, "a tap does not play")
    }

    /// The selection bar's Delete deletes the item: one delta.
    @MainActor
    func testTheSelectionBarDeletes() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        toolbarToggle(app, "Select").tap()
        Thread.sleep(forTimeInterval: 1)
        middle(of: "math", on: canvas, app: app)?.tap()
        guard let r1 = waitReport(canvas, "the equation is selected", { $0.selected == "math" && $0.bar }) else { return }
        // The bar is inside the canvas, which lists only its strokes to accessibility: aim at its Delete (the right half).
        let bar = r1.barFrame
        canvasPoint(CGPoint(x: bar.maxX - bar.height / 2, y: bar.midY), on: canvas, r1, app: app).tap()
        guard let r2 = waitReport(canvas, "Delete removes it", { $0.frame("math") == nil }) else { return }
        XCTAssertEqual(r2.edits, r1.edits + 1, "one delta")
        XCTAssertEqual(r2.selected, "none")
    }

    /// The text tool places one box, then the canvas goes back: the next tap on the page makes no
    /// second box.
    @MainActor
    func testTheTextToolPlacesOneBox() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        let textBoxes = report(canvas)?.items.filter { $0.kind == "text" }.count ?? 0
        toolbarToggle(app, "Text").tap()
        Thread.sleep(forTimeInterval: 1)
        guard let r0 = report(canvas) else { return }
        point(Self.emptySpot, on: canvas, r0, app: app).tap()
        waitReport(canvas, "a new box is being typed in") { $0.typing != nil }
        // (The text view is inside the canvas, out of the accessibility tree: XCTest cannot type into it.)
        // A tap elsewhere ends the box; the tool is done, typed in or not. Above the box: the
        // software keyboard, when the simulator shows one, covers the bottom of the page.
        point(CGPoint(x: 500, y: 110), on: canvas, r0, app: app).tap()
        waitReport(canvas, "the box's edit ended", timeout: 10) { $0.typing == nil }
        XCTAssertEqual(report(canvas)?.items.filter { $0.kind == "text" }.count, textBoxes, "an empty box writes nothing")
        Thread.sleep(forTimeInterval: 1)
        guard let r1 = report(canvas) else { return }
        point(CGPoint(x: 520, y: 170), on: canvas, r1, app: app).tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertNil(report(canvas)?.typing, "the text tool was one-shot: no second box")
    }

    /// The note list takes the focus; a tap on the canvas brings the palette back.
    @MainActor
    func testATapOnTheCanvasBringsThePaletteBack() throws {
        let app = launch(columns: "all", landscape: true)
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        let row = app.staticTexts.matching(NSPredicate(format: "label == %@", "Quick thoughts")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        Thread.sleep(forTimeInterval: 1.5)
        print("PALETTE after the list took the tap: \(String(describing: report(canvas)?.palette))")
        guard let r = report(canvas) else { return }
        point(CGPoint(x: 120, y: 160), on: canvas, r, app: app).tap()
        waitReport(canvas, "the palette is back") { $0.palette }
    }
}
