import Foundation

/// The app's attachment index on disk (docs/attachments.md §4): one sealed
/// file per note, a per-device cache under format.md §10.1 (purpose
/// `attachment-index`, magic `SMPX` ‖ `0x01`), in a folder whose name is
/// derived from the vault secret. Updating one note writes that note's file
/// only. It holds the rule-4 records (`AttachmentIndexEntry.unusedSince`):
/// losing a file only restarts its note's windows, which can never delete
/// anything sooner.
///
/// Not thread-safe; the app uses it from one task at a time.
public struct AttachmentIndexStore: Sendable {
    static let purpose = "attachment-index"
    /// `SMPX` then format version 1.
    static let magic: [UInt8] = [0x53, 0x4D, 0x50, 0x58, 0x01]
    /// The largest entry file read (thousands of revisions' references).
    public static let maxFileBytes = 16 << 20
    static let suffix = ".idx"

    /// The vault's folder inside the root.
    public let folder: URL
    private let key: LocalCacheKey

    /// The store of `vault` under `root` (one folder per vault secret).
    ///
    /// - Throws: `VaultError.locked` when the vault secret is not known.
    public init(root: URL, vault: Vault) throws {
        self.init(root: root, key: try LocalCacheKey(vault: vault, purpose: Self.purpose, magic: Self.magic))
    }

    init(root: URL, key: LocalCacheKey) {
        self.key = key
        folder = root.appendingPathComponent(key.name, isDirectory: true)
    }

    func fileName(_ note: UUID) -> String { key.entryName("note|\(note.uuidString.lowercased())") + Self.suffix }

    /// The entry of `note`; nil when there is none, it is damaged or of another schema.
    public func load(_ note: UUID) -> AttachmentIndexEntry? {
        let name = fileName(note)
        guard let data = try? BoundedRead.contents(of: folder.appendingPathComponent(name), maxBytes: Self.maxFileBytes),
              let plain = try? key.open(data, fileName: name),
              let entry = try? JSONDecoder().decode(AttachmentIndexEntry.self, from: plain),
              entry.note == note, entry.schema == AttachmentIndexEntry.schemaVersion else { return nil }
        return entry
    }

    /// Every readable entry, by note (Settings' totals). Damaged files are skipped.
    public func loadAll() -> [UUID: AttachmentIndexEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var out: [UUID: AttachmentIndexEntry] = [:]
        for name in names where name.hasSuffix(Self.suffix) {
            guard let data = try? BoundedRead.contents(of: folder.appendingPathComponent(name), maxBytes: Self.maxFileBytes),
                  let plain = try? key.open(data, fileName: name),
                  let entry = try? JSONDecoder().decode(AttachmentIndexEntry.self, from: plain),
                  entry.schema == AttachmentIndexEntry.schemaVersion, fileName(entry.note) == name else { continue }
            out[entry.note] = entry
        }
        return out
    }

    /// Writes the entry of its note (atomically; that note's file only).
    public func save(_ entry: AttachmentIndexEntry) throws {
        let name = fileName(entry.note)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sealed = try key.seal(try encoder.encode(entry), fileName: name)
        try FileIO.createDirectory(folder)
        try FileIO.writeAtomically(sealed, to: folder.appendingPathComponent(name), replacing: true)
    }

    /// Forgets the entry of `note` (it is gone from the vault).
    public func remove(_ note: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName(note)))
    }
}
