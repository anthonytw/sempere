import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// The signing item's contents (`StoredSigning`, moved from the app with wave 6 follow-up F1; the Secure Enclave pair
/// that fills it is the app's `SecureEnclaveSigner`, tested on a device there).
struct StoredSigningTests {
    /// Stands in for the app's enclave signer: blobs and public keys, signing with a software pair.
    struct FakeEnclaveSigner: EnclaveBackedSigner {
        let p256Blob: Data
        let mldsa65Blob: Data
        let keys: DeviceSigningPublicKeys

        init(p256Blob: Data, mldsa65Blob: Data, keys: DeviceSigningPublicKeys) {
            self.p256Blob = p256Blob; self.mldsa65Blob = mldsa65Blob; self.keys = keys
        }

        func publicKeys() throws -> DeviceSigningPublicKeys { keys }
        func sign(_ message: Data) throws -> AuthorSignature { throw DeviceKeyStoreError.malformed }
    }

    /// Moved from the app's `JoinTakeoverPlatformTests`.
    @Test func storedSigningRoundTripsASoftwarePair() throws {
        let pair = DeviceSigningKeys.generate()
        let stored = try StoredSigning(pair)
        #expect(stored.kind == StoredSigning.software && stored.publicP256 == nil)
        let back = try JSONDecoder().decode(StoredSigning.self, from: JSONEncoder().encode(stored))
        #expect(back == stored)
        let signer = try back.signer(enclave: FakeEnclaveSigner.self)
        #expect(signer is DeviceSigningKeys)
        let message = Data("m".utf8)
        #expect(try signer.sign(message).verifies(message, keys: try pair.publicKeys()))
    }

    @Test func anEnclavePairKeepsItsBlobsAndPublicKeys() throws {
        let keys = try DeviceSigningKeys.generate().publicKeys()
        let enclave = FakeEnclaveSigner(p256Blob: Data([1, 2, 3]), mldsa65Blob: Data([4, 5]), keys: keys)
        let stored = try StoredSigning(enclave, fingerprint: Data([9]))
        #expect(stored.kind == StoredSigning.enclave)
        #expect(stored.p256 == Data([1, 2, 3]) && stored.mldsa65 == Data([4, 5]))
        #expect(stored.publicP256 == keys.p256 && stored.publicMLDSA65 == keys.mldsa65)
        #expect(stored.fingerprint == Data([9]), "readable without the device key")
        let back = try JSONDecoder().decode(StoredSigning.self, from: JSONEncoder().encode(stored))
        let signer = try #require(try back.signer(enclave: FakeEnclaveSigner.self) as? FakeEnclaveSigner)
        #expect(signer.p256Blob == Data([1, 2, 3]) && signer.mldsa65Blob == Data([4, 5]) && signer.keys == keys)
    }

    @Test func aStoredItemThatDoesNotReadAsKeysIsMalformed() throws {
        let keys = try DeviceSigningKeys.generate().publicKeys()
        var stored = try StoredSigning(FakeEnclaveSigner(p256Blob: Data([1]), mldsa65Blob: Data([2]), keys: keys))
        stored.publicMLDSA65 = nil
        #expect(throws: DeviceKeyStoreError.malformed) { try stored.signer(enclave: FakeEnclaveSigner.self) }
        stored.kind = "tpm"
        #expect(throws: DeviceKeyStoreError.malformed) { try stored.signer(enclave: FakeEnclaveSigner.self) }
        // A software item with seeds of the wrong size is not keys either.
        var software = try StoredSigning(DeviceSigningKeys.generate())
        software.p256 = Data([1])
        #expect(throws: (any Error).self) { try software.signer(enclave: FakeEnclaveSigner.self) }
    }

    /// Only the enclave and software signers can be stored.
    @Test func anyOtherSignerIsRefused() {
        struct Other: AuthorSigner {
            func publicKeys() throws -> DeviceSigningPublicKeys { throw DeviceKeyStoreError.malformed }
            func sign(_ message: Data) throws -> AuthorSignature { throw DeviceKeyStoreError.malformed }
        }
        #expect(throws: DeviceKeyStoreError.malformed) { try StoredSigning(Other()) }
    }
}
