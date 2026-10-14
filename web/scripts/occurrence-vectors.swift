// Prints, for each [text, term] of the JSON array on stdin, what the CLI's
// `sempere search` finds (Sources/SempereCLI/Search.swift, `RecognitionSearch`):
// every occurrence as UTF-16 offsets and the snippet around the first. Run by
// web/scripts/golden.sh into web/test/golden/occurrence-vectors.json, which
// web/test/occurrences.test.ts compares with the viewer's port.
import Foundation

func ranges(of term: String, in text: String) -> [Range<String.Index>] {
    var out: [Range<String.Index>] = []
    var from = text.startIndex
    while from < text.endIndex, let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                                   range: from..<text.endIndex) {
        out.append(r)
        from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
    }
    return out
}

func snippet(_ text: String, around range: Range<String.Index>, context: Int = 30) -> String {
    let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
    let body = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let cases = try JSONSerialization.jsonObject(with: input) as? [[String]] else { fatalError("expected [[text, term]]") }
var out: [[String: Any]] = []
for c in cases {
    let text = c[0], term = c[1].trimmingCharacters(in: .whitespacesAndNewlines)
    let found = ranges(of: term, in: text)
    let u = { (i: String.Index) in text.utf16.distance(from: text.utf16.startIndex, to: i) }
    var o: [String: Any] = ["text": text, "term": c[1], "ranges": found.map { [u($0.lowerBound), u($0.upperBound)] }]
    if let first = found.first { o["snippet"] = snippet(text, around: first) }
    out.append(o)
}
let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
