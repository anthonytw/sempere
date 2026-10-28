import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Quick voice note starts (docs/quick-capture.md "When iOS refuses a background start"): the
/// start diagnostics kept for Settings ▸ Quick Voice Notes ▸ Recent Starts, a Live Activity
/// request that fails, and the Lock Screen fallback (continue in the app, wait until it is
/// active, try once more, and say so in the banner if that fails too). TestFlight 1.0.0 (4):
/// the Lock Screen widget opened the app and recorded nothing, with no message anywhere.
///
/// The app state, the "became active" signal and the Live Activity request are injected; the
/// real ones (`UIApplication`, `Activity.request`, `continueInForeground`) need a device.
@Suite(.serialized)
@MainActor
struct VoiceNoteStartTests {
    struct Refused: Error {}

    /// A capture whose recorder refuses to start unless the (fake) app is active, as iOS
    /// refused the background start on the owner's iPhone.
    @MainActor
    final class Phone {
        var state = UIApplication.State.background
        var continued = 0
        var waits = 0
        var backends: [FakeCapture] = []
        /// Resumed by a test to say "the app became active".
        var signal: CheckedContinuation<Bool, Never>?
        let capture: QuickCapture
        let vault: URL

        init(activityFails: Bool = false) throws {
            let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
            vault = url
            capture = qc
            qc.applicationState = { [unowned self] in state }
            qc.backend = { [unowned self] in
                let fake = FakeCapture()
                fake.failBegin = state != .active
                backends.append(fake)
                return fake
            }
            qc.waitUntilActive = { [unowned self] _ in
                waits += 1
                state = .active   // the user unlocked; the app came to the front
                return true
            }
            if activityFails {
                qc.showsActivity = true
                qc.activitiesEnabled = { true }
                qc.requestActivity = { _ in throw Refused() }
            }
        }

        func request(_ source: VoiceNoteStartSource = .widgetOrControl) -> VoiceNoteStartRequest {
            VoiceNoteStartRequest(source: source, intentMode: "background", continueInApp: { [unowned self] in continued += 1 })
        }

        var last: VoiceNoteStartAttempt? { capture.recentStarts.first }
    }

    @Test func aStartInTheAppIsRecordedAsSuch() async throws {
        let phone = try Phone()
        phone.state = .active
        try await phone.capture.start()
        let a = try #require(phone.last)
        #expect(a.source == .app && a.intentMode == nil)
        #expect(a.outcome == .recording)
        #expect(a.first.appState == "active")
        #expect(a.first.activity == .notRequested("turned off"))
        #expect(a.first.error == nil && a.foreground == nil && a.retry == nil)
        _ = try await phone.capture.stop()
    }

    /// The Lock Screen path: refused in the background, the intent continues in the app, the
    /// retry waits for the app to be active and records.
    @Test func aRefusedBackgroundStartRecordsOnceTheAppIsActive() async throws {
        let phone = try Phone()
        try await phone.capture.start(phone.request())
        #expect(phone.capture.state == .recording)
        #expect(phone.continued == 1 && phone.waits == 1)
        let a = try #require(phone.last)
        #expect(a.source == .widgetOrControl && a.intentMode == "background")
        #expect(a.outcome == .recordingInApp)
        #expect(a.first.appState == "background")
        let first = try #require(a.first.error)
        #expect(first.type.hasSuffix("RecordingError"))
        #expect(first.description.contains("test"))
        #expect(a.foreground?.becameActive == true && a.foreground?.error == nil)
        #expect(a.retry?.appState == "active" && a.retry?.error == nil)
        #expect(a.finalError == nil)
        #expect(phone.capture.notice == nil, "nothing to say: it records")
        _ = try await phone.capture.stop()
        #expect(QuickCaptureTests.inbox(phone.vault).count == 1)
    }

    /// The retry fails too: the banner says so and stays until dismissed, and the intent gets the error.
    @Test func aRetryThatFailsIsShownInTheAppNeverSilently() async throws {
        let phone = try Phone()
        phone.capture.waitUntilActive = { _ in false }   // the app never became active within the wait
        await #expect(throws: RecordingError.self) { try await phone.capture.start(phone.request(.shortcut)) }
        #expect(phone.capture.state == .idle)
        let a = try #require(phone.last)
        #expect(a.outcome == .failed && a.source == .shortcut)
        #expect(a.foreground?.becameActive == false)
        #expect(a.retry?.appState == "background")
        #expect(a.finalError == a.retry?.error && a.finalError != nil)
        let notice = try #require(phone.capture.notice)
        #expect(notice.result == .failed && notice.persists)
        #expect(notice.title == String(localized: "Voice Note Not Recorded"))
        #expect(notice.error?.contains("test") == true)
        #expect(VoiceNoteBannerRule.shows(state: phone.capture.state, hasNotice: true))
    }

    /// `Activity.request` failing is kept (it used to be swallowed by `try?`), and with the app in the
    /// background the recorder is not even started: no Live Activity, no background recording.
    @Test func aLiveActivityRequestThatFailsIsKeptAndContinuesInTheApp() async throws {
        let phone = try Phone(activityFails: true)
        try await phone.capture.start(phone.request())
        #expect(phone.capture.state == .recording, "in front the app records without its Live Activity")
        let a = try #require(phone.last)
        guard case .failed(let why) = a.first.activity else {
            Issue.record("the failed request was not kept: \(String(describing: a.first.activity))")
            return
        }
        #expect(why.type.hasSuffix("Refused"))
        #expect(a.first.error?.type.hasSuffix("QuickCaptureError") == true)
        #expect(a.first.error?.description.hasPrefix("iOS did not start the voice note's Live Activity") == true)
        #expect(phone.backends.first?.log == ["activate", "deactivate"],
                "the background try activated the session, then released it, and never reached the recorder")
        if case .failed = a.retry?.activity {} else { Issue.record("the retry's request is kept too") }
        #expect(a.outcome == .recordingInApp)
        _ = try await phone.capture.stop()
    }

    /// iOS would not bring the app forward (or nobody unlocked): no wait, the banner says why.
    @Test func anAppThatCannotComeForwardFailsAtOnce() async throws {
        let phone = try Phone()
        let request = VoiceNoteStartRequest(source: .widgetOrControl, intentMode: nil, continueInApp: { throw Refused() })
        await #expect(throws: QuickCaptureError.self) { try await phone.capture.start(request) }
        #expect(phone.waits == 0)
        let a = try #require(phone.last)
        #expect(a.outcome == .failed && a.retry == nil)
        #expect(a.foreground?.error?.type.hasSuffix("Refused") == true)
        #expect(phone.capture.notice?.persists == true)
    }

    /// Errors that the app in front would not fix (not set up, no microphone) are reported as they are.
    @Test func otherRefusalsDoNotContinueInTheApp() async throws {
        let phone = try Phone()
        try phone.capture.store.delete()
        await #expect(throws: QuickCaptureError.notSetUp) { try await phone.capture.start(phone.request()) }
        #expect(phone.continued == 0 && phone.waits == 0)
        let a = try #require(phone.last)
        #expect(a.outcome == .failed && a.first.activity == nil)
        #expect(a.first.error?.description == QuickCaptureError.notSetUp.description)
        #expect(phone.capture.notice == nil, "the intent shows this one itself")
    }

    /// The retry belongs to the app, not to the intent: an intent cancelled while the app comes forward
    /// (the Lock Screen's unlock) still gets its recording.
    @Test func theRetrySurvivesTheIntentBeingCancelled() async throws {
        let phone = try Phone()
        phone.capture.waitUntilActive = { [phone] _ in await withCheckedContinuation { phone.signal = $0 } }
        let intent = Task { try await phone.capture.start(phone.request()) }
        #expect(await TS.waitUntil(timeout: .seconds(5)) { phone.signal != nil })
        intent.cancel()
        phone.state = .active
        phone.signal?.resume(returning: true)
        try await intent.value
        #expect(phone.capture.state == .recording)
        #expect(phone.last?.outcome == .recordingInApp)
        _ = try await phone.capture.stop()
    }

    // MARK: - Waiting for the app to be active

    @Test func waitingEndsAtOnceWhenTheAppIsActive() async {
        let center = NotificationCenter()
        let start = ContinuousClock.now
        #expect(await AppActivation.wait(timeout: .seconds(10), center: center) { true })
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func waitingEndsOnTheNotification() async {
        let center = NotificationCenter()
        let start = ContinuousClock.now
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        #expect(await AppActivation.wait(timeout: .seconds(10), center: center) { false })
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func waitingGivesUpAfterTheTimeout() async {
        let center = NotificationCenter()
        let start = ContinuousClock.now
        #expect(await AppActivation.wait(timeout: .milliseconds(300), center: center) { false } == false)
        #expect(ContinuousClock.now - start >= .milliseconds(300))
        // A late notification after the timeout is harmless (the observer is gone).
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - The record

    @Test func theLogKeepsTheLastFewNewestFirstAcrossLaunches() throws {
        let url = QuickCaptureTests.temp("start-log").appendingPathComponent("recent-starts.json")
        let log = VoiceNoteStartLog(url: url)
        for i in 0..<(VoiceNoteStartLog.capacity + 3) {
            log.append(VoiceNoteStartAttempt(date: Date(timeIntervalSince1970: Double(i)), source: .shortcut,
                                             first: VoiceNoteStartTry(appState: "background", activity: .started)))
        }
        let again = VoiceNoteStartLog(url: url)
        #expect(again.attempts.count == VoiceNoteStartLog.capacity)
        #expect(again.attempts.first?.date == Date(timeIntervalSince1970: Double(VoiceNoteStartLog.capacity + 2)))
        #expect(again.attempts == log.attempts)
        again.clear()
        #expect(VoiceNoteStartLog(url: url).attempts.isEmpty)
    }

    @Test func aDamagedLogReadsAsEmpty() throws {
        let url = QuickCaptureTests.temp("start-log-bad").appendingPathComponent("recent-starts.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(VoiceNoteStartLog(url: url).attempts.isEmpty)
        try Data(count: VoiceNoteStartLog.maxFileBytes + 1).write(to: url)
        #expect(VoiceNoteStartLog(url: url).attempts.isEmpty)
    }

    /// The audio system's refusal is kept with its domain, code and name, which is what tells the
    /// background refusals apart (AudioSessionTypes.h).
    @Test func errorsKeepTheirDomainCodeAndName() {
        let session = NSError(domain: NSOSStatusErrorDomain, code: 561_145_187, userInfo: [NSLocalizedDescriptionKey: "Session activation failed"])
        let text = AVAudioCaptureBackend.explain(session, step: "setActive")
        #expect(text == "Session activation failed (setActive: \(NSOSStatusErrorDomain) 561145187 '!rec' cannotStartRecording)")
        #expect(AVAudioCaptureBackend.sessionErrorName(560_557_684) == "'!int' cannotInterruptOthers")
        #expect(AVAudioCaptureBackend.sessionErrorName(42) == nil)

        let info = VoiceNoteErrorInfo(session)
        #expect(info.domain == NSOSStatusErrorDomain && info.code == 561_145_187)
        #expect(info.description == "Session activation failed")

        let wrapped = VoiceNoteErrorInfo(RecordingError.cannotRecord(text))
        #expect(wrapped.type.hasSuffix("RecordingError"))
        #expect(wrapped.description.contains("'!rec'"))
        #expect(VoiceNoteErrorInfo(type: "T", domain: "D", code: 1, description: String(repeating: "x", count: 1000)).description.count
                == VoiceNoteErrorInfo.maxDescription)
    }

    /// What Settings shows for each attempt (`RecentStartsView`): a line per step, nothing personal.
    @Test func theSettingsLinesNameEveryStep() {
        var a = VoiceNoteStartAttempt(date: Date(), source: .widgetOrControl, intentMode: "background",
                                      first: VoiceNoteStartTry(appState: "background", activity: .failed(VoiceNoteErrorInfo(type: "ActivityKit.ActivityAuthorizationError", domain: "ActivityKit.ActivityAuthorizationError", code: 7, description: "visibility")),
                                                               error: VoiceNoteErrorInfo(RecordingError.cannotRecord("x"))))
        a.foreground = .init(error: nil, becameActive: true, waited: 3.2)
        a.retry = VoiceNoteStartTry(appState: "active", activity: .started)
        a.outcome = .recordingInApp
        let lines = RecentStartsView.lines(a)
        #expect(lines.count == 3)
        #expect(lines.joined(separator: "\n").contains("visibility"))
        #expect(!RecentStartsView.sourceTitle(.app).isEmpty && !RecentStartsView.outcomeTitle(.failed).isEmpty)
    }
}
