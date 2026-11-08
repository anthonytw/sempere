import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Save Version, editing sessions, the grouped history list and thinning after a Save Version
/// (format.md §5.8) in the app model. The rest of thinning is `ThinningTests` in `SempereAppCoreTests`.
@MainActor
struct VersionHistoryAppTests {
    static let lecture = AppModelTests.lecture

    /// The `session` of each of the note's deltas written by `device`, oldest first.
    static func sessions(_ vault: Vault, device: DeviceID) throws -> [String?] {
        try vault.revisionNames(of: lecture).filter { $0.device == device && $0.kind == .delta }.map {
            try vault.readRevision(noteId: lecture, name: $0).session
        }
    }

    // MARK: - Editing sessions

    @Test func editorDeltasCarryOneSessionPerOpening() async throws {
        let model = try await HistoryTests.unlockedModel()
        let vault = try #require(model.vault)
        let device = try model.deviceClockForWriting().device
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let first = try #require(model.editor)
        try await HistoryTests.draw(first, y: 300)
        try await HistoryTests.draw(first, y: 340)
        try await model.openEditor(for: nil)              // closed
        try await model.openEditor(for: Self.lecture)     // and opened again, at once
        let second = try #require(model.editor)
        try await HistoryTests.draw(second, y: 380)
        #expect(first.editingSession != second.editingSession)

        let written = try Self.sessions(vault, device: device)
        #expect(written == [first.editingSession, first.editingSession, second.editingSession])
        #expect(written.allSatisfy { $0.map(EditingSession.isValid) ?? false })

        // The history list shows two sessions for this device (rule a), although no 10 minutes passed.
        let data = try await model.loadHistory(for: Self.lecture)
        let mine = data.groups.filter { $0.kind == .session && $0.newest.isThisDevice }
        #expect(mine.map(\.saves) == [1, 2])
        #expect(mine.first?.containsLatest == true)
    }

    @Test func browserEditsCarryNoSession() async throws {
        let model = try await HistoryTests.unlockedModel()
        let vault = try #require(model.vault)
        let device = try model.deviceClockForWriting().device
        try await model.addTag("plain", to: Self.lecture)
        #expect(try Self.sessions(vault, device: device) == [nil])
    }

    // MARK: - Save Version

    @Test func saveVersionWritesANamedCheckpointAfterTheOpenInk() async throws {
        let model = try await HistoryTests.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 420)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)   // not saved yet

        let name = try await model.saveVersion(of: Self.lecture, name: "  Before the exam ")
        let names = try vault.revisionNames(of: Self.lecture)
        #expect(names.last == name, "the pending ink is saved before the checkpoint")
        let rev = try vault.readRevision(noteId: Self.lecture, name: name)
        #expect(rev.checkpoint == Checkpoint(name: "Before the exam"))
        guard case .delta(let ops) = rev.body else { Issue.record("not a delta"); return }
        #expect(ops.isEmpty)
        let ink = try vault.readRevision(noteId: Self.lecture, name: names[names.count - 2])
        guard case .delta(let inkOps) = ink.body else { Issue.record("not a delta"); return }
        #expect(!inkOps.isEmpty)

        let unnamed = try await model.saveVersion(of: Self.lecture, name: "   ")
        #expect(try vault.readRevision(noteId: Self.lecture, name: unnamed).checkpoint == Checkpoint())

        let data = try await model.loadHistory(for: Self.lecture)
        #expect(data.groups.prefix(2).map(\.kind) == [.checkpoint, .checkpoint])
        #expect(data.groups[0].newest.checkpointTitle == "Saved Version")
        #expect(data.groups[1].newest.checkpointTitle == "Before the exam")
        #expect(data.groups[1].newest.kindLabel == "Saved version")
        #expect(data.groups[0].newest.isLatest)
        // A checkpoint can be previewed like any point.
        let preview = try await model.historyPreview(data, at: name)
        #expect(preview.isReadOnly)
    }

    // MARK: - Grouping rows

    @Test func groupRowsAreNewestFirstWithLabels() {
        let device = DeviceID("aaaaaaaa")!
        func point(_ minutes: Double, seq: Int, session: String?, checkpoint: Checkpoint? = nil) -> RestorePoint {
            let ms = Int64(1_760_000_000_000 + minutes * 60_000)
            return RestorePoint(name: RevisionName(hlc: HLC(millis: ms, counter: 0)!, device: device, seq: seq, kind: .delta),
                                wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "t", complete: true,
                                checkpoint: checkpoint, session: session)
        }
        let points = [point(0, seq: 1, session: "s1"), point(2, seq: 2, session: "s1"),
                      point(3, seq: 3, session: "s1", checkpoint: Checkpoint(name: "v1")),
                      point(4, seq: 4, session: "s1"), point(30, seq: 5, session: "s1")]
        let entries = HistoryEntry.entries(points, thisDevice: device)
        let rows = HistoryGroupRow.rows(points, entries: entries)
        #expect(rows.map(\.kind) == [.session, .session, .checkpoint, .session])
        #expect(rows.map(\.saves) == [1, 1, 1, 2])
        #expect(rows[0].containsLatest)
        #expect(rows[3].summary == "This device · 2 saves")
        #expect(rows[0].summary == "This device · 1 save")
        #expect(rows[3].entries.map(\.id) == [points[1].name, points[0].name])
        #expect(rows[3].start == points[0].wall)
        #expect(rows[3].end == points[1].wall)
        #expect(rows[3].timeRange.contains("–"))
        #expect(!rows[0].timeRange.contains("–"))
    }

    // MARK: - Thinning

    /// The schedule and the window's rule are `ThinningTests` (SempereAppCoreTests); here, the choices' words.
    @Test func thinningPreferenceLabels() {
        #expect(ThinningPreference.label(0) == "Never")
        #expect(ThinningPreference.label(30) == "30 days")
        #expect(ThinningPreference.label(365) == "1 year")
    }

    @Test func thinNowPreviewsThenKeepsCheckpointsAndSessionEnds() async throws {
        let model = try await HistoryTests.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        for y in stride(from: 300.0, through: 420, by: 40) { try await HistoryTests.draw(editor, y: y) }
        let checkpoint = try await model.saveVersion(of: Self.lecture, name: "keep")
        try await model.openEditor(for: nil)
        let sessionEnd = try #require(try vault.revisionNames(of: Self.lecture).last { $0 < checkpoint && $0.kind == .delta })
        let before = try vault.revisionNames(of: Self.lecture)
        let current = try vault.reconstruct(noteId: Self.lecture)
        let later = Date().addingTimeInterval(400 * 86_400)   // everything is a year old by then

        let preview = try await model.thinVault(days: 30, dryRun: true, now: later)
        #expect(try vault.revisionNames(of: Self.lecture) == before, "a preview writes and deletes nothing")
        let lecture = try #require(preview.notes.first { $0.id == Self.lecture })
        #expect(lecture.deletions > 0)
        #expect(lecture.bytesDeleted > 0)
        #expect(!ThinningPreviewView.sentence(preview, done: false).isEmpty)

        let done = try await model.thinVault(days: 30, dryRun: false, now: later)
        #expect(done.notes.first { $0.id == Self.lecture }?.deletions == lecture.deletions)
        let after = try vault.revisionNames(of: Self.lecture)
        #expect(after.contains(checkpoint))
        #expect(after.contains(sessionEnd))
        #expect(after.count < before.count + lecture.snapshots)
        #expect(try vault.reconstruct(noteId: Self.lecture).pages.map(\.strokes.count) == current.pages.map(\.strokes.count))
        let points = try vault.restorePoints(noteId: Self.lecture)
        #expect(points.first { $0.name == checkpoint }?.complete == true)
        #expect(points.first { $0.name == sessionEnd }?.complete == true)

        let again = try await model.thinVault(days: 30, dryRun: true, now: later)
        #expect(again.notes.first { $0.id == Self.lecture } == nil, "nothing left to thin")
    }

    /// "Thin versions older than 30 days" leaves today's autosaves; "Thin everything
    /// except checkpoints" ignores the window and keeps checkpoints and session ends.
    /// Both state their rule, count notes as they go and change no note's state.
    @Test func thinEverythingExceptCheckpointsIgnoresTheWindow() async throws {
        let model = try await HistoryTests.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        for y in stride(from: 300.0, through: 420, by: 40) { try await HistoryTests.draw(editor, y: y) }
        let checkpoint = try await model.saveVersion(of: Self.lecture, name: "keep")
        try await model.openEditor(for: nil)
        let sessionEnd = try #require(try vault.revisionNames(of: Self.lecture).last { $0 < checkpoint && $0.kind == .delta })
        let before = try vault.revisionNames(of: Self.lecture)
        let current = try vault.reconstruct(noteId: Self.lecture)
        let notes = try vault.noteIDs().count

        let windowed = try await model.thinVault(rule: .olderThan(days: 30), dryRun: true)
        #expect(windowed.rule == .olderThan(days: 30))
        #expect(windowed.notes.first { $0.id == Self.lecture } == nil, "today's autosaves are inside the window")
        #expect(windowed.checked == notes)
        #expect(model.thinningProgress == nil)

        let preview = try await model.thinVault(rule: .allButCheckpoints, dryRun: true)
        #expect(preview.rule == .allButCheckpoints)
        let lecture = try #require(preview.notes.first { $0.id == Self.lecture })
        #expect(lecture.deletions > 0)
        #expect(try vault.revisionNames(of: Self.lecture) == before)
        #expect(ThinningRule.allButCheckpoints.title == "Thin everything except checkpoints")
        #expect(ThinningRule.allButCheckpoints.explanation.contains("Keeps every checkpoint"))
        #expect(ThinningRule.olderThan(days: 30).title == "Thin versions older than 30 days")

        let done = try await model.thinVault(rule: .allButCheckpoints, dryRun: false)
        #expect(done.notes.first { $0.id == Self.lecture }?.deletions == lecture.deletions)
        let after = try vault.revisionNames(of: Self.lecture)
        #expect(after.contains(checkpoint))
        #expect(!after.contains(sessionEnd), "no session end stays (format.md §5.8.4)")
        #expect(try vault.reconstruct(noteId: Self.lecture).pages.map(\.strokes.count) == current.pages.map(\.strokes.count))
        let points = try vault.restorePoints(noteId: Self.lecture)
        #expect(points.first { $0.name == checkpoint }?.complete == true)
        #expect(try await model.thinVault(rule: .allButCheckpoints, dryRun: true).notes.isEmpty, "nothing left")
    }

    @Test func thinningProgressHeadline() {
        #expect(ThinningProgress(done: 120, total: 640, dryRun: true).headline == "Checking notes: 120 of 640")
        #expect(ThinningProgress(done: 3, total: 12, dryRun: false).headline == "Thinning notes: 3 of 12")
    }

    // MARK: - Menu

    @Test func saveVersionMenuCommand() {
        #expect(MenuCommand.saveVersion.title == "Save Version…")
        #expect(MenuLayout.note.flatMap { $0 }.contains(.saveVersion))
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        #expect(!MenuCommand.saveVersion.isEnabled(in: c))
        c.hasNote = true
        #expect(MenuCommand.saveVersion.isEnabled(in: c))
        c.noteDeleted = true
        #expect(!MenuCommand.saveVersion.isEnabled(in: c))
        #expect(!MenuCommand.saveVersion.isEnabled(in: MenuCommand.Context(window: .note, vault: .locked, hasNote: true)))
    }
}
