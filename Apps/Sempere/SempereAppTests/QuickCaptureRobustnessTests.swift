import AVFoundation
import Foundation
import Sempere
import SempereAppCore
import SempereCaptureShared
import Testing
import UIKit
@testable import SempereApp
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Audio files made for the tests.
enum TestAudio {
    /// A 2-second 440 Hz tone, AAC in ADTS (what quick voice notes record, `CaptureSegments.segmentExtension`),
    /// written once per test run.
    static func adtsTone() throws -> URL {
        let url = TestTemp.root.appendingPathComponent("sempere-test-tone.aac")
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

/// Quick voice notes that a restart or a force quit got in the way of (TestFlight 1.0.0 (6), iPhone, 2026-10-19;
/// docs/quick-capture.md "Interruptions"), on the app's recorder, AVFoundation and ActivityKit. The start order, the
/// background refusals and the banner's reports run on Linux with fakes: `QuickCaptureStartTests` (SempereAppCoreTests).
@Suite(.serialized)
@MainActor
struct QuickCaptureRobustnessTests {
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
        #expect(await AVCaptureAudioFiles().classify(cutAAC) == .audio)
        let duration = try await AVURLAsset(url: cutAAC).load(.duration).seconds
        #expect(duration > 0.9 && duration < 1.5, "about 60 % of the 2 s: \(duration)")
    }

    /// Quick voice notes record ADTS segments, and Apple Lossless (which ADTS cannot carry) as AAC.
    @Test func quickVoiceNotesRecordCrashSafeSegments() async throws {
        let (url, _, _, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        try await qc.start()
        let segment = try #require(qc.session?.segments.first)
        #expect(segment.pathExtension == "aac")
        #expect(CaptureSegments.number(segment.lastPathComponent) == 1)
        _ = try await qc.stop()
        #expect(QuickCaptureTests.inbox(url).count == 1)
        let lossless = RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 48_000, channels: 1)
        #expect(CaptureSegments.captureFormat(lossless).codec == .aac)
        #expect(CaptureSegments.captureFormat(.default) == .default)
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

}
