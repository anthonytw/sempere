import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Thinning through the model (format.md §5.8.4; `AppModel+Thinning`; moved from the app's `VersionHistoryAppTests`,
    /// which keeps the two runs after a Save Version until `+History` moves, and the words): the settings' window and
    /// schedule, a confirmed preview, notes open or being opened, and the automatic run after a listing.
    @MainActor
    struct ThinningTests {
        static let lecture = ModelFixture.lecture

        /// The fixture vault, unlocked, with a long editor debounce (each `draw` flushes itself).
        static func unlockedModel(afterIO: (@Sendable () async -> Void)? = nil, automaticThinning: Bool = false,
                                  settings: any KeyValueStore = MemoryKeyValueStore()) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60),
                                 automaticThinning: automaticThinning, services: .headless(settings: settings), afterIO: afterIO)
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            return model
        }

        /// Draws one stroke on the open note's first page and saves it as one delta.
        @discardableResult
        static func draw(_ editor: TestEditor, y: Double) async throws -> UUID {
            let page = try #require(editor.currentPage)
            var drawing = editor.drawing(for: page.id)
            let before = Set(editor.liveStrokes(of: page.id).map(\.id))
            drawing.strokes.append(TS.canvasStroke(TS.stroke(y: y)))
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            await editor.flush()
            #expect(editor.saveFailure == nil)
            return try #require(Set(editor.liveStrokes(of: page.id).map(\.id)).subtracting(before).first)
        }

        @Test func thinningPreferenceAndSchedule() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(ThinningPreference.defaultDays == 30)
            #expect(ThinningPreference.isDue(days: 30, lastRun: nil, now: now))
            #expect(!ThinningPreference.isDue(days: 0, lastRun: nil, now: now))
            #expect(!ThinningPreference.isDue(days: 30, lastRun: now.addingTimeInterval(-3600), now: now))
            #expect(ThinningPreference.isDue(days: 30, lastRun: now.addingTimeInterval(-86_400), now: now))
            #expect(ThinningPreference.isDue(days: 30, lastRun: now.addingTimeInterval(86_400), now: now), "a run in the future does not block")
            #expect(ThinningPreference.choices.contains(0))
            let settings = MemoryKeyValueStore()
            #expect(ThinningPreference.days(in: settings) == 30)
            settings.set(-4, forKey: ThinningPreference.key)
            #expect(ThinningPreference.days(in: settings) == 0, "never")
            settings.set(100_000, forKey: ThinningPreference.key)
            #expect(ThinningPreference.days(in: settings) == 3650)
            #expect(ThinningProgress(done: 0, total: 0).fractionCompleted == 1)
            #expect(ThinningProgress(done: 3, total: 12, dryRun: false).fractionCompleted == 0.25)
        }

        /// The listing `unlock` starts ends in the core's automatic thinning (no host step): due once a day per vault, by
        /// the window in this device's settings, and never with "Never".
        @Test func theListingThinsOnceADayByTheDevicesWindow() async throws {
            let settings = MemoryKeyValueStore()
            let model = try await Self.unlockedModel(automaticThinning: true, settings: settings)
            defer { model.close() }
            try await model.notesLoaded()
            let key = ThinningPreference.lastRunKey(try #require(model.vault?.vaultId))
            let ran = try #require(settings.object(forKey: key) as? Date, "the listing ran it")
            await model.automaticThinningRun?.value
            // Due again only a day later.
            let run = model.automaticThinningRun
            model.thinIfDue(now: ran.addingTimeInterval(3600))
            #expect(settings.object(forKey: key) as? Date == ran)
            #expect(model.automaticThinningRun == run, "nothing started")
            // "Never" in this device's settings: nothing runs, whenever.
            settings.set(0, forKey: ThinningPreference.key)
            model.thinIfDue(now: ran.addingTimeInterval(400 * 86_400))
            #expect(settings.object(forKey: key) as? Date == ran)
        }

        /// Confirming a preview runs as of the preview's time (`ThinningReport.now`):
        /// autosaves written after the preview are not in the range, even with the
        /// zero cutoff of "Thin everything except checkpoints". Re-planning at the
        /// confirmation's time would delete the older of two newer autosaves of the
        /// same session, which the preview never listed.
        @Test func confirmingAPreviewKeepsWhatWasWrittenSince() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let editor = try #require(model.editor)
            // Three autosaves of one session: the first is the witness the fixture's other device needs
            // (format.md §5.8.4 rule 3) and the last is the session's end, so the second is thinned.
            for y in [220.0, 260, 300] { try await Self.draw(editor, y: y) }
            let preview = try await model.thinVault(rule: .allButCheckpoints, dryRun: true)
            #expect(preview.notes.first { $0.id == Self.lecture } != nil)
            let at = try #require(preview.now)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { Date() > at }, "the clock passes the preview's time before the later saves")
            for y in [340.0, 380] { try await Self.draw(editor, y: y) }
            let since = try vault.loadNote(Self.lecture).revisions.filter { $0.wall > at }.map(\.name)
            #expect(since.count >= 2)
            let current = try vault.reconstruct(noteId: Self.lecture)

            let done = try await model.thinVault(rule: .allButCheckpoints, dryRun: false, now: at)
            #expect(done.now == at)
            #expect(done.notes.first { $0.id == Self.lecture } != nil)
            let after = Set(try vault.revisionNames(of: Self.lecture))
            for name in since { #expect(after.contains(name), "written after the preview: \(name.filename)") }
            #expect(try vault.reconstruct(noteId: Self.lecture).pages.map(\.strokes.count) == current.pages.map(\.strokes.count))
        }

        @Test func automaticThinningSkipsOpenNotesAndIsOffInTests() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            #expect(!model.automaticThinning)
            let vault = try #require(model.vault)
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let editor = try #require(model.editor)
            try await Self.draw(editor, y: 300)
            try await Self.draw(editor, y: 340)
            let before = try vault.revisionNames(of: Self.lecture)
            let report = try await model.thinVault(days: 30, dryRun: false, skipOpen: true,
                                                   now: Date().addingTimeInterval(400 * 86_400))
            #expect(report.skipped[Self.lecture] == "open")
            #expect(try vault.revisionNames(of: Self.lecture) == before)
            #expect(try await model.thinVault(days: 0, dryRun: false).isEmpty, "never thins nothing")
        }

        /// Audit B36: a note opened while an automatic run is under way (after
        /// the run started) is left alone too.
        @Test func automaticThinningSkipsANoteOpenedDuringTheRun() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let vault = try #require(model.vault)
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let editor = try #require(model.editor)
            // Three autosaves of one session: the middle one is thinned (see `confirmingAPreviewKeepsWhatWasWrittenSince`).
            for y in [220.0, 260, 300] { try await Self.draw(editor, y: y) }
            try await model.openEditor(for: nil)
            let before = try vault.revisionNames(of: Self.lecture)
            // The run starts with no note open, then waits for the edit gate.
            await model.editGate.acquire()
            let run = Task {
                try await model.thinVault(days: 30, dryRun: false, skipOpen: true, now: Date().addingTimeInterval(400 * 86_400))
            }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.thinningProgress != nil })
            try await model.openEditor(for: Self.lecture)
            #expect(model.editor?.noteID == Self.lecture)
            model.editGate.release()
            let report = try await run.value
            #expect(report.skipped[Self.lecture] == "open")
            #expect(try vault.revisionNames(of: Self.lecture) == before)
        }

        /// A note being opened (read, before its editor is assigned) counts as
        /// open for the automatic run, which would otherwise delete revisions
        /// the editor is reading (bug audit follow-up).
        @Test func aNoteBeingOpenedCountsAsOpen() async throws {
            let gate = Gate()
            let model = try await Self.unlockedModel(afterIO: { await gate.pass() })
            defer { model.close() }
            model.selectedNoteID = Self.lecture
            let before = await gate.arrivals
            await gate.close()
            let opening = Task { try await model.openEditor(for: Self.lecture) }
            await gate.waitForArrivals(before + 1)
            #expect(model.editor == nil)
            #expect(model.isNoteOpen(Self.lecture), "being opened counts as open")
            await gate.open()
            try await opening.value
            #expect(model.isNoteOpen(Self.lecture))
            try await model.openEditor(for: nil)
            #expect(!model.isNoteOpen(Self.lecture))
        }
    }
}
