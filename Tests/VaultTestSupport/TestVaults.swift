import Age
import Foundation
import Sempere

/// Vaults for tests under the key hierarchy (format.md §15; KH2): a test names a device by a bare
/// post-quantum identity, as tests always have, and this gives it a signing pair, kept for the life of
/// the process so the device's fingerprint (and id) never changes between calls.
public enum TestVaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var signings: [String: DeviceSigningKeys] = [:]

    /// The device keys of `identity`: its decryption key and a signing pair made on first use.
    public static func device(_ identity: NativeIdentity) -> DeviceKeys {
        guard case .mlkem768x25519(let pq) = identity else { preconditionFailure("vault devices are post-quantum") }
        lock.lock()
        let signing = signings[identity.recipient.string] ?? DeviceSigningKeys.generate()
        signings[identity.recipient.string] = signing
        lock.unlock()
        // swiftlint:disable:next force_try
        return try! DeviceKeys(identity: pq, signing: signing)
    }

    /// Makes `keys` the device keys of its identity from now on (a fixture's device key file, whose
    /// signing seeds are committed).
    public static func register(_ keys: DeviceKeys) {
        lock.lock()
        signings[keys.key] = keys.signing
        lock.unlock()
    }

    /// The signing keys of `identity` (`device`'s).
    public static func signing(_ identity: NativeIdentity) -> DeviceSigningKeys { device(identity).signing }

    /// A vault listing `identities` as devices (the first is home and creates it; each other is approved
    /// by it), with `recovery` (a fresh key when nil) as the recovery key, opened as the first device.
    ///
    /// - Parameter names: one per identity, or empty ("device 1", …).
    @discardableResult
    public static func create(at url: URL, identities: [NativeIdentity], names: [String] = [], kind: String = "cli",
                              recovery: MLKEM768X25519Identity? = nil, recoveryPassphrase: String? = nil,
                              workFactor: Int = 10, vaultId: UUID = UUID(), created: Date = Date(),
                              trust: (any EpochTrustStore)? = nil, label: String? = nil) throws -> Vault {
        precondition(!identities.isEmpty, "a vault needs a device")
        func name(_ i: Int) -> String { names.indices.contains(i) ? names[i] : "device \(i + 1)" }
        var vault = try Vault.create(at: url, device: device(identities[0]), deviceName: name(0), kind: kind,
                                     recovery: try recovery ?? MLKEM768X25519Identity(), recoveryPassphrase: recoveryPassphrase,
                                     workFactor: workFactor, vaultId: vaultId, created: created, trust: trust, label: label)
        for (i, id) in identities.enumerated().dropFirst() {
            try vault.approveDevice(device(id).joinRequest(vaultId: vault.vaultId, name: name(i), kind: kind, created: created),
                                    added: created)
        }
        return vault
    }

    /// Approves `identity` into `vault`, which must be open as its home with the signing keys.
    public static func approve(_ identity: NativeIdentity, into vault: inout Vault, name: String = "device",
                               kind: String = "cli") throws {
        try vault.approveDevice(device(identity).joinRequest(vaultId: vault.vaultId, name: name, kind: kind))
    }

    /// Opens `url` as the device `identity`, with its signing keys.
    public static func open(at url: URL, identity: NativeIdentity, trust: (any EpochTrustStore)? = nil) throws -> Vault {
        try Vault.open(at: url, identities: [identity], signing: signing(identity), trust: trust)
    }

    /// The device key file of `identity` (`DeviceKeys.fileText`): what the CLI reads from `--identity`.
    public static func deviceKeyFile(_ identity: NativeIdentity, created: Date = Date()) -> String {
        device(identity).fileText(created: created)
    }
}
