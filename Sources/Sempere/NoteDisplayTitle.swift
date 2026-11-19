import Foundation

// MARK: - What a note's list row and editor show as its title (docs/format.md §8.3.1 `captureInfo`, §16.8)
//
// A quick voice note stores NO title unless the user gave one. What is shown while the title is blank (or is still a default
// that notes of 1.0 through 1.2 stored) is made at display time: the generated title Note Insights derived, else a default
// from the note's source and the reader's language ("Voice note Nov 16, 2026, 2:32 PM"). A title the user entered always wins.

/// Where and when a voice note was captured, as its first captured recording says (`NoteSummary.voice`).
public struct VoiceOrigin: Hashable, Sendable, Codable {
    /// The recording's start.
    public var started: Date
    /// The capturing device's time zone (`CaptureInfo.tz`); nil for a note adopted before 1.3.
    public var tz: String?
    /// `phone` or `watch` (`CaptureInfo.source`); nil when unknown.
    public var source: String?

    public init(started: Date, tz: String? = nil, source: String? = nil) {
        self.started = started; self.tz = tz; self.source = source
    }

    /// The origin of a note's state: its first recording that was captured (format.md §8.3.1), nil for any other note.
    public init?(state: NoteState) {
        guard let r = state.recordings.first(where: { $0.captured != nil }) else { return nil }
        self.init(started: r.started, tz: r.captureInfo?.tz, source: r.captureInfo?.source)
    }

    /// The zone the capture's clock read, else the reader's.
    public var timeZone: TimeZone { tz.flatMap(TimeZone.init(identifier:)) ?? .current }
}

public enum NoteDisplayTitle {
    /// "Voice note" for a source in a language, as the CLI and tests say it. The app gives its own localized words
    /// (`Localizable.xcstrings`) through `Words`.
    public struct Words: Sendable {
        /// The words before the date: "Voice note", "Watch voice note".
        public var prefix: @Sendable (_ source: String?) -> String

        public init(prefix: @escaping @Sendable (_ source: String?) -> String) { self.prefix = prefix }

        /// English and Spanish by `locale`'s language (the languages the app is localized in); anything else English.
        public static func builtIn(locale: Locale = .current) -> Words {
            let spanish = locale.language.languageCode?.identifier == "es"
            return Words { source in
                switch (source, spanish) {
                case ("watch", true): return "Nota de voz del reloj"
                case (_, true): return "Nota de voz"
                case ("watch", false): return "Watch voice note"
                default: return "Voice note"
                }
            }
        }
    }

    /// The default title of a voice note: its words and the capture's date and time, in the capture's time zone and
    /// `locale`'s style ("Voice note Nov 16, 2026, 2:32 PM").
    public static func defaultTitle(for origin: VoiceOrigin, words: Words? = nil, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = origin.timeZone
        f.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return (words ?? .builtIn(locale: locale)).prefix(origin.source) + " " + f.string(from: origin.started)
    }

    /// True when `stored` is no title the user chose: blank, or the default 1.0 through 1.2 stored for a voice note
    /// (`CaptureWriter.defaultTitle`'s shape, the Watch's, the app's localized form of 1.1).
    public static func isStoredDefault(_ stored: String, origin: VoiceOrigin?) -> Bool {
        let t = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        guard let origin else { return false }
        return isCaptureDefault(t) || isLocalizedCaptureDefault(t, started: origin.started)
    }

    /// The title to show: a title the user entered; else, for a voice note, `generated` (Note Insights' title), else the
    /// default for its source; else `stored` as it is (blank: the caller shows "Untitled"). `generated` is only used while
    /// the stored title is blank or a default stored before 1.3.
    public static func resolve(stored: String, origin: VoiceOrigin?, generated: String?, words: Words? = nil,
                               locale: Locale = .current) -> String {
        guard isStoredDefault(stored, origin: origin) else { return stored }
        if origin != nil, let g = generated?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty { return g }
        let t = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty, let origin { return defaultTitle(for: origin, words: words, locale: locale) }
        return stored
    }

    // MARK: Shapes of the titles older versions stored

    /// True when `title` has the shape of a capture's default title: it ends with the capture's local
    /// `YYYY-MM-DD HH:mm` (`CaptureWriter.defaultTitle`, the Watch's, the app's form of 1.2).
    public static func isCaptureDefault(_ title: String) -> Bool {
        let scalars = Array(title.trimmingCharacters(in: .whitespaces).unicodeScalars)
        guard scalars.count >= 16 else { return false }
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars.suffix(16))
        return VoiceNoteTitleFormat.localStamp(in: String(tail)) != nil
    }

    /// "Voice note" in each language the app was localized in before 1.2, lowercased.
    static let localizedPrefixes = ["voice note ", "nota de voz "]

    /// True when `title` has the shape of the default title the app gave quick voice notes before 1.2: "Voice note" (in a
    /// language of the app) and the start in the capturing device's language (`started.formatted(date: .abbreviated,
    /// time: .shortened)`, e.g. "Nota de voz 16 nov 2026, 14:32"), which ends in no `YYYY-MM-DD HH:mm`. The capture kept
    /// no time zone, so it is judged by what every such form holds: the start's year (any zone) and its minute after a `:`
    /// or `.`, near the end.
    public static func isLocalizedCaptureDefault(_ title: String, started: Date?) -> Bool {
        guard let started else { return false }
        let t = title.trimmingCharacters(in: .whitespaces)
        // Only the words the app wrote (its localizations: English, Spanish), so a rename that happens to hold the year
        // and minute is never taken for one.
        guard t.count <= 80, localizedPrefixes.contains(where: { t.lowercased().hasPrefix($0) }) else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        // Every zone is within 14 hours of UTC; most zones' offsets are whole or half hours, a few are 45 minutes.
        let years = Set([-14.0, 0, 14].map { cal.component(.year, from: started.addingTimeInterval($0 * 3600)) })
        guard years.contains(where: { t.contains(String($0)) }) else { return false }
        let minute = cal.component(.minute, from: started)
        let minutes = Set([minute, (minute + 30) % 60, (minute + 15) % 60, (minute + 45) % 60])
        let tail = String(t.suffix(24))
        return minutes.contains { m in
            let mm = String(format: "%02d", m)
            return tail.contains(":" + mm) || tail.contains("." + mm) || tail.contains("h" + mm)
        }
    }
}

extension NoteSummary {
    /// The title to show for this note (`NoteDisplayTitle.resolve`): `generated` is the title Note Insights derived for it.
    public func displayTitle(generated: String? = nil, words: NoteDisplayTitle.Words? = nil,
                             locale: Locale = .current) -> String {
        NoteDisplayTitle.resolve(stored: title, origin: voice, generated: generated, words: words, locale: locale)
    }
}
