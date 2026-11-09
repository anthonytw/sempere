import Foundation
import Sempere

/// Applying changes to the note list, sorted by title (case-insensitive), then id: the order of
/// `AppModel.notes` (`AppModel.byTitle`).
public enum NoteListDiff {
    /// The list's sort key.
    static func key(_ s: NoteSummary) -> (String, String) { (s.title.lowercased(), s.id.uuidString) }

    /// `list` (sorted by title, then id) with `removals` dropped and
    /// `upserts` put in their sorted place; nil when nothing changes.
    public static func apply(upserts: [NoteSummary], removals: Set<UUID>, to list: [NoteSummary]) -> [NoteSummary]? {
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

    /// `list` in the list's order (`key`).
    static func sorted(_ list: [NoteSummary]) -> [NoteSummary] {
        list.sorted { key($0) < key($1) }
    }
}
