import Foundation

/// A partial copy of a vault (format.md §1.2): a vault folder that holds
/// every root file a reader needs (`vault.json` and the rest) but not yet
/// every revision or blob of the vault it was copied from. The WebDAV app
/// copies and `sempere sync webdav --metadata-only` make one; fetching what
/// is missing completes it.
///
/// Three kinds of marker, all starting with a dot so readers ignore them
/// (format.md §1):
///
/// - the folder `.sempere-partial/` at the vault root marks the copy as
///   partial (it also holds the copier's own files);
/// - an empty file `notes/<id>/.sempere-pending` marks a note whose
///   revisions have not all arrived (its folder may hold some, or none);
/// - an empty file `notes/<id>/att/.<blob file name>.sempere-pending` stands
///   for a blob of that note the copy lacks.
///
/// Writers obey these rules:
///
/// - no revision is written into a note marked incomplete (`noteIncomplete`):
///   it would be stamped and sequenced without the revisions still missing,
///   and computed from a state that lacks them;
/// - nothing is compacted, thinned or blob-collected in such a note;
/// - no recipient change starts or resumes while the folder is partial
///   (`partialCopy`): a rewrap must see every file.
public enum PartialCopy {
    /// The folder at the vault root that marks a partial copy.
    public static let folderName = ".sempere-partial"
    /// The marker of an incomplete note, in its folder.
    public static let noteMarkerName = ".sempere-pending"
    /// The suffix of a blob stand-in (`.<name>` + suffix).
    public static let standInSuffix = ".sempere-pending"

    /// The stand-in name of the file `name` (`X.pdf.age` → `.X.pdf.age.sempere-pending`).
    public static func standInName(for name: String) -> String {
        "." + name + standInSuffix
    }

    /// The file name a stand-in stands for; nil when `name` is not a stand-in
    /// (the note marker is none either).
    public static func realName(ofStandIn name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(standInSuffix), name != noteMarkerName else { return nil }
        let real = String(name.dropFirst().dropLast(standInSuffix.count))
        return real.isEmpty || real.hasPrefix(".") || real.contains("/") ? nil : real
    }

    /// The names `entries` (a folder's listing) hold stand-ins for whose
    /// real file is not among them, filtered by `accept`, sorted.
    public static func pending(in entries: [String], accept: (String) -> Bool) -> [String] {
        let present = Set(entries)
        return entries.compactMap { realName(ofStandIn: $0) }.filter { accept($0) && !present.contains($0) }.sorted()
    }

    /// True when the vault folder at `root` is a partial copy.
    public static func isPartial(_ root: URL) -> Bool {
        FileIO.isDirectory(root.appendingPathComponent(folderName, isDirectory: true))
    }

    /// True when the note folder `noteFolder` is marked incomplete.
    public static func isIncomplete(noteFolder: URL) -> Bool {
        FileIO.exists(noteFolder.appendingPathComponent(noteMarkerName))
    }
}

extension Vault {
    /// `.sempere-partial/` of this vault.
    public var partialCopyURL: URL { url.appendingPathComponent(PartialCopy.folderName, isDirectory: true) }

    /// True when the vault folder is a partial copy (format.md §1.2).
    public var isPartialCopy: Bool { PartialCopy.isPartial(url) }

    /// True when note `noteId` is marked incomplete: some of its revisions
    /// have not arrived (format.md §1.2).
    public func isNoteIncomplete(_ noteId: UUID) -> Bool {
        PartialCopy.isIncomplete(noteFolder: noteURL(noteId))
    }

    /// The blob files of note `noteId` this copy lacks (their stand-ins), sorted.
    ///
    /// - Throws: `VaultError.io` when the note's `att/` exists but cannot be listed.
    public func pendingBlobNames(of noteId: UUID) throws -> [String] {
        let att = noteURL(noteId).appendingPathComponent(Self.attachmentsName)
        return try PartialCopy.pending(in: FileIO.entries(att)) { name in
            guard let parsed = BlobName.parse(name) else { return false }
            return BlobName.fileName(name: parsed.name, kind: parsed.kind) == name
        }
    }

    /// The `problem` of an incomplete note's summary: it is never summarized
    /// from part of its log.
    public static let incompleteNoteProblem = "not completely downloaded yet (partial copy)"

    /// Throws `VaultError.noteIncomplete` when note `noteId` is marked
    /// incomplete: nothing may be written to it, or deleted from it, until
    /// its revisions arrive (format.md §1.2).
    public func requireNoteComplete(_ noteId: UUID) throws {
        if isNoteIncomplete(noteId) { throw VaultError.noteIncomplete(noteId.uuidString.lowercased()) }
    }

    /// Throws `VaultError.partialCopy` when the vault folder is a partial
    /// copy: for operations that must see every file (a recipient change, a
    /// backup, an export or search of every note).
    public func requireCompleteCopy() throws {
        if isPartialCopy { throw VaultError.partialCopy(url.path) }
    }
}
