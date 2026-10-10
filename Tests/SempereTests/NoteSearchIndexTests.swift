import Foundation
import XCTest
@testable import Sempere

/// The fast paths of `NoteSearch`: the ASCII byte compare must give
/// Foundation's answer, the index must follow changed text, and `updated`
/// must equal a full search.
final class NoteSearchIndexTests: XCTestCase {
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private func foundation(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: NoteSearch.options) != nil
    }

    private func fast(_ haystack: String, _ needle: String) -> Bool? {
        guard let h = ASCIIFold.folded(haystack), let n = ASCIIFold.needle(needle) else { return nil }
        return ASCIIFold.contains(h, n)
    }

    /// Every ASCII character against every one, in one- and three-character haystacks.
    func testASCIIByteCompareMatchesFoundationExhaustively() {
        let all = (0..<128).map { String(UnicodeScalar(UInt8($0))) }
        for n in all where !n.isEmpty {
            for h in all {
                // Line breaks are never searched for (nil); every other word gives Foundation's answer.
                for hay in [h, "x" + h + "\r\n", "\r" + h + "\n"] {
                    if let f = fast(hay, n) {
                        XCTAssertEqual(f, foundation(hay, n), "\(Array(hay.utf8)) / \(Array(n.utf8))")
                    } else {
                        XCTAssertTrue(n == "\n" || n == "\r" || n == "\u{0}", "\(Array(n.utf8))")
                    }
                }
            }
        }
    }

    /// Random ASCII text and words (letters of both cases, digits, punctuation, controls, CR LF).
    func testASCIIByteCompareMatchesFoundationOnRandomText() {
        var rng = RNG(state: 7)
        let alphabet = Array("aAbBcCsSkKiIlL01 .,;:'\"`^~-_/\\\t\r\n\u{0}\u{7}\u{1F}\u{7F}#@!?()[]{}").map(String.init)
        for _ in 0..<20_000 {
            let h = (0..<rng.below(30)).map { _ in alphabet[rng.below(alphabet.count)] }.joined()
            var n = (0..<(1 + rng.below(4))).map { _ in alphabet[rng.below(alphabet.count)] }.joined()
            if rng.below(3) == 0, h.count > 2 {   // often a real substring, with its case changed
                let chars = Array(h)
                let a = rng.below(chars.count - 1), b = a + 1 + rng.below(min(3, chars.count - a - 1))
                n = String(chars[a..<b]).uppercased()
            }
            guard let f = fast(h, n) else { continue }
            XCTAssertEqual(f, foundation(h, n), "\(Array(h.utf8)) / \(Array(n.utf8))")
        }
    }

    /// Non-ASCII on either side is left to Foundation.
    func testNonASCIIIsNotFolded() {
        XCTAssertNil(ASCIIFold.folded("café"))
        XCTAssertNil(ASCIIFold.folded("ＦＵＬＬ"))
        XCTAssertNotNil(ASCIIFold.folded("cafe"))
    }

    private func note(_ id: Int, _ pages: [String], title: String = "Note", modified: Double = 0) -> NoteSummary {
        let uuid = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!
        var s = NoteSummary(id: uuid, title: title, tags: [], notebook: nil, deleted: false, pages: pages.count, strokes: 0,
                            modified: Date(timeIntervalSince1970: modified), problem: nil)
        s.pageTexts = pages.enumerated().map {
            PageText(pageId: UUID(uuidString: String(format: "00000000-0000-4000-9000-%06d%06d", id, $0.offset))!,
                     number: $0.offset + 1, text: $0.element)
        }
        return s
    }

    /// A note whose recognised text changes is folded again (no stale hits or misses).
    func testIndexFollowsChangedText() {
        let index = NoteSearchIndex()
        var a = note(1, ["momentum and energy"])
        XCTAssertEqual(NoteSearch.search("momentum", in: [a], index: index).count, 1)
        XCTAssertEqual(index.count, 1)
        a.pageTexts[0].text = "force and mass"
        XCTAssertEqual(NoteSearch.search("momentum", in: [a], index: index).count, 0)
        XCTAssertEqual(NoteSearch.search("mass", in: [a], index: index).count, 1)
        a.pageTexts.append(PageText(pageId: UUID(), number: 2, text: "Momentum again"))
        XCTAssertEqual(NoteSearch.search("momentum", in: [a], index: index).first?.page?.number, 2)
        index.removeAll()
        XCTAssertEqual(index.count, 0)
    }

    private func randomNotes(_ rng: inout RNG, count: Int) -> [NoteSummary] {
        let words = ["momentum", "Energy", "café", "CAFE", "straße", "STRASSE", "ﬁsh", "fish", "ＦＵＬＬ", "full", "naïve",
                     "naive", "ok", "the", "quick", "fox", "#todo", "Ünïcode", "x"]
        return (0..<count).map { i in
            let pages = (0..<rng.below(4)).map { _ in (0..<rng.below(8)).map { _ in words[rng.below(words.count)] }.joined(separator: " ") }
            return note(i, pages, title: words[rng.below(words.count)], modified: Double(rng.below(5)))
        }
    }

    /// With and without an index, and across text changes, the hits are the same.
    func testIndexedSearchEqualsUnindexed() {
        var rng = RNG(state: 11)
        let queries = ["cafe", "STRASSE", "ss", "fi", "full", "naive", "the fox", "e", "quick momentum", "ok #todo", "Ü"]
        let index = NoteSearchIndex()
        var notes = randomNotes(&rng, count: 120)
        for round in 0..<4 {
            for q in queries {
                XCTAssertEqual(NoteSearch.search(q, in: notes, index: index), NoteSearch.search(q, in: notes), "\(round) \(q)")
            }
            for _ in 0..<20 { let i = rng.below(notes.count); notes[i] = randomNotes(&rng, count: notes.count)[i] }
        }
    }

    /// `updated` after changes equals a full search of the changed list.
    func testUpdatedEqualsAFullSearch() {
        var rng = RNG(state: 5)
        let queries = ["cafe", "ss", "fi", "the fox", "e", "x"]
        for q in queries {
            var notes = randomNotes(&rng, count: 80)
            var hits = NoteSearch.search(q, in: notes)
            for _ in 0..<10 {
                var changed = Set<UUID>()
                let fresh = Dictionary(uniqueKeysWithValues: randomNotes(&rng, count: 80).map { ($0.id, $0) })
                for _ in 0..<rng.below(6) {
                    let i = rng.below(notes.count)
                    notes[i] = fresh[notes[i].id]!
                    changed.insert(notes[i].id)
                }
                if rng.below(3) == 0 {   // a note leaves the list
                    let i = rng.below(notes.count)
                    changed.insert(notes.remove(at: i).id)
                }
                hits = NoteSearch.updated(hits, query: q, changed: changed, in: notes)
                XCTAssertEqual(hits, NoteSearch.search(q, in: notes), q)
            }
        }
    }

    func testCancelledSearchStops() {
        var rng = RNG(state: 3)
        let notes = randomNotes(&rng, count: 200)
        var checks = 0
        XCTAssertEqual(NoteSearch.search("e", in: notes, isCancelled: { checks += 1; return checks > 1 }), [])
        XCTAssertEqual(checks, 2)
    }

    /// Prints how long a search over a large vault takes, without and with a
    /// warm index (`SEMPERE_BENCH_SEARCH_NOTES`, default 300 notes of 20 pages × 1 KB).
    func testSearchTimings() {
        let count = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_SEARCH_NOTES"] ?? "") ?? 300
        var rng = RNG(state: 1)
        let vocabulary = ["the", "quick", "brown", "fox", "momentum", "energy", "integral", "matrix", "vector", "proof",
                          "lemma", "theorem", "notes", "lecture", "chapter", "section", "example", "result", "method", "data"]
        let notes = (0..<count).map { i in
            note(i, (0..<20).map { _ in
                var t = ""
                while t.utf8.count < 1_000 { t += vocabulary[rng.below(vocabulary.count)] + " " }
                return t
            })
        }
        let index = NoteSearchIndex()
        for q in ["vector", "proof lemma", "zebra", "the quick brown"] {
            var t = Date()
            let plain = NoteSearch.search(q, in: notes)
            let cold = Date().timeIntervalSince(t)
            _ = NoteSearch.search(q, in: notes, index: index)
            t = Date()
            let warm = NoteSearch.search(q, in: notes, index: index)
            let warmTime = Date().timeIntervalSince(t)
            XCTAssertEqual(plain, warm)
            print("bench: search '\(q)' over \(count) notes x 20 KB: no index (Foundation) \(String(format: "%.3f", cold)) s, "
                  + "warm index \(String(format: "%.3f", warmTime)) s, \(warm.count) hits")
        }
    }
}
