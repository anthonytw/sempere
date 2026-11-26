import Foundation
import Sempere

// MARK: - When Note Insights runs in the foreground, and why a pass stopped (docs/design/1.2-note-insights.md §3.7)
//
// Pure rules, so the gate, the pacing of the foreground loop and the words of a stop are tested without a device: the app
// reads the device (`InsightsPowerState`) and the model decides (`InsightsPowerGate`, `InsightsLoopPacing`).

/// How hot the device is (`ProcessInfo.ThermalState`, which Linux does not have).
public enum InsightsThermal: Int, Comparable, Sendable {
    case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What the device says about its power now (the app reads it: `AppInsights.powerState`).
public struct InsightsPowerState: Equatable, Sendable {
    /// Where the power comes from. `unknown` is not taken for power.
    public enum Source: Sendable { case external, battery, unknown }
    public var source: Source
    /// The charge, 0...1; nil when the device cannot say (a Mac, the simulator).
    public var batteryLevel: Double?
    public var lowPowerMode: Bool
    public var thermal: InsightsThermal

    public init(source: Source, batteryLevel: Double? = nil, lowPowerMode: Bool = false, thermal: InsightsThermal = .nominal) {
        self.source = source; self.batteryLevel = batteryLevel; self.lowPowerMode = lowPowerMode; self.thermal = thermal
    }
}

public enum InsightsPowerGate {
    /// The least charge, on battery, at which the foreground processes.
    public static let minimumBatteryLevel = 0.30

    /// Now is a time for the foreground to process: never in Low Power Mode or at a serious thermal state; on external
    /// power (the old rule, unchanged); on battery only with `onBattery` allowed, the charge at 30% or more and the
    /// thermal state nominal or fair.
    public static func allows(_ state: InsightsPowerState, onBattery: Bool) -> Bool {
        guard !state.lowPowerMode, state.thermal < .serious else { return false }
        switch state.source {
        case .external: return true
        case .unknown: return false
        case .battery:
            guard onBattery, let level = state.batteryLevel else { return false }
            return level >= minimumBatteryLevel
        }
    }
}

/// How long the foreground loop waits between looks for work: short (3 minutes) while looks keep making insights, longer
/// and longer (doubling, up to the old 15 minutes) while they make nothing.
public struct InsightsLoopPacing: Equatable, Sendable {
    public static let base = Duration.seconds(3 * 60)
    public static let longest = Duration.seconds(15 * 60)
    public private(set) var interval = InsightsLoopPacing.base
    public init() {}

    /// The wait after a look that made `generated` summaries, titles or topics.
    public mutating func next(generated: Int) -> Duration {
        if generated > 0 { interval = Self.base } else { interval = min(interval * 2, Self.longest) }
        return interval
    }
}

/// Why the last pass on this device stopped (shown under "Process Now"; the app words it, in each language).
public enum InsightsStopReason: Equatable, Sendable {
    /// The app left the screen or the device locked. `resumes`: it was "Process Now", which continues by itself when the
    /// app is active again; an automatic pass starts again at the next look.
    case backgrounded(resumes: Bool)
    /// The device left the power window (unplugged below 30%, Low Power Mode, too hot): an automatic pass only.
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
