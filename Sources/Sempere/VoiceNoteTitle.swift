import Foundation

// MARK: - Voice-note titles (docs/design/1.2-note-insights.md D14; format.md §16.2 `titleOp`)
//
// After adoption, once a voice note's transcript is summarized, the work device sets its title from the shared format
// `insights.voiceNoteTitle`, only while the title is still the capture default: the title register has not been set
// since adoption (or was last set by this device's own automatic title). A user's rename always wins and is never
// overwritten. The check is local, so a rename made on another device that has not synced yet must not lose: the work
// device records the stamp of the revision it wrote (`titleOp`), and when it later sees a title set by another device
// after the adoption and before that stamp (so not causally after it) while its own title still wins, it writes the
// user's value again.

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

    /// The capture's local date and time from its default title (`… YYYY-MM-DD HH:mm`, as `CaptureWriter.defaultTitle`
    /// writes it in the capturing device's time zone), else from `started` in UTC. The capture records no time zone,
    /// so the default title is the one place that holds its local time (PR 1 notes in the design).
    public static func captureDateAndTime(defaultTitle: String?, started: Date) -> (date: String, time: String) {
        if let t = defaultTitle, let m = localStamp(in: t) { return m }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
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

/// What a voice note's title history says (D14), from its revisions.
public struct VoiceNoteTitleState: Hashable, Sendable {
    /// Every title set, oldest first: deltas' `setMeta(.title)` ops and snapshots' title registers.
    public var sets: [(stamp: Stamp, title: String)]
    /// The register's winner.
    public var current: (stamp: Stamp, title: String)?
    /// The note is a quick voice note: one of its recordings was captured (format.md §8.3.1, §11.3).
    public var isVoiceNote: Bool
    /// The capture's recording start, for the title's date when the default title has none.
    public var started: Date?

    public static func == (a: Self, b: Self) -> Bool {
        a.sets.map(\.stamp) == b.sets.map(\.stamp) && a.sets.map(\.title) == b.sets.map(\.title)
            && a.current?.stamp == b.current?.stamp && a.isVoiceNote == b.isVoiceNote && a.started == b.started
    }
    public func hash(into h: inout Hasher) { h.combine(sets.map(\.stamp)); h.combine(isVoiceNote) }

    /// The state of a note from its revisions and its reconstructed state.
    public init(revisions: [Revision], state: NoteState) {
        var sets: [(Stamp, String)] = []
        var seen = Set<Stamp>()
        for r in revisions {
            let stamp = Stamp(hlc: r.hlc, device: r.device)
            switch r.body {
            case .delta(let ops):
                for op in ops { if case .setMeta(.title(let t)) = op, seen.insert(stamp).inserted { sets.append((stamp, t)) } }
            case .snapshot(_, let s):
                if let c = s.clocks?["title"].flatMap(Stamp.init), c != .zero, seen.insert(c).inserted { sets.append((c, s.meta.title)) }
            }
        }
        sets.sort { $0.0 < $1.0 }
        self.sets = sets.map { (stamp: $0.0, title: $0.1) }
        current = self.sets.last
        let captured = state.recordings.first { $0.captured != nil }
        isVoiceNote = captured != nil
        started = captured?.started
    }

    /// The capture's default title: the first title the note got (adoption sets it).
    public var defaultTitle: (stamp: Stamp, title: String)? { sets.first }

    /// What to do with the title of this voice note, given the title this device applied before (`applied`, from its
    /// sidecar's `titleOp`) and the title it would write now (`proposed`).
    public enum Decision: Hashable, Sendable {
        /// Write `proposed` (the title is still the capture default).
        case apply(String)
        /// A rename from another device lost to this device's automatic title: write the user's title again.
        case restore(String)
        /// Leave the title alone (a user's title, already applied, or not a voice note).
        case keep
    }

    public func decide(applied: InsightsNoteFile.TitleOp?, proposed: String?) -> Decision {
        guard isVoiceNote, let first = defaultTitle, let current else { return .keep }
        let mine = applied.flatMap { Stamp($0.stamp) }
        if let mine, current.stamp == mine {
            // This device's own title wins: a title another device set after the adoption and before it was not seen
            // when it was written (not causally after it), so the user's value comes back.
            if let lost = sets.last(where: { $0.stamp > first.stamp && $0.stamp < mine && $0.stamp.device != mine.device }) {
                return .restore(lost.title)
            }
            return .keep
        }
        guard current.stamp == first.stamp, let proposed, proposed != current.title else { return .keep }
        return .apply(proposed)
    }
}
