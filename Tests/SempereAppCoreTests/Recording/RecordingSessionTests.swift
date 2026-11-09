import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// Writes a small file for each segment instead of recording: the segments, the manifest and their assembly are the
/// real ones, and no microphone is needed (the app's `AVAudioCaptureBackend` is tested in the app).
@MainActor
final class FakeCapture: AudioCaptureBackend {
    var log: [String] = []
    var files: [URL] = []
    var failResume = false
    var failBegin = false

    func activateSession(mixable: Bool) async throws { log.append(mixable ? "activate-mixable" : "activate") }

    func begin(file url: URL, format: RecordingFormat) throws {
        log.append("begin")
        if failBegin { throw RecordingError.cannotRecord("test") }
        try Data("audio \(files.count + 1)\n".utf8).write(to: url)
        files.append(url)
    }
    func pause() { log.append("pause") }
    func resume() throws {
        log.append("resume")
        if failResume { throw RecordingError.cannotRecord("test") }
    }
    func finish() { log.append("finish") }
    func deactivate() { log.append("deactivate") }
}

/// Stands in for the audio session's notifications: the test sends what the system would.
@MainActor
final class FakeSystemEvents: RecordingSystemEvents {
    private(set) var handlers: RecordingSystemHandlers?
    private(set) var starts = 0, stops = 0
    func start(_ handlers: RecordingSystemHandlers) { self.handlers = handlers; starts += 1 }
    func stop() { handlers = nil; stops += 1 }
}

/// The recording session's state machine (pause, resume, interruption, segments, file layout) on a fake backend.
/// Serialized: one recording runs at a time app-wide (`RecordingSession.active`).
@Suite(.serialized)
@MainActor
struct RecordingSessionTests {
    static let note = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    static func root() -> URL {
        TestTemp.root.appendingPathComponent("rec-" + UUID().uuidString, isDirectory: true)
    }

    static func session(_ clock: CaptureClock, backend: FakeCapture, events: FakeSystemEvents = FakeSystemEvents(),
                        protection: FileProtectionType = .completeUnlessOpen, segmentExtension: String = "m4a") -> RecordingSession {
        RecordingSession(noteID: note, format: .default, root: root(), protection: protection, segmentExtension: segmentExtension,
                         backend: backend, events: events, now: { clock.now })
    }

    /// A call pauses the recorder, the end of the call resumes it in the same file, and the audio timeline leaves
    /// the interruption out.
    @Test func interruptionPausesAndResumesTheSameRecording() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        try s.start()
        defer { s.stop(); s.discardFiles() }
        #expect(s.state == .recording && s.isActive && !s.isPaused)
        clock.advance(5)
        s.interruption(began: true, shouldResume: false)
        #expect(s.state == .interrupted && s.isPaused)
        clock.advance(30)   // the call
        s.interruption(began: false, shouldResume: true)
        #expect(s.state == .recording)
        clock.advance(2)
        #expect(backend.log == ["begin", "pause", "resume"])
        #expect(backend.files.count == 1, "the same file goes on")
        #expect(abs(s.timeline.audioLength(at: clock.now) - 7) < 0.001)
        s.stop()
        #expect(s.state == .stopped)
        #expect(backend.log.suffix(2) == ["finish", "deactivate"])
        #expect(RecordingSession.active == nil)
        #expect(abs(s.elapsed - 7) < 0.001)
    }

    @Test func interruptionWithoutShouldResumeWaitsForTheUser() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        try s.start()
        defer { s.stop(); s.discardFiles() }
        s.interruption(began: true, shouldResume: false)
        s.interruption(began: false, shouldResume: false)
        #expect(s.state == .interrupted)
        s.resumeByUser()
        #expect(s.state == .recording)
        s.routeChanged(oldDeviceUnavailable: false)
        #expect(s.state == .recording, "only a device that went away pauses")
        s.routeChanged(oldDeviceUnavailable: true)   // the headset was unplugged
        #expect(s.state == .interrupted)
        backend.failResume = true
        s.resumeByUser()
        #expect(s.state == .interrupted, "a refused resume stays paused")
        backend.failResume = false
        s.interruption(began: false, shouldResume: true)
        #expect(s.state == .recording, "the end of an interruption that recommends it resumes")
    }

    /// The user's pause is the user's: an interruption ending does not resume it, Resume does; a pause during an
    /// interruption leaves the recorder paused once.
    @Test func pausingByTheUser() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        try s.start()
        defer { s.stop(); s.discardFiles() }
        clock.advance(3)
        s.pauseByUser()
        #expect(s.state == .paused && s.isPaused)
        clock.advance(10)
        s.interruption(began: true, shouldResume: false)
        s.interruption(began: false, shouldResume: true)
        #expect(s.state == .paused, "an interruption does not touch a pause by the user")
        s.resumeByUser()
        clock.advance(2)
        #expect(s.state == .recording)
        #expect(backend.log == ["begin", "pause", "resume"])
        #expect(abs(s.timeline.audioLength(at: clock.now) - 5) < 0.001)
        s.interruption(began: true, shouldResume: false)
        s.pauseByUser()   // the user pauses an interrupted recording: already paused, no second pause
        #expect(s.state == .paused)
        #expect(backend.log == ["begin", "pause", "resume", "pause"])
    }

    @Test func onlyOneRecordingAtATime() throws {
        let clock = CaptureClock()
        let a = Self.session(clock, backend: FakeCapture()), b = Self.session(clock, backend: FakeCapture())
        try a.start()
        defer { a.stop(); a.discardFiles() }
        #expect(throws: RecordingError.alreadyRecording) { try b.start() }
        #expect(b.state == .stopped)
    }

    /// `rec.at` within 0.1 s: ink drawn while recording carries the recording id and its time in the audio, across
    /// an interruption (the stamp is a value copy: it knows the timeline as it was).
    @Test func linksCarryTheAudioTimeAcrossAnInterruption() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        let t0 = clock.now
        try s.start()
        defer { s.stop(); s.discardFiles() }
        clock.advance(2); s.interruption(began: true, shouldResume: false)
        clock.advance(8); s.resumeByUser()   // 8 s not recorded
        clock.advance(5)
        let stamp = s.stamp
        let early = try #require(stamp(t0.addingTimeInterval(1.25)))
        let late = try #require(stamp(t0.addingTimeInterval(14.5)))
        #expect(early.id == s.id && abs(early.at - 1.25) < 0.1)
        #expect(abs(late.at - 6.5) < 0.1, "14.5 s of wall time less the 8 s interruption")
        #expect(stamp(t0.addingTimeInterval(-60)) == nil, "drawn before the recording")
        #expect(s.link(at: t0.addingTimeInterval(14.5)) == late)
    }

    /// Segment files are `segment-NNN.<extension>` in the session's folder, with a manifest that says which are
    /// finished: the layout recovery and quick capture read back.
    @Test func segmentsRotateAndTheManifestFollows() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend, segmentExtension: "aac")
        s.segmentSeconds = 1
        try s.start()
        defer { s.discardFiles() }
        let manifestURL = s.folder.appendingPathComponent(RecordingRecovery.manifestName)
        var manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.segments == ["segment-001.aac"] && manifest.finished == 0)
        #expect(manifest.note == Self.note && manifest.recording == s.id && manifest.codec == "aac")
        clock.advance(0.5)
        s.tick()
        #expect(s.segments.count == 1, "not long enough yet")
        clock.advance(1)
        s.tick()
        #expect(s.segments.count == 2)
        #expect(backend.log == ["begin", "finish", "begin"])
        #expect(s.segments.map(\.lastPathComponent) == ["segment-001.aac", "segment-002.aac"])
        #expect(s.segments.allSatisfy { $0.deletingLastPathComponent() == s.folder })
        manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.segments.count == 2 && manifest.finished == 1)
        s.stop()
        manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.finished == 2)
        #expect(s.folder.deletingLastPathComponent().lastPathComponent.hasPrefix("rec-"))
        #expect(s.folder.lastPathComponent == s.id.uuidString.lowercased())
    }

    /// No new segment file could be started: the session stops with what was recorded, and its owner hears of it.
    @Test func aSegmentThatCannotStartStopsTheSession() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        s.segmentSeconds = 0
        var stopped = 0
        s.onStoppedBySystem = { stopped += 1 }
        try s.start()
        defer { s.discardFiles() }
        backend.failBegin = true
        s.tick()
        #expect(s.state == .stopped && stopped == 1)
        #expect(backend.log.suffix(2) == ["begin", "deactivate"])
        #expect(RecordingSession.active == nil)
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: s.folder.appendingPathComponent("manifest.json")))
        #expect(manifest.finished == 1, "the segment that was recorded is complete")
    }

    @Test func startFailureLeavesNothingActive() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        backend.failBegin = true
        let s = Self.session(clock, backend: backend)
        #expect(throws: RecordingError.cannotRecord("test")) { try s.start() }
        defer { s.discardFiles() }
        #expect(s.state == .stopped && RecordingSession.active == nil)
    }

    @Test func failingReleasesTheMicrophone() throws {
        let clock = CaptureClock(), backend = FakeCapture()
        let s = Self.session(clock, backend: backend)
        try s.start()
        defer { s.discardFiles() }
        s.fail("gone")
        #expect(s.state == .failed("gone") && !s.isActive)
        #expect(backend.log.suffix(2) == ["finish", "deactivate"])
        #expect(RecordingSession.active == nil)
    }

    /// The system's words reach the session through `RecordingSystemEvents`, from `start` to `stop`.
    @Test func systemEventsDriveTheSession() throws {
        let clock = CaptureClock(), backend = FakeCapture(), events = FakeSystemEvents()
        let s = Self.session(clock, backend: backend, events: events)
        try s.start()
        defer { s.discardFiles() }
        let h = try #require(events.handlers)
        #expect(events.starts == 1)
        h.interruption(true, false)
        #expect(s.state == .interrupted)
        h.interruption(false, true)
        #expect(s.state == .recording)
        h.routeChanged(true)
        #expect(s.state == .interrupted)
        var stopped = 0
        s.onStoppedBySystem = { stopped += 1 }
        h.mediaServicesReset()   // the recorder is gone: what was written is kept
        #expect(s.state == .stopped && stopped == 1)
        #expect(events.stops == 1 && events.handlers == nil, "the session stops listening when it ends")
        s.stopBySystem()
        #expect(stopped == 1, "a stopped session has nothing more to report")
    }

    /// The files are protected in the class asked for, and made in the session's folder under the root.
    @Test func filesAreProtectedInTheClassAskedFor() throws {
        #expect(RecordingSession.writingOption(.completeUnlessOpen) == .completeFileProtectionUnlessOpen)
        #expect(RecordingSession.writingOption(.completeUntilFirstUserAuthentication) == .completeFileProtectionUntilFirstUserAuthentication)
        #expect(RecordingSession.writingOption(.complete) == .completeFileProtection)
        let clock = CaptureClock()
        let s = Self.session(clock, backend: FakeCapture(), protection: .completeUntilFirstUserAuthentication)
        #expect(s.protection.rawValue == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        try s.start()
        defer { s.stop(); s.discardFiles() }
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("manifest.json").path))
        s.discardFiles()
        #expect(!FileManager.default.fileExists(atPath: s.folder.path))
    }
}
