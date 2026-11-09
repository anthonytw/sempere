import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// The paper picker's model (`PaperDraft`) and the remembered default paper (`PaperPreference`).
@MainActor
struct PaperDraftTests {
    @Test func selectingAKindTakesItsDefaultsAndKeepsTheBackground() {
        let draft = PaperDraft(paper: Paper(kind: .ruled, spacing: 30, background: Paper.cream))
        draft.select(.dot)
        #expect(draft.kind == .dot)
        #expect(draft.paper.spacing == Paper.template(.dot).spacing)
        #expect(draft.paper.background == Paper.cream)
        draft.select(.staff)
        #expect(draft.paper.staffSpacing == Paper.template(.staff).staffSpacing)
        #expect(draft.paper.lineColor == Paper.template(.staff).lineColor)
    }

    @Test func aLineColourTheUserPickedSurvivesChangingKind() {
        let draft = PaperDraft(paper: .ruled)
        let red = Sempere.Color(r: 255, g: 0, b: 0)
        draft.setLineColor(red)
        draft.select(.grid)
        #expect(draft.paper.lineColor == red)
    }

    @Test func parametersAreClampedToTheirRanges() {
        let draft = PaperDraft(paper: .ruled)
        draft.set(.spacing, to: 1)
        #expect(draft.value(of: .spacing) == Paper.Limits.spacing.lowerBound)
        draft.set(.lineWidth, to: 100)
        #expect(draft.value(of: .lineWidth) == Paper.Limits.lineWidth.upperBound)
        draft.set(.marginLeft, to: -5)
        #expect(draft.value(of: .marginLeft) == 0)
        draft.set(.spacing, to: .nan)
        #expect(draft.paper.isValid)
        let wild = PaperDraft(paper: Paper(kind: .dot, spacing: 9999, dotRadius: -1))
        #expect(wild.paper.isValid)
    }

    @Test func eachKindOffersItsOwnParameters() {
        #expect(PaperDraft(paper: .blank).parameters.isEmpty)
        #expect(PaperDraft(paper: Paper(kind: .dot)).parameters.contains(.dotRadius))
        #expect(!PaperDraft(paper: Paper(kind: .ruled)).parameters.contains(.dotRadius))
        #expect(PaperDraft(paper: Paper(kind: .cornell)).parameters.contains(.cueWidth))
        let staff = PaperDraft(paper: Paper(kind: .staff)).parameters
        #expect(staff.contains(.staffSpacing) && staff.contains(.staffGap) && !staff.contains(.spacing))
        for kind in PaperKind.allCases {
            let draft = PaperDraft(paper: Paper.template(kind))
            for p in draft.parameters { #expect(p.range.contains(draft.value(of: p)), "\(kind) \(p)") }
        }
    }

    @Test func backgroundPresetsAndReset() {
        let draft = PaperDraft(paper: .ruled)
        draft.select(PaperBackground.dark)
        #expect(draft.background == .dark)
        #expect(draft.paper.lineColor == PaperDraft.darkLineColor)
        draft.select(PaperBackground.cream)
        #expect(draft.paper.background == Paper.cream)
        #expect(draft.paper.lineColor == Paper.template(.ruled).lineColor)
        draft.set(.spacing, to: 40)
        draft.reset()
        #expect(draft.paper == Paper(kind: .ruled, background: Paper.cream))
    }

    @Test func defaultPaperPersists() {
        let d = MemoryKeyValueStore()
        #expect(PaperPreference.load(from: d) == PaperPreference.fallback)
        let paper = Paper(kind: .isoDot, spacing: 28, background: Paper.cream, dotRadius: 1.4)
        PaperPreference.save(paper, to: d)
        #expect(PaperPreference.load(from: d) == paper)
    }

    @Test func defaultPaperIsClampedAndCorruptDataFallsBack() {
        let d = MemoryKeyValueStore()
        PaperPreference.save(Paper(kind: .grid, spacing: 1, lineWidth: 99), to: d)
        let loaded = PaperPreference.load(from: d)
        #expect(loaded.isValid)
        #expect(loaded.spacing == Paper.Limits.spacing.lowerBound)
        d.set(Data("not json".utf8), forKey: PaperPreference.defaultsKey)
        #expect(PaperPreference.load(from: d) == PaperPreference.fallback)
    }
}
