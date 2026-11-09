import Foundation
import Sempere

/// A signing pair whose private halves live in a Secure Enclave: key blobs only that device's enclave can use, and the
/// public keys that go with them. The app's `SecureEnclaveSigner` is the one conformer; the stored item
/// (`StoredSigning`) only needs to read the blobs and build one again.
public protocol EnclaveBackedSigner: AuthorSigner {
    var p256Blob: Data { get }
    var mldsa65Blob: Data { get }
    var keys: DeviceSigningPublicKeys { get }
    init(p256Blob: Data, mldsa65Blob: Data, keys: DeviceSigningPublicKeys)
}

/// The signing item's contents (the app keeps it in the Keychain, `KeychainDeviceKeyStore`): enclave blobs, or
/// software seeds where there is no enclave. Its JSON is what the Keychain holds, so its keys are stable.
public struct StoredSigning: Codable, Equatable, Sendable {
    public var kind: String
    public var p256: Data
    public var mldsa65: Data
    public var publicP256: Data?
    public var publicMLDSA65: Data?
    /// The device fingerprint of the keys (read without the device key, which may need Face ID).
    public var fingerprint: Data?

    public static let enclave = "enclave", software = "software"

    /// `signer`'s keys as stored: an enclave signer's blobs, or a software pair's seeds; any other signer is `malformed`.
    public init(_ signer: any AuthorSigner, fingerprint: Data? = nil) throws {
        self.fingerprint = fingerprint
        if let se = signer as? any EnclaveBackedSigner {
            kind = Self.enclave
            p256 = se.p256Blob; mldsa65 = se.mldsa65Blob
            publicP256 = se.keys.p256; publicMLDSA65 = se.keys.mldsa65
        } else if let sw = signer as? DeviceSigningKeys {
            kind = Self.software
            p256 = sw.p256Scalar; mldsa65 = sw.mldsa65SeedBytes
        } else {
            throw DeviceKeyStoreError.malformed
        }
    }

    /// The signer these contents describe; `enclave` builds an enclave one (the app's `SecureEnclaveSigner`).
    public func signer(enclave: any EnclaveBackedSigner.Type) throws -> any AuthorSigner {
        switch kind {
        case Self.enclave:
            guard let pp = publicP256, let pm = publicMLDSA65, let keys = DeviceSigningPublicKeys(p256: pp, mldsa65: pm) else {
                throw DeviceKeyStoreError.malformed
            }
            return enclave.init(p256Blob: p256, mldsa65Blob: mldsa65, keys: keys)
        case Self.software:
            return try DeviceSigningKeys(p256Scalar: p256, mldsa65Seed: mldsa65)
        default:
            throw DeviceKeyStoreError.malformed
        }
    }
}
