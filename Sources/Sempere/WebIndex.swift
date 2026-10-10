import Foundation

/// `sempere-index.json` (docs/web-viewer.md "Hosting"): the note and
/// revision listing the web viewer reads where the server cannot list
/// folders. Names only (note ids and revision file names, which storage
/// shows anyway), never content; no key needed. To every reader of the
/// format it is an unknown file (format.md §1).
///
/// Wherever the file exists it is kept current: every `sempere` command
/// that opens a vault rewrites it when the vault's listing changed, and
/// `sempere sync webdav` rewrites the server's copy after a sync.
public enum WebIndex {
    /// The file at the vault root.
    public static let fileName = "sempere-index.json"
    /// `format` of the file.
    public static let format = "sempere-index/1"
    /// The largest index read back (the viewer's limit too).
    public static let maxBytes = 64 << 20

    /// The file's bytes for a listing (note id → revision file names):
    /// sorted keys and names, no escaped slashes, a final newline, so equal
    /// listings give equal bytes and an unchanged index is never rewritten.
    public static func encode(_ notes: [String: [String]]) throws -> Data {
        struct Index: Encodable { var format: String; var notes: [String: [String]] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Index(format: format, notes: notes.mapValues { $0.sorted() }))
        data.append(0x0A)
        return data
    }
}

extension Vault {
    /// `<vault>/sempere-index.json`.
    public var webIndexURL: URL { url.appendingPathComponent(WebIndex.fileName) }

    /// Every note id and its revision file names, as `sempere-index.json`
    /// lists them (`att/` and unknown files left out). Needs no key.
    public func webIndexListing() throws -> [String: [String]] {
        var notes: [String: [String]] = [:]
        for id in try noteIDs() {
            notes[id.uuidString.lowercased()] = try revisionNames(of: id).map(\.filename)
        }
        return notes
    }

    /// Rewrites `sempere-index.json` when it exists and no longer matches the
    /// vault's listing; never creates it (`sempere vault index` does). A
    /// legacy vault is left alone: the viewer cannot read one.
    ///
    /// - Parameter listing: `webIndexListing()` when the caller just made
    ///   it (it is not listed again); nil lists the vault.
    /// - Returns: true when the file was rewritten.
    @discardableResult
    public func refreshWebIndex(listing: [String: [String]]? = nil) throws -> Bool {
        // A read-only vault is never written, not even its index (format.md §7.3).
        guard FileIO.exists(webIndexURL), (try? requireMigrated()) != nil, !isReadOnly else { return false }
        let data = try WebIndex.encode(try listing ?? webIndexListing())
        if let current = try? FileIO.read(webIndexURL, maxBytes: WebIndex.maxBytes), current == data { return false }
        try FileIO.writeAtomically(data, to: webIndexURL, replacing: true)
        return true
    }
}
