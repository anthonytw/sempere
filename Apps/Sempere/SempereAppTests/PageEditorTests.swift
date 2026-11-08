import Foundation
import Sempere
import PencilKit
import Testing
@testable import SempereApp
import SempereAppCore

/// New-note layouts and the page strip. The editor's page gestures and the paged/pageless switch (format.md
/// §5.4.3) are tested on every platform: `Tests/SempereAppCoreTests/NoteEditor/NoteEditorModelTests.swift`.
@MainActor
struct PageEditorTests {
    static let lecture = AppModelTests.lecture

    @Test func newNoteLayouts() async throws {
        #expect(NewNoteLayout.letter.pageSize == .letter)
        #expect(NewNoteLayout.a4.pageSize == .a4)
        #expect(NewNoteLayout.pagelessA4.pageSize == PageSize(width: 595, height: 842, infinite: true, breakHeight: 842))
        let defaults = try #require(TestDefaults.suite("PageEditorTests-\(UUID())"))
        #expect(NewNoteLayout.load(from: defaults) == .letter)
        NewNoteLayout.save(.pagelessLetter, to: defaults)
        #expect(NewNoteLayout.load(from: defaults) == .pagelessLetter)

        let model = try await BrowserTests.unlockedFixtureModel()
        let id = try await model.createNote(title: "Scroll", paper: .ruled, notebook: nil,
                                            pageSize: NewNoteLayout.pagelessLetter.pageSize)
        let state = try #require(model.vault).reconstruct(noteId: id)
        #expect(state.meta.pageSize.isPageless)
        #expect(state.pages.count == 1)
    }

    @Test func stripMoveIndexAndThumbnailSize() {
        #expect(PageStrip.targetIndex(from: 0, toOffset: 2) == 1)   // down past one row
        #expect(PageStrip.targetIndex(from: 2, toOffset: 0) == 0)
        #expect(PageStrip.targetIndex(from: 1, toOffset: 3) == 2)
        #expect(PageStrip.thumbnailHeight(width: 85, pageSize: .letter) == 110)
        #expect(PageStrip.thumbnailHeight(width: 100, pageSize: PageSize(width: .nan, height: 1)) == 100 * 11 / 8.5)
        let image = PageThumbnail.image(strokes: [TS.stroke()], paper: .ruled, pageSize: .letter,
                                        size: CGSize(width: 60, height: 78), scale: 2)
        #expect(image.size == CGSize(width: 60, height: 78))
    }
}
