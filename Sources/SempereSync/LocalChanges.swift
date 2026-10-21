import Foundation
import Sempere

/// What a run changed in the local vault folder (docs/design/device-first-sync.md §4 "Arrivals"): the
/// app reads only these notes again (reconcile, then an open editor's merge), and reloads the vault,
/// its settings, its inbox or its notebooks when they changed. Derived from the report's paths
/// (`downloaded`, local deletions, `merged`), so it says what was written, never what the remote holds.
public struct LocalChanges: Codable, Hashable, Sendable {
    /// Note ids (lowercase) whose folder got or lost a revision or a blob.
    public var notes: [String] = []
    /// `vault.json` was replaced.
    public var manifest = false
    /// the re-encryption journal (format.md §15.8, KH6) was replaced.
    public var journal = false
    /// `settings.age` was replaced (taken or merged).
    public var settings = false
    /// A file of `inbox/` was placed or deleted.
    public var inbox = false
    /// A notebook record arrived.
    public var notebooks = false
    /// Another device's `summaries/<device>.sealed` arrived.
    public var summaries = false

    public init() {}

    /// The changes `report` lists on the local side.
    public init(report: SyncReport) {
        var notes = Set<String>()
        let local = report.downloaded + report.deleted.filter { $0.side == "local" }.map(\.path) + report.merged
        for path in local {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let first = parts.first else { continue }
            switch first {
            case Vault.notesName where parts.count >= 3 && Vault.isNoteDirectoryName(parts[1]): notes.insert(parts[1])
            case Vault.manifestName where parts.count == 1: manifest = true
            case Vault.journalName where parts.count == 1: journal = true
            case SharedSettings.fileName where parts.count == 1: settings = true
            case CaptureFile.folderName: inbox = true
            case NotebookRecords.folderName: notebooks = true
            case PublishedSummaries.deviceFolderName: summaries = true
            default: break
            }
        }
        self.notes = notes.sorted()
    }

    /// Nothing changed locally.
    public var isEmpty: Bool {
        notes.isEmpty && !manifest && !journal && !settings && !inbox && !notebooks && !summaries
    }

    /// The changed notes as ids.
    public var noteIDs: Set<UUID> { Set(notes.compactMap(UUID.init(uuidString:))) }
}
