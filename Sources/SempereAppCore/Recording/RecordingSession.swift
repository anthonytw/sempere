import Foundation
import Observation
import Sempere

/// One recording being made into a note (docs/attachments.md §9, §13).
///
/// Audio is written in segments of `segmentSeconds` (10 minutes): a crash
/// loses at most the segment being written, and `RecordingRecovery` saves the
/// rest the next time the note opens. The `RecordingTimeline` maps wall time
/// to audio time across interruptions, so strokes drawn during the recording
/// get `rec.at` in audio seconds.
///
/// Interruptions (a call, Siri, another app taking the audio session) pause
/// the recording; when the interruption ends with "should resume" it goes on
/// in the same file, otherwise it stays paused until Resume. A headset
/// unplugged pauses it too. Plaintext audio lives in the app's own folder,
/// protected `completeUnlessOpen` by default (written while locked, unreadable
/// once closed until the device is unlocked), and is deleted once the
/// encrypted blob is written. Quick voice notes, which must also be read and
/// sealed while the device stays locked, pass `completeUntilFirstUserAuthentication`.
///
/// The microphone is the `AudioCaptureBackend`'s and the system's word of interruptions the `RecordingSystemEvents`'
/// (the app: `AVAudioCaptureBackend`, `AVAudioSessionEvents`); everything else is here, and tested with fakes.
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable {
        case recording
        /// Paused by an interruption or a route change; may resume by itself.
        case interrupted
        /// Paused by the user.
        case paused
        case stopped
        case failed(String)
    }

    /// The recording's id (strokes drawn meanwhile link to it).
    public let id: UUID
    public let noteID: UUID
    public let format: RecordingFormat
    public private(set) var state: State = .stopped
    public private(set) var timeline = RecordingTimeline()
    /// Seconds recorded, refreshed while recording (for the UI).
    public private(set) var elapsed: Double = 0
    /// This session's folder (segments and manifest).
    public let folder: URL
    public private(set) var segments: [URL] = []
    @ObservationIgnored private var finishedSegments = 0
    @ObservationIgnored private var segmentStartAudio: Double = 0
    @ObservationIgnored private let backend: AudioCaptureBackend
    @ObservationIgnored private let events: any RecordingSystemEvents
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// A new segment starts after this many seconds of audio.
    @ObservationIgnored public var segmentSeconds: Double = 600
    /// The segment files' extension, which picks their container (`AVAudioRecorder` goes by it):
    /// `m4a` (MPEG-4, unreadable if the app dies before the file is finished), or `aac` (ADTS, AAC
    /// only: every frame stands alone, so a file cut off by a crash, a force quit or a restart is
    /// readable up to its last frame). Quick voice notes use `aac` (`CaptureSegments.segmentExtension`).
    public let segmentExtension: String
    /// Called when the session stops by itself (the media server was reset,
    /// or no new segment file could be started): its owner saves what was
    /// recorded, as after `stop`.
    @ObservationIgnored public var onStoppedBySystem: (@MainActor () -> Void)?
    /// The vault and epoch id the recording started under (`CaptureRecording.bind`), kept in the manifest.
    @ObservationIgnored private var bound: (vault: UUID, epochId: String)?

    public func bind(vault: UUID, epochId: String) { bound = (vault, epochId) }

    /// The session recording now, app-wide (the audio session is shared).
    public static weak var active: RecordingSession?
    /// Sessions whose files are still in use after they stopped (being
    /// saved or transcribed): recovery leaves them alone.
    public static var busy: Set<UUID> = []

    /// Where sessions keep their files: Application Support, not backed up.
    public nonisolated static var root: URL { AppSupport.folder("Recordings") }

    /// The Data Protection class of the session's files (iOS).
    public let protection: FileProtectionType

    public init(noteID: UUID, format: RecordingFormat, root: URL = RecordingSession.root,
                protection: FileProtectionType = .completeUnlessOpen, segmentExtension: String = "m4a",
                backend: AudioCaptureBackend, events: any RecordingSystemEvents, now: @escaping () -> Date = { Date() }) {
        id = UUID()
        self.protection = protection
        self.segmentExtension = segmentExtension
        self.noteID = noteID
        self.format = format.normalized()
        folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        self.backend = backend
        self.events = events
        self.now = now
    }

    public var isActive: Bool { state == .recording || state == .interrupted || state == .paused }

    /// Paused by an interruption, a route change or the user.
    public var isPaused: Bool { state == .interrupted || state == .paused }

    /// The `rec` link of something written at `wall` (format.md §8.3.3).
    public func link(at wall: Date) -> RecordingLink? { timeline.link(id, at: wall) }

    /// A value copy that stamps strokes off this session's timeline as it is now.
    public var stamp: @Sendable (Date) -> RecordingLink? {
        let tl = timeline, id = self.id
        return { tl.link(id, at: $0) }
    }

    /// Starts recording. Throws `alreadyRecording` when another session runs.
    public func start() throws {
        if let other = Self.active, other !== self, other.isActive { throw RecordingError.alreadyRecording }
        try Self.makeFolder(folder, protection: protection)
        try beginSegment()
        timeline.resume(at: now())
        state = .recording
        Self.active = self
        try? writeManifest()
        observe()
        startTicker()
    }

    private func beginSegment() throws {
        let url = folder.appendingPathComponent(String(format: "segment-%03d.", segments.count + 1) + segmentExtension)
        try backend.begin(file: url, format: format)
        segments.append(url)
        segmentStartAudio = timeline.audioLength(at: now())
        try? writeManifest()
    }

    public func pauseByUser() {
        guard state == .recording || state == .interrupted else { return }
        if state == .recording { backend.pause(); timeline.pause(at: now()) }
        state = .paused
    }

    public func resumeByUser() {
        guard state == .paused || state == .interrupted else { return }
        resumeNow()
    }

    private func resumeNow() {
        do {
            try backend.resume()
            timeline.resume(at: now())
            state = .recording
        } catch {
            state = .interrupted   // the user can try Resume again
        }
    }

    /// An audio session interruption began (`true`) or ended.
    public func interruption(began: Bool, shouldResume: Bool) {
        if began {
            guard state == .recording else { return }
            backend.pause()
            timeline.pause(at: now())
            state = .interrupted
        } else if state == .interrupted && shouldResume {
            resumeNow()
        }
    }

    /// The audio route changed; a headset that went away pauses the recording.
    public func routeChanged(oldDeviceUnavailable: Bool) {
        guard oldDeviceUnavailable, state == .recording else { return }
        backend.pause()
        timeline.pause(at: now())
        state = .interrupted
    }

    /// Stops recording; the segment files are complete afterwards.
    public func stop() {
        guard isActive else { return }
        backend.finish()
        finishedSegments = segments.count
        timeline.stop(at: now())
        elapsed = timeline.audioLength(at: now())
        state = .stopped
        backend.deactivate()
        try? writeManifest()
        end()
    }

    /// `stop`, then `onStoppedBySystem`: the session ended without the user.
    public func stopBySystem() {
        guard isActive else { return }
        stop()
        onStoppedBySystem?()
    }

    /// Marks the session failed (nothing to save) and releases the microphone.
    public func fail(_ why: String) {
        backend.finish()
        backend.deactivate()
        state = .failed(why)
        end()
    }

    private func end() {
        ticker?.cancel()
        ticker = nil
        events.stop()
        if Self.active === self { Self.active = nil }
    }

    /// Deletes the session's files (after they were saved into the vault).
    public func discardFiles() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Called about once a second while active: updates `elapsed` and
    /// starts a new segment when the current one is long enough.
    public func tick() {
        let t = now()
        elapsed = timeline.audioLength(at: t)
        guard state == .recording, elapsed - segmentStartAudio >= segmentSeconds else { return }
        backend.finish()
        finishedSegments = segments.count
        do { try beginSegment() } catch {
            // No new file: stop here; what was recorded is complete and is saved.
            timeline.stop(at: t)
            state = .stopped
            backend.deactivate()
            try? writeManifest()
            end()
            onStoppedBySystem?()
        }
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func observe() {
        events.start(RecordingSystemHandlers(
            interruption: { [weak self] began, shouldResume in self?.interruption(began: began, shouldResume: shouldResume) },
            routeChanged: { [weak self] gone in self?.routeChanged(oldDeviceUnavailable: gone) },
            // The recorder is gone with the media server: what was written up to now is kept and saved.
            mediaServicesReset: { [weak self] in self?.stopBySystem() }))
    }

    public var manifest: RecordingManifest {
        RecordingManifest(note: noteID, recording: id, started: timeline.started, codec: format.codec.rawValue,
                          segments: segments.map(\.lastPathComponent), finished: finishedSegments,
                          vault: bound?.vault, epochId: bound?.epochId)
    }

    private func writeManifest() throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: folder.appendingPathComponent(RecordingRecovery.manifestName),
                       options: [.atomic, Self.writingOption(protection)])
    }

    /// The `Data.write` option of a protection class.
    public nonisolated static func writingOption(_ protection: FileProtectionType) -> Data.WritingOptions {
        // By raw value: `FileProtectionType` is not `Equatable` everywhere.
        switch protection.rawValue {
        case FileProtectionType.completeUnlessOpen.rawValue: return .completeFileProtectionUnlessOpen
        case FileProtectionType.completeUntilFirstUserAuthentication.rawValue: return .completeFileProtectionUntilFirstUserAuthentication
        default: return .completeFileProtection
        }
    }

    public nonisolated static func makeFolder(_ url: URL, protection: FileProtectionType = .completeUnlessOpen) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: protection])
        var root = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }
}

/// The recording quick capture drives (`QuickCapture`; `AppCaptureRecorder` makes it).
extension RecordingSession: CaptureRecording {}
