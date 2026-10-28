import Crypto
import Foundation

private let scryptLabel = Array("age-encryption.org/v1/scrypt".utf8)

/// A passphrase recipient (the `age -p` scrypt stanza). It must be the only
/// recipient of a file; `AgeFile.encrypt` and `AgeFile.decrypt` enforce that.
public struct ScryptRecipient: AgeRecipient {
    let passphrase: [UInt8]
    let workFactor: Int

    /// - Parameter workFactor: log2 of the scrypt N parameter (1...30).
    ///   `age` uses 18; `docs/format.md` §3.2 asks writers for 15...18.
    public init(passphrase: String, workFactor: Int = 18) {
        self.passphrase = Array(passphrase.utf8)
        self.workFactor = workFactor
    }

    /// Wraps `fileKey` in one `scrypt` stanza with a fresh 16-byte salt.
    ///
    /// - Throws: `AgeError.scryptWorkFactor` if the work factor is outside
    ///   1...30.
    public func wrap(fileKey: FileKey) throws -> [Stanza] {
        guard (1...30).contains(workFactor) else { throw AgeError.scryptWorkFactor }
        let salt = secureRandomBytes(16)
        guard
            let k = Scrypt.derive(
                password: passphrase, salt: scryptLabel + salt, n: 1 << workFactor, r: 8, p: 1, keyLength: 32)
        else { throw AgeError.scryptWorkFactor }
        let body = try aeadSealFileKey(key: SymmetricKey(data: k), fileKey: fileKey)
        return [Stanza(type: "scrypt", args: [Base64.encodeRaw(salt), String(workFactor)], body: body)]
    }
}

/// A passphrase identity that unwraps scrypt stanzas.
public struct ScryptIdentity: AgeIdentity {
    let passphrase: [UInt8]
    let maxWorkFactor: Int
    let maxMemoryBytes: Int

    /// - Parameters:
    ///   - maxWorkFactor: the largest log2(N) accepted when decrypting;
    ///     larger values throw `AgeError.scryptWorkFactor`. `docs/format.md`
    ///     §3.2 requires accepting up to 20. Values above 30 are clamped.
    ///   - maxMemoryBytes: the most memory scrypt may allocate (128 · r · N
    ///     bytes, 2^w KiB at r = 8); a stanza needing more throws
    ///     `AgeError.scryptWorkFactor` instead of attempting the allocation.
    ///     The default, 1 GiB, matches the default work factor cap of 20.
    public init(passphrase: String, maxWorkFactor: Int = 20, maxMemoryBytes: Int = 1 << 30) {
        self.passphrase = Array(passphrase.utf8)
        self.maxWorkFactor = min(maxWorkFactor, 30)
        self.maxMemoryBytes = maxMemoryBytes
    }

    /// Unwraps the file key from the header's scrypt stanza.
    ///
    /// - Returns: nil if there is no scrypt stanza or the passphrase is wrong.
    /// - Throws: `AgeError.scryptNotAlone` if the scrypt stanza is not the only
    ///   stanza, `AgeError.scryptWorkFactor` if the work factor exceeds the
    ///   cap or the memory budget, `AgeError.invalidStanza` if the stanza is
    ///   malformed.
    public func unwrap(stanzas: [Stanza]) throws -> FileKey? {
        guard let stanza = stanzas.first(where: { $0.type == "scrypt" }) else { return nil }
        guard stanzas.count == 1 else { throw AgeError.scryptNotAlone }
        guard stanza.args.count == 2,
            let salt = Base64.decodeRaw(stanza.args[0].utf8), salt.count == 16
        else { throw AgeError.invalidStanza }
        let wf = Array(stanza.args[1].utf8)
        // ^[1-9][0-9]*$, then a range check (also catches overflow).
        guard let first = wf.first, (0x31...0x39).contains(first), wf.allSatisfy({ (0x30...0x39).contains($0) })
        else { throw AgeError.invalidStanza }
        guard wf.count <= 2, let logN = Int(stanza.args[1]), logN <= maxWorkFactor,
            let memory = Scrypt.memoryBytes(n: 1 << logN, r: 8), memory <= maxMemoryBytes
        else {
            throw AgeError.scryptWorkFactor
        }
        guard stanza.body.count == 32 else { throw AgeError.invalidStanza }
        guard
            let k = Scrypt.derive(
                password: passphrase, salt: scryptLabel + salt, n: 1 << logN, r: 8, p: 1, keyLength: 32,
                maxMemoryBytes: maxMemoryBytes)
        else { throw AgeError.scryptWorkFactor }
        return try aeadOpenFileKey(key: SymmetricKey(data: k), body: stanza.body)
    }
}
