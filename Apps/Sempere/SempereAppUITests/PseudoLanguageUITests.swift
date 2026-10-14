#if canImport(UIKit)
import UIKit
#endif
import XCTest

/// Layout check for localization (docs/localization.md "Checking layouts"). Walks the main screens of
/// the synthetic demo vault with a pseudo-language and fails when something runs off the window
/// sideways or a single-line label is cut off. `scripts/app.sh pseudo` runs it three times, selected by
/// `TEST_RUNNER_SEMPERE_PSEUDO`:
///
/// - `double`: `-NSDoubleLocalizedStrings YES`, every localized string twice as long;
/// - `rtl`: `-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`, right-to-left layout;
/// - `es`: the Spanish translation.
///
/// Without the variable the test is skipped, so `screenshots.sh` and the app job never run it.
final class PseudoLanguageUITests: XCTestCase {
    enum Mode: String {
        case double, rtl, es

        var arguments: [String] {
            switch self {
            case .double: return ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-NSDoubleLocalizedStrings", "YES"]
            case .rtl: return ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleTextDirection", "YES",
                               "-NSForceRightToLeftWritingDirection", "YES"]
            case .es: return ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
            }
        }
    }

    /// A screen of the demo vault: its launch variables.
    struct Screen {
        let name: String
        let environment: [String: String]
    }

    static let screens: [Screen] = [
        Screen(name: "library", environment: ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all"]),
        Screen(name: "locked", environment: ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_LOCKED": "1"]),
        Screen(name: "note", environment: ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEBUG_COLUMNS": "all"]),
        Screen(name: "tags", environment: ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_SIDEBAR": "tag:lecture", "SEMPERE_DEBUG_COLUMNS": "all"]),
        Screen(name: "paper", environment: ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_NOTE": "atlas", "SEMPERE_DEMO_PAPER_PICKER": "1",
                                           "SEMPERE_DEBUG_COLUMNS": "detailOnly"]),
        Screen(name: "settings", environment: ["SEMPERE_DEMO": "1", "SEMPERE_DEMO_SETTINGS": "1", "SEMPERE_DEBUG_COLUMNS": "all"]),
    ]

    @MainActor
    func testScreensFitInPseudoLanguage() throws {
        let raw = ProcessInfo.processInfo.environment["SEMPERE_PSEUDO"] ?? ""
        try XCTSkipUnless(!raw.isEmpty, "run scripts/app.sh pseudo")
        let mode = try XCTUnwrap(Mode(rawValue: raw), "SEMPERE_PSEUDO must be double, rtl or es")
        continueAfterFailure = true
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        for screen in Self.screens {
            check(screen, mode: mode)
        }
    }

    @MainActor
    private func check(_ screen: Screen, mode: Mode) {
        let app = XCUIApplication()
        app.launchArguments = mode.arguments
        app.launchEnvironment = screen.environment.merging(["TZ": "UTC"]) { mine, _ in mine }
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 45), "\(mode.rawValue)/\(screen.name): no window")
        // The demo vault is built, opened and drawn asynchronously.
        Thread.sleep(forTimeInterval: 8)

        let bounds = window.frame
        var problems: [String] = []
        for kind in [XCUIElement.ElementType.staticText, .button, .textField, .secureTextField, .switch] {
            for element in app.descendants(matching: kind).allElementsBoundByIndex.prefix(250) where element.exists && element.isHittable {
                let frame = element.frame
                let label = element.label
                guard !frame.isEmpty, !label.isEmpty else { continue }
                // Sideways overflow is a bug; vertical overflow is just scrolling.
                if frame.minX < bounds.minX - 1 || frame.maxX > bounds.maxX + 1 {
                    problems.append("off the window sideways: “\(label)” \(frame)")
                }
                if kind == .staticText, Self.isTruncated(label, in: frame) {
                    problems.append("truncated: “\(label)” in \(frame.width) pt")
                }
            }
        }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "\(mode.rawValue)-\(screen.name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        for problem in Set(problems).sorted() {
            XCTFail("\(mode.rawValue)/\(screen.name): \(problem)")
        }
    }

    /// A one-line label whose frame is narrower than its text at the smallest text style. A lower bound,
    /// so it cannot cry wolf: a wrapped label is taller than a line and exempt.
    static func isTruncated(_ label: String, in frame: CGRect) -> Bool {
        #if canImport(UIKit)
        let font = UIFont.preferredFont(forTextStyle: .caption2)
        let size = (label as NSString).size(withAttributes: [.font: font])
        let oneLine = frame.height < size.height * 1.6
        return oneLine && size.width > frame.width + 2
        #else
        return false
        #endif
    }
}
