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
            Shot(name: "04-map", environment: env(["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEMO_INSIGHTS": "map"]),
                 waitFor: "insightsMap.canvas", timeout: 150, settle: 3, taps: ["Zoom Out"]),
            Shot(name: "05-notes", environment: env(["SEMPERE_DEMO_SIDEBAR": "all"]), waitFor: "New Note"),
            Shot(name: "06-tags", environment: env(["SEMPERE_DEMO_SIDEBAR": "tag:lecture"]), waitFor: "#lecture"),
            Shot(name: "07-library", environment: env([:]), waitFor: "sidebar-notebook-School"),
            Shot(name: "08-unlock", environment: env(["SEMPERE_DEMO_LOCKED": "1"]), waitFor: "Unlock My Notes"),
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
            Shot(name: "04-map", environment: env(all, ["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEMO_INSIGHTS": "map"]),
                 waitFor: "insightsMap.canvas", timeout: 150, settle: 3, taps: ["Zoom Out"]),
            Shot(name: "05-notes", environment: env("doubleColumn", ["SEMPERE_DEMO_NOTE": "respiration"]), waitFor: respiration),
            Shot(name: "06-tags", environment: env("all", ["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEMO_SIDEBAR": "tag:lecture"]),
                 waitFor: "#lecture"),
            Shot(name: "07-paper", environment: env(all, ["SEMPERE_DEMO_NOTE": "atlas", "SEMPERE_DEMO_PAPER_PICKER": "1"]),
                 waitFor: "Apply to This Page"),
            Shot(name: "08-unlock", environment: env("all", ["SEMPERE_DEMO_LOCKED": "1"]), waitFor: "Unlock My Notes"),
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
    private func drawAndUndo(_ strokes: Shot.Underlines, shot: Shot, in app: XCUIApplication) -> XCUIScreenshot? {
        let window = app.windows.firstMatch
        func stroke(_ line: (CGVector, CGVector)) {
            let from = window.coordinate(withNormalizedOffset: line.0)
            let to = window.coordinate(withNormalizedOffset: line.1)
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 1.5)
        }
        let undo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'undoButton' OR label BEGINSWITH 'Undo'")).firstMatch
        let redo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'redoButton' OR label BEGINSWITH 'Redo'")).firstMatch
        let diag = ProcessInfo.processInfo.environment["SEMPERE_SHOTS_DIAG"] != nil
        func phase(_ name: String) {
            guard diag else { return }
            let value = app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.value as? String ?? "-"
            print("SHOTDEBUG diag \(shot.name) \(name) \(value.split(separator: ";").first { $0.hasPrefix("strokes=") } ?? "no strokes=")")
            if let directory = ProcessInfo.processInfo.environment["SEMPERE_SHOTS_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("diag-\(shot.name)-\(name).png"))
            }
        }
        phase("0-before")
        stroke(strokes.kept)
        phase("1-stroke1")
        stroke(strokes.undone)
        phase("2-stroke2")
        let ready = undo.waitForExistence(timeout: 10) && waitUntil(10) { undo.isEnabled }
        XCTAssertTrue(ready, "\(shot.name): Undo never became enabled after the strokes")
        if ready { undo.tap() }
        Thread.sleep(forTimeInterval: 2)
        phase("3-undo2s")
        let redoReady = waitUntil(10) { redo.exists && redo.isEnabled }
        XCTAssertTrue(redoReady, "\(shot.name): Redo never became enabled after Undo")
        if !ready || !redoReady {
            print("SHOTDEBUG \(shot.name): undo=\(undo.exists) redo=\(redo.exists)")
        }
        // After Undo PencilKit redraws its tiles on the simulator, and a screenshot taken meanwhile can show a tile of the
        // page missing (a vertical slice of the drawing gone, now the left part, a moment later the right: the stroke count
        // is right all the time, `SEMPERE_SHOTS_DIAG`). The whole page has the most ink of them, so the shot is the one
        // with the most ink of a dozen taken over the next 20 s.
        var frames: [(XCUIScreenshot, Int)] = []
        for _ in 0..<14 {
            let now = XCUIScreen.main.screenshot()
            frames.append((now, Self.ink(now)))
            Thread.sleep(forTimeInterval: 1.5)
        }
        let most = frames.max { $0.1 < $1.1 }
        let least = frames.map(\.1).min() ?? 0
        print("SHOTDEBUG \(shot.name): ink of \(frames.count) frames after Undo: most \(most?.1 ?? 0), least \(least), \(frames.filter { $0.1 >= (most?.1 ?? 0) * 995 / 1000 }.count) of them whole")
        phase("4-final")
        return most?.0
    }

    /// The dark pixels (on a 200 x 266 gray copy, the rows between the toolbar and the strokes): the ink on the page.
    static func ink(_ shot: XCUIScreenshot) -> Int {
        let w = 200, h = 266
        guard let cg = shot.image.cgImage else { return 0 }
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var dark = 0
        for row in Int(Double(h) * 0.13)..<Int(Double(h) * 0.79) {
            for col in 0..<w where buf[row * w + col] < 170 { dark += 1 }
        }
        return dark
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// A notification banner of the machine, drawn over the top-right corner of the window by another process, is in a screen
    /// capture of it: closes what Notification Center shows (the banner's own Close button, as a person would), Mac only.
    @MainActor
    private func dismissBanners() {
        #if targetEnvironment(macCatalyst)
        let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
        let close = NSPredicate(format: "label IN {'Close','Clear','Clear All','Cerrar','Borrar','Borrar todo'} OR identifier CONTAINS 'close'")
        // The banner is a window of Notification Center near the top-right corner of the screen (its labels are not readable
        // from a test): swiping it to the right is how a person sends it away.
        let screenWidth = XCUIApplication(bundleIdentifier: "com.apple.finder").frame.width
        for _ in 0..<4 {
            let candidates = center.descendants(matching: .any).allElementsBoundByIndex.filter {
                $0.frame.width > 150 && $0.frame.height > 40 && $0.frame.height < 300 && $0.frame.minY < 120
                    && $0.frame.maxX > screenWidth - 60 && $0.frame.minX > screenWidth / 2
            }
            print("SHOTDEBUG banners: \(candidates.count) near the corner: \(candidates.prefix(4).map { "\($0.elementType.rawValue) \($0.frame)" })")
            guard let banner = candidates.first else { break }
            // Hover shows its close button at the top left; else a swipe to the screen's edge.
            banner.hover()
            Thread.sleep(forTimeInterval: 0.7)
            let corner = banner.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.12))
            corner.click()
            Thread.sleep(forTimeInterval: 1)
            banner.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: banner.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5)),
                       withVelocity: .fast, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 1.5)
        }
        #endif
    }

    @MainActor
    private func capture(_ shot: Shot, to directory: URL?) {
        if Self.isMac { dismissBanners() }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // UTC: the note list shows dates, and the demo dates are fractions of a day before noon UTC.
        app.launchEnvironment = shot.environment.merging(["TZ": "UTC"]) { mine, _ in mine }
        app.launchEnvironment["SEMPERE_DEMO_APPEARANCE"] = Self.appearance
        // An iPad's finger draws only when the palette's Draw with Finger says so; the simulator has no Pencil.
        if shot.strokes != nil { app.launchEnvironment["SEMPERE_DEBUG_FINGERS_DRAW"] = "1" }
        // SEMPERE_SHOTS_DIAG: the canvas reports its stroke count and PNGs are kept after each step of the strokes.
        if ProcessInfo.processInfo.environment["SEMPERE_SHOTS_DIAG"] != nil { app.launchEnvironment["SEMPERE_DEMO_ITEMS"] = "1" }
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
        var whole: XCUIScreenshot?
        if let strokes = shot.strokes, found { whole = drawAndUndo(strokes, shot: shot, in: app) }
        let screenshot = whole ?? (Self.isMac ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot())
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
