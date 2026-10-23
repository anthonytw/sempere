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
    /// The folder of the per-device files (format.md §12.5): `summaries/<device>.sealed`.
    public static let deviceFolderName = "summaries"
    /// `<device>.sealed`.
    public static func deviceFileName(_ device: DeviceID) -> String { "\(device).sealed" }
    /// The device of a per-device file name; nil for any other name (ignored).
    public static func device(ofFileName name: String) -> DeviceID? {
        guard name.hasSuffix(".sealed") else { return nil }
        return DeviceID(String(name.dropLast(".sealed".count)))
    }

    /// For each note, the entry to show (format.md §12.3, §12.5), out of every
    /// published file the reader opened: one whose `revisions` are exactly the
    /// note's listed revision file names (`listing`, sorted or not) when there
    /// is one; otherwise, provisionally (the note has not arrived, or changed
    /// since), the entry made from the most revisions, then the latest
    /// `modified`, then the greatest first revision name, so every reader picks
    /// the same one. Notes `listing` does not name keep their best entry too
    /// (a reader that has not listed the folder yet); the caller decides
    /// whether to show them.
    public static func best(of files: [[UUID: Entry]], listing: [UUID: [String]] = [:]) -> [UUID: Entry] {
        var out: [UUID: Entry] = [:]
        var exact: Set<UUID> = []
        for file in files {
            for (id, e) in file {
                if exact.contains(id) { continue }
                if let names = listing[id], !names.isEmpty, names.sorted() == e.revisions {
                    out[id] = e
                    exact.insert(id)
                    continue
                }
                guard let current = out[id] else { out[id] = e; continue }
                if (e.revisions.count, e.modified, e.revisions.last ?? "")
                    > (current.revisions.count, current.modified, current.revisions.last ?? "") {
                    out[id] = e
                }
            }
        }
        return out
    }

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
        /// summarize in full: such notes are never published.
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
    static func key(_ secret: VaultEpochKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: Data(keyInfo.utf8), outputByteCount: 32)
    }

    /// `SMPU` then version 3: a signed per-device file (format.md §12.5), whose header also carries its epoch.
    static let deviceMagic: [UInt8] = [0x53, 0x4D, 0x50, 0x55, 0x03]
    /// `deviceMagic` and the epoch (4 bytes, big-endian).
    static let deviceHeaderSize = 9
    /// The signature after a per-device file's tag: P-256 `r ‖ s` (64 bytes), then ML-DSA-65 (3309 bytes).
    static let signatureSize = AuthorSignature.p256Size + AuthorSignature.mldsa65Size

    static func aad(vaultId: UUID) -> Data { aad(header: Data(magic), vaultId: vaultId) }

    static func aad(header: Data, vaultId: UUID) -> Data {
        header + Data("sempere/1".utf8) + Data([0]) + Data(vaultId.uuidString.lowercased().utf8)
    }

    /// True when `data` starts like a sealed summaries file (`SMPU` `0x01`, or `0x03` for a per-device file).
    public static func looksSealed(_ data: Data) -> Bool {
        data.starts(with: magic) || data.starts(with: deviceMagic)
    }

    /// The epoch in the clear header of a per-device file (`SMPU` `0x03`, format.md §12.5), nil for any other
    /// bytes. It is bound to the content as associated data and covered by the signature, so a file whose
    /// header was changed does not open; read without the key, it tells whether a file that does not open
    /// is of a later epoch.
    public static func sealedEpoch(_ data: Data) -> Int? {
        guard data.count >= deviceHeaderSize, data.starts(with: deviceMagic) else { return nil }
        let b = Array(data.prefix(deviceHeaderSize).suffix(4))
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    /// A per-device file split into its sealed part (header, nonce, ciphertext, tag) and its signature; nil
    /// when it is not `SMPU` `0x03` or too short to hold both.
    static func split(_ data: Data) -> (sealed: Data, signature: AuthorSignature)? {
        guard data.starts(with: deviceMagic), data.count >= deviceHeaderSize + nonceSize + tagSize + signatureSize else {
            return nil
        }
        let sealed = Data(data.prefix(data.count - signatureSize))
        let sig = Data(data.suffix(signatureSize))
        guard let signature = AuthorSignature(p256: Data(sig.prefix(AuthorSignature.p256Size)),
                                              mldsa65: Data(sig.suffix(AuthorSignature.mldsa65Size))) else { return nil }
        return (sealed, signature)
    }

    /// `sealed` followed by `signature` (P-256, then ML-DSA-65): a per-device file.
    static func attach(_ signature: AuthorSignature, to sealed: Data) -> Data {
        sealed + signature.p256 + signature.mldsa65
    }

    // MARK: - Sealing

    /// `SMPU 0x01 ‖ nonce ‖ AES-256-GCM(plaintext) ‖ tag`, or with `epoch` the sealed part of a per-device
    /// file (§12.5), `SMPU 0x03 ‖ epoch (u32 BE) ‖ nonce ‖ … ‖ tag`, which its signature then follows
    /// (`attach`); the header is the associated data's start.
    /// `nonce` is random unless given (test vectors).
    static func seal(_ plaintext: Data, secret: VaultEpochKey, vaultId: UUID, epoch: Int? = nil, nonce: Data? = nil) throws -> Data {
        var header = Data(magic)
        if let epoch {
            guard (0...Int(UInt32.max)).contains(epoch) else { throw PublishedSummariesError.damaged("epoch out of range") }
            let e = UInt32(epoch)
            header = Data(deviceMagic) + Data([UInt8(e >> 24), UInt8(e >> 16 & 0xff), UInt8(e >> 8 & 0xff), UInt8(e & 0xff)])
        }
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key(secret), nonce: n, authenticating: aad(header: header, vaultId: vaultId))
        guard let combined = box.combined else { throw PublishedSummariesError.damaged("cannot seal") }
        return header + combined
    }

    /// The plaintext of a sealed file (a per-device file's sealed part, without its signature: `split`);
    /// throws `damaged` for anything that is not one of this vault's. Checks no signature.
    static func open(_ data: Data, secret: VaultEpochKey, vaultId: UUID) throws -> Data {
        guard data.count <= maxFileBytes else { throw PublishedSummariesError.damaged("larger than \(maxFileBytes) bytes") }
        let headerSize = data.starts(with: deviceMagic) ? deviceHeaderSize : magic.count
        guard data.count >= headerSize + nonceSize + tagSize, looksSealed(data) else {
            throw PublishedSummariesError.damaged("not a published summaries file")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(headerSize))
            return try AES.GCM.open(box, using: key(secret), authenticating: aad(header: Data(data.prefix(headerSize)), vaultId: vaultId))
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
        /// Per-device files only (format.md §12.5): the writer's device id and its version of the file.
        var device: String?
        var version: Int64?
        var notes: [String: WireEntry]
        /// Per-device files only (format.md §12.5): the end of the device's last complete two-way sync.
        var synced: String?
    }

    /// Decodes an entry, or nil when it is malformed (only that entry is dropped).
    private struct Lenient: Decodable {
        var entry: WireEntry?
        init(from decoder: Decoder) throws {
            entry = try? decoder.singleValueContainer().decode(WireEntry.self)
        }
    }

    /// A field decoded leniently: nil when absent or malformed (only that field is dropped).
    private struct LenientField<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(T.self)
        }
    }

    private struct ReadFile: Decodable {
        var format: String
        var vaultId: String
        var device: LenientField<String>?
        var version: LenientField<Int64>?
        var notes: [String: Lenient]
        var synced: LenientField<String>?
    }

    /// The greatest `version` (format.md §12.5): 2^53 − 1, exact in every JSON reader (the web viewer's too).
    public static let maxVersion: Int64 = (1 << 53) - 1

    /// What a sealed file holds: its entries and, in a per-device file, its writer and version.
    public struct Contents: Hashable, Sendable {
        public var entries: [UUID: Entry]
        /// The writer's device id (`device`), nil when absent or malformed.
        public var device: DeviceID?
        /// The writer's version of its file (`version`, 1 … `maxVersion`), nil when absent or out of range.
        public var version: Int64?
        /// Per-device files: when the writer last completed a two-way sync (`synced`, key-hierarchy design §5.5),
        /// nil when absent or malformed.
        public var synced: Date?

        public init(entries: [UUID: Entry], device: DeviceID? = nil, version: Int64? = nil, synced: Date? = nil) {
            self.entries = entries; self.device = device; self.version = version; self.synced = synced
        }
    }

    /// How far ahead of a reader's clock a `version` may be (format.md §12.5): 7 days. A later one counts
    /// as no version, so a key holder who seals another device's file at a far-future version (or at the
    /// cap) never wins over the real one, and no writer ever climbs toward `maxVersion`.
    public static let futureWindow: TimeInterval = 7 * 24 * 3600

    /// The milliseconds since 1970 of `date`, clamped to 1 … `maxVersion`.
    public static func millis(_ date: Date) -> Int64 {
        let ms = date.timeIntervalSince1970 * 1000
        return ms.isFinite && ms >= 1 ? (ms < Double(maxVersion) ? Int64(ms) : maxVersion) : 1
    }

    /// `version` when a reader whose clock says `now` takes it (at most `futureWindow` ahead), else nil.
    public static func accepted(_ version: Int64?, now: Date) -> Int64? {
        guard let version else { return nil }
        return version <= millis(now.addingTimeInterval(futureWindow)) ? version : nil
    }

    /// The version a device gives the file it writes now (format.md §12.5): one more than its previous
    /// one, and at least the milliseconds since 1970 of `now`, so a device that lost its file (and with it
    /// its last version) still writes a later one. Nil only when the previous one is already `maxVersion`
    /// (which `accepted` keeps out of reach: a previous version beyond the window is no version).
    public static func nextVersion(after previous: Int64?, now: Date) -> Int64? {
        let clock = millis(now)
        guard let previous, previous >= 1 else { return clock }
        guard previous < maxVersion else { return nil }
        return max(previous + 1, clock)
    }

    /// The JSON content: sorted keys, no escaped slashes, so equal entries give equal bytes.
    public static func encode(_ entries: [UUID: Entry], vaultId: UUID, device: DeviceID? = nil,
                              version: Int64? = nil, synced: Date? = nil) throws -> Data {
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
        var data = try encoder.encode(WireFile(format: format, vaultId: vaultId.uuidString.lowercased(),
                                               device: device?.rawValue, version: version, notes: notes,
                                               synced: synced.flatMap { RFC3339.string(from: $0) }))
        data.append(0x0A)
        return data
    }

    /// The valid entries of a JSON content (format.md §12.3).
    ///
    /// - Throws: `damaged` when the content is not JSON of this format and vault.
    public static func decode(_ json: Data, vaultId: UUID) throws -> [UUID: Entry] {
        try decodeContents(json, vaultId: vaultId).entries
    }

    /// The valid entries of a JSON content, with its `device` and `version` (format.md §12.3, §12.5).
    ///
    /// - Throws: `damaged` when the content is not JSON of this format and vault.
    public static func decodeContents(_ json: Data, vaultId: UUID) throws -> Contents {
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
        let version = file.version?.value.flatMap { (1...maxVersion).contains($0) ? $0 : nil }
        return Contents(entries: out, device: file.device?.value.flatMap { DeviceID($0) }, version: version,
                        synced: file.synced?.value.flatMap { RFC3339.parse($0) })
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
    /// A per-device file cannot be written: the vault was not opened as a listed device with its signing keys.
    case cannotSign(String)
}

extension Vault {
    /// `<vault>/sempere-summaries.sealed`.
    public var publishedSummariesURL: URL { url.appendingPathComponent(PublishedSummaries.fileName) }

    /// `<vault>/summaries/<device>.sealed`: the published summaries `device` writes (format.md §12.5).
    public func devicePublishedSummariesURL(_ device: DeviceID) -> URL {
        url.appendingPathComponent(PublishedSummaries.deviceFolderName, isDirectory: true)
            .appendingPathComponent(PublishedSummaries.deviceFileName(device))
    }

    /// Every published summaries file the vault holds, as listed: the root file
    /// (§12) and the per-device files (§12.5), sorted; other names are ignored.
    public func publishedSummaryFiles() -> [URL] {
        var files: [URL] = []
        if FileIO.exists(publishedSummariesURL) { files.append(publishedSummariesURL) }
        let folder = url.appendingPathComponent(PublishedSummaries.deviceFolderName, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        for name in names where PublishedSummaries.device(ofFileName: name) != nil {
            files.append(folder.appendingPathComponent(name))
        }
        return files
    }

    /// The valid entries of every published summaries file of the vault that is
    /// here and opens (`publishedSummaryFiles`), one dictionary per file; a
    /// file that is missing, too large or does not open is skipped.
    public func readEveryPublishedSummaries(now: Date = Date()) -> [[UUID: PublishedSummaries.Entry]] {
        publishedSummaryFiles().compactMap { file in
            guard let data = try? BoundedRead.contents(of: file, maxBytes: PublishedSummaries.maxFileBytes) else { return nil }
            // A per-device file counts only when it is that device's, signed (§12.5).
            if let device = PublishedSummaries.device(ofFileName: file.lastPathComponent),
               file.deletingLastPathComponent().lastPathComponent == PublishedSummaries.deviceFolderName {
                return try? openDevicePublishedSummaries(data, device: device, now: now).entries
            }
            return try? openPublishedSummaries(data)
        }
    }

    /// The sealed root file (§12.1) for `entries`.
    public func sealPublishedSummaries(_ entries: [UUID: PublishedSummaries.Entry]) throws -> Data {
        let json = try PublishedSummaries.encode(entries, vaultId: vaultId)
        return try PublishedSummaries.seal(try Gzip.compress(json), secret: try requireSecret(), vaultId: vaultId)
    }

    /// This device's per-device file (format.md §12.5) for `entries` at `version`: sealed under the epoch's
    /// key with the epoch in its header, then signed by this device (`writerDevice`) with its signing pair.
    ///
    /// - Throws: `PublishedSummariesError.cannotSign` when the vault was not opened as a listed device with
    ///   its signing keys; `VaultError.locked` without the key.
    package func sealDevicePublishedSummaries(_ entries: [UUID: PublishedSummaries.Entry], version: Int64,
                                              synced: Date? = nil) throws -> Data {
        guard let device = writerDevice, let signing else {
            throw PublishedSummariesError.cannotSign("needs this device's own entry and signing keys")
        }
        return try sealDeviceFile(entries, device: device, version: version, signer: signing, synced: synced)
    }

    /// `entries` as `device`'s file at `version`, signed by `signer` over the message for `device` and
    /// `version` (tests forge with it; `sealDevicePublishedSummaries` is the writer).
    func sealDeviceFile(_ entries: [UUID: PublishedSummaries.Entry], device: DeviceID, version: Int64,
                        signer: DeviceSigningKeys, nonce: Data? = nil, synced: Date? = nil) throws -> Data {
        let sealed = try sealDeviceBody(entries, device: device, version: version, nonce: nonce, synced: synced)
        let message = AuthorMessage.summaries(vaultId: vaultId, epoch: manifest.epoch, epochId: manifest.epochId,
                                              device: device, version: version, sealed: sealed)
        return PublishedSummaries.attach(try signer.sign(message), to: sealed)
    }

    /// The sealed part of a per-device file (header, nonce, ciphertext, tag), without its signature.
    func sealDeviceBody(_ entries: [UUID: PublishedSummaries.Entry], device: DeviceID, version: Int64,
                        nonce: Data? = nil, synced: Date? = nil) throws -> Data {
        let json = try PublishedSummaries.encode(entries, vaultId: vaultId, device: device, version: version,
                                                 synced: synced)
        return try PublishedSummaries.seal(try Gzip.compress(json), secret: try requireSecret(), vaultId: vaultId,
                                           epoch: manifest.epoch, nonce: nonce)
    }

    /// When the device `id` (its 8 hex digits) last completed a two-way sync, from its own
    /// `summaries/<id>.sealed` (format.md §12.5, key-hierarchy design §5.5): nil when it has none, or its
    /// file does not open as that device's under the current key (an older epoch's, or not written yet).
    public func lastSynced(device id: String, now: Date = Date()) -> Date? {
        guard let device = DeviceID(id) else { return nil }
        let url = devicePublishedSummariesURL(device)
        guard FileIO.exists(url), let data = try? FileIO.read(url, maxBytes: PublishedSummaries.maxFileBytes) else { return nil }
        return (try? openDevicePublishedSummaries(data, device: device, now: now))?.synced
    }

    /// Records in this device's own `summaries/<device>.sealed` that it completed a two-way sync at `now`
    /// (design §5.5): its entries are kept, `synced` set, at the next version (§12.5). Nothing is written while
    /// the recorded time is less than `granularity` old (each write is uploaded to every target). A file that
    /// does not open as this device's under the current key is rewritten with no entries. Returns true when
    /// it wrote.
    @discardableResult
    public func recordSynced(device: DeviceID, now: Date, granularity: TimeInterval) throws -> Bool {
        try requireWritable()
        let url = devicePublishedSummariesURL(device)
        var contents = PublishedSummaries.Contents(entries: [:], device: device)
        if FileIO.exists(url), let data = try? FileIO.read(url, maxBytes: PublishedSummaries.maxFileBytes),
           let file = try? openDevicePublishedSummaries(data, device: device, now: now) {
            if let synced = file.synced, now.timeIntervalSince(synced) < granularity, synced <= now { return false }
            contents = file
        }
        guard let version = PublishedSummaries.nextVersion(after: contents.version, now: now) else {
            throw PublishedSummariesError.damaged("the previous version is the greatest there is")
        }
        contents.version = version
        contents.synced = now
        try FileIO.createDirectory(url.deletingLastPathComponent())
        try FileIO.writeAtomically(try sealDevicePublishedSummaries(contents.entries, version: version, synced: now), to: url,
                                   replacing: true)
        return true
    }

    /// This device's own `summaries/<device>.sealed` sealed again under this vault's (current) key, from
    /// `previous` (its contents as the key it was sealed under opened them), at the next version: what a device
    /// does when it takes a new epoch (KH4), so other devices read it at once.
    public func resealOwnSummaries(_ previous: PublishedSummaries.Contents, device: DeviceID, now: Date = Date()) throws {
        try requireWritable()
        guard let version = PublishedSummaries.nextVersion(after: previous.version, now: now) else { return }
        let url = devicePublishedSummariesURL(device)
        try FileIO.createDirectory(url.deletingLastPathComponent())
        try FileIO.writeAtomically(try sealDevicePublishedSummaries(previous.entries, version: version, synced: previous.synced),
                                   to: url, replacing: true)
    }

    /// The valid entries of the root file (§12.1, `SMPU` `0x01`). A per-device file is read only through
    /// `openDevicePublishedSummaries`, which checks its signature.
    ///
    /// - Throws: `PublishedSummariesError.damaged` for a file that is not
    ///   this vault's root file (or is damaged); `VaultError.locked` without the secret.
    public func openPublishedSummaries(_ data: Data) throws -> [UUID: PublishedSummaries.Entry] {
        guard data.starts(with: PublishedSummaries.magic) else {
            throw PublishedSummariesError.damaged("not a root summaries file")
        }
        return try decryptPublishedSummaries(data).entries
    }

    /// The content of a sealed file of this vault (a per-device file's sealed part, or the whole file:
    /// its signature is ignored) with its `device` and `version`. Checks NO signature: diagnostics and
    /// `openDevicePublishedSummaries` only.
    func decryptPublishedSummaries(_ data: Data) throws -> PublishedSummaries.Contents {
        guard data.starts(with: PublishedSummaries.deviceMagic) else { return try decryptSealed(data) }
        guard let (sealed, _) = PublishedSummaries.split(data) else {
            throw PublishedSummariesError.damaged("too short for a signed per-device file")
        }
        return try decryptSealed(sealed)
    }

    /// The content of a root file, or of a per-device file's sealed part (no signature).
    private func decryptSealed(_ body: Data) throws -> PublishedSummaries.Contents {
        // A per-device file's header names the epoch of the key that sealed it: this vault's, or it is not one.
        if let epoch = PublishedSummaries.sealedEpoch(body), epoch != manifest.epoch {
            throw PublishedSummariesError.damaged("sealed under epoch \(epoch), not this vault's \(manifest.epoch)")
        }
        let plain = try PublishedSummaries.open(body, secret: try requireSecret(), vaultId: vaultId)
        let json: Data
        do { json = try Gzip.decompress(plain, maxOutput: PublishedSummaries.maxJSONBytes) } catch {
            throw PublishedSummariesError.damaged("does not gunzip")
        }
        return try PublishedSummaries.decodeContents(json, vaultId: vaultId)
    }

    /// The signing keys a per-device file of `device` must verify under (format.md §12.5): those of every
    /// device entry with that id in this vault's `vault.json`, as opened and checked (`listStatus`
    /// verified), never a list from anywhere else. Empty when the list did not check or no listed device
    /// has that id (a removed device's signatures stop verifying once its entry is gone).
    public func summariesSigningKeys(of device: DeviceID) -> [DeviceSigningPublicKeys] {
        guard case .verified = listStatus else { return [] }
        return manifest.devices(withId: device.rawValue).compactMap(\.sign)
    }

    /// A per-device file of `device` (format.md §12.5): `SMPU` `0x03` of this vault's epoch, it opens under
    /// the epoch's key, names `device` and carries a version, its signature verifies under the signing keys
    /// of a device of the checked list with that id (`summariesSigningKeys`) over the message for this
    /// vault, epoch, device, version and sealed bytes (`AuthorMessage.summaries`), and its version is no
    /// more than `PublishedSummaries.futureWindow` ahead of `now` (a clock-skew guard). Anything else
    /// throws `damaged`: such a copy is never placed, never ordered against another and never read for
    /// entries.
    public func openDevicePublishedSummaries(_ data: Data, device: DeviceID, now: Date = Date()) throws
        -> PublishedSummaries.Contents {
        guard data.count <= PublishedSummaries.maxFileBytes else {
            throw PublishedSummariesError.damaged("larger than \(PublishedSummaries.maxFileBytes) bytes")
        }
        guard let (sealed, signature) = PublishedSummaries.split(data) else {
            throw PublishedSummariesError.damaged("not a signed per-device file")
        }
        let contents = try decryptSealed(sealed)
        guard contents.device == device else {
            throw PublishedSummariesError.damaged("written for another device than its name says")
        }
        guard let version = contents.version else { throw PublishedSummariesError.damaged("no version") }
        let keys = summariesSigningKeys(of: device)
        guard !keys.isEmpty else {
            throw PublishedSummariesError.damaged("no device \(device) on the checked device list to verify it")
        }
        let message = AuthorMessage.summaries(vaultId: vaultId, epoch: manifest.epoch, epochId: manifest.epochId,
                                              device: device, version: version, sealed: sealed)
        guard keys.contains(where: { signature.verifies(message, keys: $0) }) else {
            throw PublishedSummariesError.damaged("its signature does not verify as device \(device)'s")
        }
        guard PublishedSummaries.accepted(version, now: now) != nil else {
            throw PublishedSummariesError.damaged("a version too far ahead of this device's clock")
        }
        return contents
    }

    /// Writes this device's `summaries/<device>.sealed` (format.md §12.5, `<device>` its `writerDevice`)
    /// with `entries`, signed, under the next version after the one there (`PublishedSummaries.nextVersion`).
    /// Returns the bytes written. A file there that does not open as this device's (sealed under an earlier
    /// epoch's key, damaged, unsigned, or with a version beyond the window) gives no previous version: the
    /// new one starts at the clock.
    ///
    /// - Throws: `PublishedSummariesError.cannotSign` without this device's entry and signing keys.
    ///
    /// A device that takes a new epoch reseals its file under the new key at once (`resealOwnSummaries`, KH4).
    @discardableResult
    public func writeDevicePublishedSummaries(_ entries: [UUID: PublishedSummaries.Entry], now: Date = Date()) throws -> Data {
        try requireWritable()
        guard let device = writerDevice, signing != nil else {
            throw PublishedSummariesError.cannotSign("needs this device's own entry and signing keys")
        }
        let url = devicePublishedSummariesURL(device)
        let previous = FileIO.exists(url)
            ? (try? BoundedRead.contents(of: url, maxBytes: PublishedSummaries.maxFileBytes))
                .flatMap { try? openDevicePublishedSummaries($0, device: device, now: now) } : nil
        guard let version = PublishedSummaries.nextVersion(after: previous?.version, now: now) else {
            throw PublishedSummariesError.damaged("the previous version is the greatest there is")
        }
        // The device's last sync (`synced`, KH4) stays as it was.
        let data = try sealDevicePublishedSummaries(entries, version: version, synced: previous?.synced)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileIO.writeAtomically(data, to: url, replacing: true)
        return data
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
    /// are summarized through `cache` (format.md §10).
    ///
    /// - Parameter ownListing: the vault's own listing in the form of
    ///   `webIndexListing()`, when the caller just made it (the vault is not
    ///   listed again); nil lists the vault.
    /// - Returns: the entries and how many notes had to be summarized.
    public func publishedSummaryEntries(for listing: [String: [String]]? = nil,
                                        reuse: [UUID: PublishedSummaries.Entry] = [:],
                                        cache: SummaryCache? = nil,
                                        ownListing: [String: [String]]? = nil) throws
        -> (entries: [UUID: PublishedSummaries.Entry], summarised: Int) {
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
    /// Needs the vault unlocked; a locked vault is left alone.
    ///
    /// - Returns: true when the file was rewritten.
    /// The vault is opened again first (a command may have changed its
    /// manifest); with `cacheDirectory`, notes are summarized through the
    /// summary cache there (format.md §10).
    @discardableResult
    public func refreshPublishedSummaries(cacheDirectory: URL? = nil, ownListing: [String: [String]]? = nil) throws -> Bool {
        // A read-only vault is never written, not even its summaries (format.md §7.3).
        guard FileIO.exists(publishedSummariesURL), canRead, !isReadOnly,
              let vault = try? Vault.open(at: url, identities: unlockIdentities, signing: signing, trust: trustStore,
                                            root: manifest.root) else { return false }
        return try vault.refreshOpenedPublishedSummaries(
            cache: cacheDirectory.flatMap { try? SummaryCache(directory: $0, vault: vault) }, ownListing: ownListing)
    }

    private func refreshOpenedPublishedSummaries(cache: SummaryCache?, ownListing: [String: [String]]?) throws -> Bool {
        guard canRead else { return false }
        let data = try? FileIO.read(publishedSummariesURL, maxBytes: PublishedSummaries.maxFileBytes)
        let current = data.flatMap { try? openPublishedSummaries($0) }
        guard !isReadOnly else { return false }
        let (entries, _) = try publishedSummaryEntries(reuse: current ?? [:], cache: cache, ownListing: ownListing)
        // Summarizing may have just read newer content (format.md §7.3).
        guard !isReadOnly else { return false }
        if let current, current == entries { return false }
        try FileIO.writeAtomically(try sealPublishedSummaries(entries), to: publishedSummariesURL, replacing: true)
        return true
    }
}
