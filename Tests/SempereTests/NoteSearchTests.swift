import Foundation
import XCTest
@testable import Sempere

final class NoteSearchTests: XCTestCase {
    private func note(_ title: String, notebook: String? = nil, tags: [String] = [], pages: [String] = [],
                      modified: TimeInterval = 0) -> NoteSummary {
        var s = NoteSummary(id: UUID(), title: title, tags: tags, notebook: notebook, deleted: false, pages: pages.count,
                            strokes: 0, modified: Date(timeIntervalSince1970: modified), problem: nil)
        s.pageTexts = pages.enumerated().compactMap { i, t in
            t.isEmpty ? nil : PageText(pageId: UUID(), number: i + 1, text: t)
        }
        return s
    }

    func testFindsHandwritingAndNamesThePage() throws {
        let a = note("Physics", pages: ["Newton's laws", "", "Kinetic energy and momentum"])
        let b = note("Chemistry", pages: ["Periodic table"])
        let hits = NoteSearch.search("momentum", in: [a, b])
        XCTAssertEqual(hits.map(\.note), [a.id])
        XCTAssertEqual(hits[0].page?.number, 3)
        XCTAssertEqual(hits[0].page?.pageId, a.pageTexts[1].pageId)
        XCTAssertEqual(hits[0].fields, [.text])
        let snippet = try XCTUnwrap(hits[0].snippet)
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["momentum"])
    }

    func testTheSameNoteListedTwiceDoesNotTrap() {
        let a = note("Physics", pages: ["momentum"])
        XCTAssertEqual(NoteSearch.search("momentum", in: [a, a]).map(\.note), [a.id, a.id])
    }

    func testIgnoresCaseAccentsAndWidth() {
        let a = note("Reunión", pages: ["Café con leche", "ＦＵＬＬ width"])
        XCTAssertEqual(NoteSearch.search("reunion", in: [a]).count, 1)
        XCTAssertEqual(NoteSearch.search("CAFE", in: [a]).first?.page?.number, 1)
        XCTAssertEqual(NoteSearch.search("full", in: [a]).first?.page?.number, 2)
    }

    func testEveryWordMustMatchAndNotesMatchAcrossFields() {
        let a = note("Linear algebra", notebook: "School/Math", tags: ["exam"], pages: ["eigenvalues of a matrix"])
        let b = note("Cooking", pages: ["matrix of flavours"])
        XCTAssertEqual(NoteSearch.search("matrix eigenvalues", in: [a, b]).map(\.note), [a.id])
        // Title + tag + notebook + text together.
        let hit = NoteSearch.search("linear exam math matrix", in: [a, b])
        XCTAssertEqual(hit.map(\.note), [a.id])
        XCTAssertEqual(hit[0].fields, [.title, .tag, .notebook, .text])
        XCTAssertTrue(NoteSearch.search("matrix unicorn", in: [a, b]).isEmpty)
        XCTAssertTrue(NoteSearch.search("   ", in: [a]).isEmpty)
        XCTAssertTrue(NoteSearch.search("", in: [a]).isEmpty)
    }

    func testHashWordsMatchTagsOnly() {
        let tagged = note("A", tags: ["Physics"])
        let titled = note("Physics notes", pages: ["physics"])
        XCTAssertEqual(NoteSearch.search("#physics", in: [tagged, titled]).map(\.note), [tagged.id])
        XCTAssertEqual(NoteSearch.search("#phys", in: [tagged, titled]).map(\.note), [tagged.id], "substring of a tag")
        XCTAssertEqual(Set(NoteSearch.search("physics", in: [tagged, titled]).map(\.note)), [tagged.id, titled.id])
        XCTAssertTrue(NoteSearch.search("#", in: [tagged]).isEmpty)
    }

    func testRanksTitleOverTagOverNotebookOverText() {
        let text = note("Misc", pages: ["history of art"], modified: 100)
        let nb = note("Misc 2", notebook: "History", modified: 100)
        let tag = note("Misc 3", tags: ["history"], modified: 100)
        let title = note("History", modified: 0)
        let ranked = NoteSearch.search("history", in: [text, nb, tag, title]).map(\.note)
        XCTAssertEqual(ranked, [title.id, tag.id, nb.id, text.id])
    }

    func testTiesGoToTheNewestNote() {
        let old = note("Same", modified: 10), new = note("Same", modified: 20)
        XCTAssertEqual(NoteSearch.search("same", in: [old, new]).map(\.note), [new.id, old.id])
    }

    func testBestPageHasMostWordsThenTheEarliest() {
        let n = note("N", pages: ["alpha", "alpha beta", "beta alpha", "gamma"])
        let hit = NoteSearch.search("alpha beta", in: [n])[0]
        XCTAssertEqual(hit.page?.number, 2)
        XCTAssertEqual(hit.matchedPages, 3)
        XCTAssertEqual(NoteSearch.search("alpha", in: [n])[0].page?.number, 1)
    }

    func testTitleOnlyHitHasNoPage() {
        let n = note("Budget", pages: ["unrelated"])
        let hit = NoteSearch.search("budget", in: [n])[0]
        XCTAssertNil(hit.page)
        XCTAssertNil(hit.snippet)
        XCTAssertEqual(hit.fields, [.title])
    }

    func testSnippetIsFlattenedTrimmedAndMarked() throws {
        let long = String(repeating: "word ", count: 60) + "needle\nsecond line " + String(repeating: "tail ", count: 60)
        let hit = NoteSearch.search("needle", in: [note("N", pages: [long])])[0]
        let s = try XCTUnwrap(hit.snippet)
        XCTAssertTrue(s.text.hasPrefix("…") && s.text.hasSuffix("…"))
        XCTAssertFalse(s.text.contains("\n"))
        XCTAssertLessThan(s.text.count, 160)
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["needle"])
        XCTAssertTrue(s.text.contains("second line"))
    }

    func testQueryWordsAreCappedAndDeduplicated() {
        let n = note("N", pages: ["a b c"])
        XCTAssertEqual(NoteSearch.words("a A a").count, 2, "case differs, so two words")
        XCTAssertEqual(NoteSearch.words((0..<100).map(String.init).joined(separator: " ")).count, NoteSearch.maxWords)
        XCTAssertEqual(NoteSearch.search("a a a a", in: [n]).count, 1)
    }

    // MARK: Snippets leave equations out

    /// A page with handwriting, an equation and a text box, as a note about a pendulum would have it.
    private func pendulumPage() -> Page {
        var page = Page(order: "a")
        page.recognition = Recognition(engine: "t", text: "For small angles a pendulum is a harmonic oscillator")
        let formula = Item.math(MathContent(latex: #"T = 2\pi\sqrt{\frac{L}{g}}"#), frame: Rect(x: 10, y: 10, w: 100, h: 30), z: "a")
        let box = Item.text(TextContent(size: 14, color: .black, runs: [TextRun("Period depends on the length")]),
                            frame: Rect(x: 10, y: 60, w: 200, h: 40), z: "b")
        page.items = [formula, box]
        return page
    }

    private func pendulumNote() -> NoteSummary {
        var s = NoteSummary(id: UUID(), title: "Pendulum", tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0,
                            modified: nil, problem: nil)
        s.pageTexts = PageText.texts(of: [pendulumPage()])
        return s
    }

    func testPageTextRecordsWhichPartIsWhich() throws {
        let t = try XCTUnwrap(PageText.texts(of: [pendulumPage()]).first)
        XCTAssertEqual(t.spans.map(\.isMath), [false, true, false])
        let utf16 = Array(t.text.utf16)
        func part(_ s: PageText.Span) -> String { String(decoding: utf16[s.start..<s.end], as: UTF16.self) }
        XCTAssertEqual(t.spans.map(part), ["For small angles a pendulum is a harmonic oscillator", #"T = 2\pi\sqrt{\frac{L}{g}}"#,
                                           "Period depends on the length"])
    }

    func testSnippetOfProseNeverQuotesTheEquationNextToIt() throws {
        let note = pendulumNote()
        for query in ["oscillator", "pendulum", "small"] {
            let hit = try XCTUnwrap(NoteSearch.search(query, in: [note]).first, query)
            let snippet = try XCTUnwrap(hit.snippet, query)
            XCTAssertFalse(snippet.isEquation)
            XCTAssertFalse(snippet.text.contains("\\") || snippet.text.contains("frac") || snippet.text.contains("sqrt"), snippet.text)
            XCTAssertEqual(snippet.text, "For small angles a pendulum is a harmonic oscillator", "the whole part, nothing of its neighbours")
            XCTAssertFalse(snippet.matches.isEmpty)
        }
        // A match in the text box after the equation stays in the box.
        let boxHit = try XCTUnwrap(NoteSearch.search("length", in: [note]).first?.snippet)
        XCTAssertEqual(boxHit.text, "Period depends on the length")
    }

    func testAMatchInsideAnEquationShowsTheMarkerButStaysSearchable() throws {
        let note = pendulumNote()
        for query in ["frac", "sqrt", #"\pi"#] {
            let hits = NoteSearch.search(query, in: [note])
            XCTAssertEqual(hits.count, 1, "the LaTeX source is still searched: \(query)")
            let snippet = try XCTUnwrap(hits[0].snippet)
            XCTAssertTrue(snippet.isEquation)
            XCTAssertEqual(snippet.text, NoteSearch.equationMarker)
            XCTAssertTrue(snippet.matches.isEmpty)
            XCTAssertEqual(hits[0].page?.number, 1)
        }
        // Words in both: the prose is shown.
        XCTAssertFalse(try XCTUnwrap(NoteSearch.search("pendulum frac", in: [note]).first?.snippet).isEquation)
    }

    func testSnippetStartsAndEndsAtWordBoundaries() throws {
        let words = (0..<120).map { "word\($0)" }
        var s = NoteSummary(id: UUID(), title: "Long", tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0,
                            modified: nil, problem: nil)
        s.pageTexts = [PageText(pageId: UUID(), number: 1, text: words.joined(separator: " "))]
        let snippet = try XCTUnwrap(NoteSearch.search("word60", in: [s]).first?.snippet)
        XCTAssertTrue(snippet.text.hasPrefix("…") && snippet.text.hasSuffix("…"))
        let shown = snippet.text.trimmingCharacters(in: CharacterSet(charactersIn: "…")).split(separator: " ").map(String.init)
        XCTAssertTrue(shown.allSatisfy { Set(words).contains($0) }, "only whole words: \(shown)")
        XCTAssertTrue(shown.contains("word60"))
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["word60"])
    }

    func testHandBuiltPageTextIsOneProsePart() throws {
        let t = PageText(pageId: UUID(), number: 1, text: "plain words only")
        XCTAssertEqual(NoteSearch.snippet(t, words: ["words"])?.text, "plain words only")
        XCTAssertNil(NoteSearch.snippet(t, words: ["absent"]))
    }

    /// Review of #147: a part ending in a carriage return joins the separating newline into one
    /// character (`\r\n`), so its span did not end on a character boundary and the part was
    /// dropped from snippets.
    func testASnippetSurvivesAPartEndingInACarriageReturn() throws {
        let text = "Lecture notes\r"
        let page = PageText(pageId: UUID(), number: 1, text: text + "\n" + "x^2",
                            spans: [.init(start: 0, end: text.utf16.count), .init(start: text.utf16.count + 1,
                                                                                   end: text.utf16.count + 4, isMath: true)])
        let snippet = try XCTUnwrap(NoteSearch.snippet(page, words: ["lecture"]))
        XCTAssertFalse(snippet.isEquation)
        XCTAssertTrue(snippet.text.hasPrefix("Lecture notes"), snippet.text)
    }
}
