import Foundation
import Sempere

/// What the Settings title-pattern field decides (pure, tested): the fields its Insert menu offers and what a
/// pattern gives now or why it cannot be used (`DefaultTitle.check`, the rules `notes new --title-format` applies).
/// The words (field names, the problem text) are the app's.
public enum TitlePatternCheck {
    /// A date field the Insert menu offers.
    public enum Field: CaseIterable, Hashable, Sendable {
        case year, month, monthNumber, day, weekday, time, time12Hour, text

        /// What the field adds to the pattern.
        public var pattern: String {
            switch self {
            case .year: return "yyyy"
            case .month: return "MMMM"
            case .monthNumber: return "MM"
            case .day: return "d"
            case .weekday: return "EEEE"
            case .time: return "HH:mm"
            case .time12Hour: return "h:mm a"
            case .text: return "'Note'"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        /// The title the pattern gives at the time checked.
        case preview(String)
        /// Nothing but blanks.
        case empty
        /// Why the pattern cannot be used.
        case invalid(DefaultTitle.Problem)
    }

    /// What the field shows under `pattern` at `now`.
    public static func status(of pattern: String, now: Date = Date(), locale: Locale = .current,
                              timeZone: TimeZone = .current) -> Status {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if let problem = DefaultTitle.check(pattern, at: now, locale: locale, timeZone: timeZone) { return .invalid(problem) }
        return .preview(DefaultTitle.title(at: now, format: pattern, locale: locale, timeZone: timeZone))
    }
}
