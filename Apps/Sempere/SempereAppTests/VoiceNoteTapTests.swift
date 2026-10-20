import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// TestFlight 1.0.0 (6): a tap on the Lock Screen widget opened the app, recorded nothing and left
/// no entry in Settings ▸ Quick Voice Notes ▸ Recent Starts, which kept only starts. Every tap that
/// reaches Sempere is kept now (`VoiceNoteTapLog`), whatever it was decided to do, and a widget tap
/// that opens the app instead of running its intent (`VoiceNoteLink.widgetTapURL`) is kept and then
/// done in the app.
///
/// In `QuickCaptureIntentTests` (serialized): both change the process-wide `VoiceNoteActions`.
extension QuickCaptureIntentTests {
    @Test func everyControlTapIsKeptWithWhatItWasDecidedToDo() async throws {
        let calls = Calls()
        calls.install()
        defer { Self.reset() }

        calls.live = VoiceNoteStatus(phase: .ready)
        _ = try await VoiceNoteControlIntent(shown: .notSetUp).perform()
        calls.live = VoiceNoteStatus(phase: .recording, started: Date(timeIntervalSince1970: 1_000))
        _ = try await VoiceNoteControlIntent(shown: .ready).perform()

        let taps = calls.taps.read()
        #expect(taps.map(\.decision) == [.stop, .start], "newest first")
        let start = try #require(taps.last)
        #expect(start.entry == .controlIntent)
        #expect(start.shown == "notSetUp" && start.live == "ready")
        #expect(start.process == "app" && start.appState == "background")
        #expect(start.mode != nil, "the intent's mode says whether iOS ran it in the background")
        #expect(taps.first?.live == "recording")
        #expect(calls.started == 1 && calls.stopped == 1)
    }

    @Test func startAndStopIntentsKeepTheirTapsAndAFailedStopSaysWhy() async throws {
        let calls = Calls()
        calls.install()
        defer { Self.reset() }
        _ = try await StartVoiceNoteIntent().perform()
        VoiceNoteActions.stop = { throw QuickCaptureError.notRecording }
        await #expect(throws: QuickCaptureError.self) { _ = try await StopVoiceNoteIntent().perform() }
        let taps = calls.taps.read()
        #expect(taps.map(\.entry) == [.stopIntent, .startIntent])
        #expect(taps.first?.error?.isEmpty == false)
        #expect(taps.last?.error == nil)
    }

    /// An intent run where the app's hooks are missing (the widget extension) is kept too.
    @Test func aTapWithoutTheAppsHooksIsKeptAsUnavailable() async throws {
        let calls = Calls()
        defer { Self.reset() }
        Self.reset()
        VoiceNoteActions.tapLog = calls.taps
        await #expect(throws: VoiceNoteIntentError.self) { _ = try await VoiceNoteControlIntent(shown: .ready).perform() }
        await #expect(throws: VoiceNoteIntentError.self) { _ = try await StartVoiceNoteIntent().perform() }
        await #expect(throws: VoiceNoteIntentError.self) { _ = try await StopVoiceNoteIntent().perform() }
        let taps = calls.taps.read()
        #expect(taps.count == 3)
        #expect(taps.allSatisfy { $0.decision == .unavailable && $0.live == nil && $0.appState == nil })
        #expect(taps.first?.summary.contains("decision=unavailable") == true)
    }

    @Test func theTapLogKeepsTheNewestAndRefusesWhatIsNotOurs() throws {
        let dir = TestTemp.root.appendingPathComponent("taps-\(UUID().uuidString)", isDirectory: true)
        let log = VoiceNoteTapLog(directory: dir)
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

    /// The widget's own URL (a tap that did not run the button's intent) is told apart from the
    /// other quick-voice links and from anything else.
    @Test func theWidgetsOwnLinkRoutesAsAWidgetTap() throws {
        #expect(VoiceNoteLink.widgetTapURL.absoluteString == "sempere://quick-voice/widget")
        #expect(VoiceNoteLink.route(VoiceNoteLink.widgetTapURL) == .widgetTap)
        #expect(VoiceNoteLink.route(try #require(URL(string: "SEMPERE://Quick-Voice/widget/"))) == .widgetTap)
        #expect(VoiceNoteLink(url: VoiceNoteLink.widgetTapURL) == nil, "not a place to show")
        #expect(VoiceNoteLink.route(try #require(URL(string: "sempere://quick-voice/widgets"))) == .ignore)
        #expect(VoiceNoteLink.route(try #require(URL(string: "sempere://elsewhere/widget"))) == .ignore)
    }

    /// A widget tap that opened the app records there (the app is in front), and a second one stops.
    @Test func aWidgetTapThatOpenedTheAppRecordsThereAndIsKept() async throws {
        let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        let calls = Calls()
        defer { Self.reset() }
        VoiceNoteActions.tapLog = calls.taps
        VoiceNoteActions.status = { qc.status }
        qc.activitiesEnabled = { true }
        qc.applicationState = { .active }

        await qc.widgetOpenedApp().value
        #expect(qc.state == .recording)
        #expect(qc.recentStarts.first?.outcome == .recording)
        #expect(qc.recentStarts.first?.source == .widgetOrControl)

        await qc.widgetOpenedApp().value
        #expect(qc.state == .idle)
        #expect(QuickCaptureTests.inbox(url).count == 1)

        let taps = calls.taps.read()
        #expect(taps.map(\.entry) == [.widgetOpenedApp, .widgetOpenedApp])
        #expect(taps.map(\.decision) == [.stop, .start])
    }

    /// Not set up: the widget's link shows the setup, as the intent would have.
    @Test func aWidgetTapThatOpenedTheAppBeforeSetupShowsSettings() async throws {
        let (_, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        let calls = Calls()
        defer { Self.reset() }
        VoiceNoteActions.tapLog = calls.taps
        VoiceNoteActions.status = { qc.status }
        qc.activitiesEnabled = { true }
        try qc.store.delete()

        await qc.widgetOpenedApp().value
        #expect(qc.state == .idle)
        #expect(qc.pendingLink == .settings)
        #expect(calls.taps.read().first?.decision == .openSettings)
        #expect(qc.recentStarts.isEmpty)
    }

    /// Settings shows starts and taps together, newest first.
    @Test func recentStartsListsStartsAndTapsByTime() {
        let start = VoiceNoteStartAttempt(date: Date(timeIntervalSince1970: 20), source: .widgetOrControl, intentMode: nil,
                                          first: VoiceNoteStartTry(appState: "background"))
        let older = VoiceNoteTap(date: Date(timeIntervalSince1970: 10), entry: .controlIntent, process: "app", decision: .start)
        let newer = VoiceNoteTap(date: Date(timeIntervalSince1970: 30), entry: .widgetOpenedApp, process: "app", decision: .start)
        let rows = RecentStartsView.rows(attempts: [start], taps: [newer, older])
        #expect(rows.map(\.id) == [newer.id, start.id, older.id])
        for entry in [VoiceNoteTap.Entry.controlIntent, .startIntent, .stopIntent, .widgetOpenedApp] {
            #expect(!RecentStartsView.tapTitle(VoiceNoteTap(date: Date(), entry: entry, process: "app", decision: .start)).isEmpty)
        }
        for decision in [VoiceNoteTap.Decision.start, .stop, .openSettings, .openRecording, .unavailable] {
            #expect(!RecentStartsView.decisionTitle(decision).isEmpty)
        }
    }
}
