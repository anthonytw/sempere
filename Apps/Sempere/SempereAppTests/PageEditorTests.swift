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

    @Test func newNoteLayoutsCreateANote() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = try await model.createNote(title: "Scroll", paper: .ruled, notebook: nil,
                                            pageSize: NewNoteLayout.pagelessLetter.pageSize)
        let state = try #require(model.vault).reconstruct(noteId: id)
        #expect(state.meta.pageSize.isPageless)
        #expect(state.pages.count == 1)
    }

    @Test func stripThumbnailsAreDrawn() {
        let image = PageThumbnail.image(strokes: [TS.stroke()], paper: .ruled, pageSize: .letter,
                                        size: CGSize(width: 60, height: 78), scale: 2)
        #expect(image.size == CGSize(width: 60, height: 78))
    }
}
