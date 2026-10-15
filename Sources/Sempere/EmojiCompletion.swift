import Foundation

/// `:name` emoji completion for naming fields (Slack and GitHub style), on the
/// built-in `EmojiShortcodes` table. Pure logic, shared by every field that
/// offers it; the app draws the suggestions and calls `accept`.
///
/// A field's text is completed at its end (where typing happens): the active
/// token is a `:` at the start of the text or after whitespace, followed by at
/// least `minimumQueryLength` shortcode characters (letters, digits, `_`, `+`,
/// `-`) up to the end. A closed shortcode anywhere (`:smile:`) is replaced by
/// `replacingClosedShortcodes`, so fields that cannot show a list (an alert's
/// field) still turn it into the emoji.
public enum EmojiCompletion {
    /// Characters typed after `:` before suggestions show.
    public static let minimumQueryLength = 2
    /// Longest query looked at (no shortcode is longer).
    public static let maximumQueryLength = 48
    /// Default number of suggestions.
    public static let defaultLimit = 8

    /// One suggestion: the emoji and the name that matched.
    public struct Suggestion: Hashable, Sendable, Identifiable {
        public var emoji: String
        /// The shortcode shown next to the emoji (the matching name, or the preferred one).
        public var name: String
        public var id: String { emoji }

        public init(emoji: String, name: String) {
            self.emoji = emoji; self.name = name
        }
    }

    /// The query being typed at the end of `text` (without the colon), or nil
    /// when there is none: no `:` token, fewer than `minimumQueryLength`
    /// characters after it, or a character a shortcode cannot hold.
    public static func activeQuery(in text: String) -> String? {
        guard let colon = activeColon(in: text) else { return nil }
        let query = String(text[text.index(after: colon)...])
        return query.count >= minimumQueryLength ? query.lowercased() : nil
    }

    /// The index of the `:` that starts the active token, if any.
    static func activeColon(in text: String) -> String.Index? {
        var i = text.endIndex
        var count = 0
        while i > text.startIndex {
            let prev = text.index(before: i)
            let c = text[prev]
            if c == ":" {
                // The colon must start the text or follow whitespace (not "10:30" or "a:b").
                if prev == text.startIndex || text[text.index(before: prev)].isWhitespace {
                    return count > 0 ? prev : nil
                }
                return nil
            }
            guard isShortcodeCharacter(c), count < maximumQueryLength else { return nil }
            count += 1
            i = prev
        }
        return nil
    }

    static func isShortcodeCharacter(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "_" || c == "+" || c == "-"
    }

    /// Suggestions for `query` (no colons), best first: a name equal to the
    /// query, then names starting with it, then names with a `_`-separated word
    /// starting with it, then names containing it; ties keep table order
    /// (common emoji first). One suggestion per emoji.
    public static func suggestions(for query: String, limit: Int = defaultLimit) -> [Suggestion] {
        let q = query.lowercased()
        guard !q.isEmpty, limit > 0 else { return [] }
        var best: [String: (rank: Int, order: Int, name: String)] = [:]
        for (order, entry) in EmojiShortcodes.entries.enumerated() {
            for name in entry.names {
                guard let rank = rank(name, q) else { continue }
                if let current = best[entry.emoji], current.rank <= rank { continue }
                best[entry.emoji] = (rank, order, name)
            }
        }
        return best.sorted {
            if $0.value.rank != $1.value.rank { return $0.value.rank < $1.value.rank }
            return $0.value.order < $1.value.order
        }
        .prefix(limit)
        .map { Suggestion(emoji: $0.key, name: $0.value.name) }
    }

    private static func rank(_ name: String, _ q: String) -> Int? {
        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if name.split(separator: "_").dropFirst().contains(where: { $0.hasPrefix(q) }) { return 2 }
        if name.contains(q) { return 3 }
        return nil
    }

    /// The suggestions for the text being typed in a field (empty when no
    /// `:query` is active).
    public static func suggestions(forText text: String, limit: Int = defaultLimit) -> [Suggestion] {
        guard let q = activeQuery(in: text) else { return [] }
        return suggestions(for: q, limit: limit)
    }

    /// `text` with the active `:query` replaced by `emoji`; `text` unchanged
    /// when no token is active.
    public static func accept(_ emoji: String, in text: String) -> String {
        guard let colon = activeColon(in: text) else { return text }
        return String(text[..<colon]) + emoji
    }

    /// `text` with every closed shortcode (`:name:` naming an emoji of the
    /// table, the opening colon at the start or after whitespace) replaced by
    /// its emoji; nil when there is none, so a caller writes only on a change.
    public static func replacingClosedShortcodes(in text: String) -> String? {
        guard text.contains(":") else { return nil }
        var out = ""
        var changed = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let atBoundary = i == text.startIndex || text[text.index(before: i)].isWhitespace
            if c == ":", atBoundary, let (emoji, end) = closedShortcode(in: text, at: i) {
                out += emoji
                changed = true
                i = end
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        return changed ? out : nil
    }

    /// The emoji and the index after the closing colon, for `:name:` starting at `start`.
    private static func closedShortcode(in text: String, at start: String.Index) -> (String, String.Index)? {
        var j = text.index(after: start)
        var name = ""
        while j < text.endIndex, name.count <= maximumQueryLength {
            let c = text[j]
            if c == ":" {
                guard !name.isEmpty, let emoji = EmojiShortcodes.emoji(named: name) else { return nil }
                return (emoji, text.index(after: j))
            }
            guard isShortcodeCharacter(c) else { return nil }
            name.append(c)
            j = text.index(after: j)
        }
        return nil
    }
}
