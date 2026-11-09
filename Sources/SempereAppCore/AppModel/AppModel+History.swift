import Foundation
import Sempere

/// One note's revisions as read for the history browser: loaded once, so
/// previewing several restore points does not decrypt the note again. The
/// revisions are read in full, on several cores (`Vault.loadNoteConcurrently`,
/// P53): the list's completeness flags come from exactly the revisions and
/// failures a plain `loadNote` gives, and decrypting (not decoding stroke
/// geometry) is what the read costs.
public struct HistoryData: Sendable {
    public let noteID: UUID
    let revisions: [Revision]
    /// Listed revisions that could not be read.
    let unreadable: [RevisionName]
    /// This installation's device id, for "This device" labels.
    let thisDevice: DeviceID?
    /// Restore points, oldest first (`NoteHistory.restorePoints`). Computed
    /// once: the views read it on every update.
    public let points: [RestorePoint]
    /// The rows to show, newest first.
    public let entries: [HistoryRow]
    /// The same rows grouped as the list shows them (format.md §5.8.2):
    /// checkpoints and editing sessions, newest first.
    public let groups: [HistoryGroupRow]

    init(noteID: UUID, revisions: [Revision], unreadable: [RevisionName], thisDevice: DeviceID?) {
        self.noteID = noteID
        self.revisions = revisions
        self.unreadable = unreadable
        self.thisDevice = thisDevice
        points = NoteHistory.restorePoints(revisions, unreadable: unreadable)
        entries = HistoryRow.entries(points, thisDevice: thisDevice)
        groups = HistoryGroupRow.rows(points, entries: entries)
    }

    /// The last previewed states, shared by copies of this value.
    public let previews = HistoryPreviews()

    /// The note as of `point`; throws `HistoryError.incompleteHistory` for a
    /// point compaction or an unreadable file made unrebuildable. Stepping
    /// back to one of the last few points previewed rebuilds nothing.
    public func state(at point: RevisionName) throws -> NoteState {
        if let kept = previews.state(at: point) { return kept }
        let state = try NoteHistory.state(revisions, at: point, unreadable: unreadable)
        previews.remember(state, at: point)
        return state
    }

    /// Whether the list says compacted revisions are not restore points (`HistoryRow.needsCompactionNotice`;
    /// the sentence is the app's).
    var needsCompactionNotice: Bool { HistoryRow.needsCompactionNotice(points) }
}

/// The last `kept` states a history browser previewed, newest last. Previews
/// are built off the main actor, so behind a lock.
public final class HistoryPreviews: @unchecked Sendable {
    static let kept = 4
    private let lock = NSLock()
    private var states: [(point: RevisionName, state: NoteState)] = []
    /// States built (not taken from here), for tests.
    private(set) var built = 0

    init() {}

    func state(at point: RevisionName) -> NoteState? {
        lock.withLock { states.first { $0.point == point }?.state }
    }

    func remember(_ state: NoteState, at point: RevisionName) {
        lock.withLock {
            built += 1
            states.removeAll { $0.point == point }
            states.append((point, state))
            if states.count > Self.kept { states.removeFirst(states.count - Self.kept) }
        }
    }

    public var buildCount: Int { lock.withLock { built } }
}

/// A restore point as a row of the history list. Its words (`deviceLabel`, `kindLabel`, `checkpointTitle`,
/// `unavailableReason`) are the app's, from the typed values here.
public struct HistoryRow: Identifiable, Hashable, Sendable {
    /// What kind of restore point a row is.
    public enum Kind: Hashable, Sendable {
        /// A checkpoint ("Saved version").
        case savedVersion
        /// A compacted snapshot.
        case snapshot
        /// One autosaved change (a delta).
        case edit
    }

    public let point: RestorePoint
    /// The newest restore point: what the note is now.
    public let isLatest: Bool
    public let isThisDevice: Bool

    init(point: RestorePoint, isLatest: Bool, isThisDevice: Bool) {
        self.point = point
        self.isLatest = isLatest
        self.isThisDevice = isThisDevice
    }

    public var id: RevisionName { point.name }
    public var date: Date { point.wall }
    /// Whether the note as of this point can be shown and restored.
    public var isAvailable: Bool { point.complete }

    /// The first four characters of the device id, which names another device.
    public var devicePrefix: String { String(point.device.rawValue.prefix(4)) }

    /// A checkpoint for a checkpoint, else a snapshot or an edit.
    public var kind: Kind {
        if point.isCheckpoint { return .savedVersion }
        return point.kind == .snapshot ? .snapshot : .edit
    }

    /// Rows for `points` (oldest first, as `NoteHistory.restorePoints` returns
    /// them), newest first.
    public static func entries(_ points: [RestorePoint], thisDevice: DeviceID?) -> [HistoryRow] {
        points.enumerated().reversed().map { i, p in
            HistoryRow(point: p, isLatest: i == points.count - 1, isThisDevice: p.device == thisDevice)
        }
    }

    /// Compaction (format.md §5.3) deletes revisions and they are not restore
    /// points; said whenever a snapshot exists or a point is incomplete.
    public static func needsCompactionNotice(_ points: [RestorePoint]) -> Bool {
        points.contains(where: { $0.kind == .snapshot || !$0.complete })
    }
}

/// One top-level row of the history list: a checkpoint, or an editing
/// session whose autosaves are shown when it is expanded.
public struct HistoryGroupRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case checkpoint, session }
    public let kind: Kind
    /// The group's rows, newest first; never empty.
    public let entries: [HistoryRow]

    init(kind: Kind, entries: [HistoryRow]) {
        self.kind = kind
        self.entries = entries
    }

    /// The newest point's revision.
    public var id: RevisionName { entries[0].id }
    public var newest: HistoryRow { entries[0] }
    /// `wall` of the oldest and the newest point.
    public var start: Date { entries[entries.count - 1].date }
    public var end: Date { entries[0].date }
    public var saves: Int { entries.count }
    /// Whether the note as it is now is in this group.
    public var containsLatest: Bool { entries.contains(where: \.isLatest) }

    /// Groups `points` (oldest first) with `NoteHistory.groups` and pairs them
    /// with their `entries` (newest first, as `HistoryRow.entries` makes them).
    public static func rows(_ points: [RestorePoint], entries: [HistoryRow]) -> [HistoryGroupRow] {
        let byName = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return NoteHistory.groups(points).reversed().compactMap { group in
            let rows = group.points.reversed().compactMap { byName[$0.name] }
            guard !rows.isEmpty else { return nil }
            if case .checkpoint = group { return HistoryGroupRow(kind: .checkpoint, entries: rows) }
            return HistoryGroupRow(kind: .session, entries: rows)
        }
    }
}

extension AppModelCore {
    /// Reads every revision of note `id` for the history browser. The open
    /// canvas's pending changes are saved first, so the newest row ("Current")
    /// is what the canvas shows. In a partial copy the note is fetched first (`downloadNote`).
    public func loadHistory(for id: UUID) async throws -> HistoryData {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        if let editor, editor.noteID == id { await editor.flush() }
        await windowEditors[id]?.flush()   // a note window's pending ink
        try ensureCurrent(gen)
        try await downloadNote(id)
        let device = try? deviceClockForWriting().device
        let perf = services.perf
        let data = try await offMain { try Self.readHistory(id, vault: vault, thisDevice: device, perf: perf) }
        try ensureCurrent(gen)
        return data
    }

    /// `loadHistory`'s read, off the main actor: every revision of `id`, on
    /// several cores, reported to `perf` as "history.read".
    nonisolated public static func readHistory(_ id: UUID, vault: Vault, thisDevice: DeviceID?,
                                               perf: any PerfSink = NoPerfSink()) throws -> HistoryData {
        try perf.measure("history.read", "") { () throws -> HistoryData in
            let loaded = try vault.loadNoteConcurrently(id)
            return HistoryData(noteID: id, revisions: loaded.revisions, unreadable: Array(loaded.failures.keys),
                               thisDevice: thisDevice)
        }
    }

    /// A read-only editor showing the note as of `point`, for the preview. It
    /// has no writer: nothing the user does with it can reach the vault.
    public func historyPreview(_ data: HistoryData, at point: RevisionName) async throws -> Editor {
        let gen = generation
        let state = try await offMain { try data.state(at: point) }
        try ensureCurrent(gen)
        return Editor(noteID: data.noteID, state: state, writer: nil, readOnly: .preview, perf: services.perf)
    }

    /// Restores note `id` to `point` with one delta (`NoteWriter.restore`),
    /// serialized with the other edits. The open note's pending canvas
    /// changes are saved first (so they are part of the history that is kept,
    /// not written over the restore later), and the open canvas is reopened
    /// from the restored state.
    ///
    /// - Returns: what changed, or nil when the note already matched `point`.
    @discardableResult
    public func restoreVersion(of id: UUID, to point: RevisionName) async throws -> RestoreSummary? {
        try await downloadNote(id)
        if let editor, editor.noteID == id {
            await editor.flush()
            if let failure = editor.saveFailure { throw ModelError.unsavedChanges(failure) }
        }
        if let windowed = windowEditors[id] {   // the same for the note's own window
            await windowed.flush()
            if let failure = windowed.saveFailure { throw ModelError.unsavedChanges(failure) }
        }
        var result: (name: RevisionName, summary: RestoreSummary)?
        try await commit(ids: [id]) { vault, clock, verifier in
            result = try await NoteWriter.restore(id, to: point, vault: vault, clock: clock,
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
    public func saveVersion(of id: UUID, name: String?) async throws -> RevisionName {
        try await downloadNote(id)
        if let editor, editor.noteID == id {
            await editor.flush()
            if let failure = editor.saveFailure { throw ModelError.unsavedChanges(failure) }
        }
        if let windowed = windowEditors[id] {
            await windowed.flush()
            if let failure = windowed.saveFailure { throw ModelError.unsavedChanges(failure) }
        }
        let checkpoint = Checkpoint(name: name)
        var written: RevisionName?
        try await commit(ids: [id]) { vault, clock, verifier in
            written = try await NoteWriter.append([], to: id, vault: vault, clock: clock,
                                                  checkpoint: checkpoint, verify: verifier(id))
        }
        guard let written else { throw ModelError.noVaultOpen }
        return written
    }
}
