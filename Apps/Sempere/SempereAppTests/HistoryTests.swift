import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The history browser's model: restore points, previews, and restore through
/// the app's one write path (`NoteWriter`), with the open canvas following.
@MainActor
struct HistoryTests {
    static let lecture = AppModelTests.lecture

    static func unlockedModel() async throws -> AppModel {
        try await BrowserEditorTests.unlockedModel()
    }

    /// Draws one stroke on the open note's first page and saves it as one delta.
    @discardableResult
    static func draw(_ editor: NoteEditor, y: Double) async throws -> UUID {
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        let before = Set(editor.liveStrokes(of: page.id).map(\.id))
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: y)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await editor.flush()
        #expect(editor.saveError == nil)
        return try #require(Set(editor.liveStrokes(of: page.id).map(\.id)).subtracting(before).first)
    }

    /// The error `body` throws, if any (keeps throwing calls out of `#expect`).
    static func thrown(_ body: () throws -> Void) -> (any Error)? {
        do { try body(); return nil } catch { return error }
    }

    static func thrown(_ body: () async throws -> Void) async -> (any Error)? {
        do { try await body(); return nil } catch { return error }
    }

    static func strokeIDs(_ state: NoteState) -> Set<UUID> {
        Set(state.pages.flatMap(\.strokes).map(\.id))
    }

    // MARK: - Listing

    @Test func entriesAreNewestFirstAndMarkTheCurrentVersionAndThisDevice() async throws {
        let model = try await Self.unlockedModel()
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        try await Self.draw(editor, y: 300)
        try await Self.draw(editor, y: 340)

        let data = try await model.loadHistory(for: Self.lecture)
        let points = data.points
        let entries = data.entries
        let entryIDs = entries.map { $0.id }
        let pointNames = points.map { $0.name }
        #expect(entryIDs == Array(pointNames.reversed()))
        #expect(entries.first?.isLatest == true)
        let othersNotLatest = entries.dropFirst().allSatisfy { !$0.isLatest }
        #expect(othersNotLatest)
        let device = try await model.deviceClockForWriting().device
        let mine = entries.filter(\.isThisDevice)
        #expect(mine.count == 2)
        let mineOK = mine.allSatisfy { $0.point.device == device && $0.deviceLabel == "This device" }
        #expect(mineOK)
        let others = entries.filter { !$0.isThisDevice }
        let labels = others.map(\.deviceLabel)
        let labelsOK = labels.allSatisfy { $0.hasPrefix("Device ") }
        #expect(labelsOK)
        let allAvailable = entries.allSatisfy { $0.isAvailable }
        #expect(allAvailable)
        let noReasons = entries.allSatisfy { $0.unavailableReason == nil }
        #expect(noReasons)
        // The fixture note holds a snapshot, so the compaction notice is shown.
        #expect(data.compactionNotice != nil)
    }

    @Test func aNoteWithoutRevisionsHasEmptyHistory() {
        #expect(HistoryEntry.entries([], thisDevice: nil).isEmpty)
        #expect(HistoryEntry.compactionNotice([]) == nil)
    }

    // MARK: - Preview

    @Test func previewIsAReadOnlyEditorOfTheStateAtThatPoint() async throws {
        let model = try await Self.unlockedModel()
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let added = try await Self.draw(editor, y: 300)

        let data = try await model.loadHistory(for: Self.lecture)
        let points = data.points
        let older = points[points.count - 2], newest = points[points.count - 1]
        let before = try await model.historyPreview(data, at: older.name)
        let after = try await model.historyPreview(data, at: newest.name)
        #expect(before.isReadOnly)
        #expect(after.isReadOnly)
        let beforeIDs = Set(before.pages.flatMap { before.liveStrokes(of: $0.id) }.map(\.id))
        let afterIDs = Set(after.pages.flatMap { after.liveStrokes(of: $0.id) }.map(\.id))
        #expect(!beforeIDs.contains(added))
        #expect(afterIDs.contains(added))
        #expect(beforeIDs.count + 1 == afterIDs.count)
        // A preview has no writer: flushing writes nothing.
        let vault = try #require(model.vault)
        let count = try vault.revisionNames(of: Self.lecture).count
        await before.flush()
        let nowCount = try vault.revisionNames(of: Self.lecture).count
        #expect(nowCount == count)
    }

    // MARK: - Restore

    @Test func restoreRoundTripsWithOneDeltaAndUpdatesTheOpenCanvas() async throws {
        let model = try await Self.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let first = try #require(model.editor)
        let original = Self.strokeIDs(try vault.reconstruct(noteId: Self.lecture))
        let a = try await Self.draw(first, y: 300)
        let b = try await Self.draw(first, y: 340)

        let data = try await model.loadHistory(for: Self.lecture)
        let points = data.points
        var found: RestorePoint?
        for p in points where Self.strokeIDs(try data.state(at: p.name)) == original { found = p }
        let atOriginal = try #require(found)
        let target = try data.state(at: atOriginal.name)
        let revisions = try vault.revisionNames(of: Self.lecture).count

        let summary = try #require(try await model.restoreVersion(of: Self.lecture, to: atOriginal.name))
        #expect(summary.strokesRemoved == 2)
        #expect(summary.strokesRestored == 0)
        // Exactly one delta, and the reconstructed note equals the restore point.
        let afterCount = try vault.revisionNames(of: Self.lecture).count
        #expect(afterCount == revisions + 1)
        let now = try vault.reconstruct(noteId: Self.lecture)
        #expect(Self.strokeIDs(now) == original)
        #expect(!Self.strokeIDs(now).contains(a) && !Self.strokeIDs(now).contains(b))
        #expect(now.meta.title == target.meta.title)
        #expect(vault.verify().isHealthy)

        // The open canvas was reopened from the restored state.
        let second = try #require(model.editor)
        #expect(second !== first)
        #expect(!second.isReadOnly)
        let page = try #require(second.currentPage)
        let reopenedIDs = Set(second.pages.flatMap { second.liveStrokes(of: $0.id) }.map { $0.id })
        #expect(reopenedIDs == original)
        let targetPage = try #require(target.pages.first { $0.id == page.id })
        let onCanvas = Set(second.liveStrokes(of: page.id).map { $0.id })
        #expect(onCanvas == Set(targetPage.strokes.map { $0.id }))
        #expect(second.drawing(for: page.id).strokes.count == targetPage.strokes.count)

        // The history kept everything: the newest version is listed first and
        // the strokes can be brought back by restoring it, as new ids.
        let after = try await model.loadHistory(for: Self.lecture)
        #expect(after.points.count == points.count + 1)
        let newest = try #require(after.points.last)
        #expect(newest.app.hasPrefix("sempere-ios/"))
        let again = try #require(try await model.restoreVersion(of: Self.lecture, to: points.last?.name ?? newest.name))
        #expect(again.strokesRestored == 2)
        let revived = try vault.reconstruct(noteId: Self.lecture)
        #expect(Self.strokeIDs(revived).count == original.count + 2)
        let parents = Set(revived.pages.flatMap { $0.strokes }.compactMap { $0.parent })
        #expect(parents.isSuperset(of: [a, b]))
    }

    @Test func restoringAPointTheNoteAlreadyMatchesWritesNothing() async throws {
        let model = try await Self.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        try await Self.draw(try #require(model.editor), y: 300)
        let data = try await model.loadHistory(for: Self.lecture)
        let newest = try #require(data.points.last)
        let count = try vault.revisionNames(of: Self.lecture).count
        let editor = try #require(model.editor)
        let outcome = try await model.restoreVersion(of: Self.lecture, to: newest.name)
        #expect(outcome == nil)
        let nowCount = try vault.revisionNames(of: Self.lecture).count
        #expect(nowCount == count)
        #expect(model.editor === editor)   // nothing changed, so the canvas stays
    }

    @Test func pendingCanvasChangesAreSavedBeforeTheRestore() async throws {
        let model = try await Self.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let data = try await model.loadHistory(for: Self.lecture)
        let start = try #require(data.points.last)
        // Ink drawn but not yet saved (the debounce is a minute).
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 500)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        #expect(editor.deltasWritten == 0)

        let summary = try #require(try await model.restoreVersion(of: Self.lecture, to: start.name))
        #expect(editor.deltasWritten == 1)          // saved first, then restored
        #expect(summary.strokesRemoved == 1)
        let ids = Self.strokeIDs(try vault.reconstruct(noteId: Self.lecture))
        let startIDs = Self.strokeIDs(try data.state(at: start.name))
        #expect(ids == startIDs)
        // And the stale editor does not write the ink back afterwards.
        await editor.flush()
        let finalIDs = Self.strokeIDs(try vault.reconstruct(noteId: Self.lecture))
        #expect(finalIDs == ids)
    }

    @Test func pendingCanvasChangesAreSavedBeforeTheHistoryIsRead() async throws {
        let model = try await Self.unlockedModel()
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        // Ink drawn but not yet saved (the debounce is a minute).
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        let before = Set(editor.liveStrokes(of: page.id).map(\.id))
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 500)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        #expect(editor.deltasWritten == 0)

        let data = try await model.loadHistory(for: Self.lecture)
        #expect(editor.deltasWritten == 1)
        let added = try #require(Set(editor.liveStrokes(of: page.id).map(\.id)).subtracting(before).first)
        // The "Current" row is what the canvas shows, pending ink included.
        let current = try #require(data.entries.first)
        #expect(current.isLatest)
        let currentIDs = Self.strokeIDs(try data.state(at: current.id))
        #expect(currentIDs.contains(added))
        #expect(data.points.count == data.entries.count)
    }

    @Test func restoringBeforeADeleteUndeletesTheNoteAndReopensItEditable() async throws {
        let model = try await Self.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let live = try #require(try await model.loadHistory(for: Self.lecture).points.last)
        try await model.deleteNote(Self.lecture)
        let readOnly = try #require(model.editor)
        #expect(readOnly.isReadOnly)

        let summary = try #require(try await model.restoreVersion(of: Self.lecture, to: live.name))
        #expect(summary.deleted == false)
        let restored = try vault.reconstruct(noteId: Self.lecture)
        #expect(restored.deleted == false)
        let note = Self.lecture
        let listed = model.notes.first { $0.id == note }
        #expect(listed?.deleted == false)
        let reopened = try #require(model.editor)
        #expect(reopened.isReadOnly == false)
    }

    // MARK: - Compaction and iCloud

    @Test func compactedRevisionsAreNotListedAndTheUIsaysSo() async throws {
        let model = try await Self.unlockedModel()
        let vault = try #require(model.vault)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        try await Self.draw(editor, y: 300)
        try await Self.draw(editor, y: 340)
        let before = try await model.loadHistory(for: Self.lecture)

        let loaded = try vault.loadNote(Self.lecture)
        var clock = HybridClock()
        for r in loaded.revisions { clock.observe(r.hlc, wall: Date()) }
        let device = try await model.deviceClockForWriting().device
        try vault.snapshot(noteId: Self.lecture, device: device, clock: &clock, wall: Date(), app: "test/0")
        let deleted = try vault.compact(noteId: Self.lecture, retention: 0, now: Date().addingTimeInterval(3600))
        #expect(!deleted.isEmpty)

        let data = try await model.loadHistory(for: Self.lecture)
        #expect(data.points.count < before.points.count + 1)
        let listed = Set(data.points.map { $0.name })
        #expect(listed.isDisjoint(with: Set(deleted)))
        let notice = try #require(data.compactionNotice)
        #expect(notice.contains("compaction"))
        // Every row is either shown and restorable, or greyed out with a reason and refused.
        for entry in data.entries {
            if entry.isAvailable {
                _ = try data.state(at: entry.id)
            } else {
                #expect(entry.unavailableReason != nil)
                let direct = Self.thrown { _ = try data.state(at: entry.id) }
                #expect(direct as? HistoryError == .incompleteHistory(entry.id))
                let note = Self.lecture
                let viaModel = await Self.thrown { try await model.restoreVersion(of: note, to: entry.id) }
                #expect(viaModel as? HistoryError == .incompleteHistory(entry.id))
            }
        }
        #expect(vault.verify().isHealthy)
    }

    @Test func compactionNoticeAppearsOnlyForSnapshotsOrIncompletePoints() throws {
        let device = try #require(DeviceID("aaaaaaaa"))
        func point(_ ms: Int64, _ kind: RevisionName.Kind, complete: Bool = true) throws -> RestorePoint {
            let hlc = try #require(HLC(millis: ms, counter: 0))
            return RestorePoint(name: RevisionName(hlc: hlc, device: device, seq: Int(ms), kind: kind),
                                wall: Date(timeIntervalSince1970: Double(ms)), app: "test/0", complete: complete)
        }
        var points = [try point(1, .delta), try point(2, .delta)]
        #expect(HistoryEntry.compactionNotice(points) == nil)
        points[0].complete = false
        #expect(HistoryEntry.compactionNotice(points) != nil)
        let entries = HistoryEntry.entries(points, thisDevice: device)
        #expect(entries.last?.id == points[0].name)
        #expect(entries.last?.isAvailable == false)
        #expect(entries.last?.unavailableReason != nil)
        #expect(entries.first?.isAvailable == true)
        let withSnapshot = [try point(1, .delta), try point(2, .snapshot)]
        #expect(HistoryEntry.compactionNotice(withSnapshot) != nil)
    }

    @Test func restoreRefusesANoteWhoseFilesAreNotAllLocal() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let points = try vault.restorePoints(noteId: Self.lecture)
        let target = try #require(points.first)
        let count = try vault.revisionNames(of: Self.lecture).count
        let cloud = FakeCloud(vault: url)
        try cloud.evictDataless(Self.lecture)
        let hooks = cloud.hooks
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let note = Self.lecture
        let refused = await Self.thrown {
            try await NoteWriter.restore(note, to: target.name, vault: vault, clock: clock,
                                         verify: { try CloudVault.requireLocal(note: note, vault: url, hooks: hooks) })
        }
        #expect(refused is CloudVault.CloudError)
        let folder = url.appendingPathComponent("notes/\(note.uuidString.lowercased())")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".age") }
        #expect(files.count == count)
    }
}
