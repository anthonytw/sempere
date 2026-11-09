import Foundation
import Sempere

/// The note list's updates: batched, throttled and applied as differences.
///
/// A pass reads summaries in batches on other threads; each batch is queued
/// (`queueListUpdate`) and the queue is applied to `notes` at most once per
/// `listUpdateInterval` (four times a second by default), so the list, the
/// sidebar and every view derived from them re-render a few times a second
/// at most however fast notes arrive. Applying a batch changes `notes` in
/// place (`NoteListDiff`): a summary whose sort position stays is replaced
/// where it is, the rest are removed and merged in, O(n + k log k) for k
/// changes, never a re-sort of the whole list. The views' derived lists
/// (`visibleNotes`, `tags`, `notebookTree`) are computed once per change of
/// the list or the filters, not on every render (`DerivedLists`).
extension AppModelCore {
    /// Queues summaries to show and notes to drop; applied now when the last
    /// application was at least `listUpdateInterval` ago, else once that
    /// interval has passed.
    func queueListUpdate(upserts: [NoteSummary] = [], removals: Set<UUID> = []) {
        for s in upserts {
            listUpserts[s.id] = s
            listRemovals.remove(s.id)
        }
        for id in removals {
            listRemovals.insert(id)
            listUpserts[id] = nil
        }
        guard !listUpserts.isEmpty || !listRemovals.isEmpty else { return }
        let now = ContinuousClock.now
        if let last = lastListApply, now - last < listUpdateInterval {
            guard listFlushTask == nil else { return }
            let wait = listUpdateInterval - (now - last)
            let gen = generation
            listFlushTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.listFlushTask = nil
                self.flushListUpdates()
            }
        } else {
            flushListUpdates()
        }
    }

    /// Applies everything queued now (the end of a pass, so whoever awaited
    /// it sees the final list).
    func flushListUpdates() {
        listFlushTask?.cancel()
        listFlushTask = nil
        guard !listUpserts.isEmpty || !listRemovals.isEmpty else { return }
        let upserts = Array(listUpserts.values), removals = listRemovals
        listUpserts = [:]
        listRemovals = []
        applyListChanges(upserts: upserts, removals: removals)
    }

    /// Changes `notes` by `upserts` and `removals` (`NoteListDiff`); assigns
    /// only when something differs.
    func applyListChanges(upserts: [NoteSummary], removals: Set<UUID>) {
        lastListApply = .now
        let interval = services.perf.begin("list.update")
        var changed = false
        if let next = NoteListDiff.apply(upserts: upserts, removals: removals, to: notes) {
            listChangeIDs = Set(upserts.map(\.id)).union(removals)
            notes = next
            listChangeIDs = nil
            changed = true
        }
        services.perf.end(interval, "upserts=\(upserts.count) removals=\(removals.count) notes=\(notes.count) changed=\(changed)")
    }

    /// Forgets queued updates (the vault closed).
    func discardListUpdates() {
        listFlushTask?.cancel()
        listFlushTask = nil
        listUpserts = [:]
        listRemovals = []
        lastListApply = nil
    }
}

/// Lists the views derive from `notes`, computed once per change: the
/// sidebar and the list read them on every render.
struct DerivedLists {
    struct VisibleKey: Equatable {
        var version: Int
        var selection: SidebarItem?
        var search: String
        var sort: NoteSort
        var favoritesFirst: Bool

        init(version: Int, selection: SidebarItem?, search: String, sort: NoteSort, favoritesFirst: Bool) {
            self.version = version
            self.selection = selection
            self.search = search
            self.sort = sort
            self.favoritesFirst = favoritesFirst
        }
    }

    var visible: (key: VisibleKey, value: [NoteSummary])?
    var byID: (version: Int, value: [UUID: NoteSummary])?
    var tags: (version: Int, value: [String])?
    var tree: (version: Int, value: [NotebookNode])?

    init() {}
}
