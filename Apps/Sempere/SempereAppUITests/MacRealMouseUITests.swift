import XCTest

#if targetEnvironment(macCatalyst)
import CoreGraphics

/// A mouse that posts HID-level events (`CGEventPost` to `.cghidEventTap`), the way a real mouse
/// reaches the window server. XCUITest's own `click` and `click(forDuration:thenDragTo:)` hand the app
/// synthesized events, which differ from real ones (TestFlight 1.0.0: a sheet's toolbar button took a
/// real click but not an XCUITest one). Needs the posting process to be allowed to post events
/// (System Settings ▸ Privacy ▸ Accessibility for the test runner's responsible process, e.g. Terminal
/// when `~/.claude/scripts/sempere-ui-runner.sh` started it): `canPost` says whether it is.
/// Points are global screen points with the origin at the top left of the main display, which is what
/// `XCUIElement.frame` holds on a Mac.
enum HIDMouse {
    static var canPost: Bool { CGPreflightPostEventAccess() }

    private static func post(_ type: CGEventType, _ p: CGPoint, clickState: Int64 = 1, delta: CGPoint = .zero) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        event.post(tap: .cghidEventTap)
    }

    static func move(to p: CGPoint) {
        post(.mouseMoved, p)
        Thread.sleep(forTimeInterval: 0.12)
    }

    static func click(at p: CGPoint) {
        move(to: p)
        post(.leftMouseDown, p)
        Thread.sleep(forTimeInterval: 0.08)
        post(.leftMouseUp, p)
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Press at `a`, move to `b` in `steps` small moves, release.
    static func drag(from a: CGPoint, to b: CGPoint, steps: Int = 24) {
        move(to: a)
        post(.leftMouseDown, a)
        Thread.sleep(forTimeInterval: 0.12)
        var last = a
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            post(.leftMouseDragged, p, delta: CGPoint(x: p.x - last.x, y: p.y - last.y))
            last = p
            Thread.sleep(forTimeInterval: 0.016)
        }
        Thread.sleep(forTimeInterval: 0.12)
        post(.leftMouseUp, b)
        Thread.sleep(forTimeInterval: 0.2)
    }
}

/// What the owner checked by hand with a real mouse, done with a real mouse: HID-level events
/// (`HIDMouse`) instead of XCUITest's synthesized ones, on Mac Catalyst.
/// Run by `scripts/app.sh test-mac-ui`; Mac Catalyst only (not compiled elsewhere) and skipped, with a
/// message, where the test runner may not post events.
final class MacRealMouseUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard HIDMouse.canPost else {
            throw XCTSkip("the UI-test runner may not post HID events (Accessibility): CGPreflightPostEventAccess() is false")
        }
    }

    @MainActor
    private func launch(note: String, columns: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": columns, "SEMPERE_DEMO_NOTE": note,
                                 "SEMPERE_DEMO_SIDEBAR": "all", "SEMPERE_DEMO_MAC_WINDOW": "1100x900",
                                 "SEMPERE_DEMO_ITEMS": "1", "SEMPERE_DEBUG_NOTE_MODE": "annotate", "TZ": "UTC"].merging(extra) { _, new in new }
        app.launch()
        return app
    }

    @MainActor
    private func dump(_ app: XCUIApplication, _ tag: String) {
        for c in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
            print("REALMOUSEDEBUG \(tag) canvas \(c.frame) \(String(describing: c.value))")
        }
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("REALMOUSEDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(8000))")
        }
    }

    // MARK: Canvas reports

    @MainActor
    private func report(_ canvas: XCUIElement) -> MacItemUITests.Report? {
        (canvas.value as? String).flatMap(MacItemUITests.Report.init)
    }

    @MainActor
    private func canvas(_ app: XCUIApplication, holding kind: String) -> XCUIElement? {
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        for _ in 0..<60 {
            for element in canvases.allElementsBoundByIndex {
                if let r = report(element), r.frame(kind) != nil { return element }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    /// Screen points per canvas point (a Catalyst app in the iPad idiom is drawn at 77 %).
    @MainActor
    private func scale(_ canvas: XCUIElement, _ r: MacItemUITests.Report) -> CGFloat {
        r.width > 0 ? canvas.frame.width / r.width : 1
    }

    /// The global screen point of page point `p`.
    @MainActor
    private func screen(_ p: CGPoint, on canvas: XCUIElement, _ r: MacItemUITests.Report) -> CGPoint {
        let s = scale(canvas, r)
        return CGPoint(x: canvas.frame.minX + (p.x * r.zoom - r.offset.x) * s, y: canvas.frame.minY + (p.y * r.zoom - r.offset.y) * s)
    }

    @MainActor
    private func bringIntoView(_ kind: String, on canvas: XCUIElement, app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0..<12 {
            guard let r = report(canvas), let f = r.frame(kind) else { return }
            let bottom = canvas.frame.minY + (f.maxY * r.zoom - r.offset.y) * scale(canvas, r) + 60
            guard bottom > window.frame.maxY else { return }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -40)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    @MainActor
    @discardableResult
    private func waitReport(_ canvas: XCUIElement, _ what: String, timeout: TimeInterval = 6,
                            _ ok: (MacItemUITests.Report) -> Bool) -> MacItemUITests.Report? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = report(canvas), ok(r) { return r }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("\(what): canvas reports \(String(describing: canvas.value))")
        return nil
    }

    // MARK: (a) items, with the lasso as the palette's tool

    /// A placed item dragged and resized with a real mouse while the lasso is the palette's last
    /// tool (no Select tool chosen): the owner's by-hand check, which XCUITest's synthesized events
    /// could not stand in for. One delta per gesture; ⌘Z puts the frame back.
    @MainActor
    func testARealMouseMovesAndResizesItemsWithTheLassoAsTheTool() throws {
        let app = launch(note: "thoughts", columns: "detailOnly")
        defer { app.terminate() }
        guard let canvas = canvas(app, holding: "image") else { return XCTFail("no canvas reports the demo items") }
        app.typeKey("5", modifierFlags: [.command, .option])   // Tools > Lasso, and nothing after it
        Thread.sleep(forTimeInterval: 1)
        for kind in ["image", "text"] {
            bringIntoView(kind, on: canvas, app: app)
            guard let r0 = report(canvas), let f0 = r0.frame(kind) else { return XCTFail("\(kind): not reported") }
            HIDMouse.click(at: screen(CGPoint(x: f0.midX, y: f0.midY), on: canvas, r0))
            guard let r1 = waitReport(canvas, "\(kind): a real click selects it with the lasso tool", { $0.selected == kind }) else {
                return dump(app, "select-\(kind)")
            }
            Thread.sleep(forTimeInterval: 0.5)
            let pagePerScreen = 1 / (r1.zoom * scale(canvas, r1))

            // Move: 40 × 30 screen points from the middle.
            let start = screen(CGPoint(x: f0.midX, y: f0.midY), on: canvas, r1)
            HIDMouse.drag(from: start, to: CGPoint(x: start.x + 40, y: start.y + 30))
            guard let r2 = waitReport(canvas, "\(kind): a real drag moves it", { r in
                guard let f = r.frame(kind) else { return false }
                return abs(f.minX - (f0.minX + 40 * pagePerScreen)) < 6 && abs(f.minY - (f0.minY + 30 * pagePerScreen)) < 6
            }) else { return dump(app, "move-\(kind)") }
            XCTAssertEqual(r2.edits, r1.edits + 1, "\(kind): the move wrote one delta")
            guard let f1 = r2.frame(kind) else { return }

            // Resize: the bottom-right handle (a text box's right side), 30 screen points further.
            let handle = kind == "text" ? CGPoint(x: f1.maxX, y: f1.midY) : CGPoint(x: f1.maxX, y: f1.maxY)
            let corner = screen(handle, on: canvas, r2)
            HIDMouse.drag(from: corner, to: CGPoint(x: corner.x + 30, y: corner.y + 30))
            guard let r3 = waitReport(canvas, "\(kind): a real drag on the handle resizes it", { r in
                guard let f = r.frame(kind) else { return false }
                return f.width > f1.width + 10 && abs(f.minX - f1.minX) < 1
            }) else { return dump(app, "resize-\(kind)") }
            XCTAssertEqual(r3.edits, r2.edits + 1, "\(kind): the resize wrote one delta")

            app.typeKey("z", modifierFlags: .command)
            app.typeKey("z", modifierFlags: .command)
            waitReport(canvas, "\(kind): ⌘Z twice puts it back") { r in
                guard let f = r.frame(kind) else { return false }
                return abs(f.minX - f0.minX) < 0.5 && abs(f.width - f0.width) < 0.5
            }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
    }

    // MARK: (b) a new text box keeps the keyboard

    /// The text of the box being typed in (`;typing=` in the canvas report); nil while none is.
    @MainActor
    private func typing(_ app: XCUIApplication, timeout: TimeInterval) -> String? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            for c in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
                if let v = c.value as? String, let r = v.range(of: ";typing=") { return String(v[r.upperBound...]) }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < end
        return nil
    }

    /// A real click on the empty page with the text tool starts a box, and every key typed after it
    /// reaches the box while the note writes and lays out around it.
    @MainActor
    func testClickingIntoANewTextBoxWithARealMouseKeepsTheKeyboard() throws {
        let app = launch(note: "respiration", columns: "all")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        app.typeKey("5", modifierFlags: [.command, .option])   // Tools > Lasso (the palette's last tool)
        app.typeKey("6", modifierFlags: [.command, .option])   // Tools > Text
        Thread.sleep(forTimeInterval: 1)
        let window = app.windows.firstMatch
        var area: CGRect?
        for element in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
            let part = element.frame.intersection(window.frame)
            if !part.isNull, part.width > 100, part.height > 100 { area = part; break }
        }
        guard let area else { dump(app, "textbox"); return XCTFail("no page canvas on screen") }
        HIDMouse.click(at: CGPoint(x: area.minX + area.width * 0.3, y: area.minY + area.height * 0.8))
        if typing(app, timeout: 10) == nil { dump(app, "textbox-editor") }
        XCTAssertNotNil(typing(app, timeout: 1), "a real click starts a text box")
        Thread.sleep(forTimeInterval: 1)
        for ch in "hello" {
            app.typeText(String(ch))
            Thread.sleep(forTimeInterval: 0.6)
        }
        Thread.sleep(forTimeInterval: 1.5)
        for ch in " there" {
            app.typeText(String(ch))
            Thread.sleep(forTimeInterval: 0.6)
        }
        var value = typing(app, timeout: 1)
        for _ in 0..<10 where value != "hello there" {
            Thread.sleep(forTimeInterval: 0.5)
            value = typing(app, timeout: 1)
        }
        if value != "hello there" { dump(app, "textbox-value") }
        XCTAssertEqual(value, "hello there", "every key reached the text box")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    // MARK: (c) the New Notebook sheet's Create button

    /// Create in the New Notebook sheet's toolbar takes a real click (the tests so far submit with
    /// Return, because a synthesized click on a sheet's toolbar button does not reach its action).
    @MainActor
    func testTheNewNotebookSheetsCreateButtonTakesARealClick() throws {
        let app = launch(note: "respiration", columns: "all")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cellular Respiration"].firstMatch.waitForExistence(timeout: 60))
        app.typeKey("n", modifierFlags: [.command, .control])   // File > New Notebook…
        let field = app.textFields["new-notebook-name"].firstMatch
        guard field.waitForExistence(timeout: 15) else { dump(app, "new-notebook"); return XCTFail("the name field") }
        field.typeText("Real click shelf")
        let create = app.buttons["new-notebook-create"].firstMatch
        guard create.waitForExistence(timeout: 5) else { dump(app, "new-notebook-create"); return XCTFail("the Create button") }
        XCTAssertTrue(create.isEnabled, "Create is enabled once there is a name")
        let frame = create.frame
        XCTAssertFalse(frame.isEmpty, "the Create button has a frame to aim at")
        HIDMouse.click(at: CGPoint(x: frame.midX, y: frame.midY))
        let made = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-Real click shelf").firstMatch
            .waitForExistence(timeout: 15)
        if !made { dump(app, "new-notebook-after") }
        XCTAssertTrue(made, "the real click created the notebook")
        XCTAssertFalse(field.exists, "and closed the sheet")
    }
}
#endif
