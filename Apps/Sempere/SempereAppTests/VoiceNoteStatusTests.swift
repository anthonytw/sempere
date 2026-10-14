import Foundation
import Testing
@testable import SempereApp

/// What the quick voice note widgets, control and Live Activity show
/// (`VoiceNoteStatus`, `VoiceNoteLink`, `VoiceNoteResult`; docs/quick-capture.md).
struct VoiceNoteStatusTests {
    static func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-status-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build 7: the control did nothing until quick voice notes were turned
    /// on, and said nothing. Not set up and Live Activities off now open the
    /// settings; ready records; recording stops.
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
    }

    /// The control decides when tapped, from the live state; a stale Stop
    /// (the recording's process died) never starts a new recording.
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

    /// Before the first unlock nothing can be read: the widget shows the
    /// plain record button, never an empty box.
    @Test func unknownIsThePlainRecordButton() {
        #expect(VoiceNoteStatus.unknown.action == .start)
        #expect(VoiceNoteStatus.unknown.symbol == "mic.fill")
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

    /// Any other `sempere:` URL (a page or another app can open one) is
    /// ignored, never taken for a vault to open (which failed with an alert).
    @Test func otherAppLinksAreIgnoredNotOpenedAsVaults() throws {
        #expect(VoiceNoteLink.route(VoiceNoteLink.settings.url) == .link(.settings))
        #expect(VoiceNoteLink.route(try #require(URL(string: "sempere://quick-voice/other"))) == .ignore)
        #expect(VoiceNoteLink.route(try #require(URL(string: "SEMPERE://elsewhere"))) == .ignore)
        #expect(VoiceNoteLink.route(URL(fileURLWithPath: "/tmp/My.sempere")) == .file)
    }

    @Test func resultsSayWhereTheNoteWent() {
        #expect(QuickCapture.result(for: .vault) == .savedToInbox)
        #expect(QuickCapture.result(for: .queued) == .savedOnDevice)
        #expect(QuickCapture.result(for: nil) == .failed)
        #expect(VoiceNoteResult.savedToInbox.title == "Saved to Inbox")
        #expect(VoiceNoteResult.failed.shownFor > VoiceNoteResult.savedToInbox.shownFor)
    }

    @Test func storeWritesOnlyChangesAndReadsDefensively() throws {
        let dir = Self.temp()
        let store = VoiceNoteStatusStore(directory: dir)
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

    /// The Live Activity's state gained fields: one written by build 7 still decodes.
    @Test func activityStateOfAnEarlierBuildDecodes() throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let old = Data(#"{"started":0,"paused":false}"#.utf8)
        let state = try JSONDecoder().decode(VoiceNoteAttributes.ContentState.self, from: old)
        #expect(state.isRecording)
        #expect(state.result == nil)
        let done = VoiceNoteAttributes.ContentState(started: Date(), result: .savedToInbox, ended: Date())
        #expect(!done.isRecording)
        #endif
    }
}
