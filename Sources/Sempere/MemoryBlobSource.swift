import Foundation

/// Blobs held in memory, by content hash, as a `BlobSource` (format.md §8.1):
/// for tests and for exporting content that is not in a vault yet. Every
/// read checks the content against the reference's hash and size, as the
/// vault's blob store does.
public struct MemoryBlobSource: BlobSource {
    /// Content by SHA-256 (lowercase hex).
    public var blobs: [String: Data]

    public init(_ contents: [Data] = []) {
        blobs = [:]
        for c in contents { blobs[BlobRef(content: c, type: "").sha256] = c }
    }

    /// - Throws: `BlobError.contentTooLarge` beyond `maxBytes`, `.missing`
    ///   (with the hash) when no content has it, `.referenceMismatch` when
    ///   the stored content's hash or size differ from the reference.
    public func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        guard ref.size <= Int64(maxBytes) else { throw BlobError.contentTooLarge(limit: Int64(maxBytes)) }
        guard let d = blobs[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        guard Int64(d.count) == ref.size, BlobRef(content: d, type: ref.type).sha256 == ref.sha256 else {
            throw BlobError.referenceMismatch
        }
        return d
    }

    /// True when content with the reference's hash and size is held.
    public func isAvailable(_ ref: BlobRef) -> Bool {
        blobs[ref.sha256].map { Int64($0.count) == ref.size } ?? false
    }

    /// The content in a private temporary file (mode 0600, created
    /// exclusively), deleted afterwards, like `Vault.withBlobFile`.
    public func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        let d = try data(for: ref, maxBytes: Int(BlobRef.maxSize))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sempere-blob-" + UUID().uuidString.lowercased())
        try FileIO.writeNewFile(tmp) { write in try write(d) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try body(tmp)
    }
}
