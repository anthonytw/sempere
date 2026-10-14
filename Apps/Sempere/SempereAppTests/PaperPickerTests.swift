import Foundation
import SempereRender
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The paper picker's model, the remembered default and applying paper to a note.
@MainActor
struct PaperPickerTests {
    static func defaults() -> UserDefaults {
        let name = "PaperPickerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Draft

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

    // MARK: Default for new notes

    @Test func defaultPaperPersists() {
        let d = Self.defaults()
        #expect(PaperPreference.load(from: d) == PaperPreference.fallback)
        let paper = Paper(kind: .isoDot, spacing: 28, background: Paper.cream, dotRadius: 1.4)
        PaperPreference.save(paper, to: d)
        #expect(PaperPreference.load(from: d) == paper)
    }

    @Test func defaultPaperIsClampedAndCorruptDataFallsBack() {
        let d = Self.defaults()
        PaperPreference.save(Paper(kind: .grid, spacing: 1, lineWidth: 99), to: d)
        let loaded = PaperPreference.load(from: d)
        #expect(loaded.isValid)
        #expect(loaded.spacing == Paper.Limits.spacing.lowerBound)
        d.set(Data("not json".utf8), forKey: PaperPreference.defaultsKey)
        #expect(PaperPreference.load(from: d) == PaperPreference.fallback)
    }

    // MARK: Thumbnails

    @Test func thumbnailsAreRenderedAndCached() {
        let size = CGSize(width: 120, height: 155)
        let a = PaperImage.image(for: Paper.template(.grid), size: size, scale: 2)
        #expect(a.size == size)
        #expect(a === PaperImage.image(for: Paper.template(.grid), size: size, scale: 2))
        #expect(a !== PaperImage.image(for: Paper.template(.dot), size: size, scale: 2))
        #expect(a !== PaperImage.image(for: Paper(kind: .grid, spacing: 40), size: size, scale: 2))
    }

    // MARK: Canvas paper layer

    private static func subpaths(_ path: CGPath) -> Int {
        var n = 0
        path.applyWithBlock { e in if e.pointee.type == .moveToPoint { n += 1 } }
        return n
    }

    @Test func canvasPaperLayerDrawsEveryKindLikeTheRenderer() {
        let page = CGSize(width: 612, height: 792)
        for kind in PaperKind.allCases {
            let paper = Paper.template(kind)
            let groups = PaperView.groups(paper: paper, size: page, sheetHeight: 792)
            #expect(groups.isEmpty == (kind == .blank), "\(kind)")
            let commands = PaperRenderer.commands(paper: paper, width: 612, height: 792, includeBackground: false,
                                                  sheetHeight: 792)
            #expect(groups.reduce(0) { $0 + Self.subpaths($1.path) } == commands.count, "\(kind)")
        }
    }

    @Test func canvasPaperLayerFollowsLineWidthAndMarginColour() {
        let page = CGSize(width: 612, height: 792)
        let thick = PaperView.groups(paper: Paper(kind: .ruled, lineWidth: 2), size: page)
        #expect(thick.map(\.lineWidth) == [2])
        let margin = PaperView.groups(paper: Paper(kind: .marginRuled, marginTop: 50), size: page)
        #expect(margin.count == 2)   // ruling, and the margin lines in their own colour
        #expect(Set(margin.compactMap(\.stroke)).count == 2)
        let cornell = PaperView.groups(paper: Paper(kind: .cornell), size: page, sheetHeight: 792)
        #expect(Set(cornell.map(\.lineWidth)) == [0.5, 1])   // notes rules and the heavier cue / summary rules
    }

    // MARK: Applying to a note

    static let lecture = AppModelTests.lecture

    @Test func applyToThisPageWritesOnePagePaperOp() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage)
        let before = editor.meta.paper
        let grid = Paper(kind: .grid, spacing: 30)
        editor.showPaperPreview(Paper(kind: .staff))
        #expect(editor.displayedPaper(of: page) == Paper(kind: .staff).validated())   // live preview
        editor.setPaper(grid, allPages: false)
        let shown = try #require(editor.currentPage)
        #expect(editor.displayedPaper(of: shown) == grid)
        #expect(editor.meta.paper == before)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).last == [.setPagePaper(pageId: page.id, paper: grid)])
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.first { $0.id == page.id }?.paper == grid)
        #expect(state.meta.paper == before)
    }

    @Test func applyToAllPagesSetsTheNotePaperAndClearsOverrides() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault)
        editor.addPage()
        let second = try #require(editor.currentPage)
        editor.setPaper(Paper(kind: .cornell), allPages: false)
        await editor.flush()
        let cornell = Paper(kind: .cornell)
        #expect(editor.displayedPaper(of: try #require(editor.currentPage)) == cornell)

        let dots = Paper(kind: .dot, spacing: 20)
        editor.setPaper(dots, allPages: true)
        for page in editor.pages { #expect(editor.displayedPaper(of: page) == dots) }
        await editor.flush()
        let last = try #require(try NoteEditorTests.myDeltas(vault, clock).last)
        #expect(last == [.setMeta(.paper(dots)), .setPagePaper(pageId: second.id, paper: nil)])
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.meta.paper == dots)
        #expect(state.pages.allSatisfy { $0.paper == nil })
    }

    @Test func applyingTheSamePaperWritesNothing() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage)
        editor.setPaper(editor.displayedPaper(of: page), allPages: true)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).isEmpty)
        #expect(editor.previewPaper == nil)
    }
}
