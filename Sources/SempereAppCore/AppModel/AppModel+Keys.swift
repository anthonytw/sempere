import Foundation
import Sempere
import SempereRender

/// One entry of the open vault's list (format.md §15.3), as the key window
/// shows it: a device, or the recovery key.
public struct VaultDevice: Identifiable, Equatable, Sendable {
    /// The `age1pq1…` key.
    public var recipient: String
    /// The device's id (8 hex digits); empty for the recovery key.
    public var deviceID: String
    public var name: String
    /// `ipad`, `iphone`, `mac`, `cli`…; nil for the recovery key.
    public var kind: String?
    public var added: Date?
    public var isRecovery: Bool
    /// The vault's home: it approves and renames devices (design §5.6).
    public var isHome: Bool
    /// The device this vault was unlocked as.
    public var isThisDevice: Bool

    public var id: String { recipient }

    public init(recipient: String, deviceID: String, name: String, kind: String?, added: Date?, isRecovery: Bool,
                isHome: Bool, isThisDevice: Bool) {
        self.recipient = recipient
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.added = added
        self.isRecovery = isRecovery
        self.isHome = isHome
        self.isThisDevice = isThisDevice
    }

    /// `age1pq1abcdefg…` (1959 characters in full) with its SHA-256 fingerprint,
    /// as printed on the recovery kit.
    public var summary: String { Self.abbreviated(recipient) }

    public static func abbreviated(_ key: String) -> String {
        key.count > 40 ? "\(key.prefix(14))…  SHA-256 \(PaperKey.fingerprint(key))" : key
    }
}

/// The open vault's devices, as Settings names this device. The device list and its changes are
/// `AppModel+Devices` (`DevicesView`).
extension AppModelCore {
    /// The open vault's list: its devices in list order, then the recovery key.
    public var vaultDevices: [VaultDevice] {
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
