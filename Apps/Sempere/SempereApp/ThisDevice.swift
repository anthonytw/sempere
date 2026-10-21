import Sempere
import UIKit

/// How this device names itself in a vault's device list (format.md §15.3):
/// the entry's `name` and `kind` when it creates a vault (and, in KH5, when it
/// asks to join one).
enum ThisDevice {
    /// `mac`, `iphone` or `ipad`.
    @MainActor static var kind: String {
        kind(isMac: Platform.isMac, isPhone: Platform.isPhone)
    }

    nonisolated static func kind(isMac: Bool, isPhone: Bool) -> String {
        isMac ? "mac" : isPhone ? "iphone" : "ipad"
    }

    /// The device's name as the system gives it (without the entitlement for
    /// user-assigned names, the model: "iPad"), cleaned for the list.
    @MainActor static var name: String {
        let clean = DeviceName.clean(UIDevice.current.name)
        if !clean.isEmpty { return clean }
        switch kind {
        case "mac": return "Mac"
        case "iphone": return "iPhone"
        default: return "iPad"
        }
    }
}
