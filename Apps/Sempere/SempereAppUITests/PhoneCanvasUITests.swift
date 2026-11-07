import XCTest

/// The canvas with a finger on the iPhone (TestFlight 1.0.0 (2), the owner's iPhone). A finger draws
/// there (an iPhone has no Pencil), once "Annotate" is on, so a tap on a picture used to leave a dot
/// and select nothing, and a held finger showed no menu. Now a tap on an item selects it and leaves no
/// ink; a hold shows the item's menu; a stroke still draws, wherever it starts; reading mode draws and
/// selects nothing. (XCTest cannot synthesize a two-finger drag: two-finger scrolling is checked on the
/// stack, `PhoneCanvasInteractionTests.twoFingersScrollWhileOneDraws`.) The demo vault's "thoughts" note
/// has a text box, an image, an equation and an audio card (`SEMPERE_DEMO_ITEMS`), and its canvas
/// reports them, the selection, the menu and its stroke count (`ItemSelectionController.debugReport`).
/// Reading mode and the annotating checks share one launch (`testAFingerAnnotatingThenReading`).
/// Run by `scripts/app.sh test-phone-ui`; skipped on an iPad and on a Mac.
final class PhoneCanvasUITests: XCTestCase {
    typealias Report = IPadCanvasUITests.Report

    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone only")
        #else
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone only") }
        #endif
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_NOTE": "thoughts", "SEMPERE_DEMO_ITEMS": "1", "TZ": "UTC"]
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
        return app
    }

    @MainActor
    private func canvas(_ app: XCUIApplication, holding kind: String = "image") -> XCUIElement? {
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        var found: XCUIElement?
        UIWait.until(60, interval: 0.5) {
            found = canvases.allElementsBoundByIndex.first { report($0)?.frame(kind) != nil }
            return found != nil
        }
        return found
    }

    @MainActor
    private func report(_ canvas: XCUIElement) -> Report? {
        (canvas.value as? String).flatMap(Report.init)
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
    private func middle(of kind: String, on canvas: XCUIElement, app: XCUIApplication) -> XCUICoordinate? {
        guard let r = report(canvas), let f = r.frame(kind) else { return nil }
        return point(CGPoint(x: f.midX, y: f.midY), on: canvas, r, app: app)
    }

    @MainActor
    @discardableResult
    private func waitReport(_ canvas: XCUIElement, _ what: String, timeout: TimeInterval = 6,
                            _ ok: (Report) -> Bool) -> Report? {
        var last: Report?
        UIWait.until(timeout, interval: 0.2) {
            last = report(canvas)
            return last.map(ok) ?? false
        }
        if let r = last, ok(r) { return r }
        XCTFail("\(what): canvas reports \(String(describing: canvas.value))")
        return nil
    }

    /// The report of whichever canvas lists the demo items now (nil while none does; never fails the test).
    @MainActor
    private func freshReport(_ app: XCUIApplication) -> Report? {
        for element in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
            if let r = report(element), r.frame("image") != nil { return r }
        }
        return nil
    }

    /// Switches "Annotate" on (a finger draws; the palette comes up).
    @MainActor
    private func annotate(_ app: XCUIApplication) {
        let candidates = [app.buttons["Annotate"], app.switches["Annotate"], app.toggles["Annotate"]]
        for c in candidates where c.firstMatch.waitForExistence(timeout: 5) {
            let palette = app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch
            let before = palette.exists
            c.firstMatch.tap()
            // The palette comes up with Annotate on and goes down with it off.
            XCTAssertTrue(UIWait.until(5) { palette.exists != before }, "Annotate changed nothing")
            return
        }
        XCTFail("no Annotate button: \(app.debugDescription.prefix(2000))")
    }

    /// Taps the top bar's Hand button (Hand mode on, or back to reading).
    @MainActor
    private func tapHand(_ app: XCUIApplication) {
        let hand = app.descendants(matching: .any).matching(identifier: "handButton").firstMatch
        XCTAssertTrue(hand.waitForExistence(timeout: 10), "no Hand button in the top bar: \(app.debugDescription.prefix(2000))")
        let before = hand.isSelected || (hand.value as? String) == "1"
        hand.tap()
        XCTAssertTrue(UIWait.until(5) { (hand.isSelected || (hand.value as? String) == "1") != before }, "the Hand did not change")
    }

    /// An empty spot of the page, left of the equation and under the text box.
    private static let emptySpot = CGPoint(x: 120, y: 600)

    // MARK: Tests

    /// One launch through what a finger does on a paged note, annotating, then reading (these were six tests,
    /// each launching the same note; every check keeps its own message):
    ///
    /// 1. Annotating: a tap on a picture selects it (the bar is up, no menu) and leaves no dot; a tap beside it drops it.
    /// 2. Any kind: the equation, the audio card (not played) and the text box are picked by a tap too.
    /// 3. A held finger shows the item's menu, not PencilKit's "Select All / Insert Space" bar.
    /// 4. A short touch on the empty page still draws its dot.
    /// 5. Strokes still draw: from the empty page, and from an item (annotating a picture); neither selects.
    /// 6. Reading (Annotate off): a tap selects nothing and a finger draws nothing, so a stray touch only scrolls.
    /// It starts with the check as the note opens (reading): a tap on the picture selects nothing.
    @MainActor
    func testAFingerAnnotatingThenReading() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }

        // 0. As the note opens (reading): a tap on the picture selects nothing.
        UIWait.settled(5, steady: 2) { canvas.value as? String }   // the ink and the layout are at rest
        guard let opened = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        opened.tap()
        UIWait.pause(1)   // kept: a tap that selects nothing raises no event to wait for
        guard let r00 = report(canvas) else { return XCTFail("no canvas report after the tap: \(String(describing: canvas.value))") }
        XCTAssertEqual(r00.selected, "none", "reading, as the note opens: a tap selects nothing")

        // 1. Annotating: a tap selects a picture.
        annotate(app)
        guard let before = report(canvas), let image = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image.tap()
        let selected = waitReport(canvas, "a tap selects the picture") { $0.selected == "image" && $0.bar }
        UIWait.pause(0.8)   // kept: the check is that no menu comes up, which shows nothing to wait for
        XCTAssertEqual(report(canvas)?.menu, false, "a tap shows no menu")
        XCTAssertEqual(selected?.strokes, before.strokes, "the tap left no dot")
        point(Self.emptySpot, on: canvas, before, app: app).tap()
        waitReport(canvas, "a tap beside it drops the selection") { $0.selected == "none" && !$0.bar }

        // 2. The other kinds.
        for kind in ["math", "audio", "text"] {
            guard let target = middle(of: kind, on: canvas, app: app) else { XCTFail("no \(kind)"); continue }
            target.tap()
            waitReport(canvas, "a tap selects the \(kind)") { $0.selected == kind }
            XCTAssertFalse(app.descendants(matching: .any)["playerBar"].exists, "a tap does not play")
            guard let r = report(canvas) else { return }
            point(Self.emptySpot, on: canvas, r, app: app).tap()
            waitReport(canvas, "a tap beside it drops it") { $0.selected == "none" }
        }

        // 3. A hold shows the item's menu.
        guard let beforeHold = report(canvas), let held = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        held.press(forDuration: 1.0)
        let menu = waitReport(canvas, "a held finger picks the picture with its menu") { $0.selected == "image" && $0.menu }
        XCTAssertEqual(menu?.strokes, beforeHold.strokes, "the hold left no dot")
        XCTAssertFalse(["Insert Space", "Select All"].contains { app.menuItems[$0].exists || app.buttons[$0].exists },
                       "not PencilKit's bar")
        // Away from the menu and the selection (a tap beside the item, as in 1), before the ink checks.
        for _ in 0..<3 {
            guard let r = report(canvas), r.selected != "none" || r.menu else { break }
            point(Self.emptySpot, on: canvas, r, app: app).tap()
            UIWait.until(3) { report(canvas).map { $0.selected == "none" && !$0.menu } ?? false }
        }
        waitReport(canvas, "the menu and the selection are gone") { $0.selected == "none" && !$0.menu }

        // 4. A dot.
        guard let r5 = report(canvas) else { return }
        point(Self.emptySpot, on: canvas, r5, app: app).press(forDuration: 0.1)
        waitReport(canvas, "a dot", timeout: 8) { $0.strokes == r5.strokes + 1 && $0.selected == "none" }

        // 5. Strokes from the empty page and from a picture.
        guard let r6 = report(canvas), let f = r6.frame("image") else { return XCTFail("no image") }
        let from = point(Self.emptySpot, on: canvas, r6, app: app)
        from.press(forDuration: 0.05, thenDragTo: point(CGPoint(x: Self.emptySpot.x + 80, y: Self.emptySpot.y + 20), on: canvas, r6, app: app))
        let a = waitReport(canvas, "a stroke from the empty page draws") { $0.strokes == r6.strokes + 1 }
        XCTAssertEqual(a?.selected, "none")
        guard let r7 = a else { return }
        point(CGPoint(x: f.minX + 30, y: f.midY), on: canvas, r7, app: app)
            .press(forDuration: 0.05, thenDragTo: point(CGPoint(x: f.maxX - 30, y: f.midY + 10), on: canvas, r7, app: app))
        let b = waitReport(canvas, "a stroke from a picture draws too") { $0.strokes == r7.strokes + 1 }
        XCTAssertEqual(b?.selected, "none", "a stroke does not select")
        XCTAssertEqual(b?.edits, r7.edits, "and moves nothing")

        // 6. Reading again (Annotate off): a tap selects nothing, and a finger drags the page (a vertical drag:
        // a sideways one can take the phone's stack back to the list) and draws nothing.
        annotate(app)
        UIWait.pause(3)   // kept: PencilKit's recount after the palette hides shows nothing to observe
        guard let r0 = report(canvas), let image0 = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image0.tap()
        UIWait.pause(1)   // kept: a tap that selects nothing raises no event to wait for
        guard let tapped = report(canvas) else { return XCTFail("no canvas report after the reading tap: \(String(describing: canvas.value))") }
        XCTAssertEqual(tapped.selected, "none", "reading: a tap selects nothing")
        point(Self.emptySpot, on: canvas, r0, app: app)
            .press(forDuration: 0.05, thenDragTo: point(CGPoint(x: Self.emptySpot.x, y: Self.emptySpot.y - 80), on: canvas, r0, app: app))
        UIWait.pause(1)   // kept: the drag must draw and select nothing, which shows nothing to wait for
        guard let dragged = report(canvas) else { return XCTFail("no canvas report after the reading drag: \(String(describing: canvas.value))") }
        XCTAssertEqual(dragged.strokes, r0.strokes, "reading: a finger draws nothing")
        XCTAssertEqual(dragged.selected, "none", "reading: the drag selects nothing")
    }

    /// With the Hand on, one finger scrolls a two-page note and draws nothing.
    @MainActor
    func testTheHandScrollsWithOneFinger() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_NOTE": "lisbon", "TZ": "UTC"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate() }
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        XCTAssertTrue(canvases.firstMatch.waitForExistence(timeout: 60))
        let top: () -> CGFloat? = { canvases.allElementsBoundByIndex.map(\.frame.minY).min() }
        UIWait.settled { top() }   // the pages are laid out
        tapHand(app)
        guard let top0 = top() else { return XCTFail("no page canvas") }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        UIWait.until(3) { (top() ?? top0) < top0 - 40 }   // the pages scroll
        guard let top1 = top() else { return XCTFail("no page canvas after the drag") }
        XCTAssertLessThan(top1, top0 - 40, "one finger scrolls with the Hand (top \(top0) -> \(top1))")
    }
}
