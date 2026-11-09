import Foundation

/// Six words typed into one field: lowercased, split on spaces, commas and newlines.
public enum TypedWords {
    public static func split(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .map { $0.trimmingCharacters(in: CharacterSet.decimalDigits.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
    }
}
