import Foundation

/// The title a new note gets when none is typed: the date and time it was
/// created, in a format the user can change (the app's Settings → New Notes,
/// `NewNoteSettings`; the CLI's `notes new --title-format`). Shared by both,
/// with its validation (`check`), so the app's field and the CLI accept and
/// reject the same formats with the same messages.
///
/// A format is a Unicode date pattern (UTS #35, as `DateFormatter.dateFormat`:
/// `yyyy-MM-dd HH:mm`, `'Lecture' EEE d MMM`; literal text in single quotes,
/// `''` for a quote) or, when it holds a `%` outside quoted text (or holds a
/// `%` and is no valid pattern), a strftime format (`%Y-%m-%d %H:%M`, `Lecture %a %e %b`), translated to a pattern
/// (`pattern(_:)`); in a strftime format every other character is literal.
/// An empty format means the locale's own medium date and short time
/// ("Oct 7, 2026 at 2:30 PM" in English, "7 oct 2026, 14:30" in Spanish).
/// Titles are labels, never keys, so two notes made in the same minute may
/// share one.
public enum DefaultTitle {
    /// Longest format used; a longer one is ignored (the locale's default is used).
    public static let maxFormatLength = 200
    /// Longest title produced (a pattern can repeat fields).
    public static let maxTitleLength = 300

    /// Some example formats, for a settings picker.
    public static let suggestions = ["", "yyyy-MM-dd HH:mm", "EEEE d MMMM yyyy", "'Note' yyyy-MM-dd", "MMM d, h:mm a",
                                     "%Y-%m-%d %H:%M"]

    /// The letters UTS #35 gives a meaning in a date pattern (outside quotes).
    /// Any other ASCII letter is reserved: `DateFormatter` would drop or
    /// misread it, so `check` refuses it.
    static let patternLetters = Set("GyYuUrQqMLlwWdDFgEecabBhHKkjJCmsSAzZOvVXx")

    /// The UTS #35 field each strftime directive stands for.
    static let strftime: [Character: String] = [
        "Y": "yyyy", "y": "yy", "C": "yy",   // %C (century) has no field: the two-digit year is closest
        "m": "MM", "B": "MMMM", "b": "MMM", "h": "MMM",
        "d": "dd", "e": "d", "j": "DDD",
        "A": "EEEE", "a": "EEE", "u": "e",
        "H": "HH", "k": "H", "I": "hh", "l": "h", "M": "mm", "S": "ss", "p": "a",
        "Z": "zzz", "z": "xx",
        "F": "yyyy-MM-dd", "R": "HH:mm", "T": "HH:mm:ss", "D": "MM/dd/yy",
        "V": "ww", "G": "YYYY",
    ]

    /// Why a format cannot be used.
    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case tooLong(Int)
        /// A `'` opens literal text that is never closed.
        case unclosedQuote
        /// An ASCII letter outside quotes that is not a pattern field.
        case unknownLetter(Character)
        /// A `%` not followed by a strftime directive this reader knows.
        case unknownDirective(String)
        /// The format gives no text (only spaces, or nothing).
        case blank

        public var description: String {
            switch self {
            case .tooLong(let n): return "The format is \(n) characters long; at most \(DefaultTitle.maxFormatLength)."
            case .unclosedQuote: return "A quote (') opens text that is never closed. Put literal text in single quotes, and write '' for a quote."
            case .unknownLetter(let c): return "“\(c)” is not a date field. Put literal text in single quotes, e.g. 'Lecture' d MMM."
            case .unknownDirective(let d): return "“\(d)” is not a strftime directive. Known: %Y %y %m %B %b %d %e %j %A %a %H %I %M %S %p %F %R %T %Z %z %%."
            case .blank: return "The format gives no text."
            }
        }
    }

    /// The Unicode date pattern `format` stands for (a strftime format
    /// translated, a pattern as it is), or why it cannot be used. An empty
    /// format is fine: it stands for the locale's default (`nil` pattern).
    public static func pattern(_ format: String) -> Result<String?, Problem> {
        guard format.count <= maxFormatLength else { return .failure(.tooLong(format.count)) }
        if format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success(nil) }
        let chars = Array(format)
        // A Unicode pattern: quotes balanced (`''` is a quote, in or out of literal text), letters known.
        // One with a `%` outside quotes, or one that fails and holds a `%`, is a strftime format.
        var quoted = false, percentOutside = false
        var problem: Problem?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                if i + 1 < chars.count, chars[i + 1] == "'" { i += 2; continue }
                quoted.toggle()
            } else if !quoted, c == "%" {
                percentOutside = true
            } else if !quoted, problem == nil, c.isASCII, c.isLetter, !patternLetters.contains(c) {
                problem = .unknownLetter(c)
            }
            i += 1
        }
        if quoted, problem == nil { problem = .unclosedQuote }
        if percentOutside || (problem != nil && chars.contains("%")) { return translate(chars).map { Optional($0) } }
        if let problem { return .failure(problem) }
        return .success(format)
    }

    /// A strftime format as a Unicode pattern: directives become fields, the
    /// rest is quoted literal text.
    static func translate(_ chars: [Character]) -> Result<String, Problem> {
        var out = "", literal = ""
        func flush() {
            guard !literal.isEmpty else { return }
            out += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            literal = ""
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "%" else { literal.append(c); i += 1; continue }
            guard i + 1 < chars.count else { return .failure(.unknownDirective("%")) }
            var d = chars[i + 1]
            var step = 2
            // glibc's flags (`%-d`, `%_d`, `%0d`) and the `E`/`O` modifiers: the field alone.
            if "-_0^#EO".contains(d), i + 2 < chars.count { d = chars[i + 2]; step = 3 }
            if d == "%" { literal.append("%") } else if d == "n" { literal.append("\n") } else if d == "t" {
                literal.append("\t")
            } else if let field = strftime[d] {
                flush()
                // `%-d`, `%-m`, `%-H`… drop the leading zero.
                out += step == 3 && chars[i + 1] == "-" && field.count == 2 ? String(field.prefix(1)) : field
            } else {
                return .failure(.unknownDirective(String(chars[i..<min(i + step, chars.count)])))
            }
            i += step
        }
        flush()
        return .success(out)
    }

    /// Nil when `format` can be used (empty included), else why not: it
    /// translates, its fields are known, and it gives text at `date`.
    public static func check(_ format: String, at date: Date = Date(), locale: Locale = .current,
                             timeZone: TimeZone = .current) -> Problem? {
        switch pattern(format) {
        case .failure(let problem): return problem
        case .success(nil): return nil
        case .success(let p?):
            return formatted(date, pattern: p, locale: locale, timeZone: timeZone).isEmpty ? .blank : nil
        }
    }

    /// The default title of a note created at `date`.
    ///
    /// - Parameters:
    ///   - format: a Unicode date pattern or a strftime format; nil, empty, one
    ///     `check` refuses, or one that gives only blanks falls back to the
    ///     locale's medium date and short time.
    public static func title(at date: Date, format: String?, locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String {
        if let format, case .success(let p?) = pattern(format) {
            let text = formatted(date, pattern: p, locale: locale, timeZone: timeZone)
            if !text.isEmpty { return text }
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func formatted(_ date: Date, pattern: String, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return String(formatter.string(from: date).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
    }

    /// `format` when it can be used as a pattern, nil otherwise.
    public static func usable(_ format: String?) -> String? {
        guard let format, case .success(let p?) = pattern(format) else { return nil }
        return p
    }
}
