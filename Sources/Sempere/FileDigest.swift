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
        return try sha256(of: handle, path: url.path, maxBytes: maxBytes)
    }

    /// `sha256(of:maxBytes:)` of the regular file at `path` under `root`,
    /// following no symbolic link below `root` (`BoundedRead.openRegularFile(under:_:)`).
    public static func sha256(under root: URL, _ path: String, maxBytes: Int64 = .max) throws
        -> (hex: String, size: Int64)
    {
        let handle = try BoundedRead.openRegularFile(under: root, path)
        defer { try? handle.close() }
        return try sha256(of: handle, path: root.appendingPathComponent(path).path, maxBytes: maxBytes)
    }

    static func sha256(of handle: FileHandle, path: String, maxBytes: Int64) throws -> (hex: String, size: Int64) {
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let piece: Data
            do { piece = try autoreleasing { try handle.read(upToCount: 1 << 20) ?? Data() } } catch {
                throw VaultError.io("read \(path): \(error)")
            }
            if piece.isEmpty { break }
            size += Int64(piece.count)
            guard size <= maxBytes else { throw VaultError.fileTooLarge(path, limit: Int(clamping: maxBytes)) }
            hasher.update(data: piece)
        }
        return (Hex.encode(hasher.finalize()), size)
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256(_ data: Data) -> String {
        Hex.encode(SHA256.hash(data: data))
    }
}
