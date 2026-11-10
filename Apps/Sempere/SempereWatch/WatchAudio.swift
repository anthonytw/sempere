import AVFoundation
import Foundation
import Sempere
import SempereCapture

// The watch's microphone (docs/design/1.1-watch.md §3.5): `CaptureAudio`, `CaptureRecorder` and `CaptureRecording` over
// `AVAudioRecorder`, for `WatchRecorder` (SempereCapture). It writes crash-safe ADTS segments (`segment-NNN.aac`, one per
// five minutes) with a manifest beside them, as the phone does; the app's `RecordingSession` is not linked here (it lives in
// `SempereAppCore`). Plaintext audio stays in this folder, protected `completeUntilFirstUserAuthentication`, until it is
// sealed into the outbox.

/// The microphone and the recorder of one start.
@MainActor
final class WatchCaptureAudio: CaptureAudio {
    /// Where the recording's interruptions are heard (tests post to their own).
    var center: NotificationCenter = .default

    func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    var microphonePermission: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    var preferredFormat: RecordingFormat { WatchRecorder.format }

    func makeRecorder() -> any CaptureRecorder { WatchCaptureRecorder(center: center) }
}

/// The audio session of one start: category `.record`, mode `.default`, not mixable (nothing plays on the watch).
@MainActor
final class WatchCaptureRecorder: CaptureRecorder {
    let center: NotificationCenter

    init(center: NotificationCenter) { self.center = center }

    func activateSession(mixable: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        // The watch may show its route picker (Bluetooth) while it activates.
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { _, error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func makeRecording(format: RecordingFormat, root: URL, segmentExtension: String) -> any CaptureRecording {
        WatchCaptureRecording(format: format, root: root, segmentExtension: segmentExtension, center: center)
    }
}

/// One recording: segments of `segmentSeconds`, a manifest, and the timeline across pauses.
///
/// An interruption (a call, Siri, an alarm; `AVAudioSession.interruptionNotification`) ends the segment being written and
/// pauses. When it ends with `shouldResume` the recording goes on in a NEW segment; otherwise it stops and its owner seals
/// what exists (`onStoppedBySystem`). A media server reset stops it the same way. Pause time is not audio.
@MainActor
final class WatchCaptureRecording: CaptureRecording {
    let id = UUID()
    let folder: URL
    private(set) var segments: [URL] = []
    private(set) var timeline = RecordingTimeline()
    private(set) var isActive = false
    private(set) var isPaused = false
    var onStoppedBySystem: (@MainActor () -> Void)?

    /// A new segment starts after this many seconds of audio.
    var segmentSeconds: Double = 300

    private let format: RecordingFormat
    private let segmentExtension: String
    private let center: NotificationCenter
    private var recorder: AVAudioRecorder?
    private var finishedSegments = 0
    private var segmentStartAudio: Double = 0
    private var observers: [NSObjectProtocol] = []
    private var messageObservers: [NotificationCenter.ObservationToken] = []
    private var ticker: Task<Void, Never>?
    private let now: () -> Date

    init(format: RecordingFormat, root: URL, segmentExtension: String, center: NotificationCenter, now: @escaping () -> Date = { Date() }) {
        self.format = format.normalized()
        self.segmentExtension = segmentExtension
        self.center = center
        self.now = now
        folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    // MARK: Start and stop

    func start() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: Self.protection])
        var root = folder.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true   // plaintext audio is never backed up
        try? root.setResourceValues(values)
        try beginSegment()
        timeline.resume(at: now())
        isActive = true
        try? writeManifest()
        observe()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        if !isPaused { recorder?.stop() }
        recorder = nil
        finishedSegments = segments.count
        timeline.stop(at: now())
        isActive = false
        isPaused = false
        endObserving()
        try? writeManifest()
    }

    func discardFiles() { try? FileManager.default.removeItem(at: folder) }

    // MARK: Segments

    private func settings() -> [String: Any] {
        var s: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(format.sampleRate),
                                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        if let b = format.bitRate { s[AVEncoderBitRateKey] = b }
        return s
    }

    private func beginSegment() throws {
        let url = folder.appendingPathComponent(String(format: "segment-%03d.", segments.count + 1) + segmentExtension)
        let r: AVAudioRecorder
        do { r = try AVAudioRecorder(url: url, settings: settings()) } catch { throw WatchAudioError.recorder("\(error)") }
        guard r.record() else { throw WatchAudioError.recorder("the recorder did not start") }
        try? FileManager.default.setAttributes([.protectionKey: Self.protection], ofItemAtPath: url.path)
        recorder = r
        segments.append(url)
        segmentStartAudio = timeline.audioLength(at: now())
        try? writeManifest()
    }

    /// About once a second: starts a new segment when the current one is long enough.
    private func tick() {
        guard isActive, !isPaused, timeline.audioLength(at: now()) - segmentStartAudio >= segmentSeconds else { return }
        recorder?.stop()
        finishedSegments = segments.count
        do { try beginSegment() } catch { stopBySystem() }   // no new file: what exists is complete
    }

    private func stopBySystem() {
        guard isActive else { return }
        stop()
        onStoppedBySystem?()
    }

    // MARK: Interruptions

    private func observe() {
        // An interruption begins when the system deactivates the session and ends with a resumption recommendation (the
        // messages that replace `interruptionNotification` in the OS 27 SDK; the iPhone's `AVAudioSessionEvents` uses them).
        // Only `.shouldResume` resumes.
        let i = center.addObserver(of: AVAudioSession.self, for: .didBecomeInactive) { [weak self] message in
            guard case .systemInterruption = message.deactivationResult else { return }
            MainActor.assumeIsolated { self?.interruptionBegan() }
        }
        let e = center.addObserver(of: AVAudioSession.self, for: .resumptionRecommendation) { [weak self] message in
            let resume = message.recommendation == .shouldResume
            MainActor.assumeIsolated { self?.interruptionEnded(shouldResume: resume) }
        }
        messageObservers = [i, e]
        let m = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopBySystem() }
        }
        observers = [m]
    }

    private func endObserving() {
        ticker?.cancel()
        ticker = nil
        for o in observers { center.removeObserver(o) }
        observers = []
        for o in messageObservers { center.removeObserver(o) }
        messageObservers = []
    }

    private func interruptionBegan() {
        guard isActive, !isPaused else { return }
        recorder?.stop()
        recorder = nil
        finishedSegments = segments.count
        timeline.pause(at: now())
        isPaused = true
        try? writeManifest()
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isActive, isPaused else { return }
        guard shouldResume else { stopBySystem(); return }
        do {
            try beginSegment()
            timeline.resume(at: now())
            isPaused = false
        } catch {
            stopBySystem()
        }
    }

    // MARK: Manifest

    private func writeManifest() throws {
        let manifest = RecordingManifest(note: id, recording: id, started: timeline.started, codec: format.codec.rawValue,
                                         segments: segments.map(\.lastPathComponent), finished: finishedSegments)
        // The default coding: `CaptureSegments.Leftover` reads it back with a plain `JSONDecoder`.
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingManifest.fileName),
                                                     options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum WatchAudioError: Error, Equatable { case recorder(String) }
