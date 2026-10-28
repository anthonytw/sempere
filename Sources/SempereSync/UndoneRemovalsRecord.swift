import Foundation
import Sempere

/// This device's record of the removals it made as home that a takeover undid (offline audit P16): the sync that took
/// the takeover reports them once (`SyncReport.EpochStatus.undoneRemovals`), and a run given
/// `SyncOptions.undoneRemovalsURL` keeps them here, so the app can keep naming them (a banner) for as long as those
/// devices are listed. Device-local, never synced; losing it only loses the reminder.
public enum UndoneRemovalsRecord {
    static let fileName = "undone-removals.json"
    static let maxBytes = 1 << 20

    /// The record of `vaultId` in a store's sync registry (beside its targets' sync states).
    public static func url(targets: SyncTargetRegistry, vaultId: UUID) -> URL {
        targets.stateDirectory(UUID(), of: vaultId).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// The record of the store vault at `vaultURL` (`<store>/<vault id>/<name>.sempere`); nil for a vault elsewhere.
    public static func url(storeVault vaultURL: URL, vaultId: UUID) -> URL? {
        let idFolder = vaultURL.standardizedFileURL.deletingLastPathComponent()
        guard idFolder.lastPathComponent == vaultId.uuidString.lowercased() else { return nil }
        return url(targets: VaultStore(root: idFolder.deletingLastPathComponent()).targets, vaultId: vaultId)
    }

    /// The removals recorded at `url`, by device id (empty when there is no readable record).
    public static func load(_ url: URL) -> [SyncReport.UndoneRemoval] {
        guard let data = try? BoundedRead.contents(of: url, maxBytes: maxBytes),
              let items = try? JSONDecoder().decode([SyncReport.UndoneRemoval].self, from: data) else { return [] }
        return items
    }

    /// Adds `items` to the record at `url` (one per device id, the latest kept).
    public static func add(_ items: [SyncReport.UndoneRemoval], to url: URL) throws {
        guard !items.isEmpty else { return }
        var byId = Dictionary(load(url).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for i in items { byId[i.id] = i }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try LocalFS.write(try encoder.encode(byId.values.sorted { $0.id < $1.id }), to: url, replacing: true)
    }
}
