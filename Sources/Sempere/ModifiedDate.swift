import Foundation

// MARK: - A note's modified date (format.md §5.5, §10, §12.2)

extension Op {
    /// A derived recognition op (format.md §5.5): the page's recognized text
    /// (`setPageRecognition`) or the record of a vault-wide recognition run
    /// (`setMeta(.recognized)`). Software writes these from the ink; no user
    /// edit does.
    public var isDerivedRecognition: Bool {
        switch self {
        case .setPageRecognition: return true
        case .setMeta(.recognized): return true
        default: return false
        }
    }
}

extension Revision {
    /// A delta that only records recognition: a non-empty `ops`, every one a
    /// derived recognition op (`Op.isDerivedRecognition`), and not a version
    /// the user saved. A revision of newer content (`newer`) is never one: what
    /// it skipped is unknown.
    public var isDerivedOnly: Bool {
        guard case .delta(let ops) = body, !ops.isEmpty, newer == nil, checkpoint == nil else { return false }
        return ops.allSatisfy(\.isDerivedRecognition)
    }

    /// The date this revision gives the note's modified date (`ModifiedDate`),
    /// nil when it gives none:
    /// - a derived-only delta (`isDerivedOnly`): none;
    /// - any other delta: its `wall`;
    /// - a snapshot of newer content (`newer`): its `wall`;
    /// - any other snapshot: the time of the newest edit its state holds, which is the
    ///   greatest HLC of its stamps and origins without recognition's
    ///   (`NoteState.maxHLC(withRecognition:)`), or the note's `created` when
    ///   that is later; never after its own `wall`. A snapshot is written by
    ///   compaction or thinning long after the edits it folds in, so its `wall`
    ///   is no edit time.
    public var modifiedDate: Date? {
        switch body {
        case .delta: return isDerivedOnly ? nil : wall
        case .snapshot where newer != nil:
            // Newer content: it may hold edits in fields this reader skipped, so its state's stamps can be
            // older than the last edit. Fail toward counting, as a newer delta does.
            return wall
        case .snapshot(_, let state):
            let edited = Date(timeIntervalSince1970: Double(state.maxHLC(withRecognition: false).millis) / 1000)
            return min(wall, max(edited, state.meta.created))
        }
    }
}

/// A note's modified date: the latest `Revision.modifiedDate` of its
/// revisions, or, when none gives one (every revision a derived-only delta),
/// the greatest `wall` of them all. Recognition written by the app, the CLI
/// or an import (format.md §5.5) and the snapshots compaction and thinning
/// write (§5.3, §5.8.4) leave it where the user's last edit put it.
///
/// Built up one revision at a time, so an incremental summary
/// (`SummaryCheckpoint`) adds new deltas to what a full read found.
public struct ModifiedDate: Hashable, Sendable {
    /// The latest `modifiedDate` added.
    public private(set) var edited: Date?
    /// The greatest `wall` added.
    public private(set) var newest: Date?

    public init() {}

    public init<S: Sequence>(_ revisions: S) where S.Element == Revision {
        for r in revisions { add(r) }
    }

    /// Counts `revision` in.
    public mutating func add(_ revision: Revision) {
        if newest.map({ revision.wall > $0 }) ?? true { newest = revision.wall }
        if let d = revision.modifiedDate, edited.map({ d > $0 }) ?? true { edited = d }
    }

    /// The modified date; nil only when nothing was added.
    public var value: Date? { edited ?? newest }

    /// The modified date of `revisions`.
    public static func of<S: Sequence>(_ revisions: S) -> Date? where S.Element == Revision {
        ModifiedDate(revisions).value
    }
}
