import AVFoundation
import Foundation
import Sempere
import SempereAppCore

/// `AudioCaptureBackend` with `AVAudioRecorder` and the shared audio
/// session (docs/attachments.md §13 "Audio recording"): `.playAndRecord`,
/// speaker and Bluetooth headsets allowed. `UIBackgroundModes: audio` keeps
/// it running with the screen locked or the app in the background.
@MainActor
final class AVAudioCaptureBackend: AudioCaptureBackend {
    private var recorder: AVAudioRecorder?
    /// `activateSession` (or `begin`) made the session active, and nothing deactivated it since.
    private var sessionActive = false
    /// The session was activated mixable (`resume` keeps it so).
    private var mixable = false

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

    /// Not mixable (no `.mixWithOthers`): the audio system refuses a *mixable* recording started
    /// from the background ("`cannotStartRecording` … usually because it is starting a mixable
    /// recording from the background", AudioSessionTypes.h).
    ///
    /// Not mixable by default, but a background start whose fake-foreground assertion is already gone
    /// cannot activate a non-mixable session ('!int' cannotInterruptOthers, iPhone, iOS 27.0.1, TestFlight
    /// 1.0.0 (6)): `QuickCapture` activates before the Live Activity, and tries `mixable` only after that refusal.
    nonisolated static func activate(mixable: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        if mixable { options.insert(.mixWithOthers) }
        let step = mixable ? " (mixable)" : ""
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        } catch {
            throw RecordingError.cannotRecord(Self.explain(error, step: "setCategory" + step))
        }
        do {
            try session.setActive(true)
        } catch {
            throw RecordingError.cannotRecord(Self.explain(error, step: "setActive" + step))
        }
    }

    /// Off the main thread: activation can block for a while (audiomxd warns of a hang on the main thread).
    func activateSession(mixable: Bool) async throws {
        try await Task.detached(priority: .userInitiated) { try Self.activate(mixable: mixable) }.value
        sessionActive = true
        self.mixable = mixable
    }

    /// The audio system's refusal with its step, domain and code (and the code's name when it is an
    /// `AVAudioSession.ErrorCode`), so the start diagnostics say which refusal it was.
    nonisolated static func explain(_ error: Error, step: String) -> String {
        let ns = error as NSError
        var code = "\(ns.domain) \(ns.code)"
        if let name = sessionErrorName(ns.code) { code += " \(name)" }
        return "\(ns.localizedDescription) (\(step): \(code))"
    }

    /// The four-character code and name of an `AVAudioSession.ErrorCode` (AudioSessionTypes.h).
    nonisolated static func sessionErrorName(_ code: Int) -> String? {
        switch code {
        case 560_557_684: return "'!int' cannotInterruptOthers"
        case 561_145_187: return "'!rec' cannotStartRecording"
        case 561_015_905: return "'!pla' cannotStartPlaying"
        case 561_017_449: return "'!pri' insufficientPriority"
        case 560_030_580: return "'!act' isBusy"
        case 560_161_140: return "'!cat' incompatibleCategory"
        case 1_701_737_535: return "'ent?' missingEntitlement"
        case 1_936_290_409: return "'siri' siriIsRecording"
        case 561_145_203: return "'!res' resourceNotAvailable"
        case 1_768_841_571: return "'inac' sessionNotActive"
        case 561_210_739: return "'!ses' expiredSession"
        case 1_836_282_486: return "'msrv' mediaServicesFailed"
        case 2_003_329_396: return "'what' unspecified"
        default: return nil
        }
    }

    func begin(file url: URL, format: RecordingFormat) throws {
        if !sessionActive {
            try Self.activate(mixable: mixable)
            sessionActive = true
        }
        let channels = AVAudioSession.sharedInstance().inputNumberOfChannels
        let r: AVAudioRecorder
        do { r = try AVAudioRecorder(url: url, settings: Self.settings(format, inputChannels: channels)) } catch {
            throw RecordingError.cannotRecord(Self.explain(error, step: "AVAudioRecorder"))
        }
        guard r.record() else { throw RecordingError.cannotRecord("the recorder did not start") }
        recorder = r
    }

    func pause() { recorder?.pause() }

    func resume() throws {
        try Self.activate(mixable: mixable)
        sessionActive = true
        guard recorder?.record() == true else { throw RecordingError.cannotRecord("the recorder did not resume") }
    }

    func finish() {
        recorder?.stop()
        recorder = nil
    }

    func deactivate() {
        sessionActive = false
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

/// `RecordingSystemEvents` from `AVAudioSession`: the interruptions and their resumption recommendation, the route
/// changes and the media server's reset, read from `center` (tests post to their own).
@MainActor
final class AVAudioSessionEvents: RecordingSystemEvents {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var messageObservers: [NotificationCenter.ObservationToken] = []

    init(center: NotificationCenter = .default) { self.center = center }

    /// Whether a deactivation of the audio session interrupts the recording:
    /// only one the system made; the app's own (`setActive(false)` after a
    /// stop) does not.
    nonisolated static func interrupts(_ result: AVAudioSession.DeactivationResult) -> Bool {
        if case .systemInterruption = result { return true }
        return false
    }

    func start(_ handlers: RecordingSystemHandlers) {
        // An interruption begins when the system deactivates the session and
        // ends with a resumption recommendation (iOS 27; these replace
        // `interruptionNotification`). Only `.shouldResume` resumes, as the
        // `.shouldResume` option did before.
        let i = center.addObserver(of: AVAudioSession.self, for: .didBecomeInactive) { message in
            guard Self.interrupts(message.deactivationResult) else { return }
            handlers.interruption(true, false)
        }
        let e = center.addObserver(of: AVAudioSession.self, for: .resumptionRecommendation) { message in
            handlers.interruption(false, message.recommendation == .shouldResume)
        }
        messageObservers = [i, e]
        let r = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            let gone = reason == .oldDeviceUnavailable
            MainActor.assumeIsolated { handlers.routeChanged(gone) }
        }
        let m = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handlers.mediaServicesReset() }
        }
        observers = [r, m]
    }

    func stop() {
        for o in observers { center.removeObserver(o) }
        observers = []
        for o in messageObservers { center.removeObserver(o) }
        messageObservers = []
    }
}

extension RecordingSession {
    /// A session on the app's audio: `backend` (nil: `AVAudioCaptureBackend`) and the audio session's notifications
    /// from `center`.
    convenience init(noteID: UUID, format: RecordingFormat, root: URL = RecordingSession.root,
                     protection: FileProtectionType = .completeUnlessOpen, segmentExtension: String = "m4a",
                     backend: AudioCaptureBackend? = nil, center: NotificationCenter = .default,
                     now: @escaping () -> Date = { Date() }) {
        self.init(noteID: noteID, format: format, root: root, protection: protection, segmentExtension: segmentExtension,
                  backend: backend ?? AVAudioCaptureBackend(), events: AVAudioSessionEvents(center: center), now: now)
    }
}

extension NoteEditor {
    /// Starts recording into this note in `format` (the settings' by default) on the app's audio
    /// (`NoteEditorModel.startRecording(format:root:backend:events:)`). The caller asked for the microphone first.
    func startRecording(format: RecordingFormat = RecordingPreference.format(UserDefaults.standard), root: URL = RecordingSession.root,
                        backend: AudioCaptureBackend? = nil, center: NotificationCenter = .default) throws {
        try startRecording(format: format, root: root, backend: backend ?? AVAudioCaptureBackend(),
                           events: AVAudioSessionEvents(center: center))
    }
}

/// Turns a session's segment files into one `.m4a` (docs/attachments.md §13:
/// segments are concatenated with `AVMutableComposition` on stop).
enum RecordingAssembly {
    /// The audio of `segments` in order as one file at `out` (passthrough,
    /// else re-encoded as AAC). One segment is copied as it is. Segments that
    /// cannot be read (a file left unfinished by a crash) are skipped; throws
    /// when none can. Segments in another container than MPEG-4 (ADTS `.aac`) are
    /// always rewritten into one, also alone.
    nonisolated static func merge(_ segments: [URL], into out: URL) async throws {
        try? FileManager.default.removeItem(at: out)
        if segments.count == 1, segments[0].pathExtension.lowercased() == "m4a" {
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
