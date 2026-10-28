import XCTest

/// TestFlight build 8 ("pickers-mac"): a note dragged from the list to the Finder must become a file in the
/// format Settings ▸ General ▸ Drag to Finder picks. The drop is a file promise the Finder asks the app to
/// keep, which only a real drag between the two apps exercises: these open a Finder window on a fresh folder,
/// drag a row of the demo vault onto it with the pointer and wait for the file. Run by `scripts/app.sh
/// test-mac-ui -only-testing:SempereAppUITests/MacDragToFinderUITests` (not in `test-mac-ui`'s default list).
///
/// OPEN (2026-10-26): both fail, reproducing the owner's report. With `SEMPERE_DEBUG_DROPS` the app's
/// `tmp/drag-trace.txt` shows `NoteFileDrag.register` running when the drag starts, but the Finder never asks
/// for the file (no "requested" line; the trace now mirrors the `drag` log, `DragLog`): the promise never reaches the Finder, so the fix is in how the row's
/// drag is offered (SwiftUI `onDrag` on a `List` row under Catalyst), not in rendering the file.
///
/// CAVEAT: this harness cannot tell a fix from the bug yet. Tried 2026-10-26: a `UIDragInteraction` on the
/// row's cell (as notebook rows have) lifted and ended with `.cancel`, Finder never asking; a plain
/// `NSItemProvider(contentsOf:)` of a file already on disk did the same; and a control dragging a file
/// from one Finder window to another with the same synthesized pointer moved nothing either. So
/// XCUITest's synthesized drags do not drop into the Finder here: a fix must be checked by hand on a Mac
/// (or this test made to drop by other means) before it can be trusted. The by-hand check: the debug build
/// and the `drag` log (`DragLog`, `NoteDragStyle`; docs/mac.md "Debugging a drag out").
@MainActor
final class MacDragToFinderUITests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
        continueAfterFailure = false
    }

    private func launch(format: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES",
                               "-Sempere.dragFormat", format]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_MAC_WINDOW": "900x700", "SEMPERE_DEBUG_DROPS": "1",
                                 "TZ": "UTC"]
        app.launch()
        return app
    }

    /// A fresh folder for the Finder window, removed afterwards.
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sempere-ui-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func files(in dir: URL, timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let list = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasPrefix(".") } ?? []
            if !list.isEmpty { return list }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return []
    }

    /// A screen point as a coordinate (relative to `element`, which may be in another app).
    private func point(_ p: CGPoint, from element: XCUIElement) -> XCUICoordinate {
        let origin = element.frame.origin
        return element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x - origin.x, dy: p.y - origin.y))
    }

    /// Opens a Finder window on `dir` (Go to Folder) and returns it. The windows this adds to the Finder are
    /// closed when the test ends, pass or fail (a run once left dozens open on the screen). The teardown block
    /// closes by element, with the window's own close button, only windows whose title was not among those open
    /// before (a title open twice before counts twice), so a window the owner or another job had open stays.
    private func finderWindow(on dir: URL) -> (XCUIApplication, XCUIElement) {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        var existing: [String: Int] = [:]
        for w in finder.windows.allElementsBoundByIndex { existing[w.title, default: 0] += 1 }
        addTeardownBlock { [finder, existing] in
            // Read every title first, then close from the highest index down: windows are addressed by index and
            // closing one shifts the rest, so a forward walk would read vanished indices.
            let titles = finder.windows.allElementsBoundByIndex.map(\.title)
            var seen: [String: Int] = [:]
            var toClose: [Int] = []
            for (i, t) in titles.enumerated() {
                seen[t, default: 0] += 1
                if seen[t, default: 0] > existing[t, default: 0] { toClose.append(i) }
            }
            for i in toClose.reversed() {
                let w = finder.windows.element(boundBy: i)
                guard w.exists else { continue }
                let close = w.buttons[XCUIIdentifierCloseWindow]
                if close.exists {
                    close.click()
                } else {
                    w.click()
                    finder.typeKey("w", modifierFlags: .command)
                }
            }
        }
        finder.activate()
        finder.typeKey("n", modifierFlags: .command)
        sleep(1)
        finder.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        finder.typeText(dir.path + "\r")
        sleep(2)
        let window = finder.windows[dir.lastPathComponent].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "a Finder window on the folder")
        return (finder, window)
    }

    private func dragNote(format: String, expecting ext: String) throws {
        let dir = try folder()
        let (finder, window) = finderWindow(on: dir)
        let app = launch(format: format)
        defer { app.terminate() }
        let row = app.staticTexts.matching(NSPredicate(format: "label == %@", "Sync design sketch")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 90), "the note row")
        // Put the Finder window to the right of the app's.
        let appFrame = app.windows.firstMatch.frame
        var target = window.frame
        if target.intersects(appFrame) {
            let bar = point(CGPoint(x: target.midX, y: target.minY + 12), from: window)
            let to = point(CGPoint(x: appFrame.maxX + target.width / 2 + 20, y: appFrame.minY + 12), from: window)
            bar.click(forDuration: 0.3, thenDragTo: to)
            sleep(1)
            target = window.frame
        }
        print("DRAGDEBUG app=\(appFrame) finder=\(target)")
        let free = target.intersection(appFrame).isNull ? target
            : CGRect(x: max(target.minX, appFrame.maxX), y: target.minY, width: target.maxX - max(target.minX, appFrame.maxX),
                     height: target.height)
        XCTAssertGreaterThan(free.width, 60, "some of the Finder window is clear of the app's")
        let drop = CGPoint(x: free.midX, y: free.midY)
        app.activate()
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.6, thenDragTo: point(drop, from: row), withVelocity: .slow, thenHoldForDuration: 1.0)
        let written = files(in: dir, timeout: 30)
        XCTAssertEqual(written.count, 1, "one file dropped: \(written)")
        XCTAssertEqual(written.first.map { ($0 as NSString).pathExtension }, ext, "\(written)")
        _ = finder
    }

    func testDraggingANoteToTheFinderWritesAPDF() throws {
        try dragNote(format: "pdf", expecting: "pdf")
    }

    func testDraggingANoteToTheFinderWritesMarkdown() throws {
        try dragNote(format: "markdown", expecting: "md")
    }
}
