import Foundation

/// What the Live Activity of a recording shows (an `AudioRecordingIntent` must start one): elapsed
/// time and a Stop button, on the Lock Screen and in the Dynamic Island, then for a few seconds where
/// the voice note went (`result`). It shows no note content. The activity itself (`VoiceNoteAttributes`,
/// ActivityKit) is the app's and the widget's: this is its `ContentState`, the same JSON as before.
public struct VoiceNoteActivityState: Codable, Hashable, Sendable {
    /// When the timer stood at zero: when recording started, moved later by
    /// the time spent paused, so that the timer shows the audio recorded.
    public var started: Date
    /// Paused by an interruption (a call): the timer stands at `ended - started`.
    public var paused: Bool
    /// Stopped and being sealed.
    public var saving: Bool?
    /// The last state, shown until the activity is dismissed.
    public var result: VoiceNoteResult?
    /// When it stopped or paused (the length shown is `ended - started`).
    public var ended: Date?

    public init(started: Date, paused: Bool = false, saving: Bool? = nil, result: VoiceNoteResult? = nil, ended: Date? = nil) {
        self.started = started
        self.paused = paused
        self.saving = saving
        self.result = result
        self.ended = ended
    }

    /// Whether Stop is offered (recording, or paused).
    public var isRecording: Bool { result == nil && saving != true }
    /// Whether the timer runs: recording and not paused.
    public var timerRuns: Bool { isRecording && !paused }
}
