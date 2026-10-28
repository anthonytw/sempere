import Foundation
import Sempere

/// `:name` emoji completion for a text box on the canvas (the same behavior as the naming fields'
/// `EmojiCompletionModifier`), on the package's `EmojiCompletion`. A box is completed at the
/// caret, not at the end of its text: every function takes the text and the caret (UTF-16).
/// Pure, tested.
enum TextBoxEmoji {
    /// Suggestions shown at most.
    static let shown = 6

    /// The query being typed just before `caret`, or nil.
    static func query(in text: String, caret: Int) -> String? {
        guard let prefix = prefix(of: text, caret: caret) else { return nil }
        return EmojiCompletion.activeQuery(in: prefix)
    }

    /// The suggestions for the query before the caret, none while `dismissed` is that query.
    static func suggestions(in text: String, caret: Int, dismissed: String?) -> [EmojiCompletion.Suggestion] {
        guard let q = query(in: text, caret: caret), q != dismissed else { return [] }
        return EmojiCompletion.suggestions(for: q, limit: shown)
    }

    /// The edit that puts `emoji` in place of the `:query` before the caret: the UTF-16 range to
    /// replace and the caret afterwards. Nil when no query is active.
    static func accepting(_ emoji: String, in text: String, caret: Int) -> (range: NSRange, caret: Int)? {
        guard let q = query(in: text, caret: caret) else { return nil }
        let length = q.utf16.count + 1   // the colon and the query (ASCII)
        guard length <= caret else { return nil }
        return (NSRange(location: caret - length, length: length), caret - length + emoji.utf16.count)
    }

    /// The edit that turns a closed `:name:` ending at the caret into its emoji: the range to
    /// replace, the emoji and the caret afterwards. Nil when the caret is not after one.
    static func closing(in text: String, caret: Int) -> (range: NSRange, emoji: String, caret: Int)? {
        guard let prefix = prefix(of: text, caret: caret), prefix.hasSuffix(":") else { return nil }
        let ns = prefix as NSString
        var start = ns.length - 2
        let last = max(0, ns.length - (EmojiCompletion.maximumQueryLength + 2))
        while start >= last {
            let unit = ns.character(at: start)
            if unit == 0x3A {   // ":"
                guard start == 0 || (ns.substring(to: start).last.map(EmojiCompletion.opensShortcode(after:)) ?? false)
                else { return nil }
                let name = ns.substring(with: NSRange(location: start + 1, length: ns.length - start - 2))
                guard !name.isEmpty, let emoji = EmojiShortcodes.emoji(named: name) else { return nil }
                return (NSRange(location: start, length: ns.length - start), emoji, start + emoji.utf16.count)
            }
            guard let scalar = Unicode.Scalar(unit), isShortcodeCharacter(Character(scalar)) else { return nil }
            start -= 1
        }
        return nil
    }

    private static func isShortcodeCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "+" || c == "-")
    }

    /// The text before `caret` (UTF-16), or nil when the caret is out of range or inside a surrogate pair.
    private static func prefix(of text: String, caret: Int) -> String? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        if caret > 0, caret < ns.length, UTF16.isLeadSurrogate(ns.character(at: caret - 1)) { return nil }
        return ns.substring(to: caret)
    }
}
