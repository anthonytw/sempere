#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import SempereCaptureShared

/// The Live Activity shown while a voice note records (an `AudioRecordingIntent` must start one):
/// its state is `VoiceNoteActivityState` (SempereCaptureShared), which the app's `QuickCapture`
/// sends through `SystemLiveActivity`. It shows no note content.
struct VoiceNoteAttributes: ActivityAttributes {
    typealias ContentState = VoiceNoteActivityState
}
#endif
