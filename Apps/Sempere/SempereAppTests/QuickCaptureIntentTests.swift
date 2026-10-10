import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Gap audit GA-56: what the quick voice note intents do with the app's hooks
/// (`VoiceNoteActions`), how long the result is shown, and when the banner goes.
///
/// Not covered here, because it needs a device or the widget extension:
/// - the widget, control and Live Activity views (`SempereWidgets.swift`) live in
///   the extension target, which the app's test bundle does not link;
/// - ActivityKit itself (`Activity.request` / `update` / `end(… dismissalPolicy:)`)
///   in `QuickCapture.startActivity` / `endActivity`: the simulator has no Live
///   Activities. What is checked is the value passed as the dismissal delay
///   (`VoiceNoteResult.shownFor`, 5 s saved, 12 s failed);
/// - `VoiceNoteControlIntent`'s "open" branch (`continueInForeground` only works
///   while the system runs the intent);
/// - `QuickCapture.register()`, which sets process-wide state on the shared instance
///   (Keychain store, endless activity-enablement observer).
@Suite(.serialized)
@MainActor
struct QuickCaptureIntentTests {
    /// What the hooks were asked to do.
    @MainActor
    final class Calls {
        var started = 0
        var stopped = 0
        var opened: [VoiceNoteLink] = []
        var live = VoiceNoteStatus(phase: .ready)

        func install() {
            VoiceNoteActions.start = { [self] in started += 1 }
            VoiceNoteActions.stop = { [self] in stopped += 1 }
            VoiceNoteActions.open = { [self] in opened.append($0) }
            VoiceNoteActions.status = { [self] in live }
        }
    }

    static func reset() {
        VoiceNoteActions.start = nil
        VoiceNoteActions.stop = nil
        VoiceNoteActions.open = nil
        VoiceNoteActions.status = nil
    }

    @Test func intentsDoNothingUntilTheAppHasRegisteredItsHooks() async throws {
        Self.reset()
        await #expect(throws: VoiceNoteIntentError.self) { _ = try await StartVoiceNoteIntent().perform() }
        await #expect(throws: VoiceNoteIntentError.self) { _ = try await StopVoiceNoteIntent().perform() }
        await #expect(throws: VoiceNoteIntentError.self) { _ = try await VoiceNoteControlIntent(shown: .ready).perform() }

        // The control needs all of status, start and stop.
        let calls = Calls()
        calls.install()
        defer { Self.reset() }
        VoiceNoteActions.status = nil
        await #expect(throws: VoiceNoteIntentError.self) { _ = try await VoiceNoteControlIntent(shown: .ready).perform() }
        #expect(calls.started == 0 && calls.stopped == 0)
    }

    @Test func startAndStopIntentsRunTheirHook() async throws {
        let calls = Calls()
        calls.install()
        defer { Self.reset() }
        _ = try await StartVoiceNoteIntent().perform()
        #expect(calls.started == 1 && calls.stopped == 0)
        _ = try await StopVoiceNoteIntent().perform()
        #expect(calls.started == 1 && calls.stopped == 1)
    }

    /// The control decides from the live state, not from the phase it drew.
    @Test func theControlIntentStartsOrStopsFromTheLiveState() async throws {
        let calls = Calls()
        calls.install()
        defer { Self.reset() }

        calls.live = VoiceNoteStatus(phase: .ready)
        _ = try await VoiceNoteControlIntent(shown: .ready).perform()
        #expect(calls.started == 1 && calls.stopped == 0)

        calls.live = VoiceNoteStatus(phase: .recording, started: Date(timeIntervalSince1970: 1_000))
        _ = try await VoiceNoteControlIntent(shown: .ready).perform()
        #expect(calls.started == 1 && calls.stopped == 1, "recording now: a tap stops, whatever was drawn")

        // A Stop drawn for a recording that is gone (its process died) never starts a new one (#106).
        calls.live = VoiceNoteStatus(phase: .ready)
        _ = try await VoiceNoteControlIntent(shown: .recording).perform()
        #expect(calls.started == 1 && calls.stopped == 2)

        // No `shown` at all (an intent made without it): the live state decides.
        var bare = VoiceNoteControlIntent()
        bare.shown = nil
        _ = try await bare.perform()
        #expect(calls.started == 2 && calls.stopped == 2)
        #expect(calls.opened.isEmpty)
    }

    @Test func theControlIntentRemembersThePhaseItWasDrawnWith() {
        for phase in [VoiceNoteStatus.Phase.ready, .recording, .saving, .notSetUp, .liveActivitiesOff] {
            #expect(VoiceNoteControlIntent(shown: phase).shown == phase.rawValue)
            #expect(VoiceNoteStatus.Phase(rawValue: phase.rawValue) == phase)
        }
        #expect(VoiceNoteControlIntent().shown == nil)
        #expect(VoiceNoteControlIntent.isDiscoverable == false)
    }

    /// The hooks `register()` installs hand the intent's errors on: Shortcuts and
    /// the widgets show them (`QuickCaptureError.localizedStringResource`).
    @Test func startIntentThroughTheRecorderReportsItsRefusalsAndRecords() async throws {
        let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        VoiceNoteActions.start = { try await qc.start() }
        VoiceNoteActions.stop = { _ = try await qc.stop() }
        defer { Self.reset() }

        _ = try await StartVoiceNoteIntent().perform()
        #expect(qc.state == .recording)
        await #expect(throws: QuickCaptureError.alreadyRecording) { _ = try await StartVoiceNoteIntent().perform() }
        #expect(qc.state == .recording, "the refused second start leaves the recording alone")

        _ = try await StopVoiceNoteIntent().perform()
        #expect(qc.state == .idle)
        #expect(qc.notice?.result == .savedToInbox)
        #expect(QuickCaptureTests.inbox(url).count == 1)

        try qc.store.delete()
        await #expect(throws: QuickCaptureError.notSetUp) { _ = try await StartVoiceNoteIntent().perform() }
        #expect(qc.state == .idle)
    }

    /// Every error an intent can show has text (an empty message would show nothing in Shortcuts).
    @Test func intentErrorsHaveText() {
        for error in [QuickCaptureError.notSetUp, .microphoneDenied, .liveActivitiesOff, .alreadyRecording, .notRecording] {
            #expect(!error.description.isEmpty)
        }
    }

    /// The Live Activity is dismissed `shownFor` seconds after it ends (`endActivity(…, after:)`),
    /// and the banner clears itself after the same time.
    @Test func resultsAreShownFiveSecondsAndFailuresTwelve() {
        #expect(VoiceNoteResult.savedToInbox.shownFor == 5)
        #expect(VoiceNoteResult.savedOnDevice.shownFor == 5)
        #expect(VoiceNoteResult.failed.shownFor == 12)
        for result in [VoiceNoteResult.savedToInbox, .savedOnDevice, .failed] {
            #expect(!result.title.isEmpty && !result.detail.isEmpty && !result.symbol.isEmpty)
        }
        #expect(VoiceNoteResult.failed.symbol != VoiceNoteResult.savedToInbox.symbol)
    }

    /// A saved voice note's banner goes by itself after its 5 seconds, unless
    /// it was replaced meanwhile (the old timer must not clear a newer notice).
    @Test func theBannerClearsItselfAfterItsTime() async throws {
        let (_, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        try await qc.start()
        _ = try await qc.stop()
        let first = try #require(qc.notice)
        #expect(first.result == .savedToInbox)
        #expect(first.error == nil)
        #expect(await TS.waitUntil(timeout: .seconds(2)) { qc.notice == nil } == false, "still shown after 2 seconds")
        #expect(await TS.waitUntil(timeout: .seconds(8)) { qc.notice == nil }, "gone after about 5 seconds")
    }
}
