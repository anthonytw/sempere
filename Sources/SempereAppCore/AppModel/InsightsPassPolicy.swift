import Foundation
import Sempere

// MARK: - When Note Insights runs in the foreground, and why a pass stopped (docs/design/1.2-note-insights.md §3.7)
//
// The reasons a pass stopped, so the words of a stop are tested without a device (the app words them, in each language).

/// Why the last pass on this device stopped (shown under "Process Now"; the app words it, in each language).
public enum InsightsStopReason: Equatable, Sendable {
    /// The app left the screen or the device locked. `resumes`: it was "Process Now", which continues by itself when the
    /// app is active again; an automatic pass starts again at the next look.
    case backgrounded(resumes: Bool)
    /// The device left the power window (unplugged, Low Power Mode, too hot): an automatic pass only.
    case powerWindowClosed
    /// Apple Intelligence is not available or not ready on this device.
    case modelUnavailable
    /// An error (its words are `InsightsModelState.problem`).
    case failed
    /// The vault was locked or closed, or Note Insights turned off.
    case vaultLocked
    /// Another task took the slot (a topic's "Regenerate").
    case superseded
    /// Everything this device can process now is processed.
    case finished
}
