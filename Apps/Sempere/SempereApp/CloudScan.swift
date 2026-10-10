import Foundation
import Sempere

// The pure half of reading a vault from iCloud Drive: placeholder names,
// which vault files to fetch, and progress. No iCloud API here, so it is
// tested with plain files (`CloudVault` does the downloading).

/// iCloud Drive placeholders. A file that is not downloaded is listed as a
/// hidden stand-in named `.<name>.icloud`; newer iPadOS versions may instead
/// list the real name with a "not downloaded" status. Both are handled.
enum CloudPlaceholder {
    static let suffix = ".icloud"

    /// The real name a placeholder stands for (`.vault.json.icloud` →
    /// `vault.json`); nil when `name` is not a placeholder.
    static func realName(of name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(suffix) else { return nil }
        let real = String(name.dropFirst().dropLast(suffix.count))
        return real.isEmpty ? nil : real
    }

    /// The placeholder name of `name` (`vault.json` → `.vault.json.icloud`).
    static func placeholderName(for name: String) -> String {
        "." + name + suffix
    }

    /// The placeholder URL of the file at `url`, in the same folder.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(placeholderName(for: url.lastPathComponent))
    }
}

/// How far a vault file is from being readable.
enum CloudItemState: Equatable, Sendable {
    /// The local copy is the newest iCloud knows of (or the file is not in iCloud).
    case current
    /// A local copy exists; a newer version may still be on its way.
    case stale
    /// Only a placeholder is here; it must be downloaded before it can be read.
    case missing
    /// Neither the file nor a placeholder exists any more (deleted remotely).
    case gone
    /// iCloud reported an error downloading it.
    case failed(String)

    /// Readable now, or nothing left to wait for.
    var isSettled: Bool {
        switch self {
        case .current, .stale, .gone: return true
        case .missing, .failed: return false
        }
    }
}

/// Download progress over the files that were missing when it started.
struct CloudProgress: Equatable, Sendable, CustomStringConvertible {
    var total: Int
    var downloaded: Int

    init(total: Int, downloaded: Int) {
        self.total = max(0, total)
        self.downloaded = min(max(0, downloaded), self.total)
    }

    /// Progress over `states`: every settled state counts as downloaded.
    init(states: [CloudItemState]) {
        self.init(total: states.count, downloaded: states.filter(\.isSettled).count)
    }

    var isComplete: Bool { downloaded == total }
    var fractionCompleted: Double { total == 0 ? 1 : Double(downloaded) / Double(total) }

    var description: String {
        let files = String(localized: "\(total) files", comment: "A number of files")
        return String(localized: "Downloading from iCloud… \(downloaded)/\(files)",
                      comment: "Progress; %@ is a number of files, e.g. “3/6 files”")
    }
}

/// The files of a vault that iCloud may have to fetch.
enum CloudScan {
    /// One vault file, by its real name.
    struct Item: Hashable, Sendable {
        /// Where the file is (or will be) under its real name.
        var url: URL
        /// True when the listing showed `.<name>.icloud` instead of the file.
        var placeholder: Bool
    }

    /// Root files a reader needs (format.md §2, §3.3.1), and the shared
    /// settings applied at unlock (format.md §13).
    static let rootFiles: Set<String> = ["vault.json", "rewrap-journal.json", "settings.age"]

    /// `vault.json`, `rewrap-journal.json`, `keys/*.age` and
    /// `notes/<id>/*.age`, with placeholders mapped to the real names.
    /// Other files are not fetched (format.md §1: unknown files are ignored).
    /// A missing `keys/` or `notes/` lists as empty.
    ///
    /// - Throws: when the vault folder or one of its folders exists but
    ///   cannot be listed ("could not read" never looks like "nothing there").
    static func items(inVault root: URL, fileManager: FileManager = .default) throws -> [Item] {
        try essentialItems(inVault: root, fileManager: fileManager)
            + noteGroups(inVault: root, fileManager: fileManager).flatMap(\.items)
    }

    /// `vault.json`, `rewrap-journal.json` and `keys/*.age`: what unlocking
    /// needs, small enough to fetch before anything else.
    static func essentialItems(inVault root: URL, fileManager: FileManager = .default) throws -> [Item] {
        var items: [Item] = []
        for entry in try list(root, fileManager) where rootFiles.contains(entry.name) && !entry.isDirectory {
            items.append(entry.item(in: root))
        }
        let keys = root.appendingPathComponent("keys", isDirectory: true)
        for entry in try list(keys, fileManager, allowMissing: true) where entry.isRevisionLike {
            items.append(entry.item(in: keys))
        }
        return items
    }

    /// The files of one `notes/<dir>` folder.
    struct NoteGroup: Sendable {
        /// The folder name.
        var directory: String
        /// The folder.
        var url: URL
        /// The note id when the folder is named like one (others are ignored by readers).
        var id: UUID? { UUID(uuidString: directory) }
        var items: [Item]
    }

    /// Every `notes/<dir>` folder with its revision files, in folder-name order.
    static func noteGroups(inVault root: URL, fileManager: FileManager = .default) throws -> [NoteGroup] {
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        var groups: [NoteGroup] = []
        for dir in try list(notes, fileManager, allowMissing: true) where dir.isDirectory && !dir.name.hasPrefix(".") {
            let noteDir = notes.appendingPathComponent(dir.name, isDirectory: true)
            let items = try list(noteDir, fileManager, allowMissing: true).filter(\.isRevisionLike).map { $0.item(in: noteDir) }
            groups.append(NoteGroup(directory: dir.name, url: noteDir, items: items))
        }
        return groups
    }

    /// The revision files of note `id` (`notes/<id>/`), listed fresh; empty
    /// when the note has no folder.
    static func noteItems(inVault root: URL, id: UUID, fileManager: FileManager = .default) throws -> [Item] {
        let noteDir = noteFolder(inVault: root, id: id)
        return try list(noteDir, fileManager, allowMissing: true).filter(\.isRevisionLike).map { $0.item(in: noteDir) }
    }

    /// One blob file of a note's `att/` (format.md §8.1.2), by its real name.
    struct BlobItem: Hashable, Sendable {
        var item: Item
        /// From the name's `.<kind>.age` suffix.
        var kind: BlobKind
    }

    /// The blob files of note `id` (`notes/<id>/att/`), listed fresh, with
    /// their kind; empty when the note has no `att/` or iCloud has not listed
    /// it. Names that are not `<64 hex>.<kind>.age` are skipped. A note's
    /// revisions alone define it: `noteItems`, the vault scan and
    /// `requireLocal` never look in `att/`, so a missing, unlisted or evicted
    /// `att/` never makes a note look empty or pending (docs/attachments.md §4).
    static func blobItems(inVault root: URL, id: UUID, fileManager: FileManager = .default) throws -> [BlobItem] {
        let dir = attachmentFolder(inVault: root, id: id)
        return try list(dir, fileManager, allowMissing: true).filter(\.isRevisionLike).compactMap { entry in
            guard let parsed = BlobName.parse(entry.name) else { return nil }
            return BlobItem(item: entry.item(in: dir), kind: parsed.kind)
        }
    }

    /// The blob file `fileName` of note `id` as iCloud lists it now: a
    /// placeholder when only `.<name>.icloud` is there.
    static func blobItem(inVault root: URL, id: UUID, fileName: String, fileManager: FileManager = .default) -> Item {
        let url = attachmentFolder(inVault: root, id: id).appendingPathComponent(fileName, isDirectory: false)
        let placeholder = !fileManager.fileExists(atPath: url.path)
            && fileManager.fileExists(atPath: CloudPlaceholder.placeholderURL(for: url).path)
        return Item(url: url, placeholder: placeholder)
    }

    /// One file of the vault's capture inbox (format.md §11), by its real name.
    struct InboxItem: Hashable, Sendable {
        var item: Item
        var id: UUID
        var kind: CaptureFile.Kind
    }

    /// The capture inbox's files (`inbox/<id>.<kind>.age`), listed fresh,
    /// placeholders mapped to their real names; empty without `inbox/`.
    /// Other names (temporary files, unknown files) are skipped.
    static func inboxItems(inVault root: URL, fileManager: FileManager = .default) throws -> [InboxItem] {
        let dir = root.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        return try list(dir, fileManager, allowMissing: true).filter(\.isRevisionLike).compactMap { entry in
            guard let parsed = CaptureFile.parse(name: entry.name) else { return nil }
            return InboxItem(item: entry.item(in: dir), id: parsed.id, kind: parsed.kind)
        }
    }

    /// `notes/<id>/att/` of the vault at `root`.
    static func attachmentFolder(inVault root: URL, id: UUID) -> URL {
        noteFolder(inVault: root, id: id).appendingPathComponent("att", isDirectory: true)
    }

    /// `notes/<id>/` of the vault at `root`.
    static func noteFolder(inVault root: URL, id: UUID) -> URL {
        root.appendingPathComponent("notes/\(id.uuidString.lowercased())", isDirectory: true)
    }

    private struct Entry {
        /// Real name (placeholder suffix removed).
        var name: String
        var placeholder: Bool
        var isDirectory: Bool

        var isRevisionLike: Bool { !isDirectory && name.hasSuffix(".age") && !name.hasPrefix(".") }

        func item(in dir: URL) -> Item {
            Item(url: dir.appendingPathComponent(name, isDirectory: false), placeholder: placeholder)
        }
    }

    private static func list(_ dir: URL, _ fm: FileManager, allowMissing: Bool = false) throws -> [Entry] {
        var isDir: ObjCBool = false
        if allowMissing && !fm.fileExists(atPath: dir.path, isDirectory: &isDir) { return [] }
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        var byName: [String: Entry] = [:]
        for name in names.sorted() {
            if let real = CloudPlaceholder.realName(of: name) {
                // The real file wins over a leftover placeholder of the same name.
                if byName[real] == nil { byName[real] = Entry(name: real, placeholder: true, isDirectory: false) }
            } else {
                var d: ObjCBool = false
                _ = fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &d)
                byName[name] = Entry(name: name, placeholder: false, isDirectory: d.boolValue)
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }
}
