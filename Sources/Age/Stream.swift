import Crypto
import Foundation

/// The STREAM payload encryption (age spec "Payload"), mirroring
/// `filippo.io/age/internal/stream`.
enum Stream {
    static let chunkSize = 64 * 1024
    static let tagSize = 16
    static let encryptedChunkSize = chunkSize + tagSize
    static let nonceSize = 16

    static func payloadKey(fileKey: FileKey, nonce: some DataProtocol) -> SymmetricKey {
        hkdfSHA256(ikm: fileKey.bytes, salt: nonce, info: "payload")
    }

    /// 11-byte big-endian counter followed by the last-chunk flag.
    static func chunkNonce(_ counter: UInt64, last: Bool) -> ChaChaPoly.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { n[3 + i] = UInt8(truncatingIfNeeded: counter >> UInt64(56 - 8 * i)) }
        n[11] = last ? 1 : 0
        // 12 bytes is always a valid ChaChaPoly nonce.
        guard let nonce = try? ChaChaPoly.Nonce(data: n) else { fatalError("unreachable") }
        return nonce
    }

    /// Seals one chunk: ciphertext followed by the 16-byte Poly1305 tag.
    static func seal(_ chunk: some DataProtocol, key: SymmetricKey, counter: UInt64, last: Bool) throws -> Data {
        let box = try ChaChaPoly.seal(chunk, using: key, nonce: chunkNonce(counter, last: last))
        return box.ciphertext + box.tag
    }

    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        out.reserveCapacity(plaintext.count + (plaintext.count / chunkSize + 1) * tagSize)
        var counter: UInt64 = 0
        var offset = plaintext.startIndex
        repeat {
            let end = min(offset + chunkSize, plaintext.endIndex)
            let last = end == plaintext.endIndex
            let box = try ChaChaPoly.seal(plaintext[offset..<end], using: key, nonce: chunkNonce(counter, last: last))
            out += box.ciphertext
            out += box.tag
            offset = end
            counter += 1
        } while offset < plaintext.endIndex
        return out
    }

    /// Decrypts `payload` (everything after the nonce), appending each
    /// authenticated chunk to `released` as it goes, so a caller can see
    /// what was released before a failure. Throws `AgeError.payload` on a
    /// bad tag, a missing or empty final chunk, or trailing data.
    static func decrypt(_ payload: Data, key: SymmetricKey, released: inout Data) throws {
        var counter: UInt64 = 0
        var offset = payload.startIndex
        while true {
            let remaining = payload.endIndex - offset
            // A message can't end without a chunk marked final.
            guard remaining > 0 else { throw AgeError.payload }
            var last = remaining < encryptedChunkSize
            let n = min(remaining, encryptedChunkSize)
            // The final chunk may be short but not empty, unless it is the
            // only chunk (an empty payload).
            if last && counter != 0 && n == tagSize { throw AgeError.payload }
            guard n >= tagSize else { throw AgeError.payload }
            let chunk = payload[offset..<offset + n]
            var plain = open(chunk, key: key, counter: counter, last: last)
            if plain == nil && !last {
                // A full-length chunk may also be the final one.
                last = true
                plain = open(chunk, key: key, counter: counter, last: true)
            }
            guard let plain else { throw AgeError.payload }
            released += plain
            offset += n
            counter += 1
            if last {
                guard offset == payload.endIndex else { throw AgeError.payload }
                return
            }
        }
    }

    /// Opens one sealed chunk; nil if it does not authenticate under this
    /// counter and final-chunk flag.
    static func open(_ chunk: Data, key: SymmetricKey, counter: UInt64, last: Bool) -> Data? {
        let ct = chunk.prefix(chunk.count - tagSize), tag = chunk.suffix(tagSize)
        guard let box = try? ChaChaPoly.SealedBox(nonce: chunkNonce(counter, last: last), ciphertext: ct, tag: tag)
        else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }
}
