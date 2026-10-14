import Foundation

/// Loading a vault's notes from iCloud Drive without waiting for all of them.
///
/// Each pass lists the notes' files, sorts the notes into *ready* (every file
/// local, so the summary can be read now) and *pending* (some file is still a
/// placeholder), and asks iCloud for the pending notes' files: the note the
/// user opened first, then the rest, at most `window` notes at a time, so a
/// note opened later is not queued behind hundreds of others. The model keeps
/// passing until nothing is pending (`AppModel.startCloudSync`).
enum ProgressiveLoad {
    /// How many pending notes have their downloads requested at once. The
    /// opened note is always requested first (`priority`, `downloadNote`), so
    /// a wide window does not queue it behind the rest.
    static let defaultWindow = 64

    struct Pass: Equatable, Sendable {
        /// Every note directory found, in listing order.
        var all: [UUID] = []
        /// Notes whose files are all local.
        var ready: [UUID] = []
        /// Notes with at least one file still to download.
        var pending: [UUID] = []
        /// Notes iCloud reported an error for, with the reason (also in `pending`).
        var failures: [UUID: String] = [:]
        /// Notes whose folder lists no revision file at all (also in `pending`):
        /// iCloud has not listed its contents yet. A note always has at least
        /// one revision, so an empty folder is never an empty note.
        var unlisted: [UUID] = []
        /// Revision files listed, and how many of them are local.
        var files = 0
        var localFiles = 0
        /// Notes whose listed files were all local (`current`), each with a
        /// digest of its listing (`listingDigest`): passed back as `settled`,
        /// a later pass does not ask iCloud about them while the listing is
        /// the same.
        var settled: [UUID: Int] = [:]
    }

    /// A digest of a note's listing: file names and whether each was a
    /// placeholder. Revision files are write-once, so the same listing is
    /// the same files. In-memory only (`Hasher` is seeded per process).
    static func listingDigest(_ items: [CloudScan.Item]) -> Int {
        var h = Hasher()
        for item in items.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
            h.combine(item.url.lastPathComponent)
            h.combine(item.placeholder)
        }
        return h.finalize()
    }

    /// One pass over the vault at `root` (every note, or only `notes`).
    /// Requests downloads (idempotent) for up to `window` pending notes,
    /// `priority` first and notes with a download error last (none when
    /// `requestMissing` is false), and refreshes out-of-date local files of
    /// ready notes (not waited for).
    ///
    /// This asks iCloud for the state of every file it covers, which is
    /// slow on a device (one round trip per file): the model runs it only
    /// for notes whose names changed (`IndexDiff`) and, at low priority, in
    /// the background validation. A note in `settled` whose listing digest
    /// is unchanged counts as ready without asking (an earlier pass saw all
    /// of its files current); an eviction that keeps the listing the same
    /// (dataless files under their real names) is then seen only by a pass
    /// without `settled`.
    ///
    /// - Throws: when a folder cannot be listed.
    static func pass(vault root: URL, notes: Set<UUID>? = nil, priority: UUID? = nil, window: Int = defaultWindow,
                     requestMissing: Bool = true, settled: [UUID: Int] = [:],
                     hooks: CloudVault.Hooks = .live) throws -> Pass {
        var pass = Pass()
        var pendingItems: [UUID: [CloudScan.Item]] = [:]
        let groups: [CloudScan.NoteGroup]
        if let notes {
            groups = try notes.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }.compactMap { id in
                let folder = CloudScan.noteFolder(inVault: root, id: id)
                guard FileManager.default.fileExists(atPath: folder.path) else { return nil }   // gone
                return CloudScan.NoteGroup(directory: id.uuidString.lowercased(), url: folder,
                                           items: try CloudScan.noteItems(inVault: root, id: id))
            }
        } else {
            groups = try CloudScan.noteGroups(inVault: root)
        }
        for group in groups {
            guard let id = group.id else { continue }
            pass.all.append(id)
            var missing: [CloudScan.Item] = []
            var stale: [CloudScan.Item] = []
            pass.files += group.items.count
            let digest = group.items.isEmpty ? nil : listingDigest(group.items)
            if let digest, settled[id] == digest {
                pass.localFiles += group.items.count
                pass.ready.append(id)
                pass.settled[id] = digest
                continue
            }
            if group.items.isEmpty {
                // Not listed yet: ask for the folder itself, which makes iCloud
                // list (and fetch) what is in it.
                pass.unlisted.append(id)
                missing.append(CloudScan.Item(url: group.url, placeholder: false))
            }
            var allCurrent = true
            for item in group.items {
                let state = hooks.state(item)
                if state != .current || item.placeholder { allCurrent = false }
                switch state {
                case .missing: missing.append(item)
                case .stale: stale.append(item)
                case .failed(let reason): missing.append(item); pass.failures[id] = reason
                case .current, .gone: pass.localFiles += 1
                }
            }
            pass.localFiles += stale.count
            if let digest, allCurrent { pass.settled[id] = digest }
            if missing.isEmpty { pass.ready.append(id) } else {
                pass.pending.append(id)
                pendingItems[id] = missing
            }
            for item in stale { try? hooks.request(item) }
        }
        // Notes iCloud failed on go last, so they cannot hold the window
        // (and every other note) hostage; they are still retried.
        var order = pass.pending.filter { pass.failures[$0] == nil } + pass.pending.filter { pass.failures[$0] != nil }
        if let priority, let i = order.firstIndex(of: priority) { order.insert(order.remove(at: i), at: 0) }
        for id in requestMissing ? Array(order.prefix(max(1, window))) : [] {
            for item in pendingItems[id] ?? [] {
                do { try hooks.request(item) } catch { pass.failures[id] = "\(error)" }
            }
        }
        return pass
    }
}
