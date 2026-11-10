import Foundation
import SempereCaptureShared
import TempDirSupport
import Testing

/// What the quick voice note widgets, control and Live Activity show (`VoiceNoteStatus`, `VoiceNoteLink`,
/// `VoiceNoteResult`, `VoiceNoteActivityState`; docs/quick-capture.md), and the tap log they share with the app.
/// Moved from the app's `VoiceNoteStatusTests` and `VoiceNoteTapTests` (wave 5b); the words stay in the app.
struct VoiceNoteStatusTests {
    static func temp(_ name: String = "voice-status") -> URL {
        TestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build 7: the control did nothing until quick voice notes were turned on, and said nothing. Not set up and
    /// Live Activities off now open the settings; ready records; recording stops.
    @Test func eachStateHasItsAction() {
        let t = Date(timeIntervalSince1970: 1_000)
        func make(setUp: Bool = true, enabled: Bool = true, recording: Bool = false, saving: Bool = false) -> VoiceNoteStatus {
            .make(setUp: setUp, activitiesEnabled: enabled, recording: recording, saving: saving, started: t)
        }
        #expect(make(setUp: false) == VoiceNoteStatus(phase: .notSetUp))
        #expect(make(setUp: false, enabled: false).phase == .notSetUp, "the setup comes first")
        #expect(make(enabled: false) == VoiceNoteStatus(phase: .liveActivitiesOff))
        #expect(make() == VoiceNoteStatus(phase: .ready))
        #expect(make(recording: true) == VoiceNoteStatus(phase: .recording, started: t))
        #expect(make(setUp: false, enabled: false, recording: true).phase == .recording,
                "a recording keeps its Stop even if quick voice notes were turned off meanwhile")
        #expect(make(saving: true) == VoiceNoteStatus(phase: .saving, started: t))

        #expect(VoiceNoteStatus(phase: .notSetUp).action == .open(.settings))
        #expect(VoiceNoteStatus(phase: .liveActivitiesOff).action == .open(.settings))
        #expect(VoiceNoteStatus(phase: .ready).action == .start)
        #expect(VoiceNoteStatus(phase: .recording).action == .stop)
        #expect(VoiceNoteStatus(phase: .saving).action == .open(.recording))
        #expect(VoiceNoteStatus(phase: .recording).isActive)
        #expect(!VoiceNoteStatus(phase: .ready).isActive)
        #expect(VoiceNoteStatus(phase: .recording, started: t).timerRuns)
        #expect(!VoiceNoteStatus(phase: .recording, started: t, paused: t).timerRuns)
        #expect(VoiceNoteStatus.refreshInterval > 0 && VoiceNoteStatus.refreshInterval <= 3600)
    }

    /// The control decides when tapped, from the live state; a stale Stop (the recording's process died) never
    /// starts a new recording.
    @Test func theControlFollowsTheLiveStateButNeverTurnsStopIntoStart() {
        let ready = VoiceNoteStatus(phase: .ready)
        #expect(VoiceNoteStatus.controlAction(shown: .ready, live: ready) == .start)
        #expect(VoiceNoteStatus.controlAction(shown: nil, live: ready) == .start)
        #expect(VoiceNoteStatus.controlAction(shown: .recording, live: ready) == .stop)
        #expect(VoiceNoteStatus.controlAction(shown: .ready, live: VoiceNoteStatus(phase: .recording)) == .stop)
        #expect(VoiceNoteStatus.controlAction(shown: .ready, live: VoiceNoteStatus(phase: .notSetUp)) == .open(.settings),
                "turned off since the control was drawn: open the setup")
        #expect(VoiceNoteStatus.controlAction(shown: .recording, live: VoiceNoteStatus(phase: .notSetUp)) == .open(.settings))
    }

    /// Before the first unlock nothing can be read: the widget shows the plain record button, never an empty box.
    @Test func unknownIsThePlainRecordButton() {
        #expect(VoiceNoteStatus.unknown.action == .start)
        #expect(VoiceNoteStatus.unknown.symbol == "mic.fill")
    }

    /// Ready is the nib (a custom image); every other phase keeps its system symbol.
    @Test func readyDrawsTheNibAndTheOtherPhasesKeepSystemSymbols() {
        #expect(VoiceNoteStatus.unknown.glyph == .custom("SempereNib"))
        #expect(VoiceNoteStatus(phase: .ready).glyph == .custom(VoiceNoteGlyph.nibName))
        for phase in [VoiceNoteStatus.Phase.recording, .saving, .notSetUp, .liveActivitiesOff] {
            let status = VoiceNoteStatus(phase: phase)
            #expect(status.glyph == .system(status.symbol), "\(phase)")
        }
    }

    @Test func linksRoundTripAndIgnoreOtherURLs() throws {
        for link in VoiceNoteLink.allCases {
            #expect(VoiceNoteLink(url: link.url) == link)
        }
        #expect(VoiceNoteLink.settings.url.absoluteString == "sempere://quick-voice/settings")
        #expect(VoiceNoteLink(url: try #require(URL(string: "SEMPERE://Quick-Voice/recording"))) == .recording)
        #expect(VoiceNoteLink(url: try #require(URL(string: "sempere://quick-voice/other"))) == nil)
        #expect(VoiceNoteLink(url: try #require(URL(string: "sempere://elsewhere/settings"))) == nil)
        #expect(VoiceNoteLink(url: URL(fileURLWithPath: "/tmp/My.sempere")) == nil, "a vault opened from Files")
    }

    /// Any other `sempere:` URL (a page or another app can open one) is ignored, never taken for a vault to open
    /// (which failed with an alert).
    @Test func otherAppLinksAreIgnoredNotOpenedAsVaults() throws {
        #expect(VoiceNoteLink.route(VoiceNoteLink.settings.url) == .link(.settings))
        #expect(VoiceNoteLink.route(try #require(URL(string: "sempere://quick-voice/other"))) == .ignore)
        #expect(VoiceNoteLink.route(try #require(URL(string: "SEMPERE://elsewhere"))) == .ignore)
        #expect(VoiceNoteLink.route(URL(fileURLWithPath: "/tmp/My.sempere")) == .file)
    }

    /// The widget's own URL (a tap that did not run the button's intent) is told apart from the other
    /// quick-voice links and from anything else.
    @Test func theWidgetsOwnLinkRoutesAsAWidgetTap() throws {
        #expect(VoiceNoteLink.widgetTapURL.absoluteString == "sempere://quick-voice/widget")
        #expect(VoiceNoteLink.route(VoiceNoteLink.widgetTapURL) == .widgetTap)
        #expect(VoiceNoteLink.route(try #require(URL(string: "SEMPERE://Quick-Voice/widget/"))) == .widgetTap)
        #expect(VoiceNoteLink(url: VoiceNoteLink.widgetTapURL) == nil, "not a place to show")
        #expect(VoiceNoteLink.route(try #require(URL(string: "sempere://quick-voice/widgets"))) == .ignore)
        #expect(VoiceNoteLink.route(try #require(URL(string: "sempere://elsewhere/widget"))) == .ignore)
    }

    /// The Live Activity and the banner keep a result 5 seconds, a failure 12.
    @Test func resultsAreShownFiveSecondsAndFailuresTwelve() {
        #expect(VoiceNoteResult.savedToInbox.shownFor == 5)
        #expect(VoiceNoteResult.savedOnDevice.shownFor == 5)
        #expect(VoiceNoteResult.failed.shownFor == 12)
        #expect(VoiceNoteResult.failed.symbol != VoiceNoteResult.savedToInbox.symbol)
    }

    @Test func storeWritesOnlyChangesAndReadsDefensively() throws {
        let store = VoiceNoteStatusStore(directory: Self.temp())
        #expect(store.read() == nil, "nothing written yet")
        let recording = VoiceNoteStatus(phase: .recording, started: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try store.write(recording))
        #expect(store.read() == recording)
        #expect(try !store.write(recording), "unchanged: no widget reload")
        #expect(try store.write(VoiceNoteStatus(phase: .ready)))

        try Data("not json".utf8).write(to: store.file)
        #expect(store.read() == nil)
        try Data(repeating: 0x20, count: VoiceNoteStatusStore.maxBytes + 1).write(to: store.file)
        #expect(store.read() == nil, "a file larger than any status is not read")
        try Data(#"{"phase":"someday"}"#.utf8).write(to: store.file)
        #expect(store.read() == nil, "an unknown phase")
    }

    /// The Live Activity's state: Stop while recording or paused, the timer only while recording, and the same
    /// JSON as ActivityKit had it before the move (`ContentState` of `VoiceNoteAttributes`).
    @Test func theLiveActivityStateKeepsItsShape() throws {
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(VoiceNoteActivityState(started: t).timerRuns)
        #expect(VoiceNoteActivityState(started: t, paused: true).isRecording)
        #expect(!VoiceNoteActivityState(started: t, paused: true).timerRuns)
        #expect(!VoiceNoteActivityState(started: t, saving: true).isRecording)
        #expect(!VoiceNoteActivityState(started: t, result: .failed).isRecording)
        let state = VoiceNoteActivityState(started: t, paused: true, saving: false, result: .savedOnDevice, ended: t)
        let data = try JSONEncoder().encode(state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["started", "paused", "saving", "result", "ended"])
        #expect(object["result"] as? String == "savedOnDevice")
        #expect(try JSONDecoder().decode(VoiceNoteActivityState.self, from: data) == state)
    }

    // MARK: - The tap log

    @Test func theTapLogKeepsTheNewestAndRefusesWhatIsNotOurs() throws {
        let log = VoiceNoteTapLog(directory: Self.temp("taps"))
        #expect(log.read().isEmpty)
        for i in 0..<(VoiceNoteTapLog.capacity + 3) {
            log.append(VoiceNoteTap(date: Date(timeIntervalSince1970: Double(i)), entry: .controlIntent, process: "app",
                                    decision: .start))
        }
        let kept = log.read()
        #expect(kept.count == VoiceNoteTapLog.capacity)
        #expect(kept.first?.date == Date(timeIntervalSince1970: Double(VoiceNoteTapLog.capacity + 2)))
        // Too large, or not a tap list: nothing, never a trap.
        try Data(repeating: 0x20, count: VoiceNoteTapLog.maxBytes + 1).write(to: log.file)
        #expect(log.read().isEmpty)
        try Data("{\"not\":\"taps\"}".utf8).write(to: log.file)
        #expect(log.read().isEmpty)
        log.clear()
        #expect(!FileManager.default.fileExists(atPath: log.file.path))
    }

    /// A tap kept by an intent says what was shown, what was live and what was decided, nothing personal.
    @Test @MainActor func aTapIsKeptWithTheLiveStateAndItsError() throws {
        struct Failed: Error {}
        let log = VoiceNoteTapLog(directory: Self.temp("taps"))
        let saved = (VoiceNoteActions.tapLog, VoiceNoteActions.status, VoiceNoteActions.appState)
        defer { (VoiceNoteActions.tapLog, VoiceNoteActions.status, VoiceNoteActions.appState) = saved }
        VoiceNoteActions.tapLog = log
        VoiceNoteActions.status = { VoiceNoteStatus(phase: .recording) }
        VoiceNoteActions.appState = { "background" }
        VoiceNoteActions.recordTap(.stopIntent, decision: .stop, shown: "ready", mode: "background", error: Failed())
        let tap = try #require(log.read().first)
        #expect(tap.entry == .stopIntent && tap.decision == .stop && tap.shown == "ready" && tap.live == "recording")
        #expect(tap.appState == "background" && tap.mode == "background" && tap.process == "app")
        #expect(tap.error?.isEmpty == false)
        #expect(tap.summary.hasPrefix("entry=stopIntent process=app shown=ready live=recording decision=stop mode=background app=background error="))
    }
}
