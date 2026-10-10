import Crypto
import Foundation

/// `sempere-summaries.sealed` (format.md §12): the note summaries a cold
/// reader (the web viewer) lists and searches the vault with, without
/// decrypting every revision. Each entry names the revision files it was made
/// from, so it is used only while a note's listing still shows exactly those;
/// the file is a hint, and any problem with it means only a slower listing.
///
/// Sealed with AES-256-GCM under `HKDF(vaultSecret, "sempere/1 published
/// summaries key")`, the vault id in the associated data, so only recipients
/// can read or write it and a file of another vault (or secret) fails to open.
public enum PublishedSummaries {
    /// The file at the vault root.
    public static let fileName = "sempere-summaries.sealed"
    /// `format` of the JSON content.
    public static let format = "sempere-summaries/1"
    /// The largest file read (format.md §9).
    public static let maxFileBytes = 64 << 20
    /// The largest content after gunzip.
    public static let maxJSONBytes = 256 << 20
    /// HKDF `info` for the key.
    static let keyInfo = "sempere/1 published summaries key"
    /// `SMPU` then version 1.
    static let magic: [UInt8] = [0x53, 0x4D, 0x50, 0x55, 0x01]
    static let nonceSize = 12, tagSize = 16

    /// One note's entry (format.md §12.2).
    public struct Entry: Hashable, Sendable {
        /// Sorted revision file names the summary was made from.
        public var revisions: [String]
        public var title: String
        public var tags: [String]
        public var notebook: String?
        public var favorite: Bool
        public var deleted: Bool
        public var created: Date
        /// Greatest `wall` of the revisions.
        public var modified: Date
        public var pages: Int
        /// Searchable text per page with some (1-based page numbers, ascending).
        public var pageTexts: [PageTextEntry]

        public init(revisions: [String], title: String, tags: [String], notebook: String?, favorite: Bool,
                    deleted: Bool, created: Date, modified: Date, pages: Int, pageTexts: [PageTextEntry]) {
            self.revisions = revisions; self.title = title; self.tags = tags; self.notebook = notebook
            self.favorite = favorite; self.deleted = deleted; self.created = created; self.modified = modified
            self.pages = pages; self.pageTexts = pageTexts
        }

        /// The entry for a summary made from `revisions`; nil when the summary
        /// has a problem (unreadable revisions, no state) or holds content of a
        /// newer format version (format.md §7.4), which this writer cannot
        /// summarise in full: such notes are never published.
        public init?(summary s: NoteSummary, revisions: [String]) {
            guard s.problem == nil, s.newer == nil, !revisions.isEmpty, let created = s.created, let modified = s.modified,
                  RFC3339.string(from: created) != nil, RFC3339.string(from: modified) != nil else { return nil }
            self.init(revisions: revisions.sorted(), title: s.title, tags: s.tags, notebook: s.notebook,
                      favorite: s.favorite, deleted: s.deleted, created: created, modified: modified, pages: s.pages,
                      pageTexts: s.pageTexts.map { PageTextEntry(page: $0.number, text: $0.text) })
        }
    }

    /// A page's searchable text.
    public struct PageTextEntry: Hashable, Sendable, Codable {
        public var page: Int
        public var text: String
        public init(page: Int, text: String) { self.page = page; self.text = text }
    }

    /// The key for `secret`.
    static func key(_ secret: VaultSecret) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: Data(keyInfo.utf8), outputByteCount: 32)
    }

    static func aad(vaultId: UUID) -> Data {
        Data(magic) + Data("sempere/1".utf8) + Data([0]) + Data(vaultId.uuidString.lowercased().utf8)
    }

    // MARK: - Sealing

    /// `SMPU 0x01 ‖ nonce ‖ AES-256-GCM(plaintext) ‖ tag`; `nonce` is random unless given (test vectors).
    static func seal(_ plaintext: Data, secret: VaultSecret, vaultId: UUID, nonce: Data? = nil) throws -> Data {
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key(secret), nonce: n, authenticating: aad(vaultId: vaultId))
        guard let combined = box.combined else { throw PublishedSummariesError.damaged("cannot seal") }
        return Data(magic) + combined
    }

    /// The plaintext of a sealed file; throws `damaged` for anything that is not one of this vault's.
    static func open(_ data: Data, secret: VaultSecret, vaultId: UUID) throws -> Data {
        guard data.count <= maxFileBytes else { throw PublishedSummariesError.damaged("larger than \(maxFileBytes) bytes") }
        guard data.count >= magic.count + nonceSize + tagSize, data.prefix(magic.count).elementsEqual(magic) else {
            throw PublishedSummariesError.damaged("not a published summaries file")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            return try AES.GCM.open(box, using: key(secret), authenticating: aad(vaultId: vaultId))
        } catch {
            throw PublishedSummariesError.damaged("does not authenticate (another vault, another secret, or altered)")
        }
    }

    // MARK: - JSON

    private struct WireEntry: Codable {
        var revisions: [String]
        var title: String
        var tags: [String]
        var notebook: String?
        var favorite: Bool
        var deleted: Bool
        var created: String
        var modified: String
        var pages: Int
        var pageTexts: [PageTextEntry]
    }

    private struct WireFile: Encodable {
        var format: String
        var vaultId: String
        var notes: [String: WireEntry]
    }

    /// Decodes an entry, or nil when it is malformed (only that entry is dropped).
    private struct Lenient: Decodable {
        var entry: WireEntry?
        init(from decoder: Decoder) throws {
            entry = try? decoder.singleValueContainer().decode(WireEntry.self)
        }
    }

    private struct ReadFile: Decodable {
        var format: String
        var vaultId: String
        var notes: [String: Lenient]
    }

    /// The JSON content: sorted keys, no escaped slashes, so equal entries give equal bytes.
    public static func encode(_ entries: [UUID: Entry], vaultId: UUID) throws -> Data {
        var notes: [String: WireEntry] = [:]
        for (id, e) in entries {
            guard let created = RFC3339.string(from: e.created), let modified = RFC3339.string(from: e.modified) else {
                continue
            }
            notes[id.uuidString.lowercased()] = WireEntry(
                revisions: e.revisions.sorted(), title: e.title, tags: e.tags, notebook: e.notebook,
                favorite: e.favorite, deleted: e.deleted, created: created, modified: modified, pages: e.pages,
                pageTexts: e.pageTexts)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(WireFile(format: format, vaultId: vaultId.uuidString.lowercased(), notes: notes))
        data.append(0x0A)
        return data
    }

    /// The valid entries of a JSON content (format.md §12.3).
    ///
    /// - Throws: `damaged` when the content is not JSON of this format and vault.
    public static func decode(_ json: Data, vaultId: UUID) throws -> [UUID: Entry] {
        let file: ReadFile
        do { file = try JSONDecoder().decode(ReadFile.self, from: json) } catch {
            throw PublishedSummariesError.damaged("not a summaries document")
        }
        guard file.format == format else { throw PublishedSummariesError.damaged("format \(file.format)") }
        guard file.vaultId == vaultId.uuidString.lowercased() else {
            throw PublishedSummariesError.damaged("summaries of another vault")
        }
        var out: [UUID: Entry] = [:]
        for (key, lenient) in file.notes {
            guard let w = lenient.entry, let id = UUID(uuidString: key), id.uuidString.lowercased() == key,
                  let e = validate(w) else { continue }
            out[id] = e
        }
        return out
    }

    private static func validate(_ w: WireEntry) -> Entry? {
        guard !w.revisions.isEmpty, w.revisions == w.revisions.sorted(), Set(w.revisions).count == w.revisions.count,
              w.revisions.allSatisfy({ RevisionName($0)?.filename == $0 }),
              let created = RFC3339.parse(w.created), let modified = RFC3339.parse(w.modified),
              w.pages >= 0 else { return nil }
        var last = 0
        for p in w.pageTexts {
            guard p.page > last, p.page <= w.pages else { return nil }
            last = p.page
        }
        return Entry(revisions: w.revisions, title: w.title, tags: w.tags, notebook: w.notebook, favorite: w.favorite,
                     deleted: w.deleted, created: created, modified: modified, pages: w.pages, pageTexts: w.pageTexts)
    }
}

/// Why a published summaries file was ignored.
public enum PublishedSummariesError: Error, Hashable, Sendable {
    case damaged(String)
}

extension Vault {
    /// `<vault>/sempere-summaries.sealed`.
    public var publishedSummariesURL: URL { url.appendingPathComponent(PublishedSummaries.fileName) }

    /// The sealed file for `entries`.
    public func sealPublishedSummaries(_ entries: [UUID: PublishedSummaries.Entry]) throws -> Data {
        let json = try PublishedSummaries.encode(entries, vaultId: vaultId)
        return try PublishedSummaries.seal(try Gzip.compress(json), secret: try requireSecret(), vaultId: vaultId)
    }

    /// The valid entries of a sealed file of this vault.
    ///
    /// - Throws: `PublishedSummariesError.damaged` for a file that is not
    ///   this vault's (or is damaged); `VaultError.locked` without the secret.
    public func openPublishedSummaries(_ data: Data) throws -> [UUID: PublishedSummaries.Entry] {
        let plain = try PublishedSummaries.open(data, secret: try requireSecret(), vaultId: vaultId)
        let json: Data
        do { json = try Gzip.decompress(plain, maxOutput: PublishedSummaries.maxJSONBytes) } catch {
            throw PublishedSummariesError.damaged("does not gunzip")
        }
        return try PublishedSummaries.decode(json, vaultId: vaultId)
    }

    /// The local file's valid entries; empty when it is missing or unusable.
    public func readPublishedSummaries() -> [UUID: PublishedSummaries.Entry] {
        guard FileIO.exists(publishedSummariesURL),
              let data = try? FileIO.read(publishedSummariesURL, maxBytes: PublishedSummaries.maxFileBytes) else { return [:] }
        return (try? openPublishedSummaries(data)) ?? [:]
    }

    /// The entries to publish for `listing` (note id → revision file names;
    /// the vault's own listing when nil): one per note whose revisions in the
    /// listing are exactly the vault's and read cleanly. An entry of `reuse`
    /// made from the same names is kept without reading the note; the others
    /// are summarised through `cache` (format.md §10).
    ///
    /// - Parameter ownListing: the vault's own listing in the form of
    ///   `webIndexListing()`, when the caller just made it (the vault is not
    ///   listed again); nil lists the vault.
    /// - Returns: the entries and how many notes had to be summarised.
    public func publishedSummaryEntries(for listing: [String: [String]]? = nil,
                                        reuse: [UUID: PublishedSummaries.Entry] = [:],
                                        cache: SummaryCache? = nil,
                                        ownListing: [String: [String]]? = nil) throws
        -> (entries: [UUID: PublishedSummaries.Entry], summarised: Int) {
        try requireMigrated()
        _ = try requireReadable()
        var out: [UUID: PublishedSummaries.Entry] = [:]
        var toRead: [UUID] = []
        let own: [(UUID, [String])]
        if let ownListing {
            own = ownListing.sorted { $0.key < $1.key }.compactMap { k, v in UUID(uuidString: k).map { ($0, v.sorted()) } }
        } else {
            own = try noteIDs().map { ($0, try revisionNames(of: $0).map(\.filename).sorted()) }
        }
        for (id, names) in own {
            guard !names.isEmpty else { continue }
            if let listing, listing[id.uuidString.lowercased()]?.sorted() != names { continue }
            if let e = reuse[id], e.revisions == names { out[id] = e } else { toRead.append(id) }
        }
        if !toRead.isEmpty {
            for (summary, revisions) in try summaryEntries(of: toRead, cache: cache) {
                // A note may have changed while it was read: its entry names what was read.
                if let listing, listing[summary.id.uuidString.lowercased()]?.sorted() != revisions { continue }
                if let e = PublishedSummaries.Entry(summary: summary, revisions: revisions) { out[summary.id] = e }
            }
        }
        return (out, toRead.count)
    }

    /// Rewrites `sempere-summaries.sealed` when it exists and no longer
    /// matches the vault; never creates it (`sempere vault summaries` does).
    /// Needs the vault unlocked; a locked or legacy vault is left alone.
    ///
    /// - Returns: true when the file was rewritten.
    /// The vault is opened again first (a command may have changed its
    /// manifest); with `cacheDirectory`, notes are summarised through the
    /// summary cache there (format.md §10).
    @discardableResult
    public func refreshPublishedSummaries(cacheDirectory: URL? = nil, ownListing: [String: [String]]? = nil) throws -> Bool {
        // A read-only vault is never written, not even its summaries (format.md §7.3).
        guard FileIO.exists(publishedSummariesURL), canRead, !isReadOnly,
              let vault = try? Vault.open(at: url, identities: identities) else { return false }
        return try vault.refreshOpenedPublishedSummaries(
            cache: cacheDirectory.flatMap { try? SummaryCache(directory: $0, vault: vault) }, ownListing: ownListing)
    }

    private func refreshOpenedPublishedSummaries(cache: SummaryCache?, ownListing: [String: [String]]?) throws -> Bool {
        guard canRead, (try? requireMigrated()) != nil else { return false }
        let data = try? FileIO.read(publishedSummariesURL, maxBytes: PublishedSummaries.maxFileBytes)
        let current = data.flatMap { try? openPublishedSummaries($0) }
        guard !isReadOnly else { return false }
        let (entries, _) = try publishedSummaryEntries(reuse: current ?? [:], cache: cache, ownListing: ownListing)
        // Summarising may have just read newer content (format.md §7.3).
        guard !isReadOnly else { return false }
        if let current, current == entries { return false }
        try FileIO.writeAtomically(try sealPublishedSummaries(entries), to: publishedSummariesURL, replacing: true)
        return true
    }
}
