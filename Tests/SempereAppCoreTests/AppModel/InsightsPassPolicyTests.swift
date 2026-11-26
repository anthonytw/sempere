import Foundation
import Sempere
@testable import SempereAppCore
import SempereInsights
import TempDirSupport
import Testing

/// How a "Process Now" pass keeps the screen on (`KeepScreenOn`, `IdleTimerKeeper`).
struct InsightsPassPolicyTests {
    @Test func theScreenStaysOnForAForcedPassOnItsOwnAndCombinesWithTheToggle() {
        func off(_ enabled: Bool, _ open: Bool, _ active: Bool, _ processing: Bool) -> Bool {
            KeepScreenOn.idleTimerDisabled(enabled: enabled, noteOpen: open, active: active, processing: processing)
        }
        #expect(off(false, false, true, true), "Process Now alone, no toggle, no note")
        #expect(off(true, true, true, true))
        #expect(off(true, true, true, false), "the toggle alone, as before")
        #expect(!off(true, false, true, false))
        #expect(!off(false, false, true, false))
        #expect(!off(false, false, false, true), "the app left the screen: the timer is back on whatever works")
        #expect(!off(true, true, false, true))
    }

    @MainActor
    @Test func theKeeperAppliesTheOrAndRestoresIt() {
        final class Box { var processing = false; var noteOpen = false }
        let box = Box()
        let platform = HeadlessPlatform()
        let lifecycle = ManualAppLifecycle()
        let settings = MemoryKeyValueStore([KeepScreenOn.key: true])
        let keeper = IdleTimerKeeper(settings: settings, platform: platform, lifecycle: lifecycle,
                                     processing: { box.processing }, noteOpen: { box.noteOpen })
        keeper.start()
        defer { keeper.stop() }
        #expect(platform.idleTimerDisabled == false)
        box.processing = true; keeper.update()
        #expect(platform.idleTimerDisabled == true, "a pass holds the screen with no note open")
        box.noteOpen = true; keeper.update()
        box.processing = false; keeper.update()
        #expect(platform.idleTimerDisabled == true, "the toggle with a note open still holds it when the pass ends")
        box.noteOpen = false; keeper.update()
        #expect(platform.idleTimerDisabled == false, "no reason left")
        box.processing = true; keeper.update()
        lifecycle.send(.didEnterBackground)
        #expect(platform.idleTimerDisabled == false, "the app left the screen during a pass")
        lifecycle.send(.didBecomeActive)
        #expect(platform.idleTimerDisabled == true, "and it holds again when it returns while the pass works")
    }
}

extension AppModelSuites {
    /// A model's foreground passes: the stop reasons, "Process Now" holding the screen on and picking
    /// up again after the app left the screen.
    @MainActor
    struct InsightsPassPolicyModelTests {
        let helper = InsightsModelTests()

        /// A model whose summaries wait for `release` (honoring cancellation); notes are made as by the fake.
        final class GatedExtract: ModelProvider, @unchecked Sendable {
            let inner: FakeModelProvider
            let lock = NSLock()
            var gated = false
            var entered = false
            var released = false
            init(_ script: FakeModelProvider.Script = .init()) { inner = FakeModelProvider(script) }
            func set(_ body: (GatedExtract) -> Void) { lock.lock(); body(self); lock.unlock() }
            func get<T>(_ body: (GatedExtract) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
            var identity: GenerationIdentity { inner.identity }
            var availability: ModelAvailability { inner.availability }
            var contextTokens: Int { 8192 }
            func supports(language: String?) -> Bool { true }
            func extract(_ text: String, language: String?) async throws -> ModelExtraction {
                if get({ $0.gated }) {
                    set { $0.entered = true }
                    while !get({ $0.released }) { try await Task.sleep(for: .milliseconds(5)) }
                }
                return try await inner.extract(text, language: language)
            }
            func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { try await inner.merge(parts, language: language) }
            func title(transcript: String, language: String?) async throws -> String { try await inner.title(transcript: transcript, language: language) }
            func summarize(topic: String, summaries: [String], language: String?) async throws -> String {
                try await inner.summarize(topic: topic, summaries: summaries, language: language)
            }
        }

        final class Power: @unchecked Sendable {
            var on = false
        }

        func model(power: Power = Power(), provider: any ModelProvider, platform: HeadlessPlatform = HeadlessPlatform(),
                   lifecycle: ManualAppLifecycle = ManualAppLifecycle(), settings: MemoryKeyValueStore = MemoryKeyValueStore(),
                   notes: Int = 3) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless(settings: settings)
            services.platform = platform
            services.lifecycle = lifecycle
            services.insights = InsightsServices(model: { provider }, embedder: { FakeEmbeddingProvider() }, powerWindow: { power.on },
                                                 platform: .init(platform: "ios", os: "iOS 27.2"))
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), services: services)
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            #expect(await TS.waitUntil { model.insights.status != nil || model.insights.mode != .unset || model.listLoaded })
            for (i, t) in InsightsModelTests.physics.prefix(notes).enumerated() { try await helper.note(model, "N\(i)", t) }
            await model.setInsightsEnabled(true)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
            return model
        }

        @Test func aPassSaysWhyItStopped() async throws {
            let power = Power()
            let model = try await model(power: power, provider: FakeModelProvider())
            _ = await model.runInsightsPass(batch: 4, ignorePower: false)
            #expect(model.insights.lastStop == nil, "an automatic pass outside its window ran no batch: nothing stopped")
            _ = await model.runInsightsPass(batch: 4, ignorePower: true)
            #expect(model.insights.lastStop == .finished)
            var script = FakeModelProvider.Script()
            script.availability = .disabled
            let off = try await self.model(provider: FakeModelProvider(script))
            _ = await off.runInsightsPass(batch: 4, ignorePower: true, forced: true)
            #expect(off.insights.lastStop == .modelUnavailable)
        }

        @Test func anotherTaskTakingTheSlotIsSaid() async throws {
            let gated = GatedExtract()
            let model = try await model(provider: gated)
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            await model.cancelInsightsPass()
            #expect(model.insights.lastStop == .superseded)
            #expect(!model.insights.isProcessingNow)
        }

        @Test func processNowKeepsTheScreenOnAndPicksUpAfterTheAppReturns() async throws {
            let gated = GatedExtract()
            let platform = HeadlessPlatform()
            let lifecycle = ManualAppLifecycle()
            let model = try await model(provider: gated, platform: platform, lifecycle: lifecycle)
            defer { model.close(); model.idleTimer?.stop() }
            model.keepScreenOn(lifecycle: lifecycle)
            #expect(platform.idleTimerDisabled == false, "nothing holds the screen")
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            #expect(model.insights.isProcessingNow)
            #expect(platform.idleTimerDisabled == true, "held for the pass, with no note open and the toggle off")

            // The phone locks: the app is backgrounded, the pass is cut off, the screen is the system's again.
            lifecycle.send(.didEnterBackground)
            model.enterBackground()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { model.insightsRuntime.pass == nil })
            #expect(model.insights.lastStop == .backgrounded(resumes: true))
            #expect(!model.insights.isProcessingNow)
            #expect(platform.idleTimerDisabled == false)
            #expect(model.insightsRuntime.resumeForced)

            // Back on screen: it continues by itself, holds the screen again and ends.
            gated.set { $0.released = true }
            lifecycle.send(.didBecomeActive)
            model.enterForeground()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insights.lastStop == .finished && !model.insights.isProcessingNow })
            #expect(!model.insightsRuntime.resumeForced)
            #expect(platform.idleTimerSettings == [false, true, false, true, false], "held, let go, held again, let go")
            #expect(!helper.insightsFiles(model).isEmpty, "the resumed pass made the insights")
        }

        @Test func anAutomaticPassCutOffByTheBackgroundDoesNotResume() async throws {
            let gated = GatedExtract()
            let lifecycle = ManualAppLifecycle()
            let model = try await model(provider: gated, lifecycle: lifecycle)
            defer { model.close() }
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: false)   // outside the window: nothing runs; use the slot directly
            await model.cancelInsightsPass()
            let task = model.startInsightsPass(batch: 4, ignorePower: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            lifecycle.send(.didEnterBackground)
            model.enterBackground()
            _ = await task.value
            #expect(model.insights.lastStop == .backgrounded(resumes: false))
            #expect(!model.insightsRuntime.resumeForced)
        }

        /// Review of batch/120 fix 1: a lock cancels without waiting, so an old "Process Now" pass ends after a newer one began;
        /// its cleanup must not clear the newer pass's flags.
        @Test func anOldPassEndingDoesNotClearANewerProcessNow() async throws {
            let gated = GatedExtract()
            let platform = HeadlessPlatform()
            let lifecycle = ManualAppLifecycle()
            let model = try await model(provider: gated, platform: platform, lifecycle: lifecycle)
            defer { model.close(); model.idleTimer?.stop() }
            model.keepScreenOn(lifecycle: lifecycle)
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            // A lock and an unlock, then Process Now again (what the new pass sets up), while the old pass still ends.
            let old = try #require(model.insightsRuntime.pass)
            model.close()
            model.insights.isProcessingNow = true
            model.insightsRuntime.passIsForced = true
            gated.set { $0.released = true }
            _ = await old.value
            #expect(model.insights.isProcessingNow, "the newer pass still holds the screen")
            #expect(model.insightsRuntime.passIsForced, "and still resumes after the background")
        }

        /// Fix 3: the background task's expiry cancels without a reason; the app is in the background, so that is the reason.
        @Test func theBackgroundTasksExpiryIsSaidAsBackgrounded() async throws {
            let gated = GatedExtract()
            let lifecycle = ManualAppLifecycle()
            let model = try await model(provider: gated, lifecycle: lifecycle)
            defer { model.close() }
            gated.set { $0.gated = true }
            lifecycle.send(.didEnterBackground)
            let task = Task { await model.runInsightsInBackground() }
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            task.cancel()
            _ = await task.value
            #expect(await TS.waitUntil(timeout: .seconds(10)) { model.insightsRuntime.pass == nil })
            #expect(model.insights.lastStop == .backgrounded(resumes: false))
        }

        /// Fix 3: the background task's own cancel never overwrites the reason a Process Now pass still ending already has.
        @Test func aReasonAlreadySetIsNotOverwritten() async throws {
            let gated = GatedExtract()
            let lifecycle = ManualAppLifecycle()
            let model = try await model(provider: gated, lifecycle: lifecycle)
            defer { model.close() }
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            lifecycle.send(.didEnterBackground)
            model.enterBackground()
            await model.cancelInsightsPass(reason: .backgrounded(resumes: false))
            #expect(model.insights.lastStop == .backgrounded(resumes: true))
        }

        /// Fix 4: Regenerate stops a Process Now pass; it is asked again as forced, in a closed power window too.
        @Test func regenerateGivesProcessNowBack() async throws {
            let gated = GatedExtract()
            let platform = HeadlessPlatform()
            let lifecycle = ManualAppLifecycle()
            let model = try await model(provider: gated, platform: platform, lifecycle: lifecycle)   // power window closed
            defer { model.close(); model.idleTimer?.stop() }
            model.keepScreenOn(lifecycle: lifecycle)
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            await model.regenerateInsightsTopic(.init(tag: "none"))
            #expect(model.insightsRuntime.pass != nil, "Process Now goes on")
            #expect(await TS.waitUntil(timeout: .seconds(10)) { model.insights.isProcessingNow }, "asked again as forced")
            #expect(platform.idleTimerDisabled == true, "with the screen held")
            gated.set { $0.released = true }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insightsRuntime.pass == nil })
        }

        /// Item 11: a Process Now pass counts the notes to process first, and the count advances with each run, never past the total.
        @Test func processNowCountsItsNotesAndTheCountStaysWithinTheTotal() async throws {
            let gated = GatedExtract()
            let model = try await model(provider: gated, notes: 3)
            defer { model.close() }
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            let progress = try #require(model.insights.progress, "counted at the start")
            #expect(progress.total == 3 && progress.done == 0)
            gated.set { $0.released = true }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insights.lastStop == .finished && !model.insights.isProcessingNow })
            #expect(model.insights.progress == nil, "gone with the pass")
        }

        /// Fix 2: the process activity follows the pass, not the scene: it stays while the app is inactive and ends with the pass.
        @Test func theProcessActivityHoldsWhileInactiveAndEndsWithThePass() async throws {
            let gated = GatedExtract()
            let platform = HeadlessPlatform(isMac: true)
            let lifecycle = ManualAppLifecycle()
            let model = try await model(provider: gated, platform: platform, lifecycle: lifecycle)
            defer { model.close(); model.idleTimer?.stop() }
            model.keepScreenOn(lifecycle: lifecycle)
            gated.set { $0.gated = true }
            model.requestInsightsPass(force: true)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { gated.get { $0.entered } })
            #expect(platform.processActivitySettings.last == true)
            lifecycle.send(.willResignActive)   // Catalyst: every app switch
            #expect(platform.processActivitySettings.last == true, "another app has the focus: the pass goes on")
            gated.set { $0.released = true }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.insights.lastStop == .finished && !model.insights.isProcessingNow })
            #expect(platform.processActivitySettings.last == false)
        }
    }
}
