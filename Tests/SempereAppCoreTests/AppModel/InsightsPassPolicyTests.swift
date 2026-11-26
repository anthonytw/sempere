import Foundation
import Sempere
@testable import SempereAppCore
import SempereInsights
import TempDirSupport
import Testing

/// The pure rules of the foreground's Note Insights (`InsightsPassPolicy.swift`): the battery gate, the loop's pacing, and
/// how a "Process Now" pass keeps the screen on.
struct InsightsPassPolicyTests {
    typealias S = InsightsPowerState

    @Test func chargingKeepsItsOldBehavior() {
        #expect(InsightsPowerGate.allows(S(source: .external, batteryLevel: 0.05, thermal: .fair), onBattery: false))
        #expect(InsightsPowerGate.allows(S(source: .external), onBattery: true))
        #expect(!InsightsPowerGate.allows(S(source: .external, lowPowerMode: true), onBattery: true), "Low Power Mode, charging or not")
        #expect(!InsightsPowerGate.allows(S(source: .external, thermal: .serious), onBattery: true))
        #expect(!InsightsPowerGate.allows(S(source: .unknown, batteryLevel: 0.9), onBattery: true), "unknown is not power")
    }

    @Test func batteryNeedsChargeAndACoolDevice() {
        #expect(InsightsPowerGate.allows(S(source: .battery, batteryLevel: 0.30), onBattery: true))
        #expect(InsightsPowerGate.allows(S(source: .battery, batteryLevel: 0.8, thermal: .fair), onBattery: true))
        #expect(!InsightsPowerGate.allows(S(source: .battery, batteryLevel: 0.29), onBattery: true))
        #expect(!InsightsPowerGate.allows(S(source: .battery, batteryLevel: nil), onBattery: true), "no reading: not enough")
        #expect(!InsightsPowerGate.allows(S(source: .battery, batteryLevel: 0.9, lowPowerMode: true), onBattery: true))
        #expect(!InsightsPowerGate.allows(S(source: .battery, batteryLevel: 0.9, thermal: .serious), onBattery: true))
        #expect(!InsightsPowerGate.allows(S(source: .battery, batteryLevel: 0.9, thermal: .critical), onBattery: true))
        #expect(!InsightsPowerGate.allows(S(source: .battery, batteryLevel: 0.9), onBattery: false), "the opt-out")
    }

    @Test func theSettingIsOnUntilTurnedOff() {
        let defaults = MemoryKeyValueStore()
        #expect(InsightsOnBattery.isEnabled(defaults))
        defaults.set(false, forKey: InsightsOnBattery.key)
        #expect(!InsightsOnBattery.isEnabled(defaults))
    }

    @Test func theLoopWaitsThreeMinutesWhileItWorksAndBacksOffWhenIdle() {
        var pacing = InsightsLoopPacing()
        #expect(pacing.next(generated: 4) == .seconds(180))
        #expect(pacing.next(generated: 0) == .seconds(360))
        #expect(pacing.next(generated: 0) == .seconds(720))
        #expect(pacing.next(generated: 0) == .seconds(900), "never longer than the old 15 minutes")
        #expect(pacing.next(generated: 0) == .seconds(900))
        #expect(pacing.next(generated: 1) == .seconds(180), "work found: short again")
    }

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
    /// A model's foreground passes: the battery gate, the stop reasons, "Process Now" holding the screen on and picking
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
            var state: InsightsPowerState?
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
            if power.state != nil { services.insights.powerState = { power.state ?? InsightsPowerState(source: .unknown) } }
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
            #expect(model.insights.lastStop == .powerWindowClosed, "an automatic pass outside its window")
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

        @Test func theForegroundGateRunsOnBatteryUnlessTurnedOff() async throws {
            let power = Power()
            power.state = InsightsPowerState(source: .battery, batteryLevel: 0.6)
            let settings = MemoryKeyValueStore()
            let model = try await model(power: power, provider: FakeModelProvider(), settings: settings)
            defer { model.close() }
            #expect(model.insightsPowerWindow(), "on battery with enough charge: the default")
            let ran = await model.runInsightsPass(batch: 4, ignorePower: false)
            #expect(!ran.reports.isEmpty)
            settings.set(false, forKey: InsightsOnBattery.key)
            #expect(!model.insightsPowerWindow(), "opted out")
            power.state = InsightsPowerState(source: .battery, batteryLevel: 0.2)
            settings.set(true, forKey: InsightsOnBattery.key)
            #expect(!model.insightsPowerWindow(), "under 30%")
            power.state = InsightsPowerState(source: .external, batteryLevel: 0.2)
            settings.set(false, forKey: InsightsOnBattery.key)
            #expect(model.insightsPowerWindow(), "charging, whatever the setting says")
        }
    }
}
