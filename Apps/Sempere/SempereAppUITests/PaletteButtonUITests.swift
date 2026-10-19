import XCTest

/// The palette comes with Annotate (TestFlight 1.0.0 (6), the owner's iPad: "the annotation button doesn't
/// seem to do anything"). PencilKit's palette showed only for the canvas that was the first responder, so once
/// the note list (or the sidebar, or a field) had taken the focus the button flipped its icon and nothing came
/// up. Sempere's own palette (`DrawingPaletteView`) is a view of the note and needs no focus: Annotate brings it
/// up wherever the focus is, and a second tap (back to reading) puts it away, on the iPad and on the Mac (where
/// PencilKit's never showed at all). The demo vault's "thoughts" note is paged (the page stack). Run by
/// `scripts/app.sh test-ui|test-mac-ui -only-testing:SempereAppUITests/PaletteButtonUITests`. On a phone
/// `PhoneCanvasModeUITests` covers the same.
final class PaletteButtonUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .phone { throw XCTSkip("the iPhone: PhoneCanvasModeUITests") }
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

    /// The palette (`DrawingPaletteView`'s accessibility identifier, the one PencilKit's had).
    @MainActor
    private func palette(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "Drawing-Palette").firstMatch
    }

    @MainActor
    private func annotate(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "annotateButton").firstMatch
    }

    /// Annotate, reading, Annotate, reading: the palette follows each tap.
    @MainActor
    private func checkToggles(_ app: XCUIApplication, _ what: String) {
        XCTAssertTrue(annotate(app).waitForExistence(timeout: 10), "the Annotate button")
        XCTAssertFalse(palette(app).exists, "\(what): no palette while reading (a note opens in reading)")
        for round in 1...2 {
            annotate(app).tap()
            XCTAssertTrue(palette(app).waitForExistence(timeout: 10), "\(what) \(round): Annotate brought the palette up")
            annotate(app).tap()
            XCTAssertTrue(palette(app).waitForNonExistence(timeout: 10), "\(what) \(round): reading put the palette away")
        }
    }

    /// With the note alone on screen, each tap shows or hides the palette.
    @MainActor
    func testAnnotateShowsAndHidesThePalette() throws {
        let app = launch(columns: "detailOnly")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        checkToggles(app, "canvas alone")
    }

    /// The owner's case: with the sidebar and the note list on screen, the list holds the focus (a note
    /// opened from it), so the canvas never took the first responder and no palette showed. Annotate must
    /// bring the palette up.
    @MainActor
    func testAnnotateShowsThePaletteWhileTheListHasTheFocus() throws {
        let app = launch(columns: "all")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pageCanvas").firstMatch.waitForExistence(timeout: 30))
        checkToggles(app, "the note opened from the list")
    }
}
