import Foundation
import LocalAuthentication
import Sempere
import SempereAppCore

// The unlock sheet's model is the library's (`RememberedKeys`, SempereAppCore); the app gives it the Keychain store
// and words what it returns: the device's name inside sentences, its biometry, the key problems and the failures.

extension RememberedKeys {
    /// The app's keys: the Keychain, with the signing pair in the Secure Enclave.
    convenience init() {
        self.init(store: KeychainDeviceKeyStore())
    }

    /// "this iPad", "this iPhone", or "this Mac" under Mac Catalyst.
    @MainActor static var deviceName: String {
        name(isMac: ProcessInfo.processInfo.isMacCatalystApp, isPhone: Platform.isPhone)
    }

    nonisolated static func name(isMac: Bool, isPhone: Bool) -> String {
        if isMac { return String(localized: "this Mac", comment: "Device phrase inside sentences: “Saved on this Mac”") }
        return isPhone
            ? String(localized: "this iPhone", comment: "Device phrase inside sentences: “Saved on this iPhone”")
            : String(localized: "this iPad", comment: "Device phrase inside sentences: “Saved on this iPad”")
    }

    /// The device's biometry ("Face ID", "Touch ID", "Optic ID") when one is enrolled.
    static var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }
}

extension DeviceKeyProblem {
    /// The unlock sheet's line above Forget This Device's Key.
    var text: String {
        switch self {
        case .unreadable:
            return String(localized: "This device's key for the vault can no longer be read, for example after Face ID was set up again. Forget it, then join again or take over with the recovery kit.")
        case .expired:
            return String(localized: "This device's request to join the vault has expired: the device that manages devices deletes requests after 7 days. Forget this key, then join again.")
        case .stray:
            return String(localized: "This device has a key for the vault that is not on its device list and has no request to join. Forget it, then join again or take over with the recovery kit.")
        }
    }
}

extension DeviceUnlockFailure {
    /// The unlock sheet's error line.
    var text: String {
        switch self {
        case .keysNotRead(let error):
            return AppModel.describe(error)
        case .keysDidNotUnlock(let error):
            return String(localized: "This device's key did not unlock the vault: \(AppModel.describe(error))",
                          comment: "The error text follows (English)")
        }
    }
}
