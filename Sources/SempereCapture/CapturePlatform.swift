import Foundation
import Sempere

// The recorder's side of quick voice notes (docs/design/1.1-watch.md §3.2): one recording in progress, the recorder of a
// start, the microphone and the refusal a start may get past. The iPhone app (`QuickCapture`) and the Apple Watch's
// `WatchRecorder` both run over these; the platform implements them (AVFoundation). Moved out of `SempereAppCore`, which
// re-exports this module.

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

/// An error a start may get past with the app in front (the app's `RecordingError.cannotRecord`: from the background
/// iOS may refuse the microphone where the app in front would get it). `QuickCapture.worksInForeground`.
public protocol CaptureStartRefusal: Error {
    var mayWorkInForeground: Bool { get }
}

