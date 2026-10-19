import AVFoundation
import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Audio files made for the tests.
enum TestAudio {
    /// A 2-second 440 Hz tone, AAC in ADTS (what quick voice notes record, `QuickCapture.segmentExtension`),
    /// written once per test run.
    static func adtsTone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-test-tone.aac")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let staging = url.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).aac")
        try write(seconds: 2, to: staging)
        try? FileManager.default.moveItem(at: staging, to: url)
        return url
    }

    /// Writes `seconds` of a tone as AAC into `url` (its extension picks the container) and closes it.
    static func write(seconds: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { throw RecordingError.cannotAssemble("no buffer") }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.3 }
        try file.write(from: buffer)
    }

    /// The first `fraction` of `source`'s bytes in `url`: what a recorder killed mid-file leaves (the cut falls
    /// inside a frame, as a force quit or a restart cuts it).
    static func cut(_ source: URL, to fraction: Double, into url: URL) throws {
        let data = try Data(contentsOf: source)
        try data.prefix(Int(Double(data.count) * fraction) + 3).write(to: url)
    }
}

/// Quick voice notes that a restart, a force quit or the background audio rules got in the way of
/// (TestFlight 1.0.0 (6), iPhone, 2026-10-19; docs/quick-capture.md "Interruptions" and "Start order").
@Suite(.serialized)
@MainActor
struct QuickCaptureRobustnessTests {
    struct Refused: Error {}

    // MARK: - A restart or a force quit while recording

    /// ADTS keeps every frame written before a cut. (An MPEG-4 file whose writer was killed mid-file does not
    /// open at all, "Cannot Open" -11829: measured on macOS 27 by killing an `AVAudioFile` writer with SIGKILL;
    /// cutting a finished file here would not show it, since a finished file has its index.)
    @Test func aCutOffADTSSegmentStillHoldsItsAudio() async throws {
        let dir = QuickCaptureTests.temp("cut")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aac = dir.appendingPathComponent("whole.aac")
        try TestAudio.write(seconds: 2, to: aac)
        let cutAAC = dir.appendingPathComponent("segment-001.aac")
        try TestAudio.cut(aac, to: 0.6, into: cutAAC)
        #expect(await QuickCapture.segmentAudio(cutAAC) == .audio)
        let duration = try await AVURLAsset(url: cutAAC).load(.duration).seconds
        #expect(duration > 0.9 && duration < 1.5, "about 60 % of the 2 s: \(duration)")
    }

    /// Quick voice notes record ADTS segments, and Apple Lossless (which ADTS cannot carry) as AAC.
    @Test func quickVoiceNotesRecordCrashSafeSegments() async throws {
        let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        try await qc.start()
        let segment = try #require(qc.session?.segments.first)
        #expect(segment.pathExtension == "aac")
        #expect(QuickCapture.segmentNumber(segment.lastPathComponent) == 1)
        _ = try await qc.stop()
        #expect(QuickCaptureTests.inbox(url).count == 1)
        let lossless = RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 48_000, channels: 1)
        #expect(QuickCapture.captureFormat(lossless).codec == .aac)
        #expect(QuickCapture.captureFormat(.default) == .default)
    }

    /// One ADTS segment is rewritten as MPEG-4, never copied: the blob says `audio/mp4`.
    @Test func oneADTSSegmentIsMergedIntoMPEG4() async throws {
        let dir = QuickCaptureTests.temp("merge")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("capture.m4a")
        try await RecordingAssembly.merge([try TestAudio.adtsTone()], into: out)
        let bytes = try Data(contentsOf: out)
        #expect(bytes.dropFirst(4).prefix(4) == Data("ftyp".utf8))
        #expect(try await AVURLAsset(url: out).load(.duration).seconds > 1.5)
    }

    /// The whole path after a restart: a recording folder left as the killed recorder left it (a cut-off ADTS
    /// segment, the manifest naming it unfinished) becomes a voice note in the inbox at the next sweep, and the
    /// banner says so.
    @Test func aRecordingCutOffByARestartIsSavedAndSaidSo() async throws {
        let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        let id = UUID()
        let folder = qc.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try RecordingSession.makeFolder(folder, protection: QuickCapture.protection)
        try TestAudio.cut(try TestAudio.adtsTone(), to: 0.5, into: folder.appendingPathComponent("segment-001.aac"))
        let manifest = RecordingManifest(note: UUID(), recording: id, started: Date(), codec: "aac",
                                         segments: ["segment-001.aac"], finished: 0)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))
        await qc.sweep()
        #expect(QuickCaptureTests.inbox(url) == [CaptureFile.name(id, .capture)])
        #expect(QuickCaptureTests.leftovers(qc.root).isEmpty)
        #expect(qc.notice?.title == String(localized: "Interrupted Voice Note Saved"))
        #expect(qc.notice?.result == .savedToInbox)
    }

    /// A recording the sweep cannot save yet (nothing of it decodes) is kept and reported once per launch,
    /// never dropped without a word.
    @Test func aRecordingThatCannotBeSavedYetIsReportedOnce() async throws {
        let (_, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        let id = UUID()
        let folder = qc.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try RecordingSession.makeFolder(folder, protection: QuickCapture.protection)
        try Data(repeating: 0x5A, count: 4096).write(to: folder.appendingPathComponent("segment-001.aac"))
        await qc.sweep()
        #expect(QuickCaptureTests.leftovers(qc.root).count == 1, "kept")
        let notice = try #require(qc.notice)
        #expect(notice.title == String(localized: "Interrupted Voice Note Not Saved Yet") && notice.persists)
        qc.dismissNotice()
        await qc.sweep()
        #expect(qc.notice == nil, "said once per launch")
    }

    /// Stop on a Live Activity whose recording this process does not have (the app was force quit, then the
    /// Stop launched it): no error for the user, and the recording that process left is saved now.
    @Test func stopOnAnOrphanedActivitySavesWhatItsRecordingLeft() async throws {
        let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        let folder = try QuickCaptureTests.crashLeftRecording(in: qc.root)
        await #expect(throws: QuickCaptureError.notRecording) { try await qc.stop() }
        #expect(QuickCaptureTests.inbox(url).count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        // What the intent does with that error: nothing to report.
        VoiceNoteActions.stop = {
            do { _ = try await qc.stop() } catch QuickCaptureError.notRecording {}
        }
        defer { VoiceNoteActions.stop = nil }
        try await VoiceNoteActions.stop?()
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// While recording the Live Activity is sent its state again and again (`activityHeartbeat`), which moves
    /// its stale date on: a process that dies stops doing so, and the activity turns stale ("interrupted").
    @Test func theLiveActivityIsKeptFreshWhileRecording() async throws {
        let (_, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        var recordingStates = 0
        qc.activityStates = { if $0.isRecording { recordingStates += 1 } }
        qc.activityHeartbeat = .milliseconds(100)
        try await qc.start()
        let first = recordingStates
        #expect(await TS.waitUntil(timeout: .seconds(5)) { recordingStates >= first + 3 })
        _ = try await qc.stop()
        let after = recordingStates
        try await Task.sleep(for: .milliseconds(400))
        #expect(recordingStates == after, "no refresh once stopped")
    }
    #endif

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// On the simulator: a voice note Live Activity this process does not own (as one an earlier, force-quit
    /// process left) is ended by `endOrphanedActivities`, and one it owns is kept. (The simulator lists one
    /// voice note activity at a time, so the two cases run one after the other.)
    @Test func orphanedLiveActivitiesAreEnded() async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let old = Date().addingTimeInterval(-600)
        func request() -> Activity<VoiceNoteAttributes>? {
            try? Activity.request(attributes: VoiceNoteAttributes(), content: .init(state: .init(started: old), staleDate: nil))
        }
        // The test host not in front (Live Activities need it): nothing to check here.
        guard let mine = request() else { return }
        ownedActivity.value = mine.id
        defer { ownedActivity.value = nil }
        // The unsigned test host on the iPadOS 27 simulator gets an activity back from `request` that
        // `activities` never lists (2026-10-19): there is nothing this test can check then; on a device it runs.
        guard await TS.waitUntil(timeout: .seconds(3), { Activity<VoiceNoteAttributes>.activities.contains { $0.id == mine.id } }) else {
            print("orphanedLiveActivitiesAreEnded: the host does not list its Live Activities; not checked here")
            return
        }
        #expect(await QuickCapture.shared.endOrphanedActivities() == 0, "this process's recording is kept")
        #expect(mine.activityState == .active)
        // Now it is an orphan: as after a force quit, nothing in this process owns it.
        ownedActivity.value = nil
        #expect(await QuickCapture.shared.endOrphanedActivities() == 1)
        #expect(await TS.waitUntil { !Activity<VoiceNoteAttributes>.activities.contains { $0.id == mine.id && $0.activityState == .active } })
    }
    #endif

    // MARK: - Start order and the audio session (iPhone, iOS 27.0.1)

    /// A capture whose fake recorder logs the session's activation and the Live Activity request in one list.
    @MainActor
    final class Start {
        var state = UIApplication.State.background
        var events: [String] = []
        var backends: [FakeCapture] = []
        let capture: QuickCapture
        let vault: URL
        var continued = 0

        init(refuseNonMixable: Bool = false, refuseMixable: Bool = false) throws {
            let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
            vault = url
            capture = qc
            qc.applicationState = { [unowned self] in state }
            qc.showsActivity = true
            qc.activitiesEnabled = { true }
            qc.requestActivity = { [unowned self] _ in events.append("activity") }
            qc.backend = { [unowned self] in
                let fake = FakeCapture()
                // iOS refuses a non-mixable activation from the background ('!int'); in front it is fine.
                fake.failNonMixableActivation = refuseNonMixable && state != .active
                fake.failMixableActivation = refuseMixable && state != .active
                fake.onActivate = { [unowned self] mixable in events.append(mixable ? "activate-mixable" : "activate") }
                backends.append(fake)
                return fake
            }
            qc.waitUntilActive = { [unowned self] _ in
                state = .active
                return true
            }
        }

        func request() -> VoiceNoteStartRequest {
            VoiceNoteStartRequest(source: .widgetOrControl, intentMode: "background", continueInApp: { [unowned self] in continued += 1 })
        }
    }

    /// The order the iPhone needs: the session is active before the Live Activity is asked for (iOS ends the
    /// intent's fake-foreground assertion when the activity begins), and the recorder starts after both.
    @Test func theSessionIsActiveBeforeTheLiveActivityIsRequested() async throws {
        let start = try Start()
        try await start.capture.start(start.request())
        #expect(start.events == ["activate", "activity"])
        #expect(start.backends.first?.log.prefix(2) == ["activate", "begin"])
        let a = try #require(start.capture.recentStarts.first)
        #expect(a.outcome == .recording && a.first.session == "not mixable")
        _ = try await start.capture.stop()
    }

    /// A background start whose non-mixable activation iOS refuses ('!int' cannotInterruptOthers) records
    /// mixable instead, in the background, and says so in Recent Starts.
    @Test func aRefusedNonMixableActivationRecordsMixable() async throws {
        let start = try Start(refuseNonMixable: true)
        try await start.capture.start(start.request())
        #expect(start.capture.state == .recording)
        #expect(start.continued == 0, "no need to open the app")
        #expect(start.events == ["activate", "activate-mixable", "activity"])
        let a = try #require(start.capture.recentStarts.first)
        #expect(a.outcome == .recording)
        #expect(a.first.session?.hasPrefix("mixable after a refusal") == true)
        #expect(a.first.session?.contains("'!int' cannotInterruptOthers") == true)
        _ = try await start.capture.stop()
        #expect(QuickCaptureTests.inbox(start.vault).count == 1)
    }

    /// Both refused: no Live Activity is asked for in the background, the intent continues in the app, and
    /// the start in front records (non-mixable).
    @Test func bothActivationsRefusedContinueInTheApp() async throws {
        let start = try Start(refuseNonMixable: true, refuseMixable: true)
        try await start.capture.start(start.request())
        #expect(start.continued == 1)
        #expect(start.events == ["activate", "activate-mixable", "activate", "activity"],
                "the background try never asked for the activity; the retry in front did")
        let a = try #require(start.capture.recentStarts.first)
        #expect(a.outcome == .recordingInApp)
        #expect(a.first.error?.description.contains("'!int'") == true, "the first refusal is the one kept")
        #expect(a.first.activity == nil && a.first.session == nil)
        #expect(a.retry?.session == "not mixable")
        _ = try await start.capture.stop()
    }

    /// In front a non-mixable refusal is reported as it is (no mixable fallback for the app's own start).
    @Test func inFrontARefusedActivationIsNotRetriedMixable() async throws {
        let start = try Start()
        start.state = .active
        start.capture.backend = { [start] in
            let fake = FakeCapture()
            fake.failNonMixableActivation = true
            start.backends.append(fake)
            return fake
        }
        await #expect(throws: RecordingError.self) { try await start.capture.start() }
        #expect(start.backends.first?.log == ["activate"])
        #expect(start.capture.state == .idle)
    }

    // MARK: - Siri after a restart

    /// A process launched in the background (Siri after a restart) that reads the microphone permission as not
    /// granted does not say "not allowed": it continues in the app, where the answer is the user's.
    @Test func aBackgroundMicrophoneRefusalIsCheckedAgainInFront() async throws {
        let start = try Start()
        start.capture.microphoneAllowed = { [start] in start.state == .active }
        start.capture.microphonePermission = { [start] in start.state == .active ? "granted" : "undetermined" }
        try await start.capture.start(start.request())
        #expect(start.continued == 1)
        #expect(start.capture.state == .recording)
        let a = try #require(start.capture.recentStarts.first)
        #expect(a.outcome == .recordingInApp)
        #expect(a.first.microphone == "undetermined")
        #expect(a.first.error?.description == QuickCaptureError.microphoneUnconfirmed.description)
        #expect(a.retry?.microphone == "granted")
        _ = try await start.capture.stop()
    }

    /// In front, a refused microphone is the user's choice: said as it is.
    @Test func inFrontARefusedMicrophoneIsDenied() async throws {
        let start = try Start()
        start.state = .active
        start.capture.microphoneAllowed = { false }
        await #expect(throws: QuickCaptureError.microphoneDenied) { try await start.capture.start() }
    }

    /// Before the first unlock after a restart the profile cannot be read: Siri says to unlock once.
    @Test func beforeTheFirstUnlockSiriSaysToUnlockOnce() async throws {
        let start = try Start()
        start.capture.store = FailingCaptureProfileStore()
        start.capture.protectedDataAvailable = { false }
        await #expect(throws: QuickCaptureError.beforeFirstUnlock) { try await start.capture.start(start.request()) }
        #expect(start.continued == 0)
        #expect(start.capture.recentStarts.first?.first.protectedData == false)
        // After the unlock, an unreadable profile is reported as such.
        start.capture.protectedDataAvailable = { true }
        await #expect(throws: QuickCaptureError.profileUnreadable) { try await start.capture.start(start.request()) }
    }

    /// Starts kept by a launch that could not read the file (before the first unlock) are merged with it, not
    /// written over it.
    @Test func theStartLogMergesWhatItCouldNotReadAtLaunch() throws {
        let url = QuickCaptureTests.temp("start-log-merge").appendingPathComponent("recent-starts.json")
        // A launch that read the file while it could not (before the first unlock): it holds nothing.
        let launchedLocked = VoiceNoteStartLog(url: url)
        let earlier = VoiceNoteStartLog(url: url)
        earlier.append(VoiceNoteStartAttempt(date: Date(timeIntervalSince1970: 1), source: .shortcut,
                                             first: VoiceNoteStartTry(appState: "background")))
        launchedLocked.append(VoiceNoteStartAttempt(date: Date(timeIntervalSince1970: 2), source: .widgetOrControl,
                                                    first: VoiceNoteStartTry(appState: "background")))
        #expect(VoiceNoteStartLog(url: url).attempts.map(\.date.timeIntervalSince1970) == [2, 1])
    }
}
