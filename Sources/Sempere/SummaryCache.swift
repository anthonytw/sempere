import Crypto
import Foundation

/// A per-device, encrypted cache of note summaries (format.md §10), so a vault
/// that was listed before lists again without decrypting its notes.
///
/// An entry is keyed by the note id and the sorted file names of the note's
/// revisions. Files under `notes/` are write-once and named by
/// `(hlc, device, seq)`, so the same names mean the same revisions and the
/// same summary; any added, compacted or removed file is a miss. Only
/// summaries without a `problem` or `newer` content are stored, so an
/// unreadable note, or one a newer version wrote, is read again next time.
///
/// The file holds titles, tags and notebooks, so it is encrypted
/// (ChaCha20-Poly1305) under a key derived from the vault secret with HKDF;
/// its name is derived the same way and says nothing about the vault without
/// the secret. It never lives in the vault folder: the app keeps it in
/// Application Support, the CLI in `~/.cache/sempere`.
///
/// Damage of any kind (truncation, a flipped bit, another schema, a file
/// for another secret) makes `load` start empty; the next `save` replaces the
/// file. Thread-safe: `Vault.summaries` calls it from several workers.
public final class SummaryCache: @unchecked Sendable {
    /// Bumped whenever `NoteSummary` or how it is computed changes, so older
    /// files are ignored instead of serving stale fields.
    public static let schemaVersion = 11   // 11: page text `spans` (snippets leave equations out); 10: `transcribed` (transcript search); 9: stroke counts without superseded strokes (format.md §5.6.1); 8: `recognized` (format.md §5.4); 7: favorite and created (published summaries, format.md §12); 6: page texts include LaTeX (§8.2.8); 5: `newer` (§7.4); 4: PDF page text (§8.2.6)
    /// The largest cache file read (about 50 000 notes' summaries).
    public static let maxFileBytes = 64 << 20
    /// HKDF `info` for the encryption key (format.md §10).
    static let keyInfo = "sempere/1 summary-cache key"
    /// HKDF `info` for the file name.
    static let nameInfo = "sempere/1 summary-cache name"
    /// File magic: `SMPS` then format version 1.
    static let magic: [UInt8] = [0x53, 0x4D, 0x50, 0x53, 0x01]
    static let nonceSize = 12, tagSize = 16

    /// The cache file.
    public let fileURL: URL
    /// Why an existing file was ignored by `load`; nil when it was absent or read.
    public private(set) var loadProblem: String?
    /// Why the last `save` failed, if it did.
    public var saveProblem: String? {
        lock.lock(); defer { lock.unlock() }
        return storedSaveProblem
    }
    /// `saveProblem`, written by `save` (which may run on another thread): read under `lock`.
    private var storedSaveProblem: String?

    private let key: Data
    private let lock = NSLock()
    /// Held for a whole `save`, so two saves cannot land out of order (an
    /// older snapshot written last would lose the newer entries).
    private let saveLock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var dirty = false

    struct Entry: Codable, Hashable {
        /// Sorted revision file names.
        var revisions: [String]
        var summary: NoteSummary
        /// The metadata of those revisions, oldest first (`RevisionMeta`), for
        /// thinning; absent in entries written before it was kept, or when the
        /// summary was stored without it. Optional, so the schema is unchanged.
        var history: [RevisionMeta]?
    }

    private struct Payload: Codable {
        var schema: Int
        var notes: [UUID: Entry]
    }

    /// The cache of `vault` in `directory`, read from disk if it is there.
    ///
    /// - Throws: `VaultError.locked` when the vault secret is not known.
    public convenience init(directory: URL, vault: Vault) throws {
        self.init(directory: directory, secret: try vault.requireSecret())
    }

    init(directory: URL, secret: VaultSecret) {
        key = Self.derive(secret, info: Self.keyInfo, bytes: 32)
        let name = Self.derive(secret, info: Self.nameInfo, bytes: 16).map { String(format: "%02x", $0) }.joined()
        fileURL = directory.appendingPathComponent("\(name).summaries")
        load()
    }

    static func derive(_ secret: VaultSecret, info: String, bytes: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: Data(info.utf8), outputByteCount: bytes)
            .withUnsafeBytes { Data($0) }
    }

    /// The default directory for the command-line tool:
    /// `$XDG_CACHE_HOME/sempere`, else `~/.cache/sempere`.
    public static func cliDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CACHE_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("sempere")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/sempere")
    }

    // MARK: - Entries

    /// The stored summary of `id` if it was made from exactly `revisions`.
    public func summary(for id: UUID, revisions: [RevisionName]) -> NoteSummary? {
        let names = revisions.map(\.filename).sorted()
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id], e.revisions == names else { return nil }
        return e.summary
    }

    /// The revision metadata stored for note `id` if it was made from
    /// exactly `revisions` (any order), else nil.
    public func history(for id: UUID, revisions: [RevisionName]) -> [RevisionMeta]? {
        let names = revisions.map(\.filename).sorted()
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id], e.revisions == names else { return nil }
        return e.history
    }

    /// Every stored summary, whether or not it is still current: what to show
    /// while the vault is checked.
    public var storedSummaries: [NoteSummary] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.summary)
    }

    /// The sorted revision file names of every stored entry: what a reader
    /// compares a fresh listing with to tell which notes changed (a note whose
    /// names are the same has the same summary; nothing needs reading).
    public var storedRevisionNames: [UUID: [String]] {
        lock.lock(); defer { lock.unlock() }
        return entries.mapValues(\.revisions)
    }

    /// The stored summary of `id`, whether or not it is still current.
    public func storedSummary(of id: UUID) -> NoteSummary? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.summary
    }

    /// The sorted revision file names the stored summary of `id` was made from.
    public func storedRevisionNames(of id: UUID) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.revisions
    }

    /// The stored summary of `id` if it was made from exactly `names`
    /// (sorted revision file names, as in `storedRevisionNames`).
    public func summary(for id: UUID, names: [String]) -> NoteSummary? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id], e.revisions == names else { return nil }
        return e.summary
    }

    /// Stores `summary`, made from `revisions`. Summaries with a `problem`
    /// are not stored (and drop an older entry).
    public func store(_ summary: NoteSummary, revisions: [RevisionName], history: [RevisionMeta]? = nil) {
        let names = revisions.map(\.filename).sorted()
        // Metadata of other files than the summary's is never stored.
        let history = history.flatMap { h in h.map(\.name.filename).sorted() == names ? h.sorted { $0.name < $1.name } : nil }
        lock.lock(); defer { lock.unlock() }
        // A note with newer content is read again every time, so reading it
        // keeps the vault read-only (format.md §7.3).
        if summary.problem != nil || summary.newer != nil || names.isEmpty {
            if entries.removeValue(forKey: summary.id) != nil { dirty = true }
            return
        }
        // A summary stored again without metadata keeps the metadata of the same files.
        let kept = history ?? entries[summary.id].flatMap { $0.revisions == names ? $0.history : nil }
        let e = Entry(revisions: names, summary: summary, history: kept)
        guard entries[summary.id] != e else { return }
        entries[summary.id] = e
        dirty = true
    }

    /// Drops entries of notes not in `ids` (deleted from the vault).
    public func retain(only ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        let gone = entries.keys.filter { !ids.contains($0) }
        for id in gone { entries[id] = nil }
        if !gone.isEmpty { dirty = true }
    }

    /// True when there is something `save` would write.
    public var hasChanges: Bool {
        lock.lock(); defer { lock.unlock() }
        return dirty
    }

    // MARK: - File

    /// Writes the cache if anything changed since it was read or saved.
    /// Atomic: a reader sees the old or the new file.
    public func save() throws {
        saveLock.lock()
        defer { saveLock.unlock() }
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let payload = Payload(schema: Self.schemaVersion, notes: entries)
        dirty = false
        lock.unlock()
        do {
            let sealed = try Self.seal(try Gzip.compress(try JSONEncoder().encode(payload)), key: key,
                                       aad: aad)
            try FileIO.createDirectory(fileURL.deletingLastPathComponent())
            try FileIO.writeAtomically(sealed, to: fileURL, replacing: true)
            lock.lock(); storedSaveProblem = nil; lock.unlock()
        } catch {
            lock.lock(); dirty = true; storedSaveProblem = "\(error)"; lock.unlock()
            throw error
        }
    }

    /// The file name binds the file to this key's name, so a file copied over
    /// another vault's cache fails to open.
    private var aad: Data { Data(Self.magic) + Data(fileURL.lastPathComponent.utf8) }

    private func load() {
        guard FileIO.exists(fileURL) else { return }
        do {
            let data = try FileIO.read(fileURL, maxBytes: Self.maxFileBytes)
            let json = try Gzip.decompress(try Self.open(data, key: key, aad: aad), maxOutput: 4 * Self.maxFileBytes)
            let payload = try JSONDecoder().decode(Payload.self, from: json)
            guard payload.schema == Self.schemaVersion else {
                loadProblem = "schema \(payload.schema), expected \(Self.schemaVersion)"
                return
            }
            var notes = payload.notes
            for (id, e) in payload.notes {
                guard e.summary.id == id, e.revisions == e.revisions.sorted(),
                      e.revisions.allSatisfy({ RevisionName($0) != nil }) else {
                    throw SummaryCacheError.damaged("entry \(id.uuidString.lowercased())")
                }
                // Metadata that does not describe exactly the entry's files is dropped (read again when needed).
                if let h = e.history, h.map(\.name.filename) != e.revisions { notes[id]?.history = nil }
            }
            entries = notes
        } catch {
            entries = [:]
            loadProblem = "\(error)"
        }
    }

    static func seal(_ plain: Data, key: Data, aad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(), authenticating: aad)
        return Data(magic) + box.combined
    }

    static func open(_ data: Data, key: Data, aad: Data) throws -> Data {
        guard data.count >= magic.count + nonceSize + tagSize, data.prefix(magic.count).elementsEqual(magic) else {
            throw SummaryCacheError.damaged("not a summary cache file")
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(magic.count))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw SummaryCacheError.damaged("does not authenticate")
        }
    }
}

/// Why a summary cache file was ignored.
public enum SummaryCacheError: Error, Hashable, Sendable {
    case damaged(String)
}
