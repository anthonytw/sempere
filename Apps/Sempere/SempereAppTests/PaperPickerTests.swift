import Foundation
import SempereRender
import Sempere
import Testing
import UIKit
@testable import SempereApp
import SempereAppCore

/// The paper picker's model, the remembered default and applying paper to a note.
@MainActor
struct PaperPickerTests {

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
        #expect(margin.count == 2)   // ruling, and the margin lines in their own color
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
