import XCTest

/// Search highlights end to end (TestFlight 1.0.0 (6), the owner's iPhone: "Search works, but doesn't
/// highlight words or let me find the results, or jump through multiple results on the same page").
/// A search hit opens its note with the words highlighted, the "n of N" bar above the canvas, and
/// next and previous walk every match, scrolling each into the part of the screen the bars leave
/// free: three on one page, two on the next page of a paged note, and three down a pageless note.
///
/// The demo vault's search notes (`SEMPERE_DEMO_SEARCH`, `DemoVault.searchNoteOps`) carry stored
/// recognition, so no recognizer runs; each canvas reports its highlights (`hl=count,current` and
/// `hlRect`, the current match's frame in the window: `PageCanvasHost.highlightReport`).
/// Runs on an iPhone (`scripts/app.sh test-phone-ui`) and an iPad (`scripts/app.sh test-ui`);
/// skipped on a Mac.
final class SearchHighlightUITests: XCTestCase {
    private static let word = "wombat"

    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iPhone and iPad")
        #else
        continueAfterFailure = false
        #endif
    }

    /// A paged note: 1 of 5 on page 1, three matches there (the last one far down), two on page 2. Again from the
    /// note list, when the note opens from the drawing cache (`isPreparing`). Then read zoomed in (an iPhone
    /// pinched to read the handwriting): every page is taller than the screen, so each step must scroll to its
    /// match, also between matches on one page. (One launch; the zoomed walk was a test of its own.)
    @MainActor
    func testStepsThroughMatchesOfAPagedNoteAtTheFitAndZoomed() throws {
        let app = launch()
        defer { app.terminate() }
        openHit(app, title: "Wombat field notes")
        try walk(app, count: 5)
        // Again from the note list: the note now opens from the drawing cache (`isPreparing`).
        try reopen(app, title: "Wombat field notes", count: 5)
        // Zoomed: back to match 1 (the walk ended on 5 of 5), then a pinch.
        let next = app.buttons["Next Match"].firstMatch
        require(next, "the Next Match button", in: app)
        next.tap()
        expectBar(app, position: 1, count: 5)
        let stack = app.descendants(matching: .any)["pageStack"].firstMatch
        require(stack, "the page stack", in: app)
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("A pinch gesture is not available to Mac Catalyst UI tests")
        #else
        stack.pinch(withScale: 2.5, velocity: 1.5)
        #endif
        Thread.sleep(forTimeInterval: 1.5)
        try walk(app, count: 5, checkFirst: false)
    }

    /// A pageless note: three matches, the last one screens below the first.
    @MainActor
    func testStepsThroughMatchesOfAPagelessNote() throws {
        let app = launch()
        defer { app.terminate() }
        openHit(app, title: "Wombat journal")
        try walk(app, count: 3)
        try reopen(app, title: "Wombat journal", count: 3)
    }

    // MARK: - Steps

    /// Searches for the word and opens the hit of the note titled `title`.
    @MainActor
    private func openHit(_ app: XCUIApplication, title: String) {
        let field = app.searchFields.firstMatch
        if isPhone {
            // The phone's stack starts at the sidebar: whichever shows first (not a 5 s wait for the field).
            let notebook = app.descendants(matching: .any).matching(identifier: "sidebar-notebook-Search").firstMatch
            let end = Date().addingTimeInterval(30)
            while !field.exists, !notebook.exists, Date() < end { Thread.sleep(forTimeInterval: 0.3) }
            if !field.exists {
                require(notebook, "the sidebar's Search notebook", in: app)
                notebook.tap()
            }
        }
        require(field, "the search field", in: app)
        field.tap()
        field.typeText(Self.word)
        let hit = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        require(hit, "the search hit of \(title)", in: app)
        hit.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        require(app.descendants(matching: .any)["noteEditor"].firstMatch, "the note \(title)", in: app)
    }

    /// Goes back to the results (the iPhone's stack) or opens another note first (the iPad), then
    /// opens the hit of `title` again and walks its matches.
    @MainActor
    private func reopen(_ app: XCUIApplication, title: String, count: Int) throws {
        if isPhone {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            require(back, "the back button", in: app)
            back.tap()
        } else {
            let other = app.buttons.containing(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@",
                                                           "Wombat", title)).firstMatch
            require(other, "the other search hit", in: app)
            other.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let hit = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        require(hit, "the search hit of \(title) again", in: app)
        hit.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        require(app.descendants(matching: .any)["noteEditor"].firstMatch, "the note \(title) again", in: app)
        try walk(app, count: count)
    }

    /// Checks the bar says "1 of `count`", then steps forward through every match and once around,
    /// then back once: each step shows the current match on screen, clear of the bars.
    @MainActor
    private func walk(_ app: XCUIApplication, count: Int, checkFirst: Bool = true) throws {
        expectBar(app, position: 1, count: count)
        // After a pinch match 1 may have moved off screen: the walk starts from the next one.
        var rects = checkFirst ? [try currentMatch(app, "match 1 of \(count)")] : []
        let next = app.buttons["Next Match"].firstMatch
        let previous = app.buttons["Previous Match"].firstMatch
        require(next, "the Next Match button", in: app)
        XCTAssertTrue(next.isHittable, "Next Match can be tapped")
        for step in 2...count {
            next.tap()
            expectBar(app, position: step, count: count)
            let rect = try currentMatch(app, "match \(step) of \(count)")
            XCTAssertNotEqual(rect, rects.last, "match \(step) is highlighted somewhere else than match \(step - 1)")
            rects.append(rect)
        }
        next.tap()   // wraps around
        expectBar(app, position: 1, count: count)
        _ = try currentMatch(app, "match 1 again")
        XCTAssertTrue(previous.isHittable, "Previous Match can be tapped")
        previous.tap()
        expectBar(app, position: count, count: count)
        _ = try currentMatch(app, "match \(count) going back")
    }

    @MainActor
    private func expectBar(_ app: XCUIApplication, position: Int, count: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        let label = "\(position) of \(count) matches"
        let text = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        require(text, "the match bar saying \(label)", in: app, timeout: 10, file: file, line: line)
    }

    /// The current match's frame in the window, once exactly one canvas reports it and it lies inside
    /// the part of the screen between the match bar and the bottom bar (or the window's bottom).
    @MainActor
    private func currentMatch(_ app: XCUIApplication, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let end = Date().addingTimeInterval(10)
        var last = "no canvas"
        while Date() < end {
            let visible = visibleArea(app)
            var found: [CGRect] = []
            var reports: [String] = []
            for canvas in app.descendants(matching: .any).matching(identifier: "pageCanvas").allElementsBoundByIndex {
                guard let value = canvas.value as? String, let r = Highlights(value) else { continue }
                reports.append("hl=\(r.count),\(r.current ? 1 : 0) rect=\(String(describing: r.rect))")
                if r.current, let rect = r.rect { found.append(rect) }
            }
            last = "visible \(visible), canvases \(reports)"
            if found.count == 1, let rect = found.first, visible.contains(rect) { return rect }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("SEARCHDEBUG \(what):\n\(app.debugDescription.prefix(12000))")
        XCTFail("\(what) is not highlighted on screen: \(last)", file: file, line: line)
        throw XCTSkip("failed")
    }

    /// The window between the match bar and the bottom bar.
    @MainActor
    private func visibleArea(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        var top = window.minY
        let bar = app.staticTexts.containing(NSPredicate(format: "label CONTAINS ' matches' OR label == '1 match'")).firstMatch
        if bar.exists { top = max(top, bar.frame.maxY) }
        var bottom = window.maxY
        let toolbar = app.toolbars.firstMatch
        if toolbar.exists, toolbar.frame.minY > window.midY { bottom = min(bottom, toolbar.frame.minY) }
        return CGRect(x: window.minX, y: top, width: window.width, height: max(bottom - top, 0))
    }

    // MARK: - Launch

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    @MainActor
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_SEARCH": "1", "TZ": "UTC"]
        if !isPhone {
            env["SEMPERE_DEBUG_COLUMNS"] = "all"
            env["SEMPERE_DEMO_SIDEBAR"] = "notebook:Search"
        }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 30,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        print("SEARCHDEBUG \(what):\n\(app.debugDescription.prefix(12000))")
        XCTFail("\(what) not found (app state \(app.state.rawValue))", file: file, line: line)
    }

    /// A canvas report's search fields.
    struct Highlights {
        var count = 0
        var current = false
        var rect: CGRect?

        init?(_ value: String) {
            guard value.hasPrefix("zoom="), value.contains(";hl=") else { return nil }
            let head = value.range(of: ";typing=").map { String(value[..<$0.lowerBound]) } ?? value
            for field in head.split(separator: ";") {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "hl":
                    let c = pair[1].split(separator: ",").compactMap { Int($0) }
                    if c.count == 2 { count = c[0]; current = c[1] == 1 }
                case "hlRect":
                    let c = pair[1].split(separator: ",").compactMap { Double($0) }
                    if c.count == 4 { rect = CGRect(x: c[0], y: c[1], width: c[2], height: c[3]) }
                default: break
                }
            }
        }
    }
}
