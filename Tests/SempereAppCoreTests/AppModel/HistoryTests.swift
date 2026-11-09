import Foundation
import Sempere
@testable import SempereAppCore
import Testing

extension AppModelSuites {
    /// The history browser's model (`AppModel+History`; moved from the app's `HistoryTests` and the model's cases of
    /// `VersionHistoryAppTests`, which keeps the words): restore points, previews, restore through the one write path
    /// (`NoteWriter`) with the open canvas following, Save Version, editing sessions and the grouped list.
    @MainActor
    struct HistoryTests {
        static let lecture = ModelFixture.lecture

        static func unlockedModel() async throws -> AppModel { try await ThinningTests.unlockedModel() }

        @discardableResult
        static func draw(_ editor: TestEditor, y: Double) async throws -> UUID {
            try await ThinningTests.draw(editor, y: y)
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

        /// The `session` of each of the note's deltas written by `device`, oldest first.
        static func sessions(_ vault: Vault, device: DeviceID) throws -> [String?] {
            try vault.revisionNames(of: lecture).filter { $0.device == device && $0.kind == .delta }.map {
                try vault.readRevision(noteId: lecture, name: $0).session
            }
        }

        // MARK: - Listing

        @Test func entriesAreNewestFirstAndMarkTheCurrentVersionAndThisDevice() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let editor = try #require(model.editor)
            try await Self.draw(editor, y: 300)
            try await Self.draw(editor, y: 340)

            let data = try await model.loadHistory(for: Self.lecture)
            #expect(data.entries.map(\.id) == Array(data.points.map(\.name).reversed()))
            #expect(data.entries.first?.isLatest == true)
            #expect(data.entries.dropFirst().allSatisfy { !$0.isLatest })
            let device = try model.deviceClockForWriting().device
            let mine = data.entries.filter(\.isThisDevice)
            #expect(mine.count == 2)
            #expect(mine.allSatisfy { $0.point.device == device && $0.kind == .edit })
            let others = data.entries.filter { !$0.isThisDevice }
            #expect(!others.isEmpty)
            let prefixes = others.map { ($0.devicePrefix, String($0.point.device.rawValue.prefix(4))) }
            #expect(prefixes.allSatisfy { $0.0 == $0.1 && $0.0.count == 4 })
            #expect(data.entries.allSatisfy { $0.isAvailable })
            // The fixture note holds a snapshot, so the compaction notice is shown.
            #expect(data.needsCompactionNotice)
            #expect(data.entries.contains { $0.kind == .snapshot })
        }

        @Test func aNoteWithoutRevisionsHasEmptyHistory() {
            #expect(HistoryRow.entries([], thisDevice: nil).isEmpty)
            #expect(!HistoryRow.needsCompactionNotice([]))
        }

        @Test func compactionNoticeAppearsOnlyForSnapshotsOrIncompletePoints() throws {
            let device = try #require(DeviceID("aaaaaaaa"))
            func point(_ ms: Int64, _ kind: RevisionName.Kind, complete: Bool = true) throws -> RestorePoint {
                let hlc = try #require(HLC(millis: ms, counter: 0))
                return RestorePoint(name: RevisionName(hlc: hlc, device: device, seq: Int(ms), kind: kind),
                                    wall: Date(timeIntervalSince1970: Double(ms)), app: "test/0", complete: complete)
            }
            var points = [try point(1, .delta), try point(2, .delta)]
            #expect(!HistoryRow.needsCompactionNotice(points))
            points[0].complete = false
            #expect(HistoryRow.needsCompactionNotice(points))
            let entries = HistoryRow.entries(points, thisDevice: device)
            #expect(entries.last?.id == points[0].name)
            #expect(entries.last?.isAvailable == false)
            #expect(entries.first?.isAvailable == true)
            #expect(HistoryRow.needsCompactionNotice([try point(1, .delta), try point(2, .snapshot)]))
        }

        // MARK: - Preview

        @Test func previewIsAReadOnlyEditorOfTheStateAtThatPoint() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
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
            #expect(try vault.revisionNames(of: Self.lecture).count == count)
            // Stepping back to a point previewed before rebuilds nothing.
            let built = data.previews.buildCount
            _ = try await model.historyPreview(data, at: older.name)
            #expect(data.previews.buildCount == built)
        }

        /// The read is reported to the model's `services.perf` as "history.read" (the app's signpost).
        @Test func theReadIsMeasured() async throws {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless()
            let perf = MemoryPerfSink()
            services.perf = perf
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: services)
            defer { model.close() }
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            _ = try await model.loadHistory(for: Self.lecture)
            #expect(perf.records.contains(.measured(phase: "history.read", detail: "")))
        }

        // MARK: - Restore

        @Test func restoreRoundTripsWithOneDeltaAndUpdatesTheOpenCanvas() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
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
            #expect(try vault.revisionNames(of: Self.lecture).count == revisions + 1)
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
            #expect(Set(second.pages.flatMap { second.liveStrokes(of: $0.id) }.map(\.id)) == original)
            let targetPage = try #require(target.pages.first { $0.id == page.id })
            #expect(Set(second.liveStrokes(of: page.id).map(\.id)) == Set(targetPage.strokes.map(\.id)))
            #expect(second.drawing(for: page.id).strokes.count == targetPage.strokes.count)

            // The history kept everything: the newest version is listed first and
            // the strokes can be brought back by restoring it, as new ids.
            let after = try await model.loadHistory(for: Self.lecture)
            #expect(after.points.count == points.count + 1)
            let newest = try #require(after.points.last)
            #expect(newest.app == model.services.appName)
            let again = try #require(try await model.restoreVersion(of: Self.lecture, to: points.last?.name ?? newest.name))
            #expect(again.strokesRestored == 2)
            let revived = try vault.reconstruct(noteId: Self.lecture)
            #expect(Self.strokeIDs(revived).count == original.count + 2)
            let parents = Set(revived.pages.flatMap(\.strokes).compactMap(\.parent))
            #expect(parents.isSuperset(of: [a, b]))
        }

        @Test func restoringAPointTheNoteAlreadyMatchesWritesNothing() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
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
            #expect(try vault.revisionNames(of: Self.lecture).count == count)
            #expect(model.editor === editor)   // nothing changed, so the canvas stays
        }

        @Test func pendingCanvasChangesAreSavedBeforeTheRestore() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
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
            #expect(ids == Self.strokeIDs(try data.state(at: start.name)))
            // And the stale editor does not write the ink back afterwards.
            await editor.flush()
            #expect(Self.strokeIDs(try vault.reconstruct(noteId: Self.lecture)) == ids)
        }

        @Test func pendingCanvasChangesAreSavedBeforeTheHistoryIsRead() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
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
            #expect(Self.strokeIDs(try data.state(at: current.id)).contains(added))
            #expect(data.points.count == data.entries.count)
        }

        @Test func restoringBeforeADeleteUndeletesTheNoteAndReopensItEditable() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let live = try #require(try await model.loadHistory(for: Self.lecture).points.last)
            try await model.deleteNote(Self.lecture)
            #expect(try #require(model.editor).isReadOnly)

            let summary = try #require(try await model.restoreVersion(of: Self.lecture, to: live.name))
            #expect(summary.deleted == false)
            #expect(try vault.reconstruct(noteId: Self.lecture).deleted == false)
            let note = Self.lecture
            #expect(model.notes.first { $0.id == note }?.deleted == false)
            #expect(try #require(model.editor).isReadOnly == false)
        }

        @Test func compactedRevisionsAreNotListedAndCannotBeRestored() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
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
            let device = try model.deviceClockForWriting().device
            try vault.snapshot(noteId: Self.lecture, device: device, clock: &clock, wall: Date(), app: "test/0")
            let deleted = try vault.compact(noteId: Self.lecture, retention: 0, now: Date().addingTimeInterval(3600))
            #expect(!deleted.isEmpty)

            let data = try await model.loadHistory(for: Self.lecture)
            #expect(data.points.count < before.points.count + 1)
            #expect(Set(data.points.map(\.name)).isDisjoint(with: Set(deleted)))
            #expect(data.needsCompactionNotice)
            // Every row is either shown and restorable, or grayed out and refused.
            for entry in data.entries {
                if entry.isAvailable {
                    _ = try data.state(at: entry.id)
                } else {
                    let direct = Self.thrown { _ = try data.state(at: entry.id) }
                    #expect(direct as? HistoryError == .incompleteHistory(entry.id))
                    let note = Self.lecture
                    let viaModel = await Self.thrown { try await model.restoreVersion(of: note, to: entry.id) }
                    #expect(viaModel as? HistoryError == .incompleteHistory(entry.id))
                }
            }
            #expect(vault.verify().isHealthy)
        }

        // MARK: - Editing sessions and Save Version

        @Test func editorDeltasCarryOneSessionPerOpening() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            let device = try model.deviceClockForWriting().device
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let first = try #require(model.editor)
            try await Self.draw(first, y: 300)
            try await Self.draw(first, y: 340)
            try await model.openEditor(for: nil)              // closed
            try await model.openEditor(for: Self.lecture)     // and opened again, at once
            let second = try #require(model.editor)
            try await Self.draw(second, y: 380)
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
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            let device = try model.deviceClockForWriting().device
            try await model.addTag("plain", to: Self.lecture)
            #expect(try Self.sessions(vault, device: device) == [nil])
        }

        @Test func saveVersionWritesANamedCheckpointAfterTheOpenInk() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
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
            #expect(data.groups[0].newest.point.checkpoint == Checkpoint())
            #expect(data.groups[1].newest.point.checkpoint?.name == "Before the exam")
            #expect(data.groups[1].newest.kind == .savedVersion)
            #expect(data.groups[0].newest.isLatest)
            // A checkpoint can be previewed like any point.
            #expect(try await model.historyPreview(data, at: name).isReadOnly)
        }

        @Test func saveVersionNeedsAnUnlockedVault() async throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: .headless())
            defer { model.close() }
            let error = await Self.thrown { _ = try await model.saveVersion(of: Self.lecture, name: nil) }
            #expect(error as? AppModelError == .noVaultOpen)
            let read = await Self.thrown { _ = try await model.loadHistory(for: Self.lecture) }
            #expect(read as? AppModelError == .noVaultOpen)
        }

        // MARK: - Grouping rows

        @Test func groupRowsAreNewestFirst() throws {
            let device = try #require(DeviceID("aaaaaaaa"))
            func point(_ minutes: Double, seq: Int, session: String?, checkpoint: Checkpoint? = nil) throws -> RestorePoint {
                let ms = Int64(1_760_000_000_000 + minutes * 60_000)
                return RestorePoint(name: RevisionName(hlc: try #require(HLC(millis: ms, counter: 0)), device: device, seq: seq,
                                                       kind: .delta),
                                    wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "t", complete: true,
                                    checkpoint: checkpoint, session: session)
            }
            let points = [try point(0, seq: 1, session: "s1"), try point(2, seq: 2, session: "s1"),
                          try point(3, seq: 3, session: "s1", checkpoint: Checkpoint(name: "v1")),
                          try point(4, seq: 4, session: "s1"), try point(30, seq: 5, session: "s1")]
            let entries = HistoryRow.entries(points, thisDevice: device)
            let rows = HistoryGroupRow.rows(points, entries: entries)
            #expect(rows.map(\.kind) == [.session, .session, .checkpoint, .session])
            #expect(rows.map(\.saves) == [1, 1, 1, 2])
            #expect(rows[0].containsLatest)
            #expect(rows[2].newest.kind == .savedVersion)
            #expect(rows[3].entries.map(\.id) == [points[1].name, points[0].name])
            #expect(rows[3].start == points[0].wall)
            #expect(rows[3].end == points[1].wall)
            #expect(rows.allSatisfy { $0.newest.isThisDevice })
        }
    }
}
