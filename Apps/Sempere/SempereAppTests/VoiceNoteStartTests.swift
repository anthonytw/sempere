import Foundation
import Sempere
import SempereAppCore
import SempereCaptureShared
import Testing
import UIKit
@testable import SempereApp

/// Quick voice note starts on the app's platform (docs/quick-capture.md "When iOS refuses a background start"):
/// waiting for the app to be active (`AppActivation`, UIKit), the audio system's errors as the start diagnostics keep
/// them, and the Settings lines. The start and its Lock Screen fallback (continue in the app, wait, try once more,
/// say so in the banner) and the start log: `QuickCaptureStartTests` (SempereAppCoreTests).
@Suite(.serialized)
@MainActor
struct VoiceNoteStartTests {
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
