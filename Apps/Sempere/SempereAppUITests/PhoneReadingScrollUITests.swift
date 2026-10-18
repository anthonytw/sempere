import XCTest

/// Reading mode on the iPhone (Annotate off, how every note opens) scrolls with one finger
/// (docs/iphone.md "Pan and zoom"). TestFlight build 4 (a23f4bc, the owner's iPhone): one finger
/// moved nothing in reading mode, while two fingers, and one with the Hand, scrolled while annotating.
/// A slow one-finger drag (a pan, not a swipe) must move the note: a paged note at the fitted width
/// and zoomed in (the page stack, `PageStackHost`), and a pageless one (the one-page canvas). A
/// quick sideways swipe on a paged note still turns the page. Nothing draws or selects meanwhile
/// (`PhoneCanvasUITests.testReadingModeDrawsAndSelectsNothing`).
/// Run by `scripts/app.sh test-phone-ui`; skipped on an iPad and on a Mac.
final class PhoneReadingScrollUITests: XCTestCase {
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
    private func launch(note: String, items: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_NOTE": note, "TZ": "UTC"]
        if items { env["SEMPERE_DEMO_ITEMS"] = "1" }
        app.launchEnvironment = env
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
        return app
    }

    // MARK: Paged notes (the page stack)

    /// The stack's scroll view, once its pages are laid out.
    @MainActor
    private func stack(_ app: XCUIApplication) -> XCUIElement {
        let stack = app.descendants(matching: .any).matching(identifier: "pageStack").firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 60), "the page stack: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1.5)   // the pages' ink and the first layout settle
        return stack
    }

    /// The top of the highest page canvas on screen, in screen points: it rises as the note scrolls down.
    @MainActor
    private func topOfPages(_ app: XCUIApplication) -> CGFloat? {
        app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex
            .map(\.frame.minY).min()
    }

    @MainActor
    private func counter(_ app: XCUIApplication) -> String? {
        let text = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+ / [0-9]+$'")).firstMatch
        return text.waitForExistence(timeout: 5) ? text.label : nil
    }

    /// A slow drag by one finger from `from` to `to` (normalized in `element`): long enough on the
    /// glass and slow enough to be a pan, never a swipe.
    @MainActor
    private func slowDrag(_ element: XCUIElement, from: CGVector, to: CGVector) {
        element.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.1, thenDragTo: element.coordinate(withNormalizedOffset: to),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1)
    }

    /// One finger drags a two-page note at the fitted width: the pages move up.
    @MainActor
    func testOneFingerScrollsAPagedNoteInReadingMode() throws {
        let app = launch(note: "lisbon")
        defer { app.terminate() }
        let stack = stack(app)
        XCTAssertFalse(app.buttons["Add Page"].exists, "reading mode: no Add Page")
        guard let before = topOfPages(app) else { return XCTFail("no page canvas") }
        slowDrag(stack, from: CGVector(dx: 0.5, dy: 0.75), to: CGVector(dx: 0.5, dy: 0.3))
        guard let after = topOfPages(app) else { return XCTFail("no page canvas after the drag") }
        XCTAssertLessThan(after, before - 40, "one finger scrolls a paged note in reading mode (top of the pages \(before) -> \(after))")
    }

    /// The same once zoomed in (a pinch): one finger still pans.
    @MainActor
    func testOneFingerScrollsAZoomedPagedNote() throws {
        let app = launch(note: "lisbon")
        defer { app.terminate() }
        let stack = stack(app)
        #if !targetEnvironment(macCatalyst)   // no pinch in Catalyst's XCTest (the test skips on a Mac anyway)
        stack.pinch(withScale: 2, velocity: 1)
        #endif
        Thread.sleep(forTimeInterval: 1.5)   // the pinch ends and the scale is baked in
        guard let before = topOfPages(app) else { return XCTFail("no page canvas") }
        slowDrag(stack, from: CGVector(dx: 0.5, dy: 0.75), to: CGVector(dx: 0.5, dy: 0.3))
        guard let after = topOfPages(app) else { return XCTFail("no page canvas after the drag") }
        XCTAssertLessThan(after, before - 40, "one finger scrolls a zoomed note in reading mode (top of the pages \(before) -> \(after))")
    }

    /// A quick sideways swipe still turns the page while reading (`PhoneReading.swipeTurnsPages`).
    @MainActor
    func testASwipeStillTurnsThePage() throws {
        let app = launch(note: "lisbon")
        defer { app.terminate() }
        let stack = stack(app)
        XCTAssertEqual(counter(app), "1 / 2")
        stack.swipeLeft()
        let second = app.staticTexts["2 / 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5), "a swipe to the left shows page 2; counter \(counter(app) ?? "none")")
    }

    // MARK: Pageless notes (the one-page canvas)

    /// One finger drags a pageless note: the canvas's own scroll moves (its report's offset).
    @MainActor
    func testOneFingerScrollsAPagelessNoteInReadingMode() throws {
        let app = launch(note: "thoughts", items: true)
        defer { app.terminate() }
        _ = stack(app)
        // The Pages menu's layout switch (iPhone toolbar), then the one-page canvas.
        let pages = app.buttons["Pages"].firstMatch
        if !pages.waitForExistence(timeout: 5) {
            let more = app.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10), "the overflow menu: \(app.debugDescription.prefix(3000))")
            more.tap()
        }
        XCTAssertTrue(pages.waitForExistence(timeout: 10), "the Pages menu: \(app.debugDescription.prefix(3000))")
        pages.tap()
        let pageless = app.buttons["Switch to Pageless Layout"].firstMatch
        XCTAssertTrue(pageless.waitForExistence(timeout: 10), "the layout switch: \(app.debugDescription.prefix(3000))")
        pageless.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageStack").firstMatch.waitForNonExistence(timeout: 30),
                      "the note is pageless (no page stack)")
        let canvas = app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1.5)
        guard let before = (canvas.value as? String).flatMap(Report.init) else {
            return XCTFail("the canvas reports nothing: \(String(describing: canvas.value))")
        }
        slowDrag(canvas, from: CGVector(dx: 0.5, dy: 0.75), to: CGVector(dx: 0.5, dy: 0.3))
        guard let after = (canvas.value as? String).flatMap(Report.init) else { return XCTFail("no report after the drag") }
        XCTAssertGreaterThan(after.offset.y, before.offset.y + 40,
                             "one finger scrolls a pageless note in reading mode (offset \(before.offset.y) -> \(after.offset.y))")
        XCTAssertEqual(after.strokes, before.strokes, "reading: the drag drew nothing")
        XCTAssertEqual(after.selected, "none", "reading: the drag selected nothing")
    }
}
