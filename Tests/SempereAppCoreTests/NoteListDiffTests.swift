import Foundation
import Sempere
import SempereAppCore
import Testing

/// The note list's updates applied as differences (`NoteListDiff`), against a full re-sort.
struct NoteListDiffTests {
    /// Deterministic generator (SplitMix64).
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The list's order, written out: by title ignoring case, then id.
    static func resorted(_ list: [NoteSummary]) -> [NoteSummary] {
        list.sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
    }

    /// Property: applying differences gives the same list as replacing and re-sorting.
    @Test func listDiffEqualsAFullResort() {
        var rng = SplitMix(state: 9)
        func summary(_ id: UUID, _ title: String) -> NoteSummary {
            NoteSummary(id: id, title: title, tags: [], notebook: nil, deleted: false, pages: 1, strokes: Int(rng.next() % 3),
                        modified: nil, problem: nil)
        }
        let titles = ["a", "B", "b", "c", "", "Zed", "zed", "m"]
        for _ in 0..<300 {
            let ids = (0..<Int(rng.next() % 12)).map { _ in UUID() }
            let list = Self.resorted(ids.map { summary($0, titles[Int(rng.next() % 8)]) })
            var upserts: [NoteSummary] = []
            for _ in 0..<Int(rng.next() % 6) {
                let id = rng.next() % 2 == 0 && !ids.isEmpty ? ids[Int(rng.next() % UInt64(ids.count))] : UUID()
                upserts.append(summary(id, titles[Int(rng.next() % 8)]))
            }
            let removals = Set(ids.filter { _ in rng.next() % 5 == 0 })
            var byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, n in n })
            for s in upserts where !removals.contains(s.id) { byID[s.id] = s }
            for id in removals { byID[id] = nil }
            let expected = Self.resorted(Array(byID.values))
            let applied = NoteListDiff.apply(upserts: upserts, removals: removals, to: list) ?? list
            #expect(applied == expected)
        }
    }

    @Test func sortedIsTheListOrder() {
        func summary(_ title: String) -> NoteSummary {
            NoteSummary(id: UUID(), title: title, tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0, modified: nil,
                        problem: nil)
        }
        let list = ["b", "A", "a", "", "C"].map(summary)
        #expect(NoteListDiff.sorted(list) == Self.resorted(list))
        #expect(NoteListDiff.apply(upserts: [], removals: [], to: list) == nil, "nothing to change")
    }
}
