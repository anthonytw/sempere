import Foundation

/// A tactile tick (`PlatformServices.play`).
public enum HapticFeedback: String, Sendable, CaseIterable {
    /// A selection settled on a value (the zoom snapping to the fitted width).
    case selection
}

/// What the device is and the few device-wide switches the app's logic uses: in the app `AppPlatform` (the
/// `Platform.isMac` flags, `UIApplication.isIdleTimerDisabled`, UIKit's feedback generators and home-screen icons);
/// `HeadlessPlatform` in tests and the CLI, which records what it was asked.
public protocol PlatformServices: Sendable {
    /// The Mac (Catalyst) build.
    var isMac: Bool { get }
    /// An iPhone (the reader layouts). Never true on an iPad or a Mac.
    @MainActor var isPhone: Bool { get }
    /// Keeps the screen from locking (true) or lets it lock again (false). App-wide.
    @MainActor func setIdleTimerDisabled(_ disabled: Bool)
    /// Plays `feedback` where the device has haptics (never on a Mac).
    @MainActor func play(_ feedback: HapticFeedback)
    /// The home-screen icon in use, by the name settings sync stores (`appearance.icon`); nil where the device
    /// cannot switch icons (a Mac).
    @MainActor var appIcon: String? { get }
    /// Switches the home-screen icon to `name` (an `appIcon` name; unknown names change nothing). The system tells
    /// the user; a failure leaves the current icon.
    @MainActor func setAppIcon(_ name: String)
    /// How this device names its kind in a vault's device list (format.md §15.3 `kind`): `DeviceKind.of`.
    @MainActor var deviceKind: String { get }
    /// The name this device gives itself in a vault's device list (a new vault, a join, a takeover). Never the
    /// user's or the computer's name (it is stored unencrypted in `vault.json`).
    @MainActor var deviceName: String { get }
}

/// The `kind` a device of the vault's list names (format.md §15.3) for the app's devices.
public enum DeviceKind {
    /// `mac`, `iphone` or `ipad`.
    public static func of(isMac: Bool, isPhone: Bool) -> String {
        isMac ? "mac" : isPhone ? "iphone" : "ipad"
    }
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
    /// The icon `setAppIcon` last chose; nil (a device with no icons to switch) unless made with one.
    public private(set) var appIcon: String?

    /// The name the device gives itself (`deviceName`).
    public let deviceName: String

    public nonisolated init(isMac: Bool = false, isPhone: Bool = false, appIcon: String? = nil,
                            deviceName: String = "Headless Device") {
        self.isMac = isMac
        self.isPhone = isPhone
        self.appIcon = appIcon
        self.deviceName = deviceName
    }

    public var deviceKind: String { DeviceKind.of(isMac: isMac, isPhone: isPhone) }

    /// The last idle-timer setting (nil before the first).
    public var idleTimerDisabled: Bool? { idleTimerSettings.last }

    public func setIdleTimerDisabled(_ disabled: Bool) { idleTimerSettings.append(disabled) }

    public func play(_ feedback: HapticFeedback) {
        guard !isMac else { return }
        played.append(feedback)
    }

    public func setAppIcon(_ name: String) {
        guard appIcon != nil else { return }
        appIcon = name
    }
}
