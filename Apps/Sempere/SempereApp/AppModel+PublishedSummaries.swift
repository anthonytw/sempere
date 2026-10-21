import Foundation
import Sempere

/// Rows of notes not downloaded yet from every device's published summaries (format.md §12.5,
/// `summaries/<device>.sealed`): a partial copy (a join, `AppModel+Join`) lists its pending notes from
/// them (title, notebook, tags, page texts for search) when the server's own file does not name them.
/// Only notes still to arrive use the rows (`reconcile`).
extension AppModel {
    /// Reads every device's published summaries into `publishedRows` when the files changed since the last
    /// read. Needs the key; only while a partial copy is open.
    func refreshPublishedRows() async {
        guard partialCopyRoot != nil, phase == .unlocked, let vault, vault.canRead else { return }
        let gen = generation
        let previous = publishedRowsSignature
        let folder = vault.url.appendingPathComponent(PublishedSummaries.deviceFolderName, isDirectory: true)
        let read: (signature: [String], rows: [UUID: NoteSummary])? = try? await offMain(priority: .utility) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var local: [String] = []
            for name in names where !name.hasPrefix(".") {
                let values = try? folder.appendingPathComponent(name)
                    .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                local.append("\(name) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
            local.sort()
            if local == previous { return nil }
            let best = PublishedSummaries.best(of: vault.readEveryPublishedSummaries())
            var rows: [UUID: NoteSummary] = [:]
            for (id, entry) in best { rows[id] = Self.pendingSummary(id, entry) }
            return (local, rows)
        } ?? nil
        guard generation == gen, let read else { return }
        publishedRowsSignature = read.signature
        // The server's own rows (`webdavUnlocked`) stay where the devices' files do not name a note.
        publishedRows.merge(read.rows) { _, device in device }
        // Rows for notes already listed as placeholders: shown now, not at the next change.
        let waiting = placeholderNoteIDs.filter { read.rows[$0] != nil }
        if !waiting.isEmpty {
            queueListUpdate(upserts: waiting.compactMap { read.rows[$0] })
            placeholderNoteIDs.subtract(waiting)
        }
    }
}
