import AVFoundation
import Foundation
import Observation
import Sempere

/// What writes microphone audio into files: `AVAudioRecorder` in the app,
/// a fake in tests. One file at a time; `finish` leaves it complete and
/// playable.
@MainActor
protocol AudioCaptureBackend: AnyObject {
    /// Starts writing a new file at `url` in `format`.
    func begin(file url: URL, format: RecordingFormat) throws
    /// Stops writing for now (an interruption); `resume` appends to the same file.
    func pause()
    func resume() throws
    /// Ends the current file.
    func finish()
    /// Lets other apps' audio play again (the recording is over).
    func deactivate()
}

/// Why recording could not start or go on.
enum RecordingError: Error, Equatable, CustomStringConvertible {
    /// The microphone is not allowed (Settings ▸ Privacy ▸ Microphone).
    case microphoneDenied
    /// Another note is recording.
    case alreadyRecording
    /// The note cannot be edited.
    case notEditable
    /// The audio system refused.
    case cannotRecord(String)
    /// The recorded audio could not be assembled into one file.
    case cannotAssemble(String)

    var description: String {
        switch self {
        case .microphoneDenied: return String(localized: "Sempere is not allowed to use the microphone. Allow it in Settings ▸ Privacy & Security ▸ Microphone.")
        case .alreadyRecording: return String(localized: "Another note is recording. Stop that recording first.")
        case .notEditable: return String(localized: "This note cannot be edited.")
        case .cannotRecord(let why): return String(localized: "Could not record: \(why)")
        case .cannotAssemble(let why): return String(localized: "Could not save the recording: \(why)")
        }
    }
}

/// `AudioCaptureBackend` with `AVAudioRecorder` and the shared audio
/// session (docs/attachments.md §13 "Audio recording"): `.playAndRecord`,
/// speaker and Bluetooth headsets allowed. `UIBackgroundModes: audio` keeps
/// it running with the screen locked or the app in the background.
@MainActor
final class AVAudioCaptureBackend: AudioCaptureBackend {
    private var recorder: AVAudioRecorder?

    /// `AVAudioRecorder` settings for `format` (docs/attachments.md §13).
    static func settings(_ format: RecordingFormat, inputChannels: Int) -> [String: Any] {
        let id: AudioFormatID
        switch format.codec {
        case .aac: id = kAudioFormatMPEG4AAC
        case .heAAC: id = kAudioFormatMPEG4AAC_HE
        case .alac: id = kAudioFormatAppleLossless
        }
        var s: [String: Any] = [
            AVFormatIDKey: id,
            AVSampleRateKey: Double(format.sampleRate),
            // Stereo only with a stereo input (docs/attachments.md §9).
            AVNumberOfChannelsKey: min(format.channels, max(inputChannels, 1)),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        if let b = format.bitRate { s[AVEncoderBitRateKey] = b }
        if format.codec == .alac { s[AVEncoderBitDepthHintKey] = 16 }
        return s
    }

    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            throw RecordingError.cannotRecord(error.localizedDescription)
        }
    }

    func begin(file url: URL, format: RecordingFormat) throws {
        try activate()
        let channels = AVAudioSession.sharedInstance().inputNumberOfChannels
        let r: AVAudioRecorder
        do { r = try AVAudioRecorder(url: url, settings: Self.settings(format, inputChannels: channels)) } catch {
            throw RecordingError.cannotRecord(error.localizedDescription)
        }
        guard r.record() else { throw RecordingError.cannotRecord("the recorder did not start") }
        recorder = r
    }

    func pause() { recorder?.pause() }

    func resume() throws {
        try activate()
        guard recorder?.record() == true else { throw RecordingError.cannotRecord("the recorder did not resume") }
    }

    func finish() {
        recorder?.stop()
        recorder = nil
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Asks for the microphone once; false when it is refused.
    static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

/// On disk, next to a session's audio: enough to save what was recorded if
/// the app is killed before the recording is stopped (`RecordingRecovery`).
struct RecordingManifest: Codable, Equatable {
    var note: UUID
    var recording: UUID
    var started: Date?
    var codec: String
    /// Segment file names in order; the last may be unfinished.
    var segments: [String]
    /// Segments known to be complete.
    var finished: Int
}

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
@MainActor
@Observable
final class RecordingSession {
    enum State: Equatable {
        case recording
        /// Paused by an interruption or a route change; may resume by itself.
        case interrupted
        /// Paused by the user.
        case paused
        case stopped
        case failed(String)
    }

    /// The recording's id (strokes drawn meanwhile link to it).
    let id: UUID
    let noteID: UUID
    let format: RecordingFormat
    private(set) var state: State = .stopped
    private(set) var timeline = RecordingTimeline()
    /// Seconds recorded, refreshed while recording (for the UI).
    private(set) var elapsed: Double = 0
    /// This session's folder (segments and manifest).
    let folder: URL
    private(set) var segments: [URL] = []
    @ObservationIgnored private var finishedSegments = 0
    @ObservationIgnored private var segmentStartAudio: Double = 0
    @ObservationIgnored private let backend: AudioCaptureBackend
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var messageObservers: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let center: NotificationCenter
    /// A new segment starts after this many seconds of audio.
    @ObservationIgnored var segmentSeconds: Double = 600
    /// Called when the session stops by itself (the media server was reset,
    /// or no new segment file could be started): its owner saves what was
    /// recorded, as after `stop`.
    @ObservationIgnored var onStoppedBySystem: (@MainActor () -> Void)?

    /// The session recording now, app-wide (the audio session is shared).
    static weak var active: RecordingSession?
    /// Sessions whose files are still in use after they stopped (being
    /// saved or transcribed): recovery leaves them alone.
    static var busy: Set<UUID> = []

    /// Where sessions keep their files: Application Support, not backed up.
    nonisolated static var root: URL { AppSupport.folder("Recordings") }

    /// The Data Protection class of the session's files (iOS).
    let protection: FileProtectionType

    init(noteID: UUID, format: RecordingFormat, root: URL = RecordingSession.root,
         protection: FileProtectionType = .completeUnlessOpen,
         backend: AudioCaptureBackend? = nil, center: NotificationCenter = .default, now: @escaping () -> Date = { Date() }) {
        id = UUID()
        self.protection = protection
        self.noteID = noteID
        self.format = format.normalized()
        folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        self.backend = backend ?? AVAudioCaptureBackend()
        self.center = center
        self.now = now
    }

    var isActive: Bool { state == .recording || state == .interrupted || state == .paused }

    /// The `rec` link of something written at `wall` (format.md §8.3.3).
    func link(at wall: Date) -> RecordingLink? { timeline.link(id, at: wall) }

    /// A value copy that stamps strokes off this session's timeline as it is now.
    var stamp: @Sendable (Date) -> RecordingLink? {
        let tl = timeline, id = self.id
        return { tl.link(id, at: $0) }
    }

    /// Starts recording. Throws `alreadyRecording` when another session runs.
    func start() throws {
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
        let url = folder.appendingPathComponent(String(format: "segment-%03d.m4a", segments.count + 1))
        try backend.begin(file: url, format: format)
        segments.append(url)
        segmentStartAudio = timeline.audioLength(at: now())
        try? writeManifest()
    }

    func pauseByUser() {
        guard state == .recording || state == .interrupted else { return }
        if state == .recording { backend.pause(); timeline.pause(at: now()) }
        state = .paused
    }

    func resumeByUser() {
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
    func interruption(began: Bool, shouldResume: Bool) {
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
    func routeChanged(oldDeviceUnavailable: Bool) {
        guard oldDeviceUnavailable, state == .recording else { return }
        backend.pause()
        timeline.pause(at: now())
        state = .interrupted
    }

    /// Stops recording; the segment files are complete afterwards.
    func stop() {
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
    func stopBySystem() {
        guard isActive else { return }
        stop()
        onStoppedBySystem?()
    }

    /// Marks the session failed (nothing to save) and releases the microphone.
    func fail(_ why: String) {
        backend.finish()
        backend.deactivate()
        state = .failed(why)
        end()
    }

    private func end() {
        ticker?.cancel()
        ticker = nil
        for o in observers { center.removeObserver(o) }
        observers = []
        for o in messageObservers { center.removeObserver(o) }
        messageObservers = []
        if Self.active === self { Self.active = nil }
    }

    /// Deletes the session's files (after they were saved into the vault).
    func discardFiles() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Called about once a second while active: updates `elapsed` and
    /// starts a new segment when the current one is long enough.
    func tick() {
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

    /// Whether a deactivation of the audio session interrupts the recording:
    /// only one the system made; the app's own (`setActive(false)` after a
    /// stop) does not.
    nonisolated static func interrupts(_ result: AVAudioSession.DeactivationResult) -> Bool {
        if case .systemInterruption = result { return true }
        return false
    }

    private func observe() {
        // An interruption begins when the system deactivates the session and
        // ends with a resumption recommendation (iOS 27; these replace
        // `interruptionNotification`). Only `.shouldResume` resumes, as the
        // `.shouldResume` option did before.
        let i = center.addObserver(of: AVAudioSession.self, for: .didBecomeInactive) { [weak self] message in
            guard Self.interrupts(message.deactivationResult) else { return }
            self?.interruption(began: true, shouldResume: false)
        }
        let e = center.addObserver(of: AVAudioSession.self, for: .resumptionRecommendation) { [weak self] message in
            self?.interruption(began: false, shouldResume: message.recommendation == .shouldResume)
        }
        messageObservers = [i, e]
        let r = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            let gone = reason == .oldDeviceUnavailable
            MainActor.assumeIsolated { self?.routeChanged(oldDeviceUnavailable: gone) }
        }
        let m = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            // The recorder is gone with the media server: what was written up to now is kept and saved.
            MainActor.assumeIsolated { self?.stopBySystem() }
        }
        observers = [r, m]
    }

    var manifest: RecordingManifest {
        RecordingManifest(note: noteID, recording: id, started: timeline.started, codec: format.codec.rawValue,
                          segments: segments.map(\.lastPathComponent), finished: finishedSegments)
    }

    private func writeManifest() throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: folder.appendingPathComponent(RecordingRecovery.manifestName),
                       options: [.atomic, Self.writingOption(protection)])
    }

    /// The `Data.write` option of a protection class.
    nonisolated static func writingOption(_ protection: FileProtectionType) -> Data.WritingOptions {
        switch protection {
        case .completeUnlessOpen: return .completeFileProtectionUnlessOpen
        case .completeUntilFirstUserAuthentication: return .completeFileProtectionUntilFirstUserAuthentication
        default: return .completeFileProtection
        }
    }

    nonisolated static func makeFolder(_ url: URL, protection: FileProtectionType = .completeUnlessOpen) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: protection])
        var root = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }
}

/// Turns a session's segment files into one `.m4a` (docs/attachments.md §13:
/// segments are concatenated with `AVMutableComposition` on stop).
enum RecordingAssembly {
    /// The audio of `segments` in order as one file at `out` (passthrough,
    /// else re-encoded as AAC). One segment is copied as it is. Segments that
    /// cannot be read (a file left unfinished by a crash) are skipped; throws
    /// when none can.
    nonisolated static func merge(_ segments: [URL], into out: URL) async throws {
        try? FileManager.default.removeItem(at: out)
        if segments.count == 1 {
            try FileManager.default.copyItem(at: segments[0], to: out)
            return
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.cannotAssemble("no audio track")
        }
        var cursor = CMTime.zero
        var used = 0
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange), range.duration > .zero else { continue }
            do {
                try track.insertTimeRange(range, of: source, at: cursor)
                cursor = CMTimeAdd(cursor, range.duration)
                used += 1
            } catch { continue }
        }
        guard used > 0 else { throw RecordingError.cannotAssemble("no readable audio") }
        var last: Error = RecordingError.cannotAssemble("no exporter")
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: out)
            do {
                try await export.export(to: out, as: .m4a)
                return
            } catch {
                last = error
            }
        }
        throw RecordingError.cannotAssemble("\(last.localizedDescription)")
    }

    /// The segments of a session that can be read (each finished file, and an
    /// unfinished last one if AVFoundation can still read it).
    nonisolated static func readable(_ segments: [URL]) async -> [URL] {
        var out: [URL] = []
        for url in segments where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.seconds > 0 { out.append(url) }
        }
        return out
    }
}

/// Recordings a crash or a kill left behind (`RecordingSession`'s folder
/// with a manifest and no session running): saved into their note the next
/// time it is opened.
enum RecordingRecovery {
    static let manifestName = "manifest.json"

    /// Folders under `root` whose manifest names `note` and that no running session owns.
    @MainActor
    static func pending(for note: UUID, root: URL = RecordingSession.root) -> [(URL, RecordingManifest)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> (URL, RecordingManifest)? in
            guard let data = try? BoundedRead.contents(of: dir.appendingPathComponent(manifestName), maxBytes: 1 << 20),
                  let m = try? JSONDecoder().decode(RecordingManifest.self, from: data), m.note == note,
                  RecordingSession.active?.id != m.recording, !RecordingSession.busy.contains(m.recording) else { return nil }
            return (dir, m)
        }
    }
}
