import Foundation

/// What the planner needs to know about one snapshot.
public struct SnapshotCoverage: Hashable, Sendable {
    public var name: RevisionName
    public var included: Included
    /// Nil when unknown; such a snapshot is never deleted.
    public var wall: Date?

    public init(name: RevisionName, included: Included, wall: Date?) {
        self.name = name; self.included = included; self.wall = wall
    }

    /// Coverage of a snapshot revision; nil for a delta.
    public init?(_ revision: Revision) {
        guard case .snapshot(let included, _) = revision.body else { return nil }
        self.init(name: revision.name, included: included, wall: revision.wall)
    }
}

/// Decides which revision files may be deleted (format.md §5.3).
public enum CompactionPlanner {
    /// Default retention window: 30 days by `wall`.
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Revisions that may be deleted:
    ///
    /// - a delta in `names` whose own `wall` (looked up in `wall`) is older
    ///   than `retention` and which at least one snapshot's `included` covers;
    /// - a snapshot older than `retention` when another snapshot's
    ///   `included` is a superset of its `included`. Among snapshots with equal
    ///   `included`, the one with the greatest name is kept, so every deleted
    ///   snapshot is subsumed by one that stays.
    ///
    /// Anything without a known `wall` is kept. Result sorted by `(hlc, device, seq)`.
    public static func deletable(names: [RevisionName], wall: [RevisionName: Date], snapshots: [SnapshotCoverage],
                                 retention: TimeInterval = defaultRetention, now: Date) -> [RevisionName] {
        func old(_ date: Date?) -> Bool {
            guard let date else { return false }
            return now.timeIntervalSince(date) > retention
        }
        var out = Set<RevisionName>()
        for name in names where name.kind == .delta && old(wall[name]) {
            if snapshots.contains(where: { $0.included.covers(device: name.device, seq: name.seq) }) {
                out.insert(name)
            }
        }
        for s in snapshots where old(s.wall) {
            let subsumed = snapshots.contains { t in
                guard t.name != s.name, t.included.isSuperset(of: s.included) else { return false }
                return !s.included.isSuperset(of: t.included) || t.name > s.name
            }
            if subsumed { out.insert(s.name) }
        }
        return out.sorted()
    }
}
