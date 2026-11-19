import Foundation

// MARK: - Voice-note titles (docs/design/1.2-note-insights.md D14; format.md §16.2 `title`, §16.8)
//
// Once a voice note's transcript is summarized, any device with a summary derives a TITLE for it from the shared format
// `insights.voiceNoteTitle` and records it in its own insights note file (`InsightsNoteFile.title`, bound to the note's
// insight-text hash). Since 1.3 nothing writes the note's own title: the app and the CLI show the derived title while the
// stored title is blank or a default (`NoteDisplayTitle`), and a title the user entered always wins and is never touched.

/// The title format of `insights.voiceNoteTitle`: text with the tokens `{date}` (`YYYY-MM-DD`), `{time}` (`HH.mm`,
/// 24 hour), both in the capture's time zone, and `{slug}` (a 2-6 word title from the model, fact-checked, at most 60
/// characters). Braces are only ever these tokens.
public enum VoiceNoteTitleFormat {
    public static let defaultFormat = "{date} {time} {slug}"
    public static let maxLength = 200
    public static let maxSlugLength = 60
    public static let tokens = ["{date}", "{time}", "{slug}"]

    /// Why `format` is not a title format; nil when it is.
    public static func check(_ format: String) -> String? {
        guard format.count <= maxLength else { return "longer than \(maxLength) characters" }
        guard !format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "empty" }
        guard !format.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return "control characters"
        }
        var rest = Substring(format)
        while let open = rest.firstIndex(where: { $0 == "{" || $0 == "}" }) {
            guard rest[open] == "{", let close = rest[open...].firstIndex(of: "}") else { return "a brace outside a token" }
            let token = String(rest[open...close])
            guard tokens.contains(token) else { return "unknown token \(token) (use {date}, {time}, {slug})" }
            rest = rest[rest.index(after: close)...]
        }
        return nil
    }

    /// The title for `format` with the capture's local `date` (`YYYY-MM-DD`) and `time` (`HH.mm`) and `slug`; runs of
    /// spaces collapse and the ends are trimmed. Nil when the format has `{slug}` and there is no usable slug, or the
    /// format is not valid.
    public static func render(_ format: String, date: String, time: String, slug: String?) -> String? {
        guard check(format) == nil else { return nil }
        let cleanSlug = slug.map(cleaned)
        if format.contains("{slug}"), (cleanSlug ?? "").isEmpty { return nil }
        let out = format.replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{slug}", with: cleanSlug ?? "")
        let collapsed = out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let title = collapsed.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : String(title.prefix(DefaultTitle.maxTitleLength))
    }

    /// A slug as a title takes it: control characters and braces out, spaces collapsed, cut at 60 characters on a word.
    public static func cleaned(_ slug: String) -> String {
        let plain = String(slug.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0 == "{" || $0 == "}" ? " " : Character($0)
        })
        let words = plain.split(whereSeparator: { $0.isWhitespace })
        var out = ""
        for w in words {
            let next = out.isEmpty ? String(w) : out + " " + w
            if next.count > maxSlugLength { break }
            out = next
        }
        if out.isEmpty, let first = words.first { out = String(first.prefix(maxSlugLength)) }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-"))
    }

    /// The capture's local date and time: from the capture's own time zone when its recording records one
    /// (`CaptureInfo.tz`, 1.3 onward), else from a default title a note of 1.0 through 1.2 stored (`… YYYY-MM-DD HH:mm`, as
    /// `CaptureWriter.defaultTitle` wrote it in the capturing device's zone), else from `started` in UTC.
    public static func captureDateAndTime(origin: VoiceOrigin?, storedTitle: String?, started: Date) -> (date: String, time: String) {
        var cal = Calendar(identifier: .gregorian)
        if let tz = origin?.tz.flatMap(TimeZone.init(identifier:)) {
            cal.timeZone = tz
        } else if let t = storedTitle, let m = localStamp(in: t) {
            return m
        } else {
            cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        }
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: started)
        return (String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                String(format: "%02d.%02d", c.hour ?? 0, c.minute ?? 0))
    }

    /// The last `YYYY-MM-DD HH:mm` in `s`, as (`YYYY-MM-DD`, `HH.mm`).
    static func localStamp(in s: String) -> (date: String, time: String)? {
        let chars = Array(s.unicodeScalars)
        guard chars.count >= 16 else { return nil }
        func digit(_ i: Int) -> Bool { (0x30...0x39).contains(chars[i].value) }
        var i = chars.count - 16
        while i >= 0 {
            let ok = (0..<4).allSatisfy { digit(i + $0) } && chars[i + 4] == "-" && digit(i + 5) && digit(i + 6)
                && chars[i + 7] == "-" && digit(i + 8) && digit(i + 9) && chars[i + 10] == " " && digit(i + 11)
                && digit(i + 12) && chars[i + 13] == ":" && digit(i + 14) && digit(i + 15)
            if ok {
                var u = String.UnicodeScalarView(); u.append(contentsOf: chars[i..<(i + 10)])
                var h = String.UnicodeScalarView(); h.append(contentsOf: chars[(i + 11)..<(i + 13)])
                var m = String.UnicodeScalarView(); m.append(contentsOf: chars[(i + 14)..<(i + 16)])
                return (String(u), String(h) + "." + String(m))
            }
            i -= 1
        }
        return nil
    }
}
