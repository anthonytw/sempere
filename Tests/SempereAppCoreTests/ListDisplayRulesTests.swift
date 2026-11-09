import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// The rules under the note list's words (`ListDisplayRules`): a title's trim, a search snippet's equation marker and
/// the recognition results' line. The words themselves are the app's (`TitleRenameTests`, `SearchTests`,
/// `PolishRound1Tests`).
struct ListDisplayRulesTests {
    @Test func aTitleIsTrimmedAndABlankOneIsNil() {
        #expect(NoteTitle.trimmed("") == nil)
        #expect(NoteTitle.trimmed("  \n") == nil)
        #expect(NoteTitle.trimmed(" Lecture 3 ") == "Lecture 3")
    }

    @Test func anEquationSnippetShowsTheMarkerAndProseItsText() {
        let prose = NoteSearchHit.Snippet(text: "the eigenvalues", matches: [])
        #expect(SearchSnippetText.display(prose, equationMarker: "[equation]") == "the eigenvalues")
        let equation = NoteSearchHit.Snippet(text: NoteSearch.equationMarker, matches: [], isEquation: true)
        #expect(SearchSnippetText.display(equation, equationMarker: "[equation]") == "[equation]")
    }

    @Test func pagesReadAreAllOrSome() {
        #expect(RecognitionPagesRead(read: 3, of: 3) == .all(read: 3))
        #expect(RecognitionPagesRead(read: 1, of: 1) == .all(read: 1))
        #expect(RecognitionPagesRead(read: 1, of: 2) == .some(read: 1, of: 2))
        #expect(RecognitionPagesRead(read: 0, of: 5) == .some(read: 0, of: 5))
    }

    @Test func theResultsLineSaysWhatIsGoingOnAndWhatWentWrong() {
        var results = RecognitionResults()
        #expect(results.detailParts(running: false).isEmpty)
        #expect(results.detailParts(running: true) == [.running])
        results.failed = 2
        #expect(results.detailParts(running: true) == [.running, .failed(2)])
        results.stopped = true
        #expect(results.detailParts(running: false) == [.failed(2), .stopped])
    }
}
