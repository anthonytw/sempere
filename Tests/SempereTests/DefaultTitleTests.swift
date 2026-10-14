import Foundation
import XCTest
@testable import Sempere

final class DefaultTitleTests: XCTestCase {
    let posix = Locale(identifier: "en_US_POSIX")
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-07 14:05:09 UTC.
    let date = Date(timeIntervalSince1970: 1_791_381_909)

    func testPatternsAndLiteralText() {
        XCTAssertEqual(DefaultTitle.title(at: date, format: "yyyy-MM-dd HH:mm", locale: posix, timeZone: utc),
                       "2026-10-07 14:05")
        XCTAssertEqual(DefaultTitle.title(at: date, format: "'Lecture' EEE d MMM", locale: posix, timeZone: utc),
                       "Lecture Wed 7 Oct")
        XCTAssertEqual(DefaultTitle.title(at: date, format: "  HH:mm  ", locale: posix, timeZone: utc), "14:05",
                       "trimmed")
        XCTAssertEqual(DefaultTitle.title(at: date, format: "EEEE", locale: Locale(identifier: "es_ES"), timeZone: utc),
                       "miércoles")
    }

    func testEmptyOrUnusableFormatsFallBackToTheLocaleDefault() {
        let fallback = DefaultTitle.title(at: date, format: nil, locale: posix, timeZone: utc)
        XCTAssertTrue(fallback.contains("2026") && fallback.contains("Oct"), fallback)
        XCTAssertEqual(DefaultTitle.title(at: date, format: "", locale: posix, timeZone: utc), fallback)
        XCTAssertEqual(DefaultTitle.title(at: date, format: "   ", locale: posix, timeZone: utc), fallback)
        XCTAssertEqual(DefaultTitle.title(at: date, format: "' '", locale: posix, timeZone: utc), fallback,
                       "a pattern that gives nothing")
        let long = String(repeating: "y", count: DefaultTitle.maxFormatLength + 1)
        XCTAssertNil(DefaultTitle.usable(long))
        XCTAssertEqual(DefaultTitle.title(at: date, format: long, locale: posix, timeZone: utc), fallback)
        let longest = String(repeating: "yyyy", count: DefaultTitle.maxFormatLength / 4)
        XCTAssertLessThanOrEqual(DefaultTitle.title(at: date, format: longest, locale: posix, timeZone: utc).count,
                                 DefaultTitle.maxTitleLength)
    }

    func testEverySuggestionGivesATitle() {
        for format in DefaultTitle.suggestions {
            XCTAssertFalse(DefaultTitle.title(at: date, format: format, locale: posix, timeZone: utc).isEmpty, format)
        }
    }
}

/// The format's validation (TestFlight build 7: a validated field with a
/// live preview), shared by the app's settings and `notes new --title-format`.
final class DefaultTitleValidationTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_791_381_900)   // 2026-10-07 14:05 UTC (a Wednesday)
    let posix = Locale(identifier: "en_US_POSIX")
    let utc = TimeZone(identifier: "UTC")!

    func title(_ f: String) -> String { DefaultTitle.title(at: date, format: f, locale: posix, timeZone: utc) }
    func check(_ f: String) -> DefaultTitle.Problem? { DefaultTitle.check(f, at: date, locale: posix, timeZone: utc) }

    func testUnicodePatternsAreChecked() {
        XCTAssertNil(check(""))
        XCTAssertNil(check("yyyy-MM-dd HH:mm"))
        XCTAssertNil(check("'Lecture' EEE d MMM"))
        XCTAssertNil(check("'It''s' d MMM"), "'' is a quote inside literal text")
        XCTAssertNil(check("d MMM ''yy"), "and outside it")
        XCTAssertEqual(check("'Lecture d MMM"), .unclosedQuote)
        XCTAssertEqual(check("Lecture d MMM"), .unknownLetter("t"), "the first letter that is no field")
        XCTAssertEqual(check("yyyy-MM-dd T HH"), .unknownLetter("T"))
        XCTAssertEqual(check("' '"), .blank)
        XCTAssertEqual(check(String(repeating: "y", count: DefaultTitle.maxFormatLength + 1)),
                       .tooLong(DefaultTitle.maxFormatLength + 1))
        XCTAssertEqual(title("'It''s' d MMM"), "It's 7 Oct")
        // A refused format falls back to the locale's default, never to garbage.
        XCTAssertEqual(title("Lecture d MMM"), DefaultTitle.title(at: date, format: nil, locale: posix, timeZone: utc))
        XCTAssertNil(DefaultTitle.usable("'Lecture d MMM"))
    }

    func testStrftimeFormatsAreTranslated() {
        XCTAssertEqual(title("%Y-%m-%d %H:%M"), "2026-10-07 14:05")
        XCTAssertEqual(title("Lecture %a %e %b"), "Lecture Wed 7 Oct", "letters are literal in a strftime format")
        XCTAssertEqual(title("%F %R"), "2026-10-07 14:05")
        XCTAssertEqual(title("%A, %B %-d at %-I:%M %p"), "Wednesday, October 7 at 2:05 PM")
        XCTAssertEqual(title("100%% done %y"), "100% done 26")
        XCTAssertEqual(title("Bob's %Y"), "Bob's 2026", "a quote in a strftime format is literal")
        XCTAssertEqual(check("%Y-%Q"), .unknownDirective("%Q"))
        XCTAssertEqual(check("%Y %"), .unknownDirective("%"))
        XCTAssertEqual(try DefaultTitle.pattern("%d.%m.").get(), "dd'.'MM'.'")
        XCTAssertEqual(try DefaultTitle.pattern("'100%' yyyy").get(), "'100%' yyyy", "a quoted % is a pattern's literal")
    }

    func testProblemsSayWhatToDo() {
        for p in [DefaultTitle.Problem.unclosedQuote, .unknownLetter("t"), .unknownDirective("%Q"), .blank, .tooLong(300)] {
            XCTAssertFalse(p.description.isEmpty)
        }
        XCTAssertTrue(DefaultTitle.Problem.unknownLetter("t").description.contains("single quotes"))
    }
}
