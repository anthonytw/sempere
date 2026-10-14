import Foundation

/// RFC 3339 timestamps (format.md §6) without ICU.
///
/// Foundation's `ISO8601DateFormatter` hands strings to ICU, which dies with
/// SIGFPE on a long run of fractional-second digits on Linux (found by
/// fuzzing `vault.json`), so every date in a vault file is parsed here with
/// plain arithmetic. Output is byte-for-byte what `ISO8601DateFormatter`
/// with `[.withInternetDateTime, .withFractionalSeconds]` writes for years
/// 1583 to 9999 (milliseconds rounded half up); earlier years use the
/// proleptic Gregorian calendar, as RFC 3339 says, where ICU switches to the
/// Julian one.
public enum RFC3339 {
    /// `0001-01-01T00:00:00Z`, the earliest representable instant.
    public static let earliest = Date(timeIntervalSince1970: -62_135_596_800)
    /// Just past `9999-12-31T23:59:59.999Z`.
    public static let end = Date(timeIntervalSince1970: 253_402_300_800)

    private static let secondsFrom1970To2001 = 978_307_200.0

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction]` followed by `Z` or `±HH:MM`.
    /// The fraction has 1 to 9 digits and is truncated to milliseconds.
    /// Returns nil for anything else, including impossible dates (`02-30`),
    /// hour 24, leap seconds and an instant outside years 0001...9999 in UTC,
    /// so every date it returns, `string(from:)` writes.
    public static func parse(_ string: String) -> Date? {
        let b = Array(string.utf8)
        guard b.count >= 20, b.count <= 35 else { return nil }
        func number(_ at: Int, _ width: Int) -> Int? {
            guard at + width <= b.count else { return nil }
            var v = 0
            for c in b[at..<(at + width)] {
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard let year = number(0, 4), b[4] == 0x2D, let month = number(5, 2), b[7] == 0x2D, let day = number(8, 2),
              b[10] == 0x54, let hour = number(11, 2), b[13] == 0x3A, let minute = number(14, 2), b[16] == 0x3A,
              let second = number(17, 2) else { return nil }
        guard (1...9999).contains(year), (1...12).contains(month), (1...daysIn(month, of: year)).contains(day),
              hour <= 23, minute <= 59, second <= 59 else { return nil }
        var i = 19
        var millis = 0
        if b[i] == 0x2E {
            i += 1
            var digits = 0
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                if digits < 3 { millis = millis * 10 + Int(b[i] - 0x30) }
                digits += 1
                i += 1
            }
            guard (1...9).contains(digits) else { return nil }
            for _ in min(digits, 3)..<3 { millis *= 10 }
        }
        var offset = 0
        guard i < b.count else { return nil }
        switch b[i] {
        case 0x5A:
            i += 1
        case 0x2B, 0x2D:
            guard b.count == i + 6, b[i + 3] == 0x3A, let oh = number(i + 1, 2), let om = number(i + 4, 2),
                  oh <= 23, om <= 59 else { return nil }
            offset = (b[i] == 0x2B ? 1 : -1) * (oh * 3600 + om * 60)
            i += 6
        default:
            return nil
        }
        guard i == b.count else { return nil }
        let seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset
        // As ICU computes it: milliseconds since 1970 as a Double, then seconds since 2001.
        let date = Date(timeIntervalSinceReferenceDate: Double(seconds * 1000 + millis) / 1000 - secondsFrom1970To2001)
        // An offset can move a date at either end out of 0001...9999
        // (`0001-01-01T00:00:00+01:00`): writers could not write it back.
        guard date >= earliest, date < end else { return nil }
        return date
    }

    /// `YYYY-MM-DDTHH:MM:SS.mmmZ`, or nil for a date outside 0001...9999
    /// (or not finite).
    public static func string(from date: Date) -> String? {
        guard date >= earliest, date < end else { return nil }
        let udate = (date.timeIntervalSinceReferenceDate + secondsFrom1970To2001) * 1000
        let total = Int((udate + 0.5).rounded(.down))   // milliseconds, rounded half up
        let millis = ((total % 1000) + 1000) % 1000
        let seconds = (total - millis) / 1000
        let days = (seconds >= 0 ? seconds : seconds - 86_399) / 86_400
        let rest = seconds - days * 86_400
        let (y, m, d) = civil(fromDays: days)
        guard y <= 9999 else { return nil }   // 9999-12-31T23:59:59.9995 rounds into year 10000
        func p(_ v: Int, _ width: Int) -> String { pad(String(v), width) }
        return "\(p(y, 4))-\(p(m, 2))-\(p(d, 2))T\(p(rest / 3600, 2)):\(p(rest / 60 % 60, 2)):\(p(rest % 60, 2))."
            + "\(p(millis, 3))Z"
    }

    static func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    static func daysIn(_ month: Int, of year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The inverse of `daysFromCivil`.
    static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
