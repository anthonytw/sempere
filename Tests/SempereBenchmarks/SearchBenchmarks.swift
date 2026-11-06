import Foundation
import XCTest
@testable import Sempere

final class SearchBenchmarks: XCTestCase {
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

    private func note(_ id: Int, _ pages: [String]) -> NoteSummary {
        let uuid = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!
        var s = NoteSummary(id: uuid, title: "Note", tags: [], notebook: nil, deleted: false, pages: pages.count, strokes: 0,
                            modified: Date(timeIntervalSince1970: 0), problem: nil)
        s.pageTexts = pages.enumerated().map {
            PageText(pageId: UUID(uuidString: String(format: "00000000-0000-4000-9000-%06d%06d", id, $0.offset))!,
                     number: $0.offset + 1, text: $0.element)
        }
        return s
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
