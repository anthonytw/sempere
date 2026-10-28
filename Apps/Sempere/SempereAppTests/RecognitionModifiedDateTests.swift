import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Recognition is derived (format.md §5.5): the editor's pass when a note opens and "Recognize N Notes Now" write
/// deltas that leave the note's modified date, and so the list's "Modified" order, where the last edit put them
/// (`ModifiedDate`). The owner's report, 2026-10-25: opening a note moved it to the top of the list.
@MainActor
struct RecognitionModifiedDateTests {
    static let lecture = AppModelTests.lecture

    @Test func theOpenTimePassKeepsTheDate() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let before = try #require(try vault.summary(of: Self.lecture).modified)
        #expect(try vault.summary(of: Self.lecture).pagesNeedingRecognition == 2)
        let (editor, _) = try await EditorRecognitionTests.open(vault, recognizer: FakeRecognizer(), delay: .milliseconds(10))
        // The pass `open` schedules (the one a note gets when it opens).
        #expect(await TS.waitUntil(timeout: .seconds(10)) { editor.recognitionsWritten == 2 })
        await editor.close()
        let after = try vault.summary(of: Self.lecture)
        #expect(after.pagesNeedingRecognition == 0)
        #expect(after.modified == before)
        // The delta is there, with a later `wall`; it just does not count.
        let newest = try vault.loadNote(Self.lecture).revisions.map(\.wall).max()
        #expect(newest.map { $0 > before } == true)
    }

    @Test func recognizeAllKeepsTheDatesAndTheOrder() async throws {
        let fake = FakeRecognizer()
        let (model, vault, _) = try await SearchTests.model(recognizer: fake, texts: nil)
        let order = NoteOrder(.modified)
        let dates = Dictionary(uniqueKeysWithValues: model.notes.map { ($0.id, $0.modified) })
        let listed = order.sorted(model.notes).map(\.id)
        #expect(model.notesNeedingRecognition.map(\.id) == [Self.lecture])
        model.startRecognizingNotes()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionProgress == nil && model.recognitionTask == nil })
        #expect(fake.calls.count == 2)
        #expect(model.notesNeedingRecognition.isEmpty)
        #expect(try vault.reconstruct(noteId: Self.lecture).meta.recognized != nil, "the run's record was written")
        for n in model.notes { #expect(n.modified == dates[n.id], "\(n.title)") }
        #expect(order.sorted(model.notes).map(\.id) == listed)
        #expect(try vault.summary(of: Self.lecture).modified == dates[Self.lecture] ?? nil)
    }
}
