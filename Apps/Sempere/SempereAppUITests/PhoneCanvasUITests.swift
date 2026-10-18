import XCTest

/// The canvas with a finger on the iPhone (TestFlight 1.0.0 (2), the owner's iPhone). A finger draws
/// there (an iPhone has no Pencil), once "Annotate" is on, so a tap on a picture used to leave a dot
/// and select nothing, and a held finger showed no menu. Now a tap on an item selects it and leaves no
/// ink; a hold shows the item's menu; a stroke still draws, wherever it starts; reading mode draws and
/// selects nothing. (XCTest cannot synthesize a two-finger drag: two-finger scrolling is checked on the
/// stack, `PhoneCanvasInteractionTests.twoFingersScrollWhileOneDraws`.) The demo vault's "thoughts" note
/// has a text box, an image, an equation and an audio card (`SEMPERE_DEMO_ITEMS`), and its canvas
/// reports them, the selection, the menu and its stroke count (`ItemSelectionController.debugReport`).
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
            c.firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.5)
            return
        }
        XCTFail("no Annotate button: \(app.debugDescription.prefix(2000))")
    }

    /// Taps the top bar's Hand button (Annotate and select mode on in one tap).
    @MainActor
    private func tapHand(_ app: XCUIApplication) {
        let hand = app.descendants(matching: .any).matching(identifier: "handButton").firstMatch
        XCTAssertTrue(hand.waitForExistence(timeout: 10), "no Hand button in the top bar: \(app.debugDescription.prefix(2000))")
        hand.tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// An empty spot of the page, left of the equation and under the text box.
    private static let emptySpot = CGPoint(x: 120, y: 600)

    // MARK: Tests

    /// A tap on a picture selects it (the bar is up, no menu) and leaves no dot; a tap beside it drops it.
    @MainActor
    func testATapSelectsAPictureAndLeavesNoInk() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        annotate(app)
        guard let before = report(canvas), let image = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image.tap()
        let selected = waitReport(canvas, "a tap selects the picture") { $0.selected == "image" && $0.bar }
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(report(canvas)?.menu, false, "a tap shows no menu")
        XCTAssertEqual(selected?.strokes, before.strokes, "the tap left no dot")
        point(Self.emptySpot, on: canvas, before, app: app).tap()
        waitReport(canvas, "a tap beside it drops the selection") { $0.selected == "none" && !$0.bar }
    }

    /// Any kind: the equation and the audio card are picked by a tap too (the card is not played).
    @MainActor
    func testATapPicksTheOtherKindsToo() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        annotate(app)
        for kind in ["math", "audio", "text"] {
            guard let target = middle(of: kind, on: canvas, app: app) else { XCTFail("no \(kind)"); continue }
            target.tap()
            waitReport(canvas, "a tap selects the \(kind)") { $0.selected == kind }
            XCTAssertFalse(app.descendants(matching: .any)["playerBar"].exists, "a tap does not play")
            guard let r = report(canvas) else { return }
            point(Self.emptySpot, on: canvas, r, app: app).tap()
            waitReport(canvas, "a tap beside it drops it") { $0.selected == "none" }
        }
    }

    /// A held finger shows the item's menu, not PencilKit's "Select All / Insert Space" bar.
    @MainActor
    func testAHoldShowsTheItemMenu() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        annotate(app)
        guard let before = report(canvas), let image = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image.press(forDuration: 1.0)
        let held = waitReport(canvas, "a held finger picks the picture with its menu") { $0.selected == "image" && $0.menu }
        XCTAssertEqual(held?.strokes, before.strokes, "the hold left no dot")
        XCTAssertFalse(["Insert Space", "Select All"].contains { app.menuItems[$0].exists || app.buttons[$0].exists },
                       "not PencilKit's bar")
    }

    /// Strokes still draw: from the empty page, and from an item (annotating a picture); neither selects.
    @MainActor
    func testStrokesStillDrawWhereverTheyStart() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        annotate(app)
        guard let r0 = report(canvas), let f = r0.frame("image") else { return XCTFail("no image") }
        let from = point(Self.emptySpot, on: canvas, r0, app: app)
        from.press(forDuration: 0.05, thenDragTo: point(CGPoint(x: Self.emptySpot.x + 80, y: Self.emptySpot.y + 20), on: canvas, r0, app: app))
        let a = waitReport(canvas, "a stroke from the empty page draws") { $0.strokes == r0.strokes + 1 }
        XCTAssertEqual(a?.selected, "none")
        guard let r1 = a else { return }
        point(CGPoint(x: f.minX + 30, y: f.midY), on: canvas, r1, app: app)
            .press(forDuration: 0.05, thenDragTo: point(CGPoint(x: f.maxX - 30, y: f.midY + 10), on: canvas, r1, app: app))
        let b = waitReport(canvas, "a stroke from a picture draws too") { $0.strokes == r1.strokes + 1 }
        XCTAssertEqual(b?.selected, "none", "a stroke does not select")
        XCTAssertEqual(b?.edits, r1.edits, "and moves nothing")
    }

    /// A short touch on the empty page still draws its dot.
    @MainActor
    func testATapOnTheEmptyPageStillDrawsADot() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        annotate(app)
        guard let r0 = report(canvas) else { return }
        point(Self.emptySpot, on: canvas, r0, app: app).press(forDuration: 0.1)
        waitReport(canvas, "a dot", timeout: 8) { $0.strokes == r0.strokes + 1 && $0.selected == "none" }
    }

    /// Reading mode (Annotate off): a finger draws nothing and a tap selects nothing, so a stray touch only scrolls.
    @MainActor
    func testReadingModeDrawsAndSelectsNothing() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        Thread.sleep(forTimeInterval: 1)
        guard let r0 = report(canvas), let image = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(freshReport(app)?.selected ?? "none", "none", "reading: a tap selects nothing")
        point(Self.emptySpot, on: canvas, r0, app: app)
            .press(forDuration: 0.05, thenDragTo: point(CGPoint(x: Self.emptySpot.x + 80, y: Self.emptySpot.y), on: canvas, r0, app: app))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(freshReport(app)?.strokes ?? r0.strokes, r0.strokes, "reading: a finger draws nothing")
    }

    /// The top bar's Hand button, from reading mode: one tap selects an item and draws nothing; the Hand
    /// button reads as selected; a second tap leaves select mode (a tap selects nothing again, Annotate stays on).
    @MainActor
    func testTheTopBarHandButtonSelectsAnItem() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        tapHand(app)
        let hand = app.descendants(matching: .any).matching(identifier: "handButton").firstMatch
        XCTAssertTrue(hand.isSelected || (hand.value as? String) == "1", "the Hand button reads as selected: \(String(describing: hand.value))")
        guard let before = report(canvas), let image = middle(of: "image", on: canvas, app: app) else { return XCTFail("no image") }
        image.tap()
        let selected = waitReport(canvas, "a tap selects the picture") { $0.selected == "image" && $0.bar }
        XCTAssertEqual(selected?.strokes, before.strokes, "the tap left no dot")
        tapHand(app)   // off again: back to the drawing tool, still annotating
        let after = freshReport(app)
        XCTAssertEqual(after?.selected ?? "none", "none", "leaving the Hand drops the selection")
    }

    /// With the Hand on, one finger scrolls the note and draws nothing.
    @MainActor
    func testTheHandScrollsWithOneFinger() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app) else { return XCTFail("no canvas reports the demo items") }
        tapHand(app)
        let tops: () -> CGFloat? = {
            app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex.map(\.frame.minY).min()
        }
        guard let r0 = report(canvas), let top0 = tops() else { return XCTFail("no report") }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1)
        let moved = (tops().map { $0 < top0 - 40 } ?? false) || ((freshReport(app)?.offset.y ?? r0.offset.y) > r0.offset.y + 40)
        XCTAssertTrue(moved, "one finger scrolls with the Hand (top \(top0) -> \(String(describing: tops())))")
        XCTAssertEqual(freshReport(app)?.strokes ?? r0.strokes, r0.strokes, "the drag drew nothing")
    }
}
