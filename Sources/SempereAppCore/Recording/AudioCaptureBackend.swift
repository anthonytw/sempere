import Foundation
import Sempere

/// What writes microphone audio into files: `AVAudioRecorder` in the app (`AVAudioCaptureBackend`), a fake in tests.
/// One file at a time; `finish` leaves it complete and playable.
@MainActor
public protocol AudioCaptureBackend: AnyObject {
    /// Makes the audio session active for recording before anything else of the start (quick voice
    /// notes: before the Live Activity is requested, docs/quick-capture.md "Start order"). `mixable`
    /// lets other apps' audio go on, which needs no interruption. `begin` then uses the active session.
    func activateSession(mixable: Bool) async throws
    /// Starts writing a new file at `url` in `format` (activating the session first unless
    /// `activateSession` did).
    func begin(file url: URL, format: RecordingFormat) throws
    /// Stops writing for now (an interruption); `resume` appends to the same file.
    func pause()
    func resume() throws
    /// Ends the current file.
    func finish()
    /// Lets other apps' audio play again (the recording is over).
    func deactivate()
}

/// What the system tells a recording while it runs (`RecordingSystemEvents`): the app reads them from the audio
/// session's notifications; the session turns them into its states.
public struct RecordingSystemHandlers: Sendable {
    /// An interruption (a call, Siri, another app taking the audio session) began (`true`) or ended, and whether the
    /// system recommends going on.
    public var interruption: @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void
    /// The audio route changed; `oldDeviceUnavailable` is true when the device it was using went away (a headset).
    public var routeChanged: @MainActor (_ oldDeviceUnavailable: Bool) -> Void
    /// The media server was reset: the recorder is gone with it.
    public var mediaServicesReset: @MainActor () -> Void

    public init(interruption: @escaping @MainActor (Bool, Bool) -> Void, routeChanged: @escaping @MainActor (Bool) -> Void,
                mediaServicesReset: @escaping @MainActor () -> Void) {
        self.interruption = interruption
        self.routeChanged = routeChanged
        self.mediaServicesReset = mediaServicesReset
    }
}

/// Where a `RecordingSession` hears the system's interruptions, route changes and media server resets (the app:
/// `AVAudioSession`'s notifications, `AVAudioSessionEvents`). One per session: `start` when it starts recording,
/// `stop` when it ends.
@MainActor
public protocol RecordingSystemEvents: AnyObject {
    func start(_ handlers: RecordingSystemHandlers)
    func stop()
}

/// A device that tells a recording nothing (tests, the CLI): the session is driven by calls.
@MainActor
public final class NoRecordingEvents: RecordingSystemEvents {
    public init() {}
    public func start(_ handlers: RecordingSystemHandlers) {}
    public func stop() {}
}

/// Why recording could not start or go on. Worded by the app (`RecordingError+Text.swift`: its text reaches Shortcuts,
/// Siri and the widgets through `localizedStringResource`).
public enum RecordingError: Error, Equatable {
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

    /// The audio system refused to start: from the background, iOS may refuse the microphone
    /// where the app in front would get it (`VoiceNoteIntents` then continues in the app).
    public var isCannotRecord: Bool { if case .cannotRecord = self { true } else { false } }
}

extension RecordingError: CaptureStartRefusal {
    public var mayWorkInForeground: Bool { isCannotRecord }
}
