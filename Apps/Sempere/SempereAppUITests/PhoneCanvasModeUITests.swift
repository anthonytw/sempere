import XCTest

/// The note view's three modes on the iPhone and the iPad (`NoteMode`, docs/iphone.md "The note view"): reading
/// (both top-bar buttons off), Hand (the Hand lit) and Annotate (the pencil lit). Every transition, checked by what
/// the canvas then does, not only by the buttons: a slow one-finger drag scrolls or draws (the canvas report's
/// offset and stroke count, `ItemSelectionController.debugReport`), a tap on a picture selects it or not, the
/// palette is up or not. TestFlight build 5 (the owner's iPhone): the Hand turned Annotate on too, the pencil
/// turned off with the Hand on left both buttons off with a finger still drawing, and a moment after Annotate
/// went off a pageless note needed two fingers again (PencilKit's own recount when the palette finished hiding).
/// The iPad runs the same checks since its notes open in reading too (owner, 2026-10-19): the simulator has no
/// Pencil, so its finger draws while annotating as a phone's does, and scrolls and selects in the other modes.
/// (A Pencil touch switching an iPad to Annotate cannot be synthesized: `PencilAnnotatesTests`.)
/// Run by `scripts/app.sh test-phone-ui` on an iPhone and `scripts/app.sh test-ui` on an iPad; skipped on a Mac
/// (`MacNoteModeUITests`).
final class PhoneCanvasModeUITests: XCTestCase {
    typealias Report = IPadCanvasUITests.Report

    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone and iPad")
        #endif
        continueAfterFailure = false
    }

    enum Mode: String { case reading, hand, annotating }

    /// Where the note's first ink element was on screen plus the offset then (`inkAnchor`): the canvas's true
    /// scroll offset follows from where that element is now, whether or not the report was written since.
    private var inkAnchor: CGFloat?

    // MARK: Launch

    @MainActor
    private func launch(note: String = "thoughts") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        // The iPad shows the canvas alone (the phone's stack shows only it anyway).
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_NOTE": note, "SEMPERE_DEMO_ITEMS": "1", "TZ": "UTC",
                                 "SEMPERE_DEBUG_COLUMNS": "detailOnly"]
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
        return app
    }

    /// The demo note with items, switched to pageless (the one-page canvas, whose own scroll PencilKit recounts).
    @MainActor
    private func pagelessCanvas(_ app: XCUIApplication) -> XCUIElement? {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageStack").firstMatch.waitForExistence(timeout: 60))
        let pages = app.buttons["Pages"].firstMatch
        if !pages.waitForExistence(timeout: 5) {
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10), "the overflow menu: \(app.debugDescription.prefix(3000))")
            more.tap()
        }
        XCTAssertTrue(pages.waitForExistence(timeout: 10), "the Pages menu")
        pages.tap()
        let pageless = app.buttons["Switch to Pageless Layout"].firstMatch
        XCTAssertTrue(pageless.waitForExistence(timeout: 10), "the layout switch")
        pageless.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageStack").firstMatch.waitForNonExistence(timeout: 30),
                      "the note is pageless")
        let canvas = app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch
        for _ in 0..<60 {
            if let r = report(canvas), r.frame("image") != nil {
                Thread.sleep(forTimeInterval: 1)
                if let r = report(canvas), let y = inkY(canvas) { inkAnchor = y + r.offset.y }
                return canvas
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    // MARK: Reading the canvas

    @MainActor
    private func report(_ canvas: XCUIElement) -> Report? {
        (canvas.value as? String).flatMap(Report.init)
    }

    @MainActor
    private func raw(_ canvas: XCUIElement) -> String { String(describing: canvas.value) }

    /// The screen y of the note's first ink stroke (PencilKit lists strokes as the canvas's accessibility children).
    @MainActor
    private func inkY(_ canvas: XCUIElement) -> CGFloat? {
        let ink = canvas.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Pen'")).firstMatch
        return ink.exists ? ink.frame.minY : nil
    }

    /// The report with the canvas's true scroll offset (from its ink on screen), for aiming a tap.
    @MainActor
    private func aimed(_ canvas: XCUIElement, _ r: Report) -> Report {
        guard let anchor = inkAnchor, let y = inkY(canvas) else { return r }
        var r = r
        r.offset.y = anchor - y
        return r
    }

    @MainActor
    private func point(_ p: CGPoint, on canvas: XCUIElement, _ r: Report, app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let f = canvas.frame
        return origin.withOffset(CGVector(dx: f.minX - window.frame.minX + p.x * r.zoom - r.offset.x,
                                          dy: f.minY - window.frame.minY + p.y * r.zoom - r.offset.y))
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
        XCTFail("\(what): canvas reports \(raw(canvas))")
        return nil
    }

    /// A page x (page points) whose column holds no item, so a vertical drag there starts on the empty page,
    /// and at least 60 points from the screen's edges (a touch at the left edge is the system's back swipe).
    private func freeColumn(_ r: Report, width: CGFloat) -> CGFloat {
        let lo = (60 + r.offset.x) / r.zoom, hi = (width - 60 + r.offset.x) / r.zoom
        for x in stride(from: lo, through: hi, by: 4) where !r.items.contains(where: { $0.frame.minX - 12 <= x && x <= $0.frame.maxX + 12 }) {
            return x
        }
        return (lo + hi) / 2
    }

    // MARK: The buttons

    @MainActor
    private func annotateButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "annotateButton").firstMatch
    }

    @MainActor
    private func handButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "handButton").firstMatch
    }

    private func lit(_ button: XCUIElement) -> Bool {
        button.isSelected || (button.value as? String) == "1"
    }

    @MainActor
    private func tap(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(button)")
        button.tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    // MARK: What the canvas does

    /// The buttons, the palette, a one-finger drag and (outside Annotate) a tap on the picture all say `mode`.
    @MainActor
    private func expect(_ mode: Mode, _ app: XCUIApplication, _ canvas: XCUIElement, after step: String) {
        let what = "\(step) → \(mode.rawValue)"
        // The iPad's pencil is a menu button (its menu holds Compact Palette) whose on state (a filled icon) does not
        // reach XCTest; the palette below says whether it is on.
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertEqual(lit(annotateButton(app)), mode == .annotating, "\(what): the pencil reads \(lit(annotateButton(app)) ? "on" : "off")")
        }
        XCTAssertEqual(lit(handButton(app)), mode == .hand, "\(what): the Hand reads \(lit(handButton(app)) ? "on" : "off")")
        let palette = app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch
        if mode == .annotating {
            XCTAssertTrue(palette.waitForExistence(timeout: 5), "\(what): the palette is up")
        } else {
            XCTAssertTrue(palette.waitForNonExistence(timeout: 5), "\(what): no palette")
        }
        if mode != .annotating { tapOnPicture(selects: mode == .hand, app, canvas, what) }
        oneFingerDrag(scrolls: mode != .annotating, app, canvas, what)
    }

    /// The canvas's report once its scroll has come to rest (no bounce or deceleration under way).
    @MainActor
    private func settled(_ canvas: XCUIElement) -> Report? {
        var last = report(canvas)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.4)
            let now = report(canvas)
            if let a = last, let b = now, a.offset == b.offset { return b }
            last = now
        }
        return last
    }

    /// A one-finger drag on the empty page, finger up: it scrolls (and draws nothing), or draws one stroke. The
    /// scroll check is a slow pan held at the end (no fling), as `PhoneReadingScrollUITests` drags; the stroke
    /// check is the stroke gesture of `PhoneCanvasUITests`. After a scroll the note is panned back to the top,
    /// so the picture is on screen for the next check. Offsets come from the ink on screen (`aimed`).
    @MainActor
    private func oneFingerDrag(scrolls: Bool, _ app: XCUIApplication, _ canvas: XCUIElement, _ what: String) {
        guard let r0 = settled(canvas).map({ aimed(canvas, $0) }) else { return XCTFail("\(what): no report") }
        let x = freeColumn(r0, width: canvas.frame.width)
        let h = canvas.frame.height
        let high = (h * 0.35 + r0.offset.y) / r0.zoom, low = (h * 0.75 + r0.offset.y) / r0.zoom
        let start = point(CGPoint(x: x, y: low), on: canvas, r0, app: app)
        let end = point(CGPoint(x: x, y: high), on: canvas, r0, app: app)
        guard scrolls else {
            start.press(forDuration: 0.05, thenDragTo: end)
            // One stroke: the finger was ink, not a scroll. (The offset is no check here: a stroke can change the
            // pageless note's scroll extent, which moves the offset by itself.)
            waitReport(canvas, "\(what): one finger draws") { $0.strokes == r0.strokes + 1 }
            return
        }
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1)
        guard let r1 = settled(canvas).map({ aimed(canvas, $0) }) else { return }
        XCTAssertGreaterThan(r1.offset.y, r0.offset.y + 40, "\(what): one finger scrolls (offset \(r0.offset.y) -> \(r1.offset.y)): \(raw(canvas))")
        XCTAssertEqual(r1.strokes, r0.strokes, "\(what): the drag drew nothing")
        XCTAssertEqual(r1.selected, "none", "\(what): the drag selected nothing")
        // Back to the top: finger down, slowly, until the note is there again.
        for _ in 0..<4 {
            guard let r = settled(canvas).map({ aimed(canvas, $0) }), r.offset.y > 20 else { break }
            let top = (h * 0.3 + r.offset.y) / r.zoom
            let down = min(h * 0.45, r.offset.y + 30) / r.zoom
            point(CGPoint(x: x, y: top), on: canvas, r, app: app)
                .press(forDuration: 0.1, thenDragTo: point(CGPoint(x: x, y: top + down), on: canvas, r, app: app),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// A tap on the picture selects it (then a tap on the empty page drops it) or selects nothing.
    @MainActor
    private func tapOnPicture(selects: Bool, _ app: XCUIApplication, _ canvas: XCUIElement, _ what: String) {
        guard let r0 = settled(canvas).map({ aimed(canvas, $0) }), let f = r0.frame("image") else { return XCTFail("\(what): no image") }
        point(CGPoint(x: f.midX, y: f.midY), on: canvas, r0, app: app).tap()
        if selects {
            waitReport(canvas, "\(what): a tap selects the picture") { $0.selected == "image" }
            guard let r1 = report(canvas).map({ aimed(canvas, $0) }) else { return }
            point(CGPoint(x: freeColumn(r1, width: canvas.frame.width), y: f.maxY + 60), on: canvas, r1, app: app).tap()
            waitReport(canvas, "\(what): a tap beside it drops it") { $0.selected == "none" }
            XCTAssertEqual(report(canvas)?.strokes, r0.strokes, "\(what): the taps drew nothing")
        } else {
            Thread.sleep(forTimeInterval: 1)
            XCTAssertEqual(report(canvas)?.selected, "none", "\(what): a tap selects nothing")
            XCTAssertEqual(report(canvas)?.strokes, r0.strokes, "\(what): the tap drew nothing")
        }
    }

    // MARK: Tests

    /// Picks `tool` in the palette ("Pen", "Marker", "Object Eraser", "Lasso"): a tap on the palette first, which
    /// opens the phone's collapsed one so its items can be tapped.
    @MainActor
    private func pick(_ tool: String, _ app: XCUIApplication) {
        let palette = app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "the palette")
        let item = palette.buttons[tool].firstMatch
        if !item.isHittable {
            palette.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5) && item.isHittable, "the palette's \(tool): \(palette.debugDescription.prefix(3000))")
        item.tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Every transition between the three modes, each way, on a pageless note: what the buttons show is what the
    /// canvas does. Reading → Annotate → Reading (waiting: bug 2) → Hand → Reading → Annotate → Hand → Annotate
    /// (bug 3: from the Hand straight to the pencil) → Hand → Reading.
    @MainActor
    func testEveryTransitionMatchesWhatTheCanvasDoes() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = pagelessCanvas(app) else { return XCTFail("no canvas reports the demo items") }
        expect(.reading, app, canvas, after: "open")
        tap(annotateButton(app))
        expect(.annotating, app, canvas, after: "reading, pencil")
        tap(annotateButton(app))
        Thread.sleep(forTimeInterval: 3)   // PencilKit's recount comes with the palette's hide animation
        expect(.reading, app, canvas, after: "annotating, pencil, 3 s")
        tap(handButton(app))
        expect(.hand, app, canvas, after: "reading, Hand")
        tap(handButton(app))
        expect(.reading, app, canvas, after: "hand, Hand")
        tap(annotateButton(app))
        tap(handButton(app))
        expect(.hand, app, canvas, after: "annotating, Hand")
        tap(annotateButton(app))
        expect(.annotating, app, canvas, after: "hand, pencil")
        tap(handButton(app))
        tap(annotateButton(app))
        tap(annotateButton(app))
        Thread.sleep(forTimeInterval: 3)
        expect(.reading, app, canvas, after: "hand, pencil, pencil, 3 s")
    }

    /// Bug 2 on the paged stack: Annotate on and off, a wait, then one finger still scrolls the pages.
    @MainActor
    func testLeavingAnnotateKeepsOneFingerScrollingThePages() throws {
        let app = launch(note: "lisbon")
        defer { app.terminate() }
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        XCTAssertTrue(canvases.firstMatch.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: 1.5)
        tap(annotateButton(app))
        tap(annotateButton(app))
        Thread.sleep(forTimeInterval: 3)
        let top: () -> CGFloat? = { canvases.allElementsBoundByIndex.map(\.frame.minY).min() }
        guard let top0 = top() else { return XCTFail("no page canvas") }
        let stack = app.descendants(matching: .any).matching(identifier: "pageStack").firstMatch
        stack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: stack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1)
        guard let top1 = top() else { return XCTFail("no page canvas after the drag") }
        XCTAssertLessThan(top1, top0 - 40, "one finger scrolls the pages after Annotate went off (top \(top0) -> \(top1))")
    }

    /// The palette has no Hand (owner, 2026-10-19: "It serves no purpose there"): the top bar's Hand is the only
    /// one, and from Annotate it goes straight to Hand mode.
    @MainActor
    func testThePaletteHasNoHand() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = pagelessCanvas(app) else { return XCTFail("no canvas reports the demo items") }
        tap(annotateButton(app))
        let palette = app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "the palette")
        // The phone's collapsed palette opens with a tap; the iPad's lists its tools already (a tap there could
        // open a tool's options, which would take the next tap).
        if !palette.buttons["Pen"].firstMatch.isHittable {
            palette.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(palette.buttons["Pen"].firstMatch.exists, "the palette's tools are listed: \(palette.debugDescription.prefix(2000))")
        XCTAssertFalse(palette.buttons["Hand"].exists, "no Hand in the palette: \(palette.debugDescription.prefix(2000))")
        tap(handButton(app))
        expect(.hand, app, canvas, after: "annotating, Hand")
        tap(handButton(app))
        Thread.sleep(forTimeInterval: 3)
        expect(.reading, app, canvas, after: "hand, Hand")
    }

    /// Bug 2 after each tool: Annotate with the pen, marker, object eraser or lasso picked, then off; after a
    /// wait (PencilKit's recount, the object eraser and lasso restoring their saved counts) one finger still
    /// scrolls the pageless note and draws nothing.
    @MainActor
    func testLeavingAnnotateFromEachToolKeepsOneFingerScrolling() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = pagelessCanvas(app) else { return XCTFail("no canvas reports the demo items") }
        for tool in ["Object Eraser", "Lasso", "Marker", "Pen"] {
            tap(annotateButton(app))
            pick(tool, app)
            tap(annotateButton(app))
            Thread.sleep(forTimeInterval: 3)
            oneFingerDrag(scrolls: true, app, canvas, "annotating with the \(tool), pencil, 3 s")
        }
    }
}
