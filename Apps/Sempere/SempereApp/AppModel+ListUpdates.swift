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
extension AppModel {
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
        let interval = Perf.begin(.listUpdate)
        var changed = false
        if let next = NoteListDiff.apply(upserts: upserts, removals: removals, to: notes) {
            listChangeIDs = Set(upserts.map(\.id)).union(removals)
            notes = next
            listChangeIDs = nil
            changed = true
        }
        Perf.end(interval, "upserts=\(upserts.count) removals=\(removals.count) notes=\(notes.count) changed=\(changed)")
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

/// Applying changes to a list sorted by `AppModel.byTitle` order.
enum NoteListDiff {
    /// The sort key of `AppModel.byTitle`.
    static func key(_ s: NoteSummary) -> (String, String) { (s.title.lowercased(), s.id.uuidString) }

    /// `list` (sorted by title, then id) with `removals` dropped and
    /// `upserts` put in their sorted place; nil when nothing changes.
    static func apply(upserts: [NoteSummary], removals: Set<UUID>, to list: [NoteSummary]) -> [NoteSummary]? {
        guard !upserts.isEmpty || !removals.isEmpty else { return nil }
        var position: [UUID: Int] = [:]
        position.reserveCapacity(list.count)
        for (i, s) in list.enumerated() { position[s.id] = i }
        var out = list
        var drop = Set<Int>()
        var insert: [NoteSummary] = []
        var changed = false
        for id in removals { if let i = position[id] { drop.insert(i); changed = true } }
        var latest: [UUID: NoteSummary] = [:]
        for s in upserts where !removals.contains(s.id) { latest[s.id] = s }
        for s in latest.values {
            if let i = position[s.id] {
                guard out[i] != s else { continue }
                changed = true
                if key(out[i]) == key(s) { out[i] = s } else { drop.insert(i); insert.append(s) }
            } else {
                changed = true
                insert.append(s)
            }
        }
        guard changed else { return nil }
        if !drop.isEmpty { out = out.enumerated().filter { !drop.contains($0.offset) }.map(\.element) }
        guard !insert.isEmpty else { return out }
        insert.sort { key($0) < key($1) }
        var merged: [NoteSummary] = []
        merged.reserveCapacity(out.count + insert.count)
        var i = 0, j = 0
        while i < out.count || j < insert.count {
            if j == insert.count || (i < out.count && key(out[i]) < key(insert[j])) {
                merged.append(out[i]); i += 1
            } else {
                merged.append(insert[j]); j += 1
            }
        }
        return merged
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
    }

    var visible: (key: VisibleKey, value: [NoteSummary])?
    var byID: (version: Int, value: [UUID: NoteSummary])?
    var tags: (version: Int, value: [String])?
    var tree: (version: Int, value: [NotebookNode])?
}
