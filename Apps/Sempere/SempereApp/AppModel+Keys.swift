import Foundation
import Sempere
import SempereRender

/// One entry of the open vault's list (format.md §15.3), as the key window
/// shows it: a device, or the recovery key.
struct VaultDevice: Identifiable, Equatable, Sendable {
    /// The `age1pq1…` key.
    var recipient: String
    /// The device's id (8 hex digits); empty for the recovery key.
    var deviceID: String
    var name: String
    /// `ipad`, `iphone`, `mac`, `cli`…; nil for the recovery key.
    var kind: String?
    var added: Date?
    var isRecovery: Bool
    /// The vault's home: it approves and renames devices (design §5.6).
    var isHome: Bool
    /// The device this vault was unlocked as.
    var isThisDevice: Bool

    var id: String { recipient }

    /// `age1pq1abcdefg…` (1959 characters in full) with its SHA-256 fingerprint,
    /// as printed on the recovery kit.
    var summary: String { Self.abbreviated(recipient) }

    static func abbreviated(_ key: String) -> String {
        key.count > 40 ? "\(key.prefix(14))…  SHA-256 \(PaperKey.fingerprint(key))" : key
    }
}

/// The open vault's devices (the Mac key window lists them).
///
/// TODO(KH5): adding, approving, renaming, removing and replacing devices in
/// the app (join requests, `Vault.approveDevice`, `renameDevice`, new
/// epochs). Until then the app only lists them; the CLI's `sempere device`
/// commands make the changes.
extension AppModel {
    enum KeyError: Error, Equatable, CustomStringConvertible {
        case notUnlocked
        /// Another vault was opened while a sheet or dialog was up.
        case vaultChanged

        var description: String {
            switch self {
            case .notUnlocked: return String(localized: "Unlock the vault first.")
            case .vaultChanged: return String(localized: "Another vault was opened meanwhile. Nothing was changed.")
            }
        }
    }

    /// The open vault's list: its devices in list order, then the recovery key.
    var vaultDevices: [VaultDevice] {
        guard let vault else { return [] }
        let manifest = vault.manifest
        let this = vault.deviceFingerprint
        return manifest.keys.map { entry in
            VaultDevice(recipient: entry.key, deviceID: entry.id ?? "", name: DeviceName.display(entry.name), kind: entry.kind,
                        added: RFC3339.parse(entry.added), isRecovery: entry.role == .recovery,
                        isHome: entry.role == .device && entry.fingerprint == manifest.home,
                        isThisDevice: entry.role == .device && entry.fingerprint == this)
        }
    }
}
