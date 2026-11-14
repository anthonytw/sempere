#if canImport(UIKit)
import UIKit
#endif
import XCTest

/// Captures the App Store screenshots from the synthetic demo vault
/// (`DemoVault`, opened through `SEMPERE_DEMO*` launch variables, `DemoLaunch`).
/// Run through `scripts/screenshots.sh`, which sets the simulator up (status bar,
/// light mode) and passes `TEST_RUNNER_SEMPERE_SHOTS_DIR`: the PNGs are written
/// there and also attached to the result bundle.
///
/// Each shot is a fresh launch whose state comes from the environment, so the
/// test taps nothing: a change to the UI cannot break a shot's navigation. The two exceptions are `01-write` and
/// `02-sketch` (docs/design/1.2-screenshots.md §3.1): they draw two strokes with a finger and tap Undo once, so the
/// store page shows Undo and Redo both enabled and one stroke left over, an underline.
final class ScreenshotTests: XCTestCase {
    /// One screenshot: its file name, the launch variables, and the label (or accessibility identifier) to wait for.
    struct Shot {
        let name: String
        let environment: [String: String]
        let waitFor: String
        /// Drawn on the page before the shot (`Shot.Underlines`), then Undo once; nil: nothing is tapped.
        var strokes: Underlines? = nil
        /// How long to wait for `waitFor` (the Note Insights shots wait for the fake providers' passes).
        var timeout: TimeInterval = 45
        /// Extra settling time after the screen shows, on top of the usual six seconds.
        var settle: TimeInterval = 0
        /// Buttons (by label) tapped once the screen shows, in order (the map's Zoom Out).
        var taps: [String] = []

        /// Two finger strokes, each from and to a point of the screen (0...1 of its width and height): the first stays,
        /// the second is undone, so Undo and Redo are enabled and a stroke is left.
        struct Underlines {
            let kept: (CGVector, CGVector)
            let undone: (CGVector, CGVector)
        }
    }

    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// The shots for this platform, in the order they appear on the store page.
    @MainActor
    static var shots: [Shot] {
        #if !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .phone { return phoneShots }
        #endif
        return deviceShots
    }

    /// The iPhone is a stack, so each shot is one screen of it. The launch variables
    /// pick the screen (a note opens the note view; a sidebar item alone, its list).
    /// "Annotate" is the note view's pencil button. The paper picker is not shown on the phone.
    static var phoneShots: [Shot] {
        func env(_ extra: [String: String]) -> [String: String] {
            var e = ["SEMPERE_DEMO": "1"]
            for (k, v) in extra { e[k] = v }
            return e
        }
        return [
            // Annotating (the compact palette has Undo and Redo): a finger draws two strokes, Undo takes the second back.
            Shot(name: "01-write", environment: env(["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEBUG_NOTE_MODE": "annotate"]),
                 waitFor: "Drawing-Palette",
                 strokes: .init(kept: (CGVector(dx: 0.13, dy: 0.625), CGVector(dx: 0.52, dy: 0.625)),
                                undone: (CGVector(dx: 0.13, dy: 0.655), CGVector(dx: 0.40, dy: 0.655)))),
            Shot(name: "02-sketch", environment: env(["SEMPERE_DEMO_NOTE": "atlas", "SEMPERE_DEBUG_NOTE_MODE": "annotate"]),
                 waitFor: "Drawing-Palette",
                 strokes: .init(kept: (CGVector(dx: 0.13, dy: 0.625), CGVector(dx: 0.52, dy: 0.625)),
                                undone: (CGVector(dx: 0.13, dy: 0.655), CGVector(dx: 0.40, dy: 0.655)))),
            // Note Insights, the 1.2 headline: the note's sheet (summary, keywords, related notes). The map
            // (`SEMPERE_DEMO_INSIGHTS=map`) is not shot for the store: the demo's twelve notes make one group, which says little.
            Shot(name: "03-insights", environment: env(["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEMO_INSIGHTS": "note"]),
                 waitFor: "noteInsights", timeout: 150, settle: 3),
            Shot(name: "04-notes", environment: env(["SEMPERE_DEMO_SIDEBAR": "all"]), waitFor: "New Note"),
            Shot(name: "05-tags", environment: env(["SEMPERE_DEMO_SIDEBAR": "tag:lecture"]), waitFor: "#lecture"),
            Shot(name: "06-library", environment: env([:]), waitFor: "sidebar-notebook-School"),
            Shot(name: "07-unlock", environment: env(["SEMPERE_DEMO_LOCKED": "1"]), waitFor: "Unlock My Notes"),
        ]
    }

    /// The iPad's and the Mac's shots.
    static var deviceShots: [Shot] {
        // "Annotate" (the pencil) is in the toolbar whenever an editable note is open; the note's own title is
        // not (a crowded toolbar drops it). The shots open their notes annotating, the palette up.
        let respiration = "Annotate"
        let atlas = "Annotate"
        let all = isMac ? "all" : "detailOnly"
        func env(_ columns: String, _ extra: [String: String]) -> [String: String] {
            var e = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": columns, "SEMPERE_DEBUG_NOTE_MODE": "annotate"]
            if isMac { e["SEMPERE_DEMO_MAC_WINDOW"] = "1280x800" }
            for (k, v) in extra { e[k] = v }
            return e
        }
        return [
            // The Mac's Undo and Redo are in its Edit menu, which a window shot does not show: its strokes are not drawn.
            Shot(name: "01-write", environment: env(all, ["SEMPERE_DEMO_NOTE": "respiration"]), waitFor: respiration,
                 strokes: isMac ? nil : .init(kept: (CGVector(dx: 0.14, dy: 0.82), CGVector(dx: 0.52, dy: 0.82)),
                                              undone: (CGVector(dx: 0.14, dy: 0.85), CGVector(dx: 0.40, dy: 0.85)))),
            Shot(name: "02-sketch", environment: env(all, ["SEMPERE_DEMO_NOTE": "atlas"]), waitFor: atlas,
                 strokes: isMac ? nil : .init(kept: (CGVector(dx: 0.14, dy: 0.82), CGVector(dx: 0.52, dy: 0.82)),
                                              undone: (CGVector(dx: 0.14, dy: 0.85), CGVector(dx: 0.40, dy: 0.85)))),
            Shot(name: "03-insights", environment: env(all, ["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEMO_INSIGHTS": "note"]),
                 waitFor: "noteInsights", timeout: 150, settle: 3),
            Shot(name: "04-notes", environment: env("doubleColumn", ["SEMPERE_DEMO_NOTE": "respiration"]), waitFor: respiration),
            Shot(name: "05-tags", environment: env("all", ["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEMO_SIDEBAR": "tag:lecture"]),
                 waitFor: "#lecture"),
            Shot(name: "06-paper", environment: env(all, ["SEMPERE_DEMO_NOTE": "atlas", "SEMPERE_DEMO_PAPER_PICKER": "1"]),
                 waitFor: "Apply to This Page"),
            Shot(name: "07-unlock", environment: env("all", ["SEMPERE_DEMO_LOCKED": "1"]), waitFor: "Unlock My Notes"),
        ]
    }

    @MainActor
    func testCaptureScreenshots() throws {
        continueAfterFailure = true
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let directory = ProcessInfo.processInfo.environment["SEMPERE_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // SEMPERE_SHOTS_ONLY (a comma-separated list of shot names, passed as TEST_RUNNER_SEMPERE_SHOTS_ONLY): just those.
        let only = (ProcessInfo.processInfo.environment["SEMPERE_SHOTS_ONLY"] ?? "").split(separator: ",").map(String.init)
        for shot in Self.shots where only.isEmpty || only.contains(shot.name) {
            capture(shot, to: directory)
        }
    }

    /// `SEMPERE_SHOTS_APPEARANCE` (`scripts/screenshots.sh`), `light` unless it says `dark`.
    static var appearance: String { ProcessInfo.processInfo.environment["SEMPERE_SHOTS_APPEARANCE"] == "dark" ? "dark" : "light" }

    /// Two finger strokes, then Undo once (the toolbar's button on the iPad, the compact palette's on the iPhone): the
    /// first stroke stays like an underline, Undo and Redo are both enabled when the shot is taken. A miss is logged
    /// and the shot still taken.
    @MainActor
    private func drawAndUndo(_ strokes: Shot.Underlines, shot: Shot, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        func stroke(_ line: (CGVector, CGVector)) {
            let from = window.coordinate(withNormalizedOffset: line.0)
            let to = window.coordinate(withNormalizedOffset: line.1)
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 1.5)
        }
        let undo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'undoButton' OR label BEGINSWITH 'Undo'")).firstMatch
        let redo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'redoButton' OR label BEGINSWITH 'Redo'")).firstMatch
        stroke(strokes.kept)
        stroke(strokes.undone)
        let ready = undo.waitForExistence(timeout: 10) && waitUntil(10) { undo.isEnabled }
        XCTAssertTrue(ready, "\(shot.name): Undo never became enabled after the strokes")
        if ready { undo.tap() }
        let redoReady = waitUntil(10) { redo.exists && redo.isEnabled }
        XCTAssertTrue(redoReady, "\(shot.name): Redo never became enabled after Undo")
        if !ready || !redoReady {
            print("SHOTDEBUG \(shot.name): undo=\(undo.exists) redo=\(redo.exists)")
        }
        // The page redraws its tiles after the undo (a shot taken too soon showed half of the page), and the buttons settle.
        Thread.sleep(forTimeInterval: 10)
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    @MainActor
    private func capture(_ shot: Shot, to directory: URL?) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // UTC: the note list shows dates, and the demo dates are fractions of a day before noon UTC.
        app.launchEnvironment = shot.environment.merging(["TZ": "UTC"]) { mine, _ in mine }
        app.launchEnvironment["SEMPERE_DEMO_APPEARANCE"] = Self.appearance
        // An iPad's finger draws only when the palette's Draw with Finger says so; the simulator has no Pencil.
        if shot.strokes != nil { app.launchEnvironment["SEMPERE_DEBUG_FINGERS_DRAW"] = "1" }
        app.launch()
        let label = NSPredicate(format: "label CONTAINS %@ OR identifier == %@", shot.waitFor, shot.waitFor)
        let found = app.descendants(matching: .any).matching(label).firstMatch.waitForExistence(timeout: shot.timeout)
        XCTAssertTrue(found, "\(shot.name): never showed “\(shot.waitFor)”")
        if !found {
            // What was on screen, for the CI log.
            let labels = app.descendants(matching: .any).allElementsBoundByIndex.prefix(60).map(\.label).filter { !$0.isEmpty }
            print("SHOTDEBUG \(shot.name): \(labels)")
        }
        // PencilKit draws its tiles asynchronously; the sheets and the palette settle too.
        Thread.sleep(forTimeInterval: 6 + shot.settle)
        for label in shot.taps where found {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 5) { button.tap() } else { print("SHOTDEBUG \(shot.name): no button \(label)") }
            Thread.sleep(forTimeInterval: 1)
        }
        if let strokes = shot.strokes, found { drawAndUndo(strokes, shot: shot, in: app) }
        let screenshot = Self.isMac ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = shot.name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory {
            do {
                try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(shot.name).png"))
            } catch {
                // The Mac runner is sandboxed; its shots are read from the result bundle's attachments.
                if !Self.isMac { XCTFail("\(shot.name): could not write the PNG: \(error)") }
            }
        }
        app.terminate()
    }
}
