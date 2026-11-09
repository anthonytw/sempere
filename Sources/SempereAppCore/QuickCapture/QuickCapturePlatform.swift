import Foundation
import Sempere
import SempereCaptureShared

// What `QuickCapture` needs from the platform (docs/design/thin-app.md "SempereAppCore"): the recorder and its audio
// session, the audio files' decoding, the Live Activity, the app's state and background time. The app implements them
// (`QuickCapture+App.swift`: AVFoundation, ActivityKit, UIKit); the versions here are for tests and platforms without
// them (a recorder that cannot record, no Live Activities, an app always in front, no background time).

// MARK: - The recording

/// One recording in progress (the app's `RecordingSession`): segment files in `folder`, a manifest beside them, and
/// the timeline that maps wall time to audio time across pauses. Its files are protected by the recorder in a class
/// that stays readable while the device is locked after its first unlock: a voice note started from the Lock Screen is
/// read back from closed files and sealed before any unlock (the app's `QuickCapture.protection`).
@MainActor
public protocol CaptureRecording: AnyObject, Sendable {
    /// The recording's id (the capture's id).
    var id: UUID { get }
    /// Its folder (segments and manifest), deleted once the capture is sealed.
    var folder: URL { get }
    /// The segment files written so far, in order.
    var segments: [URL] { get }
    var timeline: RecordingTimeline { get }
    /// Recording or paused (not stopped, not failed).
    var isActive: Bool { get }
    /// Paused by an interruption, a route change or the user. Observable (`withObservationTracking`): quick capture
    /// follows it to show the pause on the Live Activity and the widgets.
    var isPaused: Bool { get }
    /// Called when the recording stops by itself (the media server was reset, no new segment file): its owner seals
    /// what was recorded, as after `stop`.
    var onStoppedBySystem: (@MainActor () -> Void)? { get set }
    /// Starts writing (throws when the recorder will not start).
    func start() throws
    /// Stops; the segment files are complete afterwards.
    func stop()
    /// Deletes the recording's files.
    func discardFiles()
}

/// The recorder of one start (the app: an `AudioCaptureBackend` and the shared audio session). Made per start.
@MainActor
public protocol CaptureRecorder: AnyObject, Sendable {
    /// Makes the audio session active, before the Live Activity is asked for (docs/quick-capture.md "Start order").
    /// `mixable` lets other apps' audio go on. Throws the system's refusal.
    func activateSession(mixable: Bool) async throws
    /// Lets other apps' audio play again (a start that did not record).
    func deactivate()
    /// A recording into a new folder under `root`, not started yet, its segments named `segment-NNN.<segmentExtension>`.
    func makeRecording(format: RecordingFormat, root: URL, segmentExtension: String) -> any CaptureRecording
}

/// The device's microphone and recorder (the app: AVFoundation).
@MainActor
public protocol CaptureAudio: AnyObject, Sendable {
    /// Asks for the microphone (once); false when it is refused or cannot be confirmed now.
    func requestMicrophone() async -> Bool
    /// The microphone permission as the start diagnostics name it (`granted`, `denied`, `undetermined`).
    var microphonePermission: String { get }
    /// The format the recording settings ask for (`CaptureSegments.captureFormat` makes it a quick voice note's).
    var preferredFormat: RecordingFormat { get }
    /// The recorder of one start.
    func makeRecorder() -> any CaptureRecorder
}

/// Reading and joining recorded segment files (the app: AVFoundation).
public protocol CaptureAudioFiles: Sendable {
    /// What the segment at `url` holds. Only a file positively read as an audio track of no length is `.none` with
    /// bytes in it: anything that cannot be read is `.undecodable`, which a seal never deletes.
    func classify(_ url: URL) async -> CaptureSegments.Audio
    /// The audio of `segments` in order as one MPEG-4 file at `out`.
    func merge(_ segments: [URL], into out: URL) async throws
}

/// An error a start may get past with the app in front (the app's `RecordingError.cannotRecord`: from the background
/// iOS may refuse the microphone where the app in front would get it). `QuickCapture.worksInForeground`.
public protocol CaptureStartRefusal: Error {
    var mayWorkInForeground: Bool { get }
}

/// What a seal could not do with a recording's segments (`CaptureSegments.plan`). Worded by the app.
public enum CaptureAssemblyError: Error, Equatable, Sendable {
    /// Not a byte of audio was recorded (the folder is deleted).
    case noAudio
    /// A complete segment does not decode (the folder is kept).
    case segmentUndecodable(String)
    /// Bytes of which nothing decodes (the folder is kept).
    case noReadableAudio
}

/// Where a recording's audio is turned into a transcript on device (the app: the Speech framework).
public protocol RecordingTranscribing: Sendable {
    /// `allowModelDownload`: the user asked for this one (the Transcribe button), so the engine may fetch its
    /// language model from Apple's asset service. Automatic jobs (a recording saved, a quick voice note, an
    /// adopted capture) pass false: offline, a download would fail or wait, so they report
    /// `modelNotDownloaded` instead (offline audit A-P1).
    func transcribe(file: URL, recording: UUID, noteLanguage: String?, allowModelDownload: Bool) async throws -> Transcript
}

/// A device without a recorder (tests, the CLI): the microphone is refused, so nothing starts.
@MainActor
public final class NoCaptureAudio: CaptureAudio {
    public init() {}
    public func requestMicrophone() async -> Bool { false }
    public var microphonePermission: String { "unavailable" }
    public var preferredFormat: RecordingFormat { .default }
    public func makeRecorder() -> any CaptureRecorder { NoCaptureRecorder() }
}

/// The recorder of `NoCaptureAudio`: its session never activates.
@MainActor
final class NoCaptureRecorder: CaptureRecorder {
    public struct Unavailable: Error {}
    init() {}
    func activateSession(mixable: Bool) async throws { throw Unavailable() }
    func deactivate() {}
    func makeRecording(format: RecordingFormat, root: URL, segmentExtension: String) -> any CaptureRecording {
        UnstartableRecording(folder: root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true))
    }
}

/// A recording that never starts.
@MainActor
final class UnstartableRecording: CaptureRecording {
    let id = UUID()
    let folder: URL
    let segments: [URL] = []
    let timeline = RecordingTimeline()
    let isActive = false
    let isPaused = false
    var onStoppedBySystem: (@MainActor () -> Void)?
    init(folder: URL) { self.folder = folder }
    func start() throws { throw NoCaptureRecorder.Unavailable() }
    func stop() {}
    func discardFiles() { try? FileManager.default.removeItem(at: folder) }
}

/// Segment files read by size alone (tests, platforms without a decoder): a file with bytes is audio, an empty one
/// holds none; `merge` joins the bytes.
public struct ByteCaptureAudioFiles: CaptureAudioFiles {
    public init() {}
    public func classify(_ url: URL) async -> CaptureSegments.Audio { CaptureSegments.byteCount(url) > 0 ? .audio : .none }
    public func merge(_ segments: [URL], into out: URL) async throws {
        // As AVFoundation's: nothing to join is a failure, not an empty file.
        guard !segments.isEmpty else { throw RecordingError.cannotAssemble("no readable audio") }
        var data = Data()
        for url in segments { data.append(try Data(contentsOf: url)) }
        try? FileManager.default.removeItem(at: out)
        try data.write(to: out)
    }
}

// MARK: - The Live Activity

/// The recording's Live Activity (the app: ActivityKit, iPhone and iPad only). An `AudioRecordingIntent` records in
/// the background only while one shows (docs/quick-capture.md "Start order").
@MainActor
public protocol CaptureLiveActivity: AnyObject, Sendable {
    /// Whether the platform has Live Activities at all (not a Mac).
    var isSupported: Bool { get }
    /// Whether they are allowed for the app (Settings ▸ Sempere ▸ Live Activities); true where unsupported.
    var areEnabled: Bool { get }
    /// Starts the recording's activity on `state`, stale at `staleDate`; throws what the system answered.
    func request(_ state: VoiceNoteActivityState, staleDate: Date?) throws
    /// Shows `state` on the recording's activity, if there is one (each update waits for the one before).
    func update(_ state: VoiceNoteActivityState, staleDate: Date?)
    /// Ends the recording's activity on `state`, dismissed at `dismissal`.
    func end(_ state: VoiceNoteActivityState, dismissal: Date)
    /// Ends every voice note activity that started before `cutoff`, this process's too (nothing records now).
    func endAll(startedBefore cutoff: Date) async
    /// Ends every voice note activity that started before `cutoff` and is not this process's recording: one a
    /// process that was force quit, crashed or restarted while recording left. Returns how many it ended.
    func endOrphans(startedBefore cutoff: Date) async -> Int
}

/// No Live Activities (a Mac, tests, the CLI).
@MainActor
public final class NoLiveActivity: CaptureLiveActivity {
    public init() {}
    public var isSupported: Bool { false }
    public var areEnabled: Bool { true }
    public func request(_ state: VoiceNoteActivityState, staleDate: Date?) throws {}
    public func update(_ state: VoiceNoteActivityState, staleDate: Date?) {}
    public func end(_ state: VoiceNoteActivityState, dismissal: Date) {}
    public func endAll(startedBefore cutoff: Date) async {}
    public func endOrphans(startedBefore cutoff: Date) async -> Int { 0 }
}

// MARK: - The app's state

/// How active the app is (`UIApplication.State`), named as the diagnostics name it.
public enum CaptureAppActivity: String, Sendable {
    case active, inactive, background, unknown
}

/// The app's state (the app: `UIApplication`).
@MainActor
public protocol CaptureAppState: AnyObject, Sendable {
    var activity: CaptureAppActivity { get }
    /// Whether protected data can be read (false before the first unlock after a restart).
    var protectedDataAvailable: Bool { get }
    /// Waits, at most `timeout`, for the app to become active: true when it is (at once, if it already is).
    func waitUntilActive(timeout: Duration) async -> Bool
}

/// An app always in front with its data readable (tests, the CLI).
@MainActor
public final class ActiveCaptureApp: CaptureAppState {
    public var activity: CaptureAppActivity
    public var protectedDataAvailable: Bool
    public init(activity: CaptureAppActivity = .active, protectedDataAvailable: Bool = true) {
        self.activity = activity
        self.protectedDataAvailable = protectedDataAvailable
    }
    public func waitUntilActive(timeout: Duration) async -> Bool { activity == .active }
}

// MARK: - Background time

/// Time to finish work after the app left the front (the app: `UIApplication.beginBackgroundTask`).
@MainActor
public protocol BackgroundTime: AnyObject, Sendable {
    /// Asks for time to finish `name`; `expired` runs if it runs out first. End it with `BackgroundGrant.end`.
    func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> BackgroundGrant
}

/// Time `BackgroundTime` granted, ended once.
@MainActor
public final class BackgroundGrant {
    private var endBody: (@MainActor () -> Void)?
    public init(end: @escaping @MainActor () -> Void) { endBody = end }
    /// Gives the time back (again: nothing).
    public func end() {
        let body = endBody
        endBody = nil
        body?()
    }
}

/// No background time to ask for (tests, the CLI): the work runs as long as the process does.
@MainActor
public final class NoBackgroundTime: BackgroundTime {
    public init() {}
    public func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> BackgroundGrant { BackgroundGrant {} }
}
