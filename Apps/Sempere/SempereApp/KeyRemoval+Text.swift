import Foundation
import SempereAppCore

/// The words for what removing this device's keys costs (`KeyRemoval`, in `SempereAppCore`, holds the check).
extension KeyRemoval {
    /// Delete from This Device / Remove from This Device: what happens to this device's key, nil when it simply
    /// goes (the dialog's own text says so).
    func removalWarning() -> String? {
        switch home {
        case .no: return nil
        case .withOthers:
            return String(localized: "This device manages the vault's devices, and its key goes with this copy: then only the recovery kit can manage them. Open the vault and make another device home first (Settings ▸ Sync & Devices ▸ Devices ▸ Make Home).")
        case .alone:
            return String(localized: "This device is the vault's only device, and its key goes with this copy: afterwards only the recovery kit restores write access to the vault (Take Over).")
        }
    }

    /// Forget Key on the unlock sheet: the warning when this device is home, nil otherwise.
    var forgetWarning: String? {
        switch home {
        case .no: return nil
        case .withOthers:
            return String(localized: "This device manages the vault's devices: once its key is forgotten, only the recovery kit can manage them (Take Over).")
        case .alone:
            return String(localized: "This device is the vault's only device: once its key is forgotten, only the recovery kit restores write access to the vault (Take Over).")
        }
    }
}
