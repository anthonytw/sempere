import Foundation
import Sempere

/// One note's revisions as read for the history browser: loaded once, so
/// previewing several restore points does not decrypt the note again.
struct HistoryData: Sendable {
    let noteID: UUID
    let revisions: [Revision]
    /// Listed revisions that could not be read.
    let unreadable: [RevisionName]
    /// This installation's device id, for "This device" labels.
    let thisDevice: DeviceID?
    /// Restore points, oldest first (`NoteHistory.restorePoints`). Computed
    /// once: the views read it on every update.
    let points: [RestorePoint]
    /// The rows to show, newest first.
    let entries: [HistoryEntry]
    /// The same rows grouped as the list shows them (format.md §5.8.2):
    /// checkpoints and editing sessions, newest first.
    let groups: [HistoryGroupRow]

    init(noteID: UUID, revisions: [Revision], unreadable: [RevisionName], thisDevice: DeviceID?) {
        self.noteID = noteID
        self.revisions = revisions
        self.unreadable = unreadable
        self.thisDevice = thisDevice
        points = NoteHistory.restorePoints(revisions, unreadable: unreadable)
        entries = HistoryEntry.entries(points, thisDevice: thisDevice)
        groups = HistoryGroupRow.rows(points, entries: entries)
    }

    /// The note as of `point`; throws `HistoryError.incompleteHistory` for a
    /// point compaction or an unreadable file made unrebuildable.
    func state(at point: RevisionName) throws -> NoteState {
        try NoteHistory.state(revisions, at: point, unreadable: unreadable)
    }

    /// The sentence that says compacted revisions are not restore points,
    /// shown when the note has a snapshot or a point cannot be rebuilt.
    var compactionNotice: String? { HistoryEntry.compactionNotice(points) }
}

/// A restore point as a row of the history list.
struct HistoryEntry: Identifiable, Hashable, Sendable {
    let point: RestorePoint
    /// The newest restore point: what the note is now.
    let isLatest: Bool
    let isThisDevice: Bool

    var id: RevisionName { point.name }
    var date: Date { point.wall }
    /// Whether the note as of this point can be shown and restored.
    var isAvailable: Bool { point.complete }

    /// "This device", or "Device " and the id's first four characters.
    var deviceLabel: String {
        if isThisDevice { return String(localized: "This device", comment: "History: a version saved on this device") }
        let prefix = String(point.device.rawValue.prefix(4))
        return String(localized: "Device \(prefix)", comment: "History: another device, named by the first characters of its id")
    }

    /// "Saved version" for a checkpoint, "Edit" for a delta, "Snapshot" for a snapshot.
    var kindLabel: String {
        if point.isCheckpoint { return String(localized: "Saved version", comment: "History: kind of a restore point (a checkpoint)") }
        return point.kind == .snapshot
            ? String(localized: "Snapshot", comment: "History: kind of a restore point (a compacted snapshot)")
            : String(localized: "Edit", comment: "History: kind of a restore point (noun: one autosaved change)")
    }

    /// A checkpoint's name; "Saved Version" when it has none; nil for other points.
    var checkpointTitle: String? {
        guard let c = point.checkpoint else { return nil }
        return c.name ?? String(localized: "Saved Version", comment: "History: title of a saved version without a name")
    }

    /// Why the point is greyed out, when it is.
    var unavailableReason: String? {
        isAvailable ? nil : String(localized: "Earlier revisions were compacted away or cannot be read, so this version cannot be rebuilt.")
    }

    /// Rows for `points` (oldest first, as `NoteHistory.restorePoints` returns
    /// them), newest first.
    static func entries(_ points: [RestorePoint], thisDevice: DeviceID?) -> [HistoryEntry] {
        points.enumerated().reversed().map { i, p in
            HistoryEntry(point: p, isLatest: i == points.count - 1, isThisDevice: p.device == thisDevice)
        }
    }

    /// Compaction (format.md §5.3) deletes revisions and they are not restore
    /// points; said whenever a snapshot exists or a point is incomplete.
    static func compactionNotice(_ points: [RestorePoint]) -> String? {
        guard points.contains(where: { $0.kind == .snapshot || !$0.complete }) else { return nil }
        return String(localized: "Revisions removed by compaction are not restore points and are not listed. Versions that depend on them are grayed out and cannot be shown or restored.")
    }
}

/// One top-level row of the history list: a checkpoint, or an editing
/// session whose autosaves are shown when it is expanded.
struct HistoryGroupRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case checkpoint, session }
    let kind: Kind
    /// The group's rows, newest first; never empty.
    let entries: [HistoryEntry]

    /// The newest point's revision.
    var id: RevisionName { entries[0].id }
    var newest: HistoryEntry { entries[0] }
    /// `wall` of the oldest and the newest point.
    var start: Date { entries[entries.count - 1].date }
    var end: Date { entries[0].date }
    var saves: Int { entries.count }
    /// Whether the note as it is now is in this group.
    var containsLatest: Bool { entries.contains(where: \.isLatest) }

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

    /// Groups `points` (oldest first) with `NoteHistory.groups` and pairs them
    /// with their `entries` (newest first, as `HistoryEntry.entries` makes them).
    static func rows(_ points: [RestorePoint], entries: [HistoryEntry]) -> [HistoryGroupRow] {
        let byName = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return NoteHistory.groups(points).reversed().compactMap { group in
            let rows = group.points.reversed().compactMap { byName[$0.name] }
            guard !rows.isEmpty else { return nil }
            if case .checkpoint = group { return HistoryGroupRow(kind: .checkpoint, entries: rows) }
            return HistoryGroupRow(kind: .session, entries: rows)
        }
    }
}

extension AppModel {
    /// Reads every revision of note `id` for the history browser. The open
    /// canvas's pending changes are saved first, so the newest row ("Current")
    /// is what the canvas shows. In iCloud Drive the note is downloaded first
    /// and the read, coordinated, refuses a note whose files are not all local
    /// (`CloudVault.requireLocal`).
    func loadHistory(for id: UUID) async throws -> HistoryData {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        if let editor, editor.noteID == id { await editor.flush() }
        await windowEditors[id]?.flush()   // a note window's pending ink
        try ensureCurrent(gen)
        try await downloadNote(id)
        let cloud = isCloudVault
        let hooks = cloudHooks
        let url = vault.url
        let device = try? deviceClockForWriting().device
        let data = try await offMain {
            try CloudVault.coordinatedRead(cloud ? url : nil) { () throws -> HistoryData in
                if cloud { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
                let loaded = try vault.loadNote(id)
                if cloud { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
                return HistoryData(noteID: id, revisions: loaded.revisions, unreadable: Array(loaded.failures.keys),
                                   thisDevice: device)
            }
        }
        try ensureCurrent(gen)
        return data
    }

    /// A read-only editor showing the note as of `point`, for the preview. It
    /// has no writer: nothing the user does with it can reach the vault.
    func historyPreview(_ data: HistoryData, at point: RevisionName) async throws -> NoteEditor {
        let gen = generation
        let state = try await offMain { try data.state(at: point) }
        try ensureCurrent(gen)
        return NoteEditor(noteID: data.noteID, state: state, writer: nil,
                          readOnlyReason: String(localized: "Preview of an earlier version. Nothing here can be edited."))
    }

    /// Restores note `id` to `point` with one delta (`NoteWriter.restore`),
    /// serialised with the other edits. The open note's pending canvas
    /// changes are saved first (so they are part of the history that is kept,
    /// not written over the restore later), and the open canvas is reopened
    /// from the restored state.
    ///
    /// - Returns: what changed, or nil when the note already matched `point`.
    @discardableResult
    func restoreVersion(of id: UUID, to point: RevisionName) async throws -> RestoreSummary? {
        try await downloadNote(id)
        if let editor, editor.noteID == id {
            await editor.flush()
            if let failure = editor.saveError { throw ModelError.unsavedChanges(failure) }
        }
        if let windowed = windowEditors[id] {   // the same for the note's own window
            await windowed.flush()
            if let failure = windowed.saveError { throw ModelError.unsavedChanges(failure) }
        }
        var result: (name: RevisionName, summary: RestoreSummary)?
        try await commit(ids: [id]) { vault, clock, cloud, verifier in
            result = try await NoteWriter.restore(id, to: point, vault: vault, clock: clock, coordinated: cloud,
                                                  verify: verifier(id))
        }
        guard let result else { return nil }
        try await reopenEditor(ifShowing: id)
        return result.summary
    }

    /// Saves note `id` as it is now as a version (a checkpoint, format.md
    /// §5.8.1): the open canvas's pending ink is saved first, then one delta
    /// with no ops carries the checkpoint and its name (trimmed; blank is
    /// unnamed), through the same path as the browser's edits.
    ///
    /// - Returns: the checkpoint's revision.
    @discardableResult
    func saveVersion(of id: UUID, name: String?) async throws -> RevisionName {
        try await downloadNote(id)
        if let editor, editor.noteID == id {
            await editor.flush()
            if let failure = editor.saveError { throw ModelError.unsavedChanges(failure) }
        }
        if let windowed = windowEditors[id] {
            await windowed.flush()
            if let failure = windowed.saveError { throw ModelError.unsavedChanges(failure) }
        }
        let checkpoint = Checkpoint(name: name)
        var written: RevisionName?
        try await commit(ids: [id]) { vault, clock, cloud, verifier in
            written = try await NoteWriter.append([], to: id, vault: vault, clock: clock, coordinated: cloud,
                                                  checkpoint: checkpoint, verify: verifier(id))
        }
        guard let written else { throw ModelError.noVaultOpen }
        return written
    }
}
