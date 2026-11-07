import Foundation

/// A tactile tick (`PlatformServices.play`).
public enum HapticFeedback: String, Sendable, CaseIterable {
    /// A selection settled on a value (the zoom snapping to the fitted width).
    case selection
}

/// What the device is and the few device-wide switches the app's logic uses: in the app `AppPlatform` (the
/// `Platform.isMac` flags, `UIApplication.isIdleTimerDisabled`, UIKit's feedback generators); `HeadlessPlatform`
/// in tests and the CLI, which records what it was asked.
public protocol PlatformServices: Sendable {
    /// The Mac (Catalyst) build.
    var isMac: Bool { get }
    /// An iPhone (the reader layouts). Never true on an iPad or a Mac.
    @MainActor var isPhone: Bool { get }
    /// Keeps the screen from locking (true) or lets it lock again (false). App-wide.
    @MainActor func setIdleTimerDisabled(_ disabled: Bool)
    /// Plays `feedback` where the device has haptics (never on a Mac).
    @MainActor func play(_ feedback: HapticFeedback)
}

/// `PlatformServices` with no device behind it (tests, the CLI): the flags it was made with, and a record of
/// the idle-timer settings and feedback asked of it.
@MainActor
public final class HeadlessPlatform: PlatformServices {
    public nonisolated let isMac: Bool
    public let isPhone: Bool
    /// Every `setIdleTimerDisabled` value, in order.
    public private(set) var idleTimerSettings: [Bool] = []
    /// Every `play`, in order.
    public private(set) var played: [HapticFeedback] = []

    public nonisolated init(isMac: Bool = false, isPhone: Bool = false) {
        self.isMac = isMac
        self.isPhone = isPhone
    }

    /// The last idle-timer setting (nil before the first).
    public var idleTimerDisabled: Bool? { idleTimerSettings.last }

    public func setIdleTimerDisabled(_ disabled: Bool) { idleTimerSettings.append(disabled) }

    public func play(_ feedback: HapticFeedback) {
        guard !isMac else { return }
        played.append(feedback)
    }
}
