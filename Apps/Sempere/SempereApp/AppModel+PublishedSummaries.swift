import Foundation
import Sempere

/// Index-first sync for iCloud vaults (format.md §12.5, docs/io.md "Listing
/// before the notes arrive"): each device publishes the summaries of the notes
/// it has read in its own sealed file, `summaries/<device>.sealed`, and a
/// device on which notes have not arrived yet lists them from those files (title,
/// notebook, tags, page texts for search) instead of "Downloading…" rows. Only a
/// device's own file is ever written by it, so two devices never write one file
/// and no iCloud conflict can arise from it.
extension AppModel {
    /// Writes this device's published summaries when the listing is complete
    /// (nothing pending), the entries changed since the last write and at least
    /// `publishSummariesInterval` passed (`force`: going to the background).
    /// Only notes read in this session with a clean summary get an entry.
    func publishOwnSummariesIfDue(force: Bool = false) async {
        guard publishesSummaries, isCloudVault, webdavFetcher == nil, phase == .unlocked, !isVaultReadOnly,
              let vault, vault.canRead, pendingNoteIDs.isEmpty, placeholderNoteIDs.isEmpty, listLoaded else { return }
        if !force, let last = publishedOwnAt, ContinuousClock.now - last < publishSummariesInterval { return }
        var entries: [UUID: PublishedSummaries.Entry] = [:]
        for s in notes where verifiedNoteIDs.contains(s.id) {
            guard let names = indexedNames[s.id], let e = PublishedSummaries.Entry(summary: s, revisions: names) else { continue }
            entries[s.id] = e
        }
        guard entries != publishedOwnEntries, let clock = try? deviceClockForWriting() else { return }
        let gen = generation
        let url = vault.devicePublishedSummariesURL(clock.device)
        let coordinate = coordinationURL
        let snapshot = entries
        do {
            try await offMain(priority: .utility) {
                try vault.requireWritable()
                let data = try vault.sealPublishedSummaries(snapshot)
                try CloudVault.coordinatedWrite(coordinate) {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
            }
        } catch {
            return   // a hint: the next pass tries again
        }
        guard generation == gen else { return }
        publishedOwnEntries = snapshot
        publishedOwnAt = .now
        Perf.event(.publishSummaries, "entries=\(snapshot.count)")
    }

    /// Reads every device's published summaries into `publishedRows` when the
    /// files changed since the last read, asking iCloud for the ones that are not
    /// downloaded (not waited for: a later pass reads them once they are here).
    /// Needs the key. Only notes still to arrive use the rows (`reconcile`).
    func refreshPublishedRows() async {
        guard isCloudVault, webdavFetcher == nil, phase == .unlocked, let vault, vault.canRead else { return }
        let gen = generation
        let hooks = cloudHooks
        let coordinate = coordinationURL
        let previous = publishedRowsSignature
        let read: (signature: [String], rows: [UUID: NoteSummary])? = try? await offMain(priority: .utility) {
            var local: [String] = []
            for item in try CloudScan.summaryItems(inVault: vault.url) {
                let state = hooks.state(item)
                if !state.isSettled || item.placeholder { try? hooks.request(item); continue }
                if state == .stale { try? hooks.request(item) }
                let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                local.append("\(item.url.lastPathComponent) \(values?.fileSize ?? -1) "
                             + "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
            local.sort()
            if local == previous { return nil }
            let files = try CloudVault.coordinatedRead(coordinate) { vault.readEveryPublishedSummaries() }
            let best = PublishedSummaries.best(of: files)
            return (local, Dictionary(uniqueKeysWithValues: best.map { ($0.key, Self.pendingSummary($0.key, $0.value)) }))
        } ?? nil
        guard generation == gen, let read else { return }
        publishedRowsSignature = read.signature
        publishedRows = read.rows
        // Rows for notes already listed as "Downloading…": shown now, not at the next change.
        let waiting = placeholderNoteIDs.filter { read.rows[$0] != nil }
        if !waiting.isEmpty {
            queueListUpdate(upserts: waiting.compactMap { read.rows[$0] })
            placeholderNoteIDs.subtract(waiting)
        }
    }
}
