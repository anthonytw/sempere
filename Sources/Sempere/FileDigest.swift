import Crypto
import Foundation

/// SHA-256 of files, streamed (models and other large downloads are never
/// held in memory to be hashed).
public enum FileDigest {
    /// Lowercase hex SHA-256 of the regular file at `url` and its size,
    /// read in 1 MiB pieces; stops with `VaultError.fileTooLarge` past `maxBytes`.
    public static func sha256(of url: URL, maxBytes: Int64 = .max) throws -> (hex: String, size: Int64) {
        let handle = try BoundedRead.openRegularFile(url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let piece: Data
            do { piece = try handle.read(upToCount: 1 << 20) ?? Data() } catch {
                throw VaultError.io("read \(url.path): \(error)")
            }
            if piece.isEmpty { break }
            size += Int64(piece.count)
            guard size <= maxBytes else { throw VaultError.fileTooLarge(url.path, limit: Int(clamping: maxBytes)) }
            hasher.update(data: piece)
        }
        return (Hex.encode(hasher.finalize()), size)
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256(_ data: Data) -> String {
        Hex.encode(SHA256.hash(data: data))
    }
}
