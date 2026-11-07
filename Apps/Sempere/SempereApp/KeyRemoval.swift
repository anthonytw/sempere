import Foundation
import Sempere

/// What deleting this device's keys for a vault costs (re-check of #88, R2 and SHOULD): the one check behind
/// Delete from This Device (a store vault), Remove from This Device (a WebDAV vault) and Forget Key (the unlock
/// sheet). Read without the key: the copy's manifest and the fingerprint kept with this device's signing item.
struct KeyRemoval: Equatable, Sendable {
    enum Home: Equatable, Sendable {
        /// This device does not manage the vault's devices (or that cannot be told).
        case no
        /// It manages them and other devices are listed: another device should be made home first.
        case withOthers
        /// It is the vault's only device: afterwards only the recovery kit restores write access.
        case alone
    }

    var home: Home = .no

    /// The check for the copy of `vaultID` at `url` (nil: home is not looked up).
    static func check(vaultID: UUID, at url: URL?, store: any DeviceKeyStore) async -> KeyRemoval {
        var out = KeyRemoval()
        if let url, let mine = await store.fingerprint(for: vaultID) {
            out.home = await Task.detached(priority: .userInitiated) { () -> Home in
                guard let m = try? Vault.open(at: url).manifest, m.home == mine else { return .no }
                return m.devices.count > 1 ? .withOthers : .alone
            }.value
        }
        return out
    }

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

    /// Whether the dialog offers to open the vault and make another device home first.
    var offersMakeHome: Bool { home == .withOthers }

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
