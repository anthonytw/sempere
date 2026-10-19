import XCTest

// Pinches: XCUIElement has no `pinch` in the Mac UI test build, so this iPad suite is left out of it.
#if !targetEnvironment(macCatalyst)

/// The owner's iPad on TestFlight 1.0.0 (6), on a long pageless note like one imported from
/// Notability (`SEMPERE_DEMO_DENSE`: the demo vault's "dense" note, ruled, with the demo items):
/// a pinch zooms out below the fitted width on a pageless note and on a paged one; the item menu
/// a held finger brings up goes when the page scrolls, and a hold that turns into a scroll brings
/// none. (Scrolling it is measured in process, `CanvasZoomScrollTests`: the simulator records no
/// scroll hitches, only durations.)
/// The canvas reports its zoom, offset and menu (`ItemSelectionController.debugReport`).
/// Run by `scripts/app.sh test-ui -only-testing:SempereAppUITests/IPadZoomScrollUITests`; skipped on a Mac.
final class IPadZoomScrollUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPad only")
        #endif
        continueAfterFailure = false
    }

    /// The fields of the canvas's report this suite reads.
    struct Report {
        var zoom: CGFloat = 1
        var offset = CGPoint.zero
        var width: CGFloat = 0
        var selected = "none"
        var menu = false
        var items: [(kind: String, frame: CGRect)] = []

        init?(_ value: String) {
            guard value.hasPrefix("zoom=") else { return nil }
            let head = value.range(of: ";typing=").map { String(value[..<$0.lowerBound]) } ?? value
            for field in head.split(separator: ";") {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let numbers = pair[1].split(separator: ",").compactMap { Double($0) }
                switch pair[0] {
                case "zoom": zoom = CGFloat(Double(pair[1]) ?? 1)
                case "offset" where numbers.count == 2: offset = CGPoint(x: numbers[0], y: numbers[1])
                case "width": width = CGFloat(Double(pair[1]) ?? 0)
                case "selected": selected = pair[1]
                case "menu": menu = pair[1] == "1"
                case "items":
                    items = pair[1].split(separator: "|").compactMap { entry in
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

    /// Strokes on the dense note: enough for a long page; the simulator draws ink without the GPU.
    static let denseStrokes = 3_000

    @MainActor
    private func launch(note: String = "dense", items: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "detailOnly", "SEMPERE_DEMO_NOTE": note,
                   "SEMPERE_DEMO_DENSE": "\(Self.denseStrokes)", "SEMPERE_DEBUG_PENCIL_ONLY": "1", "TZ": "UTC"]
        if items { env["SEMPERE_DEMO_ITEMS"] = "1" }
        app.launchEnvironment = env
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        return app
    }

    /// The page canvas whose report lists an item of `kind`.
    @MainActor
    private func canvas(_ app: XCUIApplication, holding kind: String = "image") -> XCUIElement? {
        let canvases = app.descendants(matching: .any).matching(identifier: "pageCanvas")
        for _ in 0..<90 {
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
    @discardableResult
    private func waitReport(_ canvas: XCUIElement, _ what: String, timeout: TimeInterval = 8,
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

    /// The screen coordinate of page point `p` on `canvas`.
    @MainActor
    private func point(_ p: CGPoint, on canvas: XCUIElement, _ r: Report, app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let f = canvas.frame
        return origin.withOffset(CGVector(dx: f.minX - window.frame.minX + p.x * r.zoom - r.offset.x,
                                          dy: f.minY - window.frame.minY + p.y * r.zoom - r.offset.y))
    }

    // MARK: Zoom

    /// A pageless note (an import from Notability is one) zooms out below the fitted width: it
    /// stopped at the fit ("still can't zoom out farther than 100%").
    @MainActor
    func testAPagelessNoteZoomsOutBelowTheFit() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app), let start = report(canvas) else { return XCTFail("no canvas reports the dense note") }
        let fit = start.width / 612
        XCTAssertEqual(start.zoom, fit, accuracy: 0.01, "the note opens at the fitted width")
        canvas.pinch(withScale: 0.5, velocity: -1)
        waitReport(canvas, "a pinch zooms out below the fit") { $0.zoom < fit * 0.85 && $0.zoom >= fit * 0.5 - 0.01 }
    }

    /// A paged note zooms out below the fit too (its pages are a stack; the pinch is the stack's).
    @MainActor
    func testAPagedNoteZoomsOutBelowTheFit() throws {
        let app = launch(note: "thoughts")
        defer { app.terminate() }
        guard let canvas = canvas(app), let start = report(canvas) else { return XCTFail("no canvas reports the demo items") }
        let stack = app.descendants(matching: .any)["pageStack"].firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 10))
        stack.pinch(withScale: 0.5, velocity: -1)
        waitReport(canvas, "a pinch zooms the pages out below the fit") { $0.zoom < start.zoom * 0.85 }
    }

    // MARK: The hold menu

    /// The menu a held finger brings up on the dense page goes as soon as the page scrolls.
    @MainActor
    func testTheHoldMenuGoesWhenThePageScrolls() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app), let r = report(canvas), let f = r.frame("image") else { return XCTFail("no image") }
        point(CGPoint(x: f.midX, y: f.midY), on: canvas, r, app: app).press(forDuration: 1.0)
        waitReport(canvas, "a held finger shows the image's menu") { $0.menu && $0.selected == "image" }
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8))
        from.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        waitReport(canvas, "a scroll dismisses it") { !$0.menu && $0.offset.y > r.offset.y + 50 }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(report(canvas)?.menu, false, "and it stays gone")
    }

    /// A finger held on an item that then scrolls the page brings no menu when it lifts: one used to
    /// come up after the scroll, over another part of the page.
    @MainActor
    func testAHoldThatScrollsShowsNoMenu() throws {
        let app = launch()
        defer { app.terminate() }
        guard let canvas = canvas(app), let r = report(canvas), let f = r.frame("image") else { return XCTFail("no image") }
        let start = point(CGPoint(x: f.midX, y: f.midY), on: canvas, r, app: app)
        start.press(forDuration: 0.9, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)))
        Thread.sleep(forTimeInterval: 1.5)
        let after = report(canvas)
        XCTAssertEqual(after?.menu, false, "no menu after a hold that scrolled: \(String(describing: canvas.value))")
    }
}
#endif
