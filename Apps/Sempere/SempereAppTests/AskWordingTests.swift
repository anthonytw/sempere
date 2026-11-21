import Foundation
import SempereAppCore
import SempereInsights
import Testing
@testable import SempereApp

/// The words of the Ask screen (`AskWording`, docs/design/1.3-ask.md §3.6): the banner per reason, the VoiceOver label of a
/// citation chip, a row's detail line and the matched words in bold.
@MainActor
struct AskWordingTests {
    @Test func everyBannerHasItsOwnWords() {
        let all: [AskBanner] = [.modelUnavailable(kind: "disabled"), .modelUnavailable(kind: "notReady"), .modelUnavailable(kind: "deviceNotEligible"),
                                .modelUnavailable(kind: "noModel"), .languageUnsupported("es"), .notesLanguageUnsupported("en"),
                                .questionNotTranslated("en"), .modelFailed,
                                .vectorsSkipped(kind: "language"), .vectorsSkipped(kind: "incompatible"), .insightsOff]
        let words = all.map(AskWording.text)
        #expect(Set(words).count == words.count - 1, "deviceNotEligible and noModel say the same: not available")
        #expect(words.allSatisfy { !$0.isEmpty })
        #expect(AskWording.text(.modelUnavailable(kind: "disabled")).contains("off"))
        #expect(AskWording.text(.modelUnavailable(kind: "notReady")).contains("not ready"))
        #expect(AskWording.text(.modelUnavailable(kind: "disabled")).contains(RememberedKeys.deviceName), "names this device")
    }

    @Test func aChipIsLabeledWithItsNumberTitleAndPage() {
        #expect(AskWording.chipLabel(number: 2, title: "Deck plan", page: 3) == "Source 2, Deck plan, page 3")
        #expect(AskWording.chipLabel(number: 1, title: "Deck plan", page: nil) == "Source 1, Deck plan")
        #expect(AskWording.chipLabel(number: 1, title: "", page: 2) == "Source 1, Untitled note, page 2")
    }

    @Test func aRowSaysWhereTheNoteIsAndWhyItMatched() {
        let note = AskNoteResult(note: "x", title: "T", notebook: "Home", modified: nil, pages: [3, 4], why: ["keywords", "similar"], used: true, passages: [])
        #expect(AskWording.detail(note) == "Home · Pages 3, 4")
        var one = note
        one.pages = [3]; one.notebook = nil
        #expect(AskWording.detail(one) == "Page 3")
        #expect(AskWording.why(["keywords"]) == "Your words")
        #expect(AskWording.why(["keywords", "similar"]) == "Your words, Similar topic")
    }

    @Test func matchedWordsAreBold() {
        let text = AskWording.highlighted("The damping ratio decides it.", question: "damping ratio")
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(text[$0.range].characters) }
        #expect(bold == ["damping", "ratio"])
    }
}
