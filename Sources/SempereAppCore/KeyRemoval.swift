import Foundation
import Sempere

/// What deleting this device's keys for a vault costs (re-check of #88, R2 and SHOULD): the one check behind
/// Delete from This Device (a store vault), Remove from This Device (a WebDAV vault) and Forget Key (the unlock
/// sheet). Read without the key: the copy's manifest and the fingerprint kept with this device's signing item.
public struct KeyRemoval: Equatable, Sendable {
    public enum Home: Equatable, Sendable {
        /// This device does not manage the vault's devices (or that cannot be told).
        case no
        /// It manages them and other devices are listed: another device should be made home first.
        case withOthers
        /// It is the vault's only device: afterwards only the recovery kit restores write access.
        case alone
    }

    public var home: Home = .no

    public init(home: Home = .no) { self.home = home }

    /// The check for the copy of `vaultID` at `url` (nil: home is not looked up).
    public static func check(vaultID: UUID, at url: URL?, store: any DeviceKeyStore) async -> KeyRemoval {
        var out = KeyRemoval()
        if let url, let mine = await store.fingerprint(for: vaultID) {
            out.home = await Task.detached(priority: .userInitiated) { () -> Home in
                guard let m = try? Vault.open(at: url).manifest, m.home == mine else { return .no }
                return m.devices.count > 1 ? .withOthers : .alone
            }.value
        }
        return out
    }

    /// Whether the dialog offers to open the vault and make another device home first.
    public var offersMakeHome: Bool { home == .withOthers }
}
