import Foundation
import Sempere

// Change detection for the note list (docs/io.md "Opening a vault fast").
//
// The list is shown from the local index (the encrypted `SummaryCache`) and
// kept up to date by comparing file NAMES: revision files are write-once and
// named by `(hlc, device, seq)`, so a note whose set of revision file names
// is the one its summary was made from has that same summary. Only notes
// whose names changed are downloaded and read. Pure file listing, no iCloud
// API: tested with plain folders.

/// One note folder as a pass lists it: the revision file names, nothing else.
struct NoteListing: Equatable, Sendable {
    var id: UUID
    /// Sorted canonical revision file names (`RevisionName.filename`);
    /// iCloud placeholders (`.<name>.icloud`) count under their real name.
    var names: [String]

    /// The folder lists no revision: iCloud has not listed it yet (a note
    /// always has one), so it is never taken for an empty note.
    var isUnlisted: Bool { names.isEmpty }
}

enum VaultEnumeration {
    /// Lists the `notes/<id>/` folders of the vault at `root` (every folder,
    /// or only those of `ids`) by name. Asks iCloud nothing and reads no
    /// file: one directory listing per note.
    ///
    /// - Throws: when `notes/` (or a listed note folder) exists but cannot be
    ///   read; a missing `notes/` lists nothing, a missing folder of `ids` is
    ///   left out (the note is gone).
    static func listNotes(vault root: URL, only ids: Set<UUID>? = nil,
                          fileManager fm: FileManager = .default) throws -> [NoteListing] {
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let candidates: [(UUID, String)]
        if let ids {
            candidates = ids.map { ($0, $0.uuidString.lowercased()) }.sorted { $0.1 < $1.1 }
        } else {
            guard fm.fileExists(atPath: notes.path) else { return [] }
            candidates = try fm.contentsOfDirectory(atPath: notes.path).sorted().compactMap { name in
                UUID(uuidString: name).map { ($0, name) }
            }
        }
        var out: [NoteListing] = []
        out.reserveCapacity(candidates.count)
        for (id, dir) in candidates {
            let folder = notes.appendingPathComponent(dir, isDirectory: true).path
            let entries: [String]
            do {
                entries = try fm.contentsOfDirectory(atPath: folder)
            } catch {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: folder, isDirectory: &isDir) || !isDir.boolValue { continue }   // gone, or not a folder
                throw error
            }
            out.append(NoteListing(id: id, names: revisionNames(in: entries)))
        }
        return out
    }

    /// The canonical revision names among a folder's entries, placeholders
    /// mapped to their real names, sorted and without duplicates.
    static func revisionNames(in entries: [String]) -> [String] {
        var names = Set<String>()
        for entry in entries {
            let real = CloudPlaceholder.realName(of: entry) ?? entry
            guard !real.hasPrefix("."), real.hasSuffix(".age"), let name = RevisionName(real) else { continue }
            names.insert(name.filename)
        }
        return names.sorted()
    }
}

/// How a listing compares with what the list shows.
struct IndexDiff: Equatable, Sendable {
    /// Listed with exactly the names their summary was made from.
    var unchanged: [UUID] = []
    /// Listed with other names, or not in the index: to be read.
    var changed: [UUID] = []
    /// In the index or the list, in scope, but no longer listed.
    var removed: [UUID] = []

    /// Compares `listings` with `indexed` (note id → sorted names its shown
    /// summary was made from).
    ///
    /// - Parameters:
    ///   - known: notes shown or indexed before the listing; only these can
    ///     be `removed` (a note created meanwhile was not listed yet).
    ///   - scope: the notes the listing covered (nil: all of them).
    static func compute(listings: [NoteListing], indexed: [UUID: [String]], known: Set<UUID>,
                        scope: Set<UUID>? = nil) -> IndexDiff {
        var diff = IndexDiff()
        var listed = Set<UUID>()
        for l in listings {
            listed.insert(l.id)
            if !l.isUnlisted, indexed[l.id] == l.names { diff.unchanged.append(l.id) } else { diff.changed.append(l.id) }
        }
        let inScope = scope ?? known
        diff.removed = known.filter { inScope.contains($0) && !listed.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return diff
    }
}
