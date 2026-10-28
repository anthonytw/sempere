import XCTest

/// The note view's three modes on a Mac (`NoteMode`, docs/mac.md "Reading, Hand and Annotate"): a note opens in
/// reading (the wheel scrolls, a click or a drag selects and draws nothing, no palette); Hand (the top bar's Hand,
/// Tools > Hand ⌥⌘7) selects with a click and moves with a drag; Annotate (the top bar's pencil, Tools > Annotate
/// ⇧⌘P) shows the palette and Drawing Tools, and the mouse draws. The demo vault's "thoughts" note has a picture
/// (`SEMPERE_DEMO_ITEMS`), and the canvas reports its items, selection, strokes and palette
/// (`ItemSelectionController.debugReport`). Run by `scripts/app.sh test-mac-ui
/// -only-testing:SempereAppUITests/MacNoteModeUITests`; skipped on the iPad and the iPhone
/// (`PhoneCanvasModeUITests`).
final class MacNoteModeUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    /// What the canvas reports (`debugReport`).
    struct Report {
        var zoom: CGFloat = 1
        var offset = CGPoint.zero
        var width: CGFloat = 0
        var edits = 0
        var selected = "none"
        var palette = false
        var strokes = 0
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
                case "edits": edits = Int(v) ?? 0
                case "selected": selected = v
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
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_NOTE": "thoughts",
                                 "SEMPERE_DEMO_MAC_WINDOW": "900x900", "SEMPERE_DEMO_ITEMS": "1", "TZ": "UTC"]
        app.launch()
        return app
    }

    @MainActor
    private func canvas(_ app: XCUIApplication) -> XCUIElement? {
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
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

    /// Screen points per canvas point (a Catalyst app in the iPad idiom is drawn at 77 %).
    @MainActor
    private func scale(_ canvas: XCUIElement, _ r: Report) -> CGFloat { r.width > 0 ? canvas.frame.width / r.width : 1 }

    @MainActor
    private func point(_ p: CGPoint, on canvas: XCUIElement, _ r: Report, app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let f = canvas.frame
        let s = scale(canvas, r)
        return origin.withOffset(CGVector(dx: f.minX - window.frame.minX + (p.x * r.zoom - r.offset.x) * s,
                                          dy: f.minY - window.frame.minY + (p.y * r.zoom - r.offset.y) * s))
    }

    @MainActor
    @discardableResult
    private func waitReport(_ canvas: XCUIElement, _ what: String, timeout: TimeInterval = 6,
                            _ ok: (Report) -> Bool) -> Report? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = report(canvas), ok(r) { return r }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("\(what): canvas reports \(String(describing: canvas.value))")
        return nil
    }

    @MainActor
    private func modeButton(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func lit(_ button: XCUIElement) -> Bool {
        button.isSelected || (button.value as? String) == "1" || (button.value as? Int) == 1
    }

    /// A click-drag on the empty page below the picture (a stroke's worth).
    @MainActor
    private func dragOnTheEmptyPage(_ canvas: XCUIElement, _ r: Report, app: XCUIApplication) {
        guard let f = r.frame("image") else { return XCTFail("no picture") }
        let a = point(CGPoint(x: f.minX + 10, y: f.maxY + 40), on: canvas, r, app: app)
        a.click(forDuration: 0.15, thenDragTo: a.withOffset(CGVector(dx: 80, dy: 20)), withVelocity: 300, thenHoldForDuration: 0.15)
        Thread.sleep(forTimeInterval: 1)
    }

    /// Reading → Hand → Annotate → reading, through the top bar's buttons and the Tools menu's keys, each checked
    /// by what the mouse then does.
    @MainActor
    func testReadingHandAndAnnotateWithTheMouse() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        let annotate = modeButton(app, "annotateButton"), hand = modeButton(app, "handButton")
        XCTAssertTrue(annotate.waitForExistence(timeout: 10) && hand.exists, "the two mode buttons are in the top bar")

        // Reading: no palette, a click selects nothing, a drag draws nothing.
        guard let r0 = waitReport(canvas, "opens in reading: no palette", { !$0.palette }), let image = r0.frame("image") else { return }
        XCTAssertFalse(lit(annotate) || lit(hand), "reading: both buttons off")
        point(CGPoint(x: image.midX, y: image.midY), on: canvas, r0, app: app).click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(report(canvas)?.selected, "none", "reading: a click selects nothing")
        dragOnTheEmptyPage(canvas, r0, app: app)
        XCTAssertEqual(report(canvas)?.strokes, r0.strokes, "reading: a drag draws nothing")
        XCTAssertEqual(report(canvas)?.edits, r0.edits, "reading: nothing moved")

        // Hand (the top bar's button): a click selects the picture, a drag moves it, no palette, no ink.
        hand.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(lit(hand), "the Hand is lit")
        guard let r1 = report(canvas) else { return }
        point(CGPoint(x: image.midX, y: image.midY), on: canvas, r1, app: app).click()
        guard let r2 = waitReport(canvas, "Hand: a click selects the picture", { $0.selected == "image" }) else { return }
        Thread.sleep(forTimeInterval: 0.5)
        let start = point(CGPoint(x: image.midX, y: image.midY), on: canvas, r2, app: app)
        start.click(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 30)), withVelocity: 400, thenHoldForDuration: 0.15)
        guard let r3 = waitReport(canvas, "Hand: a drag moves the picture", { ($0.frame("image")?.minX ?? 0) > image.minX + 10 }) else { return }
        XCTAssertEqual(r3.edits, r2.edits + 1, "the move wrote one delta")
        XCTAssertEqual(r3.strokes, r0.strokes, "Hand: nothing draws")
        XCTAssertFalse(r3.palette, "Hand: no palette")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        // Annotate (Tools > Annotate, ⇧⌘P): Drawing Tools, and a drag draws one stroke.
        app.typeKey("p", modifierFlags: [.command, .shift])
        // Sempere's own palette (PencilKit shows none in a Mac Catalyst app, docs/mac.md "The drawing palette").
        guard let r4 = waitReport(canvas, "Annotate: selection off", { $0.selected == "none" }) else { return }
        XCTAssertTrue(lit(annotate) && !lit(hand), "the pencil is lit, the Hand is not")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch.waitForExistence(timeout: 5),
                      "Annotate: the palette")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Drawing Tools")).firstMatch.exists,
                      "Drawing Tools beside Annotate")
        dragOnTheEmptyPage(canvas, r4, app: app)
        waitReport(canvas, "Annotate: a drag draws one stroke") { $0.strokes == r4.strokes + 1 }

        // The pencil again: reading, the palette goes, a drag draws nothing.
        annotate.click()
        guard let r5 = waitReport(canvas, "back to reading: no palette", { !$0.palette }) else { return }
        XCTAssertFalse(lit(annotate) || lit(hand))
        dragOnTheEmptyPage(canvas, r5, app: app)
        XCTAssertEqual(report(canvas)?.strokes, r5.strokes, "reading again: a drag draws nothing")

        // Tools > Hand (⌥⌘7) from reading, and again back to reading.
        app.typeKey("7", modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(lit(hand), "⌥⌘7: Hand")
        app.typeKey("7", modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(lit(hand), "⌥⌘7 again: reading")
    }

    /// The wheel scrolls the paged stack in reading mode.
    @MainActor
    func testTheWheelScrollsWhileReading() throws {
        let app = launch()
        defer { app.terminate() }
        guard canvas(app) != nil else { return XCTFail("no canvas reports the demo items") }
        let stack = app.descendants(matching: .any).matching(identifier: "pageStack").firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 10), "the paged note's stack")
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        let top0 = canvases.allElementsBoundByIndex.map(\.frame.minY).min() ?? 0
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -60)
        Thread.sleep(forTimeInterval: 1)
        let top1 = canvases.allElementsBoundByIndex.map(\.frame.minY).min() ?? 0
        XCTAssertLessThan(top1, top0 - 20, "the wheel scrolls the pages while reading (\(top0) -> \(top1))")
    }
}
