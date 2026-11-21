import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereInsights
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Note Insights on the model's side (`AppModel+Insights`, Insights PR 2) with the package's fake providers: the
    /// offer, the switch (off deletes `insights/`), passes and their power
    /// window, the index the note panel reads (summary, keywords, related notes, clusters), titles through the model's
    /// clock, and a sync arrival of insights files reading them again.
    @MainActor
    struct InsightsModelTests {
        static let physics = [
            "The damping ratio decides whether a spring mass system oscillates. Critical damping returns fastest without oscillation. Resonance amplifies the amplitude.",
            "Damped oscillation of a spring and mass: the amplitude decays with the damping ratio. Resonance happens near the natural frequency.",
            "Forced oscillation of a spring mass system near resonance: the amplitude peaks when damping is small.",
        ]
        static let bread = [
            "Sourdough starter needs flour and water fed daily. Knead the dough and let it rise in a warm oven.",
            "Knead sourdough dough for ten minutes, proof it overnight, bake it in a hot oven with steam.",
            "Feed the starter with flour, wait for bubbles, then mix the dough and knead it well.",
        ]

        final class Power: @unchecked Sendable { var on = true }

        func model(power: Power = Power(), model provider: any ModelProvider = FakeModelProvider(), embedder: Bool = true) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless()
            services.insights = InsightsServices(model: { provider }, embedder: { embedder ? FakeEmbeddingProvider() : nil },
                                                 powerWindow: { power.on }, platform: .init(platform: "ios", os: "iOS 27.2"))
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), services: services)
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            #expect(await TS.waitUntil { model.insights.status != nil || model.insights.mode != .unset || model.listLoaded })
            return model
        }

        /// A note with recognized text, written two hours ago (insights wait until a note has settled, design §3.7).
        @discardableResult
        func note(_ model: AppModel, _ title: String, _ text: String, age: TimeInterval = 7200) async throws -> UUID {
            let id = UUID(), page = UUID()
            var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: nil, pageId: page)
            ops.append(.setPageRecognition(pageId: page, recognition: Recognition(engine: "test", text: text)))
            let built = ops
            try await model.commit(ids: [id], creating: [id]) { vault, clock, verifier in
                _ = try await NoteWriter.append(built, to: id, vault: vault, clock: clock, wall: Date().addingTimeInterval(-age),
                                                verify: verifier(id))
            }
            return id
        }

        func insightsFiles(_ model: AppModel) -> [String] {
            guard let url = model.vault?.insightsURL else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".insights.age") }
        }

        /// The foreground loop waits `insightsLoopInterval` (15 minutes) between looks without holding the model: a model
        /// let go with its vault still open goes away (with its scratch folder), as before 1.2. The 1.2.0 release sweep
        /// left a `SempereModel-…` folder in tmp for every app test that unlocked and never closed.
        @Test func anUnlockedModelLetGoIsReleasedWhileTheLoopWaits() async throws {
            weak var weakModel: AppModel?
            do {
                let model = try await model()
                #expect(await TS.waitUntil { model.insightsRuntime.loop != nil }, "the loop started")
                // Let the loop's first look run and reach its wait.
                for _ in 0..<20 { await Task.yield() }
                try await Task.sleep(for: .milliseconds(50))
                weakModel = model
            }
            #expect(await TS.waitUntil { weakModel == nil }, "nothing holds the model while the loop waits")
        }

        @Test func theOfferTheSwitchAPassAndThePanel() async throws {
            let model = try await model()
            #expect(model.insights.mode == .unset)
            #expect(model.insights.capability.generates)
            #expect(model.showsInsightsOffer, "a capable device, a writable vault, never set")
            var ids: [UUID] = []
            for (i, t) in (Self.physics + Self.bread).enumerated() { ids.append(try await note(model, "Note \(i)", t)) }
            await model.setInsightsEnabled(true)
            #expect(model.insights.mode == .on)
            #expect(model.insights.settings.enabled)
            #expect(!model.showsInsightsOffer)
            // The pass `setInsightsEnabled` started, or one of our own.
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !model.insights.isWorking && model.insightsRuntime.pass == nil })
            await model.runInsightsPass(batch: 10, ignorePower: true)
            let status = try #require(model.insights.status)
            #expect(status.processed >= ids.count)
            let panel = try #require(model.insightsPanel(for: ids[0]))
            #expect(panel.shown?.summary?.isEmpty == false)
            #expect(panel.shown?.keywords.isEmpty == false)
            #expect(!panel.missing && !panel.stale)
            let related = Set(panel.related.compactMap { UUID(uuidString: $0.note) })
            #expect(!related.isEmpty)
            #expect(related.isSubset(of: Set(ids[1...2])), "physics notes relate to physics notes, never the bread ones")
            #expect(!model.insightsClusters.isEmpty)
            #expect(!insightsFiles(model).isEmpty)
            // Search: keyword hits from the index, without the notes the page-text search found already.
            let keyword = try #require(panel.shown?.keywords.first?.t)
            #expect(!InsightsReader.search(keyword, shown: Array(model.insightsIndex.shown.values)).isEmpty)
            model.searchText = keyword
            #expect(await TS.waitUntil(timeout: .seconds(10)) { !model.isSearching })
            let found = Set(model.searchResults.map(\.note))
            #expect(model.insightsSearchHits.allSatisfy { UUID(uuidString: $0.note).map { !found.contains($0) } ?? false })
            model.searchText = ""
            // Off deletes every insights file here (and says so to the other devices through the explicit false), and
            // this device's memo of failed generations.
            let memo = try #require(model.insightsFailureMemoURL)
            try FileManager.default.createDirectory(at: memo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: memo)
            await model.setInsightsEnabled(false)
            #expect(model.insights.mode == .off)
            #expect(insightsFiles(model).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: memo.path))
            #expect(model.insightsPanel(for: ids[0]) == nil)
            #expect(!model.showsInsightsOffer, "never offered again after an explicit off")
        }

        @Test func passesWaitForThePowerWindow() async throws {
            let power = Power()
            power.on = false
            let model = try await model(power: power)
            try await note(model, "A", Self.physics[0])
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            let off = await model.runInsightsPass(batch: 4, ignorePower: false)
            #expect(off.reports.isEmpty, "not on power: nothing runs")
            #expect(off.remains, "work is left for the next power window")
            power.on = true
            #expect(!(await model.runInsightsPass(batch: 4, ignorePower: false)).reports.isEmpty)
        }

        /// A new voice note is processed at once with "Right away" (the owner's iPhone on battery made nothing until it
        /// charged), alone, without the settle time; "Only while plugged in" leaves it to the power window. A note's
        /// "Regenerate" makes its current insights again, also off power.
        @Test func aNewVoiceNoteRightAwayAndANotesRegenerateRunOffPower() async throws {
            let power = Power()
            power.on = false
            let model = try await model(power: power)
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            let fresh = try await note(model, "Just recorded", Self.physics[0], age: 0)
            let other = try await note(model, "Older", Self.bread[0])
            VoiceNoteInsightsTiming.whilePluggedIn.save(to: model.services.settings)
            model.insightsForNewVoiceNote(fresh)
            #expect(model.insightsRuntime.pass == nil && !model.noteInsightsPending(fresh), "left to the power window")
            VoiceNoteInsightsTiming.rightAway.save(to: model.services.settings)
            model.insightsForNewVoiceNote(fresh)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil && !model.noteInsightsPending(fresh) })
            #expect(model.insightsPanel(for: fresh)?.shown?.summary?.isEmpty == false, "made off power, inside the settle time")
            #expect(model.insightsPanel(for: other)?.missing != false, "only that note")
            let before = model.insights.lastReport
            model.regenerateNoteInsights(fresh)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil && !model.noteInsightsPending(fresh) })
            #expect(model.insights.lastReport != before)
            #expect(model.insights.lastReport?.generated == [fresh.uuidString.lowercased()], "made again although current")
        }

        /// One slot, one pass (review of #63): cancelling the running pass leaves the slot empty, without starting the
        /// queued note's pass behind the canceller's back, and the queued Regenerate is still done afterwards.
        @Test func cancellingThePassDoesNotStartAQueuedNotesPass() async throws {
            let power = Power()
            power.on = false
            let model = try await model(power: power)
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            for (i, t) in Self.physics.enumerated() { try await note(model, "P\(i)", t) }
            let target = try await note(model, "Target", Self.bread[0])
            model.requestInsightsPass(force: true)
            #expect(model.insightsRuntime.pass != nil)
            model.regenerateNoteInsights(target)
            #expect(model.noteInsightsPending(target), "queued behind the running pass")
            await model.cancelInsightsPass()
            #expect(model.insightsRuntime.pass == nil, "nothing started behind the canceller")
            #expect(model.noteInsightsPending(target), "the Regenerate is still owed")
            model.startDueNoteInsights()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil && !model.noteInsightsPending(target) })
            #expect(model.insightsPanel(for: target)?.shown?.summary?.isEmpty == false)
        }

        /// Every device with the model makes summaries (the owner's iPhone: "Process Now" did nothing, "0 of 10"); one without
        /// the embedder makes no vectors or map (D21: any device that has it does, nobody is designated).
        @Test func aDeviceWithoutTheEmbedderGeneratesButNeverMaps() async throws {
            let power = Power()
            power.on = false   // no automatic pass
            let model = try await model(power: power, embedder: false)
            try await note(model, "A", Self.physics[0])
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            #expect(model.insightsHasRole, "it can make summaries")
            let pass = await model.runInsightsPass(batch: 4, ignorePower: true, forced: true)
            #expect(pass.reports.contains { !$0.generated.isEmpty })
            #expect(pass.reports.allSatisfy { $0.embedded.isEmpty && !$0.mapBuilt })
            #expect(model.insights.status?.processed == 1)
        }

        /// A model whose availability the test changes (Apple Intelligence turned on after the unlock).
        final class Switchable: ModelProvider, @unchecked Sendable {
            let inner = FakeModelProvider()
            var available: ModelAvailability
            init(_ a: ModelAvailability) { available = a }
            var identity: GenerationIdentity { inner.identity }
            var availability: ModelAvailability { available }
            var contextTokens: Int { 8192 }
            func supports(language: String?) -> Bool { true }
            func extract(_ text: String, language: String?) async throws -> ModelExtraction {
                guard available.isAvailable else { throw InsightsProviderError.unavailable(available) }
                return try await inner.extract(text, language: language)
            }
            func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { try await inner.merge(parts, language: language) }
            func summarize(topic: String, summaries: [String], language: String?) async throws -> String {
                try await inner.summarize(topic: topic, summaries: summaries, language: language)
            }
            func title(transcript: String, language: String?) async throws -> String { try await inner.title(transcript: transcript, language: language) }
        }

        @Test func whoHasARole() async throws {
            let power = Power()
            power.on = false
            let provider = Switchable(.disabled)
            let model = try await model(power: power, model: provider)
            #expect(!model.insightsHasRole, "off")
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            // Embeds only: any device that embeds has work (D21), with no role to claim.
            #expect(!model.insights.capability.generates)
            #expect(model.insights.capability.canWork)
            #expect(model.insightsHasRole, "it embeds")
            // Apple Intelligence turned on since the unlock: read again, it makes summaries too.
            provider.available = .available
            #expect(!model.insights.capability.generates, "read at unlock")
            model.refreshInsightsCapability()
            #expect(model.insights.capability.generates)
            #expect(model.insightsHasRole)
        }

        /// "Process Now" never ends silently: no settle time, no earlier back-off, open notes still wait, and a pass that
        /// makes nothing says why (`passOutcome`).
        @Test func processNowSkipsTheSettleTimeAndTheBackOffAndSaysWhy() async throws {
            let power = Power()
            power.on = false
            let model = try await model(power: power, embedder: false)
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            let fresh = try await note(model, "Fresh", Self.physics[0], age: 30)
            let failed = try await note(model, "Failed", Self.bread[0])
            #expect(await TS.waitUntil { [fresh, failed].allSatisfy { id in model.notes.contains { $0.id == id } } })
            // A failure remembered from an earlier pass.
            let vault = try #require(model.vault)
            let memoURL = try #require(model.insightsFailureMemoURL)
            let input = try #require(InsightsNotes.inputs(vault, summaries: model.insightsSummaries).first { $0.id == failed })
            var memo = InsightsFailureMemo()
            memo.record(note: failed, hash: input.hash, identity: FakeModelProvider().identity,
                        error: InsightsProviderError.failed("the model said no"), now: Date().addingTimeInterval(-60))
            try memo.save(to: memoURL, vault: vault)
            // A pass of the loop: both wait, and it says so.
            let plain = await model.runInsightsPass(batch: 4, ignorePower: true)
            #expect(plain.reports.allSatisfy { $0.generated.isEmpty })
            #expect(model.insights.passOutcome == .backedOff(count: 1, reason: "the model failed: the model said no"))
            // Process Now: both are made.
            let forced = await model.runInsightsPass(batch: 4, ignorePower: true, forced: true)
            #expect(Set(forced.reports.flatMap(\.generated)) == Set([fresh, failed].map { $0.uuidString.lowercased() }))
            #expect(model.insights.passOutcome == nil, "it made something")
            // Nothing left: it says so instead of ending silently.
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil && model.insights.passOutcome != nil })
            #expect(model.insights.passOutcome == .nothingToDo)
            // A pass that runs nothing (off power) clears it.
            _ = await model.runInsightsPass(batch: 4, ignorePower: false)
            #expect(model.insights.passOutcome == nil)
        }

        @Test func processNowOnADeviceThatCannotSummarizeSaysSo() async throws {
            let power = Power()
            power.on = false
            let model = try await model(power: power, model: Switchable(.disabled))
            try await note(model, "A", Self.physics[0])
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            let pass = await model.runInsightsPass(batch: 4, ignorePower: true, forced: true)
            #expect(!pass.reports.isEmpty)
            #expect(pass.reports.contains { !$0.embedded.isEmpty }, "it still embeds")
            #expect(model.insights.passOutcome == .modelUnavailable(.disabled))
        }

        /// A topic's "Regenerate" holds the slot: Settings shows it busy, so "Process Now" is not pressed for nothing.
        @Test func aRegenerationMakesTheSlotBusy() async throws {
            let model = try await model()
            #expect(!model.insightsBusy)
            model.insights.regeneratingTopics.insert("tag:x")
            #expect(model.insightsBusy)
        }

        @Test func theTitleFormatIsValidated() async throws {
            let model = try await model()
            await model.setInsightsEnabled(true)
            #expect(await model.setInsightsVoiceNoteTitle("{date} {slug}"))
            #expect(model.insights.settings.voiceNoteTitle == "{date} {slug}")
            #expect(!(await model.setInsightsVoiceNoteTitle("{weekday}")), "an unknown token is refused")
            #expect(model.insights.settings.voiceNoteTitle == "{date} {slug}")
            #expect(await model.setInsightsVoiceNoteTitle(nil))
            #expect(model.insights.settings.voiceNoteTitle == VoiceNoteTitleFormat.defaultFormat)
        }

        /// Turning off stops a running pass and waits for it before the purge, so no sidecar is written after it.
        @Test func offWaitsForTheRunningPass() async throws {
            let model = try await model()
            for (i, t) in Self.physics.enumerated() { try await note(model, "N\(i)", t) }
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            model.requestInsightsPass(force: true)
            await model.setInsightsEnabled(false)
            #expect(model.insightsRuntime.pass == nil)
            #expect(insightsFiles(model).isEmpty)
        }

        /// Reads run one at a time; concurrent requests share the read after the running one.
        @Test func refreshesRunOneAtATime() async throws {
            let model = try await model()
            await model.setInsightsEnabled(true)
            // Since D21 every capable device has a role, so turning Insights on starts a pass, which schedules
            // refreshes of its own: let it end first, or one of those can be running when `refreshing` is read.
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            let before = model.insightsRuntime.refreshDone
            async let a: Void = model.refreshInsights()
            async let b: Void = model.refreshInsights()
            async let c: Void = model.refreshInsights()
            _ = await (a, b, c)
            #expect(model.insightsRuntime.refreshDone >= before + 3, "every request answered")
            // A refresh the pass scheduled may still start after ours; the slot always empties again.
            #expect(await TS.waitUntil(timeout: .seconds(10)) { model.insightsRuntime.refreshing == nil })
        }

        /// The background task: the pass is in the model's one slot (so closing the vault cancels it), and work left
        /// when it is cancelled is reported, so the task is asked for again.
        @Test func theBackgroundPassIsTheModelsAndReportsWorkLeft() async throws {
            let model = try await model()
            for (i, t) in Self.physics.enumerated() { try await note(model, "N\(i)", t) }
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            let bg = Task { await model.runInsightsInBackground() }
            #expect(await TS.waitUntil(timeout: .seconds(10)) { model.insightsRuntime.pass != nil || model.insights.lastPass != nil })
            bg.cancel()
            _ = await bg.value
            #expect(model.insightsRuntime.pass == nil)
        }

        /// A run that placed or deleted insights files reads them again (PR 1 notes, item 12).
        @Test func arrivedInsightsFilesAreReadAgain() async throws {
            let model = try await model()
            await model.setInsightsEnabled(true)
            let before = model.insightsRuntime.filesRevision
            var changes = LocalChanges()
            changes.insights = true
            model.applySyncChanges(changes)
            #expect(model.insightsRuntime.filesRevision == before + 1)
        }

        /// Insights' own reads (at unlock, after arrivals) never pass through the model's `afterIO` seam, which orders the
        /// model's vault I/O: an unlock's read counted as an edit's write on CI (#52, BrowserEditorTests).
        @Test func insightsReadsDoNotPassTheModelsIOSeam() async throws {
            let counter = IOCounter()
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless()
            services.insights = InsightsServices(model: { FakeModelProvider() }, embedder: { FakeEmbeddingProvider() },
                                                 powerWindow: { false })
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: services, afterIO: { await counter.add() })
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            await model.insightsRuntime.start?.value
            let settled = await counter.count
            await model.refreshInsights()
            model.insightsFilesChanged()
            await model.refreshInsights()
            #expect(await counter.count == settled)
        }

        actor IOCounter {
            private(set) var count = 0
            func add() { count += 1 }
        }

        /// A note in a notebook, written two hours ago.
        @discardableResult
        func note(_ model: AppModel, _ title: String, _ text: String, notebook: String) async throws -> UUID {
            let id = UUID(), page = UUID()
            var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: notebook, pageId: page)
            ops.append(.setPageRecognition(pageId: page, recognition: Recognition(engine: "test", text: text)))
            let built = ops
            try await model.commit(ids: [id], creating: [id]) { vault, clock, verifier in
                _ = try await NoteWriter.append(built, to: id, vault: vault, clock: clock, wall: Date().addingTimeInterval(-7200),
                                                verify: verifier(id))
            }
            return id
        }

        /// Insights PR 3: passes make topic summaries (design §6 item 4), the index shows them by notebook (only with 3
        /// summarized notes), "Regenerate" runs one now, and the map's layout is in the index.
        @Test func topicSummariesAndTheMapInTheIndex() async throws {
            let power = Power()
            power.on = false   // only our own passes
            let model = try await model(power: power)
            for (i, t) in Self.bread.enumerated() { try await note(model, "Bread \(i)", t, notebook: "Kitchen") }
            try await note(model, "Physics", Self.physics[0], notebook: "Lab")
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            let pass = await model.runInsightsPass(batch: 10, ignorePower: true)
            #expect(pass.reports.contains { $0.topics.contains("notebook:Kitchen") }, "passes make topic summaries now")
            let kitchen = try #require(model.insightsTopic(notebook: "Kitchen"))
            #expect(kitchen.members.count == 3)
            #expect(kitchen.summary?.isEmpty == false)
            #expect(!kitchen.stale)
            #expect(model.insightsTopic(notebook: " Kitchen ") != nil, "notebook paths are compared canonically")
            #expect(model.insightsTopic(notebook: "Lab") == nil, "one summarized note: no Summary offered")
            #expect(model.insightsTopics.map(\.scope) == [kitchen.scope])
            #expect(model.canRegenerateInsightsTopics)
            let before = kitchen.at
            try await Task.sleep(for: .milliseconds(5))
            await model.regenerateInsightsTopic(kitchen.scope)
            #expect(model.insights.regeneratingTopics.isEmpty)
            #expect(model.insights.topicProblems.isEmpty)
            let again = try #require(model.insightsTopic(notebook: "Kitchen"))
            #expect(again.at.map { a in before.map { a > $0 } ?? true } == true, "made again now")
            // The map: every note with a vector, in the unit square.
            let map = model.insightsMap
            #expect(map.nodes.count == 4)
            #expect(map.nodes.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
            await model.setInsightsEnabled(false)
            #expect(model.insightsTopic(notebook: "Kitchen") == nil)
            #expect(model.insightsMap.isEmpty)
        }

        /// A model whose topic summaries wait for `release` (notes are made as by the fake); `honorsCancellation` false
        /// keeps waiting through a cancellation, as a model call that does not stop at once.
        final class GatedTopics: ModelProvider, @unchecked Sendable {
            let inner = FakeModelProvider()
            let lock = NSLock()
            var gated = false
            var entered = false
            var released = false
            let honorsCancellation: Bool
            init(honorsCancellation: Bool) { self.honorsCancellation = honorsCancellation }
            func set(_ body: (GatedTopics) -> Void) { lock.lock(); body(self); lock.unlock() }
            func get<T>(_ body: (GatedTopics) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
            var identity: GenerationIdentity { inner.identity }
            var availability: ModelAvailability { .available }
            var contextTokens: Int { 8192 }
            func supports(language: String?) -> Bool { true }
            func extract(_ text: String, language: String?) async throws -> ModelExtraction { try await inner.extract(text, language: language) }
            func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { try await inner.merge(parts, language: language) }
            func title(transcript: String, language: String?) async throws -> String { try await inner.title(transcript: transcript, language: language) }
            func summarize(topic: String, summaries: [String], language: String?) async throws -> String {
                if get({ $0.gated }) {
                    set { $0.entered = true }
                    while !get({ $0.released }) {
                        if honorsCancellation { try await Task.sleep(for: .milliseconds(5)) } else { try? await Task.sleep(for: .milliseconds(5)) }
                    }
                }
                return try await inner.summarize(topic: topic, summaries: summaries, language: language)
            }
        }

        func ownTopicsFile(_ model: AppModel) -> URL? {
            guard let vault = model.vault, let me = vault.writerDevice else { return nil }
            return vault.insightsURL.appendingPathComponent(InsightsFileName(.topics, device: me).fileName)
        }

        /// Review of #54, M1: "Regenerate" runs in the insights slot, so turning Note Insights off (or closing the vault)
        /// cancels it and waits for it, and nothing is written after the purge, also when the model call does not stop
        /// at the cancellation.
        @Test(arguments: [true, false])
        func regenerateIsCancelledByTurningOffAndWritesNothingAfter(_ honorsCancellation: Bool) async throws {
            let power = Power()
            power.on = false
            let gated = GatedTopics(honorsCancellation: honorsCancellation)
            let model = try await model(power: power, model: gated)
            for (i, t) in Self.bread.enumerated() { try await note(model, "Bread \(i)", t, notebook: "Kitchen") }
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            await model.runInsightsPass(batch: 10, ignorePower: true)
            let scope = try #require(model.insightsTopic(notebook: "Kitchen")?.scope)
            let file = try #require(ownTopicsFile(model))
            try FileManager.default.removeItem(at: file)   // so any later write would show
            gated.set { $0.gated = true }
            let regen = Task { await model.regenerateInsightsTopic(scope) }
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            #expect(model.insightsRuntime.pass != nil && model.insightsRuntime.slotIsRegeneration, "it holds the insights slot")
            let off = Task { await model.setInsightsEnabled(false) }
            if !honorsCancellation {
                // The turn-off waits for the model call to come back.
                try await Task.sleep(for: .milliseconds(50))
                #expect(model.insights.mode == .on, "not purged while the regeneration still runs")
                gated.set { $0.released = true }
            }
            await off.value
            await regen.value
            gated.set { $0.released = true }
            try await Task.sleep(for: .milliseconds(50))
            #expect(model.insights.mode == .off)
            #expect(!FileManager.default.fileExists(atPath: file.path), "nothing written after the purge")
            #expect(insightsFiles(model).isEmpty)
            #expect(model.insightsRuntime.pass == nil)
        }

        /// Closing the vault cancels a running regeneration (the slot's task), which then writes nothing.
        @Test func closingCancelsARegeneration() async throws {
            let power = Power()
            power.on = false
            let gated = GatedTopics(honorsCancellation: true)
            let model = try await model(power: power, model: gated)
            for (i, t) in Self.bread.enumerated() { try await note(model, "Bread \(i)", t, notebook: "Kitchen") }
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            await model.runInsightsPass(batch: 10, ignorePower: true)
            let scope = try #require(model.insightsTopic(notebook: "Kitchen")?.scope)
            let file = try #require(ownTopicsFile(model))
            try FileManager.default.removeItem(at: file)
            gated.set { $0.gated = true }
            let regen = Task { await model.regenerateInsightsTopic(scope) }
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            let slot = try #require(model.insightsRuntime.pass)
            model.stopInsights()
            _ = await slot.value
            await regen.value
            gated.set { $0.released = true }
            #expect(!FileManager.default.fileExists(atPath: file.path), "a cancelled regeneration writes nothing")
        }

        /// A second Regenerate waits for the first instead of stopping it; a pass in the slot is stopped first.
        @Test func regenerationsQueueInTheSlot() async throws {
            let power = Power()
            power.on = false
            let gated = GatedTopics(honorsCancellation: true)
            let model = try await model(power: power, model: gated)
            for (i, t) in Self.bread.enumerated() { try await note(model, "Bread \(i)", t, notebook: "Kitchen") }
            for (i, t) in Self.physics.enumerated() { try await note(model, "Physics \(i)", t, notebook: "Lab") }
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            await model.runInsightsPass(batch: 10, ignorePower: true)
            let kitchen = try #require(model.insightsTopic(notebook: "Kitchen")?.scope)
            let lab = try #require(model.insightsTopic(notebook: "Lab")?.scope)
            let before = try #require(model.insightsTopic(notebook: "Kitchen")?.at)
            try await Task.sleep(for: .milliseconds(5))
            gated.set { $0.gated = true }
            let first = Task { await model.regenerateInsightsTopic(kitchen) }
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            let second = Task { await model.regenerateInsightsTopic(lab) }
            try await Task.sleep(for: .milliseconds(30))
            #expect(model.insights.regeneratingTopics == [TopicScopes.name(kitchen), TopicScopes.name(lab)])
            gated.set { $0.released = true }
            await first.value
            await second.value
            #expect(model.insights.topicProblems.isEmpty, "the first was not cancelled by the second")
            #expect(try #require(model.insightsTopic(notebook: "Kitchen")?.at) > before)
        }

        @Test func theToolbarOffersInsightsOnlyWhenOn() {
            var state = NoteToolbar.State(device: .pad)
            #expect(!NoteToolbar.items(.overflow, in: state).contains(.insights))
            state.insights = true
            #expect(NoteToolbar.items(.overflow, in: state).contains(.insights))
            state.readOnly = true
            #expect(NoteToolbar.items(.overflow, in: state).contains(.insights), "read-only notes still show their insights")
        }
    }
}
