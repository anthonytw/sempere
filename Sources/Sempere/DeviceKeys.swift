import Age
import Foundation

/// Errors reading a device key file.
public enum DeviceKeysError: Error, Hashable, Sendable {
    /// Not a device key file: no single `AGE-SECRET-KEY-PQ-1…` line, a signing seed line missing or
    /// not 64 hex digits, or more than `maxBytes`.
    case malformed(String)
    /// The `# public key:` line names another key than the secret key.
    case publicKeyMismatch
    /// The signing pair is not in software (the Secure Enclave): there is no key file of it.
    case notInSoftware
}

/// A device's own keys (docs/design/key-hierarchy.md §4.1, §6.1; format.md §15.4): the MLKEM768-X25519
/// key pair its wrap in `vault.json` is sealed to, and its signing pair (P-256 and ML-DSA-65) for the list
/// changes home signs. The private halves never leave the device: there is no export of them in the app or
/// the CLI, and they are never stored in a vault.
///
/// The CLI keeps them in software (`device.key`, below); the app keeps them in the Keychain until the
/// signing pair moves to the Secure Enclave (KH5).
public struct DeviceKeys: Sendable {
    /// The largest device key file read.
    public static let maxBytes = 16 * 1024

    /// The decryption key: its recipient is the entry's `key`.
    public let identity: MLKEM768X25519Identity
    /// The signing pair: software (the CLI's) or in the Secure Enclave (the app's).
    public let signing: any AuthorSigner
    /// The signing public keys (the entry's `sign`).
    public let sign: DeviceSigningPublicKeys

    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public init(identity: MLKEM768X25519Identity, signing: any AuthorSigner) throws {
        self.identity = identity
        self.signing = signing
        sign = try signing.publicKeys()
    }

    /// Fresh keys from the system CSPRNG.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no X-Wing or ML-DSA.
    public static func generate() throws -> DeviceKeys {
        try DeviceKeys(identity: MLKEM768X25519Identity(), signing: DeviceSigningKeys.generate())
    }

    /// The decryption key as the age module's identity type.
    public var nativeIdentity: NativeIdentity { .mlkem768x25519(identity) }
    /// The `age1pq1…` recipient: the entry's `key`.
    public var key: String { identity.recipient.string }
    /// The device fingerprint (format.md §15.4).
    public var fingerprint: Data { KeyFingerprint.device(key: key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex) }
    /// The first 8 hex digits of the fingerprint: the entry's `id`, and the `<device>` of revision names.
    public var id: String { String(Hex.encode(fingerprint).prefix(8)) }

    /// This device's join request (format.md §15.12) for `vaultId`.
    public func joinRequest(vaultId: UUID, name: String, kind: String, created: Date = Date()) -> JoinRequest {
        JoinRequest(vaultId: vaultId, key: key, sign: sign, name: DeviceName.clean(name), kind: kind,
                    created: RFC3339.string(created))
    }

    // MARK: - The device key file

    static let header = "# sempere device key: keep it on this device, never copy it"
    static let p256Prefix = "# sempere-sign-p256: "
    static let mldsaPrefix = "# sempere-sign-mldsa65: "
    static let createdPrefix = "# created: "
    static let publicKeyPrefix = "# public key: "

    /// The device key file: the signing seeds and the public key as `#` comments, then the secret key,
    /// so that `age -d -i device.key` reads it as an identity file (it opens the device's wrap):
    ///
    /// ```
    /// # sempere device key: keep it on this device, never copy it
    /// # created: 2026-10-20T16:20:00Z
    /// # sempere-sign-p256: <64 hex digits: the P-256 scalar>
    /// # sempere-sign-mldsa65: <64 hex digits: the ML-DSA-65 seed>
    /// # public key: age1pq1…
    /// AGE-SECRET-KEY-PQ-1…
    /// ```
    ///
    /// - Throws: `DeviceKeysError.notInSoftware` for a signing pair in the Secure Enclave (it never leaves it).
    public func fileText(created: Date) throws -> String {
        guard let signing = signing as? DeviceSigningKeys else { throw DeviceKeysError.notInSoftware }
        return Self.header + "\n" + Self.createdPrefix + RFC3339.string(created) + "\n"
            + Self.p256Prefix + Hex.encode(signing.p256Scalar) + "\n"
            + Self.mldsaPrefix + Hex.encode(signing.mldsa65Seed) + "\n"
            + Self.publicKeyPrefix + key + "\n" + identity.string + "\n"
    }

    /// Reads a device key file (`fileText`). Lines other than the ones it names are ignored, as `age -i`
    /// ignores comments.
    ///
    /// - Throws: `DeviceKeysError`, or `AgeError.postQuantumUnavailable`.
    public static func parse(_ text: String) throws -> DeviceKeys {
        guard text.utf8.count <= maxBytes else { throw DeviceKeysError.malformed("larger than \(maxBytes) bytes") }
        var secret: String?, p256: Data?, mldsa: Data?, declared: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("AGE-SECRET-KEY-") {
                guard secret == nil else { throw DeviceKeysError.malformed("more than one secret key") }
                secret = line
            } else if line.hasPrefix(p256Prefix) {
                p256 = Hex.decode(String(line.dropFirst(p256Prefix.count)), count: 32)
            } else if line.hasPrefix(mldsaPrefix) {
                mldsa = Hex.decode(String(line.dropFirst(mldsaPrefix.count)), count: 32)
            } else if line.hasPrefix(publicKeyPrefix) {
                declared = String(line.dropFirst(publicKeyPrefix.count))
            }
        }
        guard let secret, secret.hasPrefix(pqIdentityPrefix) else {
            throw DeviceKeysError.malformed("no AGE-SECRET-KEY-PQ-1… line")
        }
        guard let p256, let mldsa else { throw DeviceKeysError.malformed("no signing seeds: not a device key file") }
        let identity: MLKEM768X25519Identity
        do { identity = try MLKEM768X25519Identity(string: secret) } catch AgeError.postQuantumUnavailable {
            throw AgeError.postQuantumUnavailable
        } catch {
            throw DeviceKeysError.malformed("the secret key does not parse")
        }
        if let declared, declared != identity.recipient.string { throw DeviceKeysError.publicKeyMismatch }
        let signing: DeviceSigningKeys
        do { signing = try DeviceSigningKeys(p256Scalar: p256, mldsa65Seed: mldsa) } catch {
            throw DeviceKeysError.malformed("the P-256 scalar is not a valid key")
        }
        return try DeviceKeys(identity: identity, signing: signing)
    }

    /// True when `text` looks like a device key file (it names signing seeds), so callers can tell it from
    /// a plain age identity file.
    public static func isDeviceKeyFile(_ text: String) -> Bool {
        text.utf8.count <= maxBytes && text.contains(p256Prefix) && text.contains(mldsaPrefix)
    }

    static let pqIdentityPrefix = "AGE-SECRET-KEY-PQ-1"
}

/// Device names (design §3: at most 40 characters, cleaned as the vault's `label`).
public enum DeviceName {
    /// The longest name writers store, in characters.
    public static let maxLength = 40

    /// A name as writers store it: one line, control characters as spaces, invisible format characters
    /// removed, trimmed, at most `maxLength` characters. It may be empty.
    public static func clean(_ name: String) -> String {
        String(VaultLabelText.clean(name).prefix(maxLength))
    }

    /// A name as readers show it: `clean`, "Device" when empty.
    public static func display(_ name: String) -> String {
        let c = clean(name)
        return c.isEmpty ? "Device" : c
    }
}
