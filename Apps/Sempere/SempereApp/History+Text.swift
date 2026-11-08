import Foundation
import Sempere
import SempereAppCore

// The words of the history list's values (`AppModel+History.swift` in SempereAppCore): the rows' labels, the
// sessions' lines and the compaction notice.

/// The history list's row (the core's; `Sempere` has a `HistoryEntry` of its own, a revision file's listing).
typealias HistoryEntry = SempereAppCore.HistoryEntry

extension HistoryEntry {
    /// "This device", or "Device " and the id's first four characters.
    var deviceLabel: String {
        if isThisDevice { return String(localized: "This device", comment: "History: a version saved on this device") }
        let prefix = devicePrefix
        return String(localized: "Device \(prefix)", comment: "History: another device, named by the first characters of its id")
    }

    /// "Saved version" for a checkpoint, "Edit" for a delta, "Snapshot" for a snapshot.
    var kindLabel: String {
        switch kind {
        case .savedVersion: return String(localized: "Saved version", comment: "History: kind of a restore point (a checkpoint)")
        case .snapshot: return String(localized: "Snapshot", comment: "History: kind of a restore point (a compacted snapshot)")
        case .edit: return String(localized: "Edit", comment: "History: kind of a restore point (noun: one autosaved change)")
        }
    }

    /// A checkpoint's name; "Saved Version" when it has none; nil for other points.
    var checkpointTitle: String? {
        guard let c = point.checkpoint else { return nil }
        return c.name ?? String(localized: "Saved Version", comment: "History: title of a saved version without a name")
    }

    /// Why the point is grayed out, when it is.
    var unavailableReason: String? {
        isAvailable ? nil : String(localized: "Earlier revisions were compacted away or cannot be read, so this version cannot be rebuilt.")
    }

    /// The sentence that says compacted revisions are not restore points (`needsCompactionNotice`).
    static func compactionNotice(_ points: [RestorePoint]) -> String? {
        guard needsCompactionNotice(points) else { return nil }
        return String(localized: "Revisions removed by compaction are not restore points and are not listed. Versions that depend on them are grayed out and cannot be shown or restored.")
    }
}

extension HistoryData {
    /// The compaction notice, shown when the note has a snapshot or a point cannot be rebuilt.
    var compactionNotice: String? { HistoryEntry.compactionNotice(points) }
}

extension HistoryGroupRow {
    /// "This device · 12 saves" (the device and the number of autosaves).
    var summary: String {
        let savesText = String(localized: "\(saves) saves", comment: "History: number of autosaves in an editing session")
        return String(localized: "\(newest.deviceLabel) · \(savesText)", comment: "History: device and number of saves of a session")
    }

    /// "Oct 6, 2026, 2:02 PM – 2:31 PM": the date and time range of a session
    /// (one time when it has one save; both dates when it spans days).
    var timeRange: String {
        let first = start.formatted(date: .abbreviated, time: .shortened)
        guard saves > 1, end != start else { return first }
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        let last = end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return String(localized: "\(first) – \(last)", comment: "History: the start and end of an editing session")
    }
}
