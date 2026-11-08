import Foundation
import Sempere
import SempereAppCore
import SempereCaptureShared
import Testing

/// Quick voice note starts (docs/quick-capture.md "Start order", "When iOS refuses a background start"), on fakes:
/// the audio session before the Live Activity, the mixable fallback, the Lock Screen fallback (continue in the app,
/// wait until it is active, try once more, and say so in the banner if that fails too), the start diagnostics kept
/// for Settings ▸ Quick Voice Notes ▸ Recent Starts, the Live Activity's heartbeat, a widget tap that opened the app,
/// and a Stop on an orphaned Live Activity. TestFlight 1.0.0 (4) and (6), iPhone. Moved from the app's
/// `VoiceNoteStartTests`, `QuickCaptureRobustnessTests` and `VoiceNoteTapTests` (wave 5b). Serialized: some change the
/// process-wide `VoiceNoteActions`.
@Suite(.serialized)
@MainActor
struct QuickCaptureStartTests {
    struct Refused: Error {}

    /// A capture with its Live Activity on, started by an intent in the background.
    static func rig(refuseNonMixable: Bool = false, refuseMixable: Bool = false, refuseStart: Bool = false) throws -> CaptureRig {
        let rig = try CaptureRig()
        rig.app.activity = .background
        rig.capture.showsActivity = true
        let app = rig.app
        rig.audio.configure = { recorder in
            // iOS refuses a non-mixable activation from the background ('!int'); in front it is fine.
            recorder.failNonMixable = refuseNonMixable && app.activity != .active
            recorder.failMixable = refuseMixable && app.activity != .active
            recorder.failStart = refuseStart && app.activity != .active
        }
        return rig
    }

    final class Continued: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    static func request(_ source: VoiceNoteStartSource = .widgetOrControl, continued: Continued) -> VoiceNoteStartRequest {
        VoiceNoteStartRequest(source: source, intentMode: "background", continueInApp: { continued.add() })
    }

    // MARK: - Start order and the audio session (iPhone, iOS 27.0.1)

    /// The order the iPhone needs: the session is active before the Live Activity is asked for (iOS ends the
    /// intent's fake-foreground assertion when the activity begins), and the recorder starts after both.
    @Test func theSessionIsActiveBeforeTheLiveActivityIsRequested() async throws {
        let rig = try Self.rig()
        try await rig.capture.start(Self.request(continued: Continued()))
        #expect(rig.audio.events == ["activate", "activity"])
        #expect(rig.live.endAllCalls == 1, "activities a dead process left were ended first")
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.outcome == .recording && a.first.session == "not mixable" && a.first.activity == .started)
        #expect(rig.live.requested.first?.started == rig.clock.now)
        _ = try await rig.capture.stop()
    }

    /// A background start whose non-mixable activation iOS refuses ('!int' cannotInterruptOthers) records mixable
    /// instead, in the background, and says so in Recent Starts.
    @Test func aRefusedNonMixableActivationRecordsMixable() async throws {
        let rig = try Self.rig(refuseNonMixable: true)
        let continued = Continued()
        try await rig.capture.start(Self.request(continued: continued))
        #expect(rig.capture.state == .recording)
        #expect(continued.count == 0, "no need to open the app")
        #expect(rig.audio.events == ["activate", "activate-mixable", "activity"])
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.outcome == .recording)
        #expect(a.first.session?.hasPrefix("mixable after a refusal") == true)
        #expect(a.first.session?.contains("'!int' cannotInterruptOthers") == true)
        _ = try await rig.capture.stop()
        #expect(rig.inbox.count == 1)
    }

    /// Both refused: no Live Activity is asked for in the background, the intent continues in the app, and the
    /// start in front records (non-mixable).
    @Test func bothActivationsRefusedContinueInTheApp() async throws {
        let rig = try Self.rig(refuseNonMixable: true, refuseMixable: true)
        let continued = Continued()
        try await rig.capture.start(Self.request(continued: continued))
        #expect(continued.count == 1)
        #expect(rig.audio.events == ["activate", "activate-mixable", "activate", "activity"],
                "the background try never asked for the activity; the retry in front did")
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.outcome == .recordingInApp)
        #expect(a.first.error?.description.contains("'!int'") == true, "the first refusal is the one kept")
        #expect(a.first.activity == nil && a.first.session == nil)
        #expect(a.retry?.session == "not mixable")
        _ = try await rig.capture.stop()
    }

    /// In front a non-mixable refusal is reported as it is (no mixable fallback for the app's own start).
    @Test func inFrontARefusedActivationIsNotRetriedMixable() async throws {
        let rig = try Self.rig()
        rig.app.activity = .active
        rig.audio.configure = { $0.failNonMixable = true }
        await #expect(throws: FakeRecorder.SessionRefused.self) { try await rig.capture.start() }
        #expect(rig.audio.recorders.first?.log == ["activate"])
        #expect(rig.capture.state == .idle)
    }

    // MARK: - The Lock Screen fallback

    @Test func aStartInTheAppIsRecordedAsSuch() async throws {
        let rig = try CaptureRig()
        try await rig.capture.start()
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.source == .app && a.intentMode == nil)
        #expect(a.outcome == .recording)
        #expect(a.first.appState == "active" && a.first.microphone == "granted" && a.first.protectedData == true)
        #expect(a.first.activity == .notRequested("turned off"))
        #expect(a.first.error == nil && a.foreground == nil && a.retry == nil)
        _ = try await rig.capture.stop()
    }

    /// The Lock Screen path: the recorder refused in the background, the intent continues in the app, the retry
    /// waits for the app to be active and records.
    @Test func aRefusedBackgroundStartRecordsOnceTheAppIsActive() async throws {
        let rig = try Self.rig(refuseStart: true)
        let continued = Continued()
        try await rig.capture.start(Self.request(continued: continued))
        #expect(rig.capture.state == .recording)
        #expect(continued.count == 1 && rig.app.waits == 1)
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.source == .widgetOrControl && a.intentMode == "background")
        #expect(a.outcome == .recordingInApp)
        #expect(a.first.appState == "background")
        let first = try #require(a.first.error)
        #expect(first.type.hasSuffix("RecorderRefused") && first.description.contains("test"))
        #expect(a.foreground?.becameActive == true && a.foreground?.error == nil)
        #expect(a.retry?.appState == "active" && a.retry?.error == nil)
        #expect(a.finalError == nil)
        #expect(rig.capture.notice == nil, "nothing to say: it records")
        _ = try await rig.capture.stop()
        #expect(rig.inbox.count == 1)
    }

    /// The retry fails too: the banner says so and stays until dismissed, and the intent gets the error.
    @Test func aRetryThatFailsIsShownInTheAppNeverSilently() async throws {
        let rig = try Self.rig(refuseNonMixable: true, refuseMixable: true)
        rig.app.wait = { _ in false }   // the app never became active within the wait
        await #expect(throws: FakeRecorder.SessionRefused.self) {
            try await rig.capture.start(Self.request(.shortcut, continued: Continued()))
        }
        #expect(rig.capture.state == .idle)
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.outcome == .failed && a.source == .shortcut)
        #expect(a.foreground?.becameActive == false)
        #expect(a.retry?.appState == "background")
        #expect(a.finalError == a.retry?.error && a.finalError != nil)
        let notice = try #require(rig.capture.notice)
        #expect(notice.result == .failed && notice.persists && notice.kind == .notRecorded)
        #expect(notice.error?.contains("cannotInterruptOthers") == true)
        #expect(rig.sleeper.requested.isEmpty, "kept until dismissed: no timer")
    }

    /// The Live Activity request failing is kept (it used to be swallowed by `try?`), and with the app in the
    /// background the recorder is not even started: no Live Activity, no background recording.
    @Test func aLiveActivityRequestThatFailsIsKeptAndContinuesInTheApp() async throws {
        let rig = try Self.rig()
        rig.live.requestError = Refused()
        let continued = Continued()
        try await rig.capture.start(Self.request(continued: continued))
        #expect(rig.capture.state == .recording, "in front the app records without its Live Activity")
        let a = try #require(rig.capture.recentStarts.first)
        guard case .failed(let why) = a.first.activity else {
            Issue.record("the failed request was not kept: \(String(describing: a.first.activity))")
            return
        }
        #expect(why.type.hasSuffix("Refused"))
        #expect(a.first.error?.type.hasSuffix("QuickCaptureError") == true)
        #expect(rig.audio.recorders.first?.log == ["activate", "deactivate"],
                "the background try activated the session, then released it, and never reached the recorder")
        #expect(rig.audio.recorders.first?.recordings.first?.state == .idle)
        if case .failed = a.retry?.activity {} else { Issue.record("the retry's request is kept too") }
        #expect(a.outcome == .recordingInApp && continued.count == 1)
        _ = try await rig.capture.stop()
    }

    /// iOS would not bring the app forward (or nobody unlocked): no wait, the banner says why.
    @Test func anAppThatCannotComeForwardFailsAtOnce() async throws {
        let rig = try Self.rig(refuseNonMixable: true, refuseMixable: true)
        let request = VoiceNoteStartRequest(source: .widgetOrControl, intentMode: nil, continueInApp: { throw Refused() })
        await #expect(throws: QuickCaptureError.self) { try await rig.capture.start(request) }
        #expect(rig.app.waits == 0)
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.outcome == .failed && a.retry == nil)
        #expect(a.foreground?.error?.type.hasSuffix("Refused") == true)
        #expect(rig.capture.notice?.persists == true)
    }

    /// Errors that the app in front would not fix (not set up, no microphone) are reported as they are.
    @Test func otherRefusalsDoNotContinueInTheApp() async throws {
        let rig = try Self.rig()
        try rig.store.delete()
        let continued = Continued()
        await #expect(throws: QuickCaptureError.notSetUp) { try await rig.capture.start(Self.request(continued: continued)) }
        #expect(continued.count == 0 && rig.app.waits == 0)
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.outcome == .failed && a.first.activity == nil)
        #expect(a.first.error?.description == "\(QuickCaptureError.notSetUp)")
        #expect(rig.capture.notice == nil, "the intent shows this one itself")
        #expect(!QuickCapture.worksInForeground(QuickCaptureError.notSetUp))
        #expect(QuickCapture.worksInForeground(FakeRecorder.SessionRefused(mixable: false)))
    }

    /// The retry belongs to the app, not to the intent: an intent cancelled while the app comes forward (the Lock
    /// Screen's unlock) still gets its recording.
    @Test func theRetrySurvivesTheIntentBeingCancelled() async throws {
        let rig = try Self.rig(refuseNonMixable: true, refuseMixable: true)
        final class Signal { var continuation: CheckedContinuation<Bool, Never>? }
        let signal = Signal()
        rig.app.wait = { _ in await withCheckedContinuation { signal.continuation = $0 } }
        let intent = Task { try await rig.capture.start(Self.request(continued: Continued())) }
        #expect(await rig.settle { signal.continuation != nil })
        intent.cancel()
        rig.app.activity = .active
        signal.continuation?.resume(returning: true)
        try await intent.value
        #expect(rig.capture.state == .recording)
        #expect(rig.capture.recentStarts.first?.outcome == .recordingInApp)
        _ = try await rig.capture.stop()
    }

    // MARK: - Siri after a restart

    /// A process launched in the background (Siri after a restart) that reads the microphone permission as not
    /// granted does not say "not allowed": it continues in the app, where the answer is the user's.
    @Test func aBackgroundMicrophoneRefusalIsCheckedAgainInFront() async throws {
        let rig = try Self.rig()
        let app = rig.app
        rig.audio.allowed = { app.activity == .active }
        rig.audio.permission = { app.activity == .active ? "granted" : "undetermined" }
        let continued = Continued()
        try await rig.capture.start(Self.request(continued: continued))
        #expect(continued.count == 1)
        #expect(rig.capture.state == .recording)
        let a = try #require(rig.capture.recentStarts.first)
        #expect(a.outcome == .recordingInApp)
        #expect(a.first.microphone == "undetermined")
        #expect(a.first.error?.description == "\(QuickCaptureError.microphoneUnconfirmed)")
        #expect(a.retry?.microphone == "granted")
        _ = try await rig.capture.stop()
    }

    /// In front, a refused microphone is the user's choice: said as it is.
    @Test func inFrontARefusedMicrophoneIsDenied() async throws {
        let rig = try Self.rig()
        rig.app.activity = .active
        rig.audio.allowed = { false }
        await #expect(throws: QuickCaptureError.microphoneDenied) { try await rig.capture.start() }
    }

    /// Before the first unlock after a restart the profile cannot be read: Siri says to unlock once.
    @Test func beforeTheFirstUnlockSiriSaysToUnlockOnce() async throws {
        let rig = try Self.rig()
        rig.capture.store = FailingCaptureProfileStore()
        rig.app.protectedDataAvailable = false
        let continued = Continued()
        await #expect(throws: QuickCaptureError.beforeFirstUnlock) { try await rig.capture.start(Self.request(continued: continued)) }
        #expect(continued.count == 0)
        #expect(rig.capture.recentStarts.first?.first.protectedData == false)
        // After the unlock, an unreadable profile is reported as such.
        rig.app.protectedDataAvailable = true
        await #expect(throws: QuickCaptureError.profileUnreadable) { try await rig.capture.start(Self.request(continued: continued)) }
    }

    // MARK: - The Live Activity while recording

    /// While recording the Live Activity is sent its state again every `activityHeartbeat`, which moves its stale
    /// date on: a process that dies stops doing so, and the activity turns stale ("interrupted").
    @Test func theLiveActivityIsKeptFreshWhileRecording() async throws {
        let rig = try CaptureRig()
        let beat = rig.capture.activityHeartbeat
        try await rig.capture.start()
        let first = rig.live.states.count
        for n in 1...3 {
            #expect(await rig.settle { rig.sleeper.pending(beat) == 1 })
            rig.clock.advance(45)
            rig.sleeper.release(beat)
            #expect(await rig.settle { rig.live.states.count == first + n }, "beat \(n)")
        }
        #expect(rig.live.states.last?.isRecording == true)
        #expect(await rig.settle { rig.sleeper.pending(beat) == 1 })
        _ = try await rig.capture.stop()
        let after = rig.live.states.count
        rig.sleeper.release(beat)
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.live.states.count == after, "no refresh once stopped")
        #expect(rig.sleeper.pending(beat) == 0, "and the heartbeat ended")
    }

    /// Stop on a Live Activity whose recording this process does not have (the app was force quit, then the Stop
    /// launched it): no error for the user, and the recording that process left is saved now.
    @Test func stopOnAnOrphanedActivitySavesWhatItsRecordingLeft() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        await #expect(throws: QuickCaptureError.notRecording) { try await rig.capture.stop() }
        #expect(rig.live.endAllCalls == 1)
        #expect(rig.inbox.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        // What the intent does with that error (`installActions`): nothing to report.
        rig.capture.installActions()
        defer { Self.resetActions() }
        try await VoiceNoteActions.stop?()
    }

    @Test func orphansAreAskedForWithAGrace() async throws {
        let rig = try CaptureRig()
        rig.live.orphans = 2
        #expect(await rig.capture.endOrphanedActivities() == 2)
        #expect(QuickCapture.orphanGrace == 10)
    }

    // MARK: - A widget tap that opened the app

    static func resetActions() {
        VoiceNoteActions.start = nil
        VoiceNoteActions.stop = nil
        VoiceNoteActions.open = nil
        VoiceNoteActions.status = nil
        VoiceNoteActions.appState = nil
        VoiceNoteActions.tapRecorded = nil
        VoiceNoteActions.tapLog = nil
    }

    /// A widget tap that opened the app records there (the app is in front), and a second one stops; both are kept.
    @Test func aWidgetTapThatOpenedTheAppRecordsThereAndIsKept() async throws {
        let rig = try CaptureRig()
        let taps = VoiceNoteTapLog(directory: CaptureFixture.temp("taps"))
        rig.capture.installActions()
        VoiceNoteActions.tapLog = taps
        defer { Self.resetActions() }

        await rig.capture.widgetOpenedApp().value
        #expect(rig.capture.state == .recording)
        #expect(rig.capture.recentStarts.first?.outcome == .recording)
        #expect(rig.capture.recentStarts.first?.source == .widgetOrControl)

        await rig.capture.widgetOpenedApp().value
        #expect(rig.capture.state == .idle)
        #expect(rig.inbox.count == 1)

        let kept = taps.read()
        #expect(kept.map(\.entry) == [.widgetOpenedApp, .widgetOpenedApp])
        #expect(kept.map(\.decision) == [.stop, .start])
        #expect(kept.last?.live == "ready" && kept.last?.appState == "active")
        #expect(rig.capture.recentTaps == kept, "Recent Starts reads them again after each tap")
    }

    /// Not set up: the widget's link shows the setup, as the intent would have.
    @Test func aWidgetTapThatOpenedTheAppBeforeSetupShowsSettings() async throws {
        let rig = try CaptureRig(profile: false)
        let taps = VoiceNoteTapLog(directory: CaptureFixture.temp("taps"))
        VoiceNoteActions.tapLog = taps
        defer { Self.resetActions() }
        await rig.capture.widgetOpenedApp().value
        #expect(rig.capture.state == .idle)
        #expect(rig.capture.pendingLink == .settings)
        #expect(taps.read().first?.decision == .openSettings)
        #expect(rig.capture.recentStarts.isEmpty)
        rig.capture.clearDiagnostics()
        #expect(taps.read().isEmpty && rig.capture.recentTaps.isEmpty)
    }

    /// The hooks hand the app's live status and its start and stop to the intents.
    @Test func theActionsReachThisCapture() async throws {
        let rig = try CaptureRig()
        rig.capture.installActions()
        defer { Self.resetActions() }
        #expect(VoiceNoteActions.status?() == VoiceNoteStatus(phase: .ready))
        #expect(VoiceNoteActions.appState?() == "active")
        try await VoiceNoteActions.start?(VoiceNoteStartRequest(source: .shortcut))
        #expect(rig.capture.state == .recording)
        #expect(VoiceNoteActions.status?().phase == .recording)
        VoiceNoteActions.open?(.recording)
        #expect(rig.capture.pendingLink == .recording)
        try await VoiceNoteActions.stop?()
        #expect(rig.capture.state == .idle && rig.inbox.count == 1)
    }

    // MARK: - The record

    @Test func theLogKeepsTheLastFewNewestFirstAcrossLaunches() throws {
        let url = CaptureFixture.temp("start-log").appendingPathComponent("recent-starts.json")
        let perf = MemoryPerfSink()
        let log = VoiceNoteStartLog(url: url, perf: perf)
        for i in 0..<(VoiceNoteStartLog.capacity + 3) {
            log.append(VoiceNoteStartAttempt(date: Date(timeIntervalSince1970: Double(i)), source: .shortcut,
                                             first: VoiceNoteStartTry(appState: "background", activity: .started)))
        }
        let again = VoiceNoteStartLog(url: url)
        #expect(again.attempts.count == VoiceNoteStartLog.capacity)
        #expect(again.attempts.first?.date == Date(timeIntervalSince1970: Double(VoiceNoteStartLog.capacity + 2)))
        #expect(again.attempts == log.attempts)
        #expect(perf.records.count == VoiceNoteStartLog.capacity + 3, "each start is logged too")
        again.clear()
        #expect(VoiceNoteStartLog(url: url).attempts.isEmpty)
    }

    @Test func aDamagedLogReadsAsEmpty() throws {
        let url = CaptureFixture.temp("start-log-bad").appendingPathComponent("recent-starts.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(VoiceNoteStartLog(url: url).attempts.isEmpty)
        try Data(count: VoiceNoteStartLog.maxFileBytes + 1).write(to: url)
        #expect(VoiceNoteStartLog(url: url).attempts.isEmpty)
    }

    /// Starts kept by a launch that could not read the file (before the first unlock) are merged with it, not
    /// written over it.
    @Test func theStartLogMergesWhatItCouldNotReadAtLaunch() throws {
        let url = CaptureFixture.temp("start-log-merge").appendingPathComponent("recent-starts.json")
        let launchedLocked = VoiceNoteStartLog(url: url)
        let earlier = VoiceNoteStartLog(url: url)
        earlier.append(VoiceNoteStartAttempt(date: Date(timeIntervalSince1970: 1), source: .shortcut,
                                             first: VoiceNoteStartTry(appState: "background")))
        launchedLocked.append(VoiceNoteStartAttempt(date: Date(timeIntervalSince1970: 2), source: .widgetOrControl,
                                                    first: VoiceNoteStartTry(appState: "background")))
        #expect(VoiceNoteStartLog(url: url).attempts.map(\.date.timeIntervalSince1970) == [2, 1])
        launchedLocked.reload()
        #expect(launchedLocked.attempts.map(\.date.timeIntervalSince1970) == [2, 1])
    }

    /// What the log says of an attempt: a line per step, nothing personal.
    @Test func theLogLineNamesEveryStep() {
        var a = VoiceNoteStartAttempt(date: Date(), source: .widgetOrControl, intentMode: "background",
                                      first: VoiceNoteStartTry(appState: "background", activity: .failed(
                                          VoiceNoteErrorInfo(type: "T", domain: "D", code: 7, description: "visibility")),
                                                               microphone: "granted", protectedData: true, session: "not mixable"))
        a.foreground = .init(error: nil, becameActive: true, waited: 3.2)
        a.retry = VoiceNoteStartTry(appState: "active", activity: .started)
        a.outcome = .recordingInApp
        let line = VoiceNoteStartLog.logLine(a)
        #expect(line.hasPrefix("voice note start source=widgetOrControl mode=background outcome=recordingInApp"))
        #expect(line.contains("first=[app=background mic=granted protectedData=true session=not mixable activity=failed T D 7: visibility error=none]"))
        #expect(line.contains("foreground=[continued in app: active=true after 3.2 s]"))
        #expect(line.contains("retry=[app=active activity=started error=none]"))
        #expect(VoiceNoteErrorInfo(type: "T", domain: "D", code: 1, description: String(repeating: "x", count: 1000)).description.count
                == VoiceNoteErrorInfo.maxDescription)
    }
}
