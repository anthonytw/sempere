#if DEBUG
import Foundation
import Sempere

/// `SEMPERE_DEMO_SEARCH` (UI tests: `PhoneSearchUITests`, `PadSearchUITests`): two notes whose
/// handwriting has stored recognition with word boxes, so a search highlights and steps through
/// them without a recognizer. The word `wombat` is written three times on page 1 of a paged
/// note (top, middle, bottom: stepping must scroll) and twice on its page 2, and three times
/// down a long pageless note. The recognition's `basis` is the digest of the page's strokes, so
/// the highlight takes it as current.
extension DemoVault {
    /// The word the search notes repeat.
    static let searchWord = "wombat"
    /// The paged search note's key.
    static let searchPagedNote = "search-paged"
    /// The pageless search note's key.
    static let searchPagelessNote = "search-pageless"

    /// Lines of the paged note's pages and the pageless note: (baseline, words).
    private static let pagedLines: [[(Double, String)]] = [
        [(90, "Field notes: the wombat burrow"), (420, "a wombat digs at night"), (740, "last wombat seen at dawn")],
        [(140, "Page two: wombat diet"), (620, "grass and roots feed the wombat")],
    ]
    private static let pagelessLines: [(Double, String)] = [
        (90, "Wombat journal"), (1200, "the wombat came back"), (2300, "one more wombat track"),
    ]

    /// The ops of both search notes, by key.
    static func searchNoteOps() -> [(key: String, title: String, ops: [Op])] {
        // Paged: two letter pages.
        var rng = DemoRandom(seed: seed("page/" + searchPagedNote))
        let first = rng.uuid()
        var paged = NoteOps.newNote(title: "Wombat field notes", paper: ruled, notebook: "Search", pageId: first)
        var previous = PageOrder.between(nil, nil)
        for (index, lines) in pagedLines.enumerated() {
            let page: UUID
            if index == 0 {
                page = first
            } else {
                page = rng.uuid()
                let order = PageOrder.between(previous, nil)
                previous = order
                paged.append(.addPage(Page(id: page, order: order)))
            }
            paged += writtenPage(page, lines: lines, seed: "ink/\(searchPagedNote)/\(index + 1)")
        }
        // Pageless: one infinite page, its stored height the ink's.
        var prng = DemoRandom(seed: seed("page/" + searchPagelessNote))
        let only = prng.uuid()
        let pageless = NoteOps.newNote(title: "Wombat journal", paper: ruled,
                                       pageSize: PageSize(width: 612, height: 2400, infinite: true, breakHeight: 792),
                                       notebook: "Search", pageId: only)
            + writtenPage(only, lines: pagelessLines, seed: "ink/" + searchPagelessNote)
        return [(searchPagedNote, "Wombat field notes", paged), (searchPagelessNote, "Wombat journal", pageless)]
    }

    /// The strokes of `lines` on `page`, then the page's recognition: every word with its box.
    private static func writtenPage(_ page: UUID, lines: [(Double, String)], seed name: String) -> [Op] {
        var sheet = DemoSheet(seed: seed(name))
        var words: [Recognition.Word] = []
        for (baseline, line) in lines {
            var x = 60.0
            for word in line.split(separator: " ").map(String.init) {
                let before = sheet.strokes.count
                let end = sheet.write(word, x: x, baseline: baseline)
                let points = sheet.strokes[before...].flatMap(\.points)
                if let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                   let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
                    words.append(Recognition.Word(text: word, box: Recognition.Box(x: minX, y: minY, w: maxX - minX, h: maxY - minY)))
                }
                x = end + 9
            }
        }
        let text = lines.map(\.1).joined(separator: "\n")
        let recognition = Recognition(engine: "demo-1", text: text, words: words,
                                      basis: RecognitionBasis.digest(of: sheet.strokes.map(\.id)))
        return sheet.strokes.map { .addStroke(page: page, stroke: $0) }
            + [.setPageRecognition(pageId: page, recognition: recognition)]
    }
}
#endif
