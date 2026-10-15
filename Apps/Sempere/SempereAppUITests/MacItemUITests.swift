import XCTest

/// Placed items with a mouse on Mac Catalyst (TestFlight 1.0.0: a click
/// selected an item but a drag neither moved nor resized it). The demo vault's
/// "thoughts" note gets a text box, an image, an equation and an audio card
/// (`SEMPERE_DEMO_ITEMS`, `DemoVault.itemOps`); the canvas reports where its
/// items are and how many item edits its page has had
/// (`ItemSelectionController.debugReport`), so each drag is checked against
/// the frame it should give and the one delta it should write.
/// Run by `scripts/app.sh test-mac-ui`; skipped on the iPad.
final class MacItemUITests: XCTestCase {
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
        /// The canvas's width in UIKit points (`debugReport`).
        var width: CGFloat = 0
        var edits = 0
        var selected = "none"
        var items: [(kind: String, frame: CGRect, rotation: Double)] = []

        init?(_ value: String) {
            guard value.hasPrefix("zoom=") else { return nil }
            for field in value.split(separator: ";", omittingEmptySubsequences: false) {
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
                case "items":
                    items = v.split(separator: "|").compactMap { entry in
                        let parts = entry.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2 else { return nil }
                        let c = parts[1].split(separator: ",").compactMap { Double($0) }
                        guard c.count == 5 else { return nil }
                        return (String(parts[0]), CGRect(x: c[0], y: c[1], width: c[2], height: c[3]), c[4])
                    }
                default: break
                }
            }
        }

        func frame(_ kind: String) -> CGRect? { items.first { $0.kind == kind }?.frame }
    }

    @MainActor
    private func launch(note: String = "thoughts", extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_NOTE": note,
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x900", "SEMPERE_DEMO_ITEMS": "1", "TZ": "UTC"]
            .merging(extra) { _, new in new }
        app.launch()
        return app
    }

    /// The page canvas whose report lists an item of `kind`.
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

    @MainActor
    private func report(_ canvas: XCUIElement) -> Report? {
        (canvas.value as? String).flatMap(Report.init)
    }

    /// Screen points per canvas (UIKit) point: a Catalyst app in the iPad idiom is drawn at 77 %
    /// of its UIKit size, so the canvas's on-screen frame is smaller than its bounds.
    @MainActor
    private func scale(_ canvas: XCUIElement, _ r: Report) -> CGFloat {
        r.width > 0 ? canvas.frame.width / r.width : 1
    }

    /// Page points per screen point at the report's zoom (a drag of `d` screen points moves an item
    /// `d * pagePerScreen(…)` page points).
    @MainActor
    private func pagePerScreen(_ canvas: XCUIElement, _ r: Report) -> CGFloat {
        1 / (r.zoom * scale(canvas, r))
    }

    /// The screen coordinate of page point `p` on `canvas`.
    @MainActor
    private func point(_ p: CGPoint, on canvas: XCUIElement, _ r: Report, app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let f = canvas.frame
        let s = scale(canvas, r)
        let x = f.minX - window.frame.minX + (p.x * r.zoom - r.offset.x) * s
        let y = f.minY - window.frame.minY + (p.y * r.zoom - r.offset.y) * s
        return origin.withOffset(CGVector(dx: x, dy: y))
    }

    /// Scrolls the pages (the wheel, over the window) until item `kind` and room for a drag below and
    /// right of it are inside the window.
    @MainActor
    private func bringIntoView(_ kind: String, on canvas: XCUIElement, app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0..<12 {
            guard let r = report(canvas), let f = r.frame(kind) else { return }
            let s = scale(canvas, r)
            let bottom = canvas.frame.minY + (f.maxY * r.zoom - r.offset.y) * s + 60
            guard bottom > window.frame.maxY else { return }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -40)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Waits until the canvas's report satisfies `ok`, and returns it.
    @MainActor
    @discardableResult
    private func waitReport(_ canvas: XCUIElement, _ what: String, timeout: TimeInterval = 5,
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

    @MainActor
    private func drag(from a: XCUICoordinate, to b: XCUICoordinate) {
        // A mouse drag is click-and-drag (XCTest's press-and-drag never reaches a Catalyst app).
        a.click(forDuration: 0.15, thenDragTo: b, withVelocity: 400, thenHoldForDuration: 0.15)
    }

    /// Each kind a user places: a click selects it, a drag inside moves it, a drag on the
    /// bottom-right handle resizes it (pictures keep their proportions), each gesture writes
    /// one delta, and ⌘Z puts the frame back.
    @MainActor
    func testAMouseDragMovesAndResizesEveryKind() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app, holding: "image") else {
            XCTFail("no canvas reports the demo items")
            return
        }
        // From the lasso: PencilKit's own lasso gestures are there while it is the palette's tool, and
        // took the drag from the item (the palette remembers its tool across launches, so the tests
        // pick it rather than depend on the last run's).
        app.typeKey("5", modifierFlags: [.command, .option])   // Tools > Lasso
        app.typeKey("7", modifierFlags: [.command, .option])   // Tools > Select
        Thread.sleep(forTimeInterval: 1)
        for kind in ["image", "text", "math", "audio"] {
            // At the fitted width the equation and the audio card start below the window's bottom edge.
            bringIntoView(kind, on: canvas, app: app)
            guard let r0 = report(canvas), let f0 = r0.frame(kind) else { return XCTFail("\(kind): not reported") }
            point(CGPoint(x: f0.midX, y: f0.midY), on: canvas, r0, app: app).click()
            guard let r1 = waitReport(canvas, "\(kind): a click selects it", { $0.selected == kind }) else { return }
            // No Escape here: the user's next press is the drag itself (TestFlight 1.0.0: an edit menu
            // that popped up on the click swallowed it).
            Thread.sleep(forTimeInterval: 0.5)

            // Move: from the middle, 40 × 30 points.
            let start = point(CGPoint(x: f0.midX, y: f0.midY), on: canvas, r1, app: app)
            drag(from: start, to: start.withOffset(CGVector(dx: 40, dy: 30)))
            guard let r2 = waitReport(canvas, "\(kind): a drag moves it", { r in
                guard let f = r.frame(kind) else { return false }
                return abs(f.minX - (f0.minX + 40 * pagePerScreen(canvas, r1))) < 6 && abs(f.minY - (f0.minY + 30 * pagePerScreen(canvas, r1))) < 6
            }) else { return }
            XCTAssertEqual(r2.edits, r1.edits + 1, "\(kind): the move wrote one delta")
            guard let f1 = r2.frame(kind) else { return }

            // Resize: the bottom-right handle (a text box's right side), 30 points right (and down).
            let handle = kind == "text" ? CGPoint(x: f1.maxX, y: f1.midY) : CGPoint(x: f1.maxX, y: f1.maxY)
            let corner = point(handle, on: canvas, r2, app: app)
            drag(from: corner, to: corner.withOffset(CGVector(dx: 30, dy: 30)))
            guard let r3 = waitReport(canvas, "\(kind): the corner handle resizes it", { r in
                guard let f = r.frame(kind) else { return false }
                return f.width > f1.width + 10 && abs(f.minX - f1.minX) < 1
            }) else { return }
            XCTAssertEqual(r3.edits, r2.edits + 1, "\(kind): the resize wrote one delta")
            if kind == "image", let f = r3.frame(kind) {
                XCTAssertEqual(f.width / f.height, f1.width / f1.height, accuracy: 0.02, "the image keeps its proportions")
            }

            // Undo twice: back where it started.
            app.typeKey("z", modifierFlags: .command)
            app.typeKey("z", modifierFlags: .command)
            waitReport(canvas, "\(kind): ⌘Z twice puts it back") { r in
                guard let f = r.frame(kind) else { return false }
                return abs(f.minX - f0.minX) < 0.5 && abs(f.width - f0.width) < 0.5
            }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
    }

    /// The keyboard on a selected item: an arrow moves it a point (Shift: ten), one
    /// delta per press, and Escape drops the selection. The wheel still scrolls.
    @MainActor
    func testArrowsNudgeEscapeDeselectsAndTheWheelScrolls() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app, holding: "image") else { return XCTFail("no canvas reports the demo items") }
        app.typeKey("1", modifierFlags: [.command, .option])   // Tools > Pen (the lasso is the drag tests')
        app.typeKey("7", modifierFlags: [.command, .option])   // Tools > Select
        Thread.sleep(forTimeInterval: 1)
        guard let r0 = report(canvas), let f0 = r0.frame("image") else { return XCTFail("no image") }
        point(CGPoint(x: f0.midX, y: f0.midY), on: canvas, r0, app: app).click()
        guard let r1 = waitReport(canvas, "a click selects the image", { $0.selected == "image" }) else { return }
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: .shift)
        guard let r2 = waitReport(canvas, "the arrows move the image", { r in
            guard let f = r.frame("image") else { return false }
            return abs(f.minX - (f0.minX + 1 / r1.zoom)) < 0.2 && abs(f.minY - (f0.minY + 10 / r1.zoom)) < 0.2
        }) else { return }
        XCTAssertEqual(r2.edits, r1.edits + 2, "one delta per key press")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        waitReport(canvas, "Escape deselects") { $0.selected == "none" }

        // Selection mode on: the wheel (two fingers on a trackpad) still scrolls the pages.
        let before = canvas.frame.minY
        // Over the image (the canvas element runs past the window, so it has no hit point of its own).
        guard let r3 = report(canvas), let f3 = r3.frame("image") else { return XCTFail("no image") }
        point(CGPoint(x: f3.midX, y: f3.midY), on: canvas, r3, app: app).scroll(byDeltaX: 0, deltaY: -120)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(canvas.frame.minY, before, accuracy: 1, "the wheel scrolls the page in selection mode")
    }

    /// A PDF page (a background item filling the page): a click selects it, a drag moves it
    /// and its top-left handle resizes it, keeping its proportions.
    @MainActor
    func testAMouseDragMovesAndResizesAPDFPage() throws {
        let app = launch(note: "respiration", extra: ["SEMPERE_DEMO_PDF": "1"])
        defer { app.terminate() }
        guard let canvas = canvas(app, holding: "pdfPage") else { return XCTFail("no canvas reports the PDF page") }
        Thread.sleep(forTimeInterval: 2)
        // From the lasso: PencilKit's own lasso gestures are there while it is the palette's tool, and
        // took the drag from the item (the palette remembers its tool across launches, so the tests
        // pick it rather than depend on the last run's).
        app.typeKey("5", modifierFlags: [.command, .option])   // Tools > Lasso
        app.typeKey("7", modifierFlags: [.command, .option])   // Tools > Select
        Thread.sleep(forTimeInterval: 1)
        guard let r0 = report(canvas), let f0 = r0.frame("pdfPage") else { return XCTFail("no PDF page") }
        let inside = CGPoint(x: f0.minX + 120, y: f0.minY + 120)
        point(inside, on: canvas, r0, app: app).click()
        guard let r1 = waitReport(canvas, "a click selects the PDF page", { $0.selected == "pdfPage" }) else { return }
        Thread.sleep(forTimeInterval: 0.5)
        let start = point(inside, on: canvas, r1, app: app)
        drag(from: start, to: start.withOffset(CGVector(dx: 40, dy: 30)))
        guard let r2 = waitReport(canvas, "a drag moves the PDF page", { r in
            guard let f = r.frame("pdfPage") else { return false }
            return abs(f.minX - (f0.minX + 40 * pagePerScreen(canvas, r1))) < 6 && abs(f.minY - (f0.minY + 30 * pagePerScreen(canvas, r1))) < 6
        }) else { return }
        XCTAssertEqual(r2.edits, r1.edits + 1, "the move wrote one delta")
        guard let f1 = r2.frame("pdfPage") else { return }
        let corner = point(CGPoint(x: f1.minX, y: f1.minY), on: canvas, r2, app: app)
        drag(from: corner, to: corner.withOffset(CGVector(dx: 60, dy: 60)))
        guard let r3 = waitReport(canvas, "the top-left handle resizes the PDF page", { r in
            guard let f = r.frame("pdfPage") else { return false }
            return f.width < f1.width - 20 && abs(f.maxX - f1.maxX) < 1 && abs(f.maxY - f1.maxY) < 1
        }) else { return }
        XCTAssertEqual(r3.edits, r2.edits + 1, "the resize wrote one delta")
        if let f = r3.frame("pdfPage") {
            XCTAssertEqual(f.width / f.height, f1.width / f1.height, accuracy: 0.02, "the page keeps its proportions")
        }
    }
}
