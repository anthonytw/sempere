import XCTest

/// The toolbar's palette button on the iPad (TestFlight 1.0.0 (6), the owner's iPad: "the annotation
/// button doesn't seem to do anything"). The palette shows only for the canvas that is the first
/// responder; once the note list (or the sidebar, or a field) had taken the focus, the button flipped
/// its icon on every tap but nothing came up, because turning the palette on never gave the canvas the
/// focus back. A tap on "Show Tool Palette" now brings the palette up wherever the focus was, and
/// "Hide Tool Palette" puts it away. The demo vault's "thoughts" note is paged (the page stack).
/// Run by `scripts/app.sh test-ui -only-testing:SempereAppUITests/PaletteButtonUITests`. Skipped on a
/// Mac: PencilKit never shows its tool picker in a Mac Catalyst app (Apple's `PKToolPicker` docs), and
/// on a phone the pencil button is the Annotate mode (`PhoneCanvasModeUITests`).
final class PaletteButtonUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("PencilKit shows no tool picker on Mac Catalyst")
        #else
        if UIDevice.current.userInterfaceIdiom == .phone { throw XCTSkip("the iPhone has its own modes (PhoneCanvasModeUITests)") }
        #endif
        continueAfterFailure = false
    }

    @MainActor
    private func launch(columns: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": columns, "SEMPERE_DEMO_NOTE": "thoughts",
                                 "SEMPERE_DEBUG_PENCIL_ONLY": "1", "TZ": "UTC"]
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launch()
        return app
    }

    /// PencilKit's palette (its accessibility identifier).
    @MainActor
    private func palette(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch
    }

    @MainActor
    private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The button reads `label`; tap it until it does (the setting is remembered across launches).
    @MainActor
    private func setButton(_ app: XCUIApplication, reading label: String) {
        let other = label == "Show Tool Palette" ? "Hide Tool Palette" : "Show Tool Palette"
        XCTAssertTrue(button(app, label).waitForExistence(timeout: 10) || button(app, other).exists, "the palette button")
        if button(app, other).exists { button(app, other).tap() }
        XCTAssertTrue(button(app, label).waitForExistence(timeout: 5), "the button reads \(label)")
    }

    /// Show, hide, show, hide: the palette follows each tap.
    @MainActor
    private func checkToggles(_ app: XCUIApplication, _ what: String) {
        for round in 1...2 {
            button(app, "Show Tool Palette").tap()
            XCTAssertTrue(button(app, "Hide Tool Palette").waitForExistence(timeout: 5), "\(what) \(round): the button reads Hide")
            XCTAssertTrue(palette(app).waitForExistence(timeout: 10), "\(what) \(round): Show brought the palette up")
            button(app, "Hide Tool Palette").tap()
            XCTAssertTrue(button(app, "Show Tool Palette").waitForExistence(timeout: 5), "\(what) \(round): the button reads Show")
            XCTAssertTrue(palette(app).waitForNonExistence(timeout: 10), "\(what) \(round): Hide put the palette away")
        }
    }

    /// With the canvas focused (the note alone on screen), each tap shows or hides the palette.
    @MainActor
    func testThePaletteButtonShowsAndHidesThePalette() throws {
        let app = launch(columns: "detailOnly")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        setButton(app, reading: "Show Tool Palette")
        checkToggles(app, "canvas focused")
    }

    /// The owner's case: with the sidebar and the note list on screen, the list holds the focus (a note
    /// opened from it, or a tap on a row), so the canvas never took the first responder and no palette
    /// showed; the button flipped its icon on every tap and showed nothing. It must bring the palette up.
    @MainActor
    func testThePaletteButtonShowsThePaletteWhileTheListHasTheFocus() throws {
        let app = launch(columns: "all")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        setButton(app, reading: "Show Tool Palette")
        XCTAssertFalse(palette(app).exists, "no palette while it is off")
        checkToggles(app, "the note opened from the list")
    }
}
