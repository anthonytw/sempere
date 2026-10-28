import Foundation

// MARK: - Replacements and concurrent replacements (docs/format.md §5.6.1)
//
// Every stroke with a `parent` is an edge of a forest. An edge is a
// replacement when the revision that added the child also removed the parent
// (a slice, move, recolor, split); otherwise it is a re-creation (undo,
// restore, page restore, join). A parent with replacements from two or more
// revisions was replaced concurrently: the greatest revision wins and the
// others' strokes, and what replaced them in turn, are superseded.

/// The `(hlc, device, seq)` of the revision that added a stroke: the group
/// its replacement belongs to (format.md §5.6.1 rule 1).
struct ReplacementGroup: Hashable, Comparable {
    var hlc: HLC
    var device: DeviceID
    var seq: Int

    init(_ origin: Origin) { hlc = origin.hlc; device = origin.device; seq = origin.seq }

    /// Parses `"<hlc>-<device>-<seq>"` (format.md §5.6.1 `replaced.by`).
    init?(_ string: String) {
        guard let o = Origin(string + "-0") else { return nil }
        self.init(o)
    }

    var description: String { "\(hlc)-\(device)-\(seq)" }

    static func < (l: ReplacementGroup, r: ReplacementGroup) -> Bool {
        (l.hlc, l.device, l.seq) < (r.hlc, r.device, r.seq)
    }
}

/// What the merge knows about one stroke that has a `parent`.
struct LineageEntry: Equatable {
    var parent: UUID
    var group: ReplacementGroup
    /// The adding revision also removed `parent`.
    var replaces: Bool
}

/// The stroke forest of one merge: every stroke with a `parent` that any
/// snapshot holds or any delta adds, live or not.
struct StrokeLineage {
    private(set) var entries: [UUID: LineageEntry] = [:]
    /// Superseded strokes snapshots recorded (`tombstones.superseded`).
    private(set) var recordedSuperseded = Set<UUID>()

    /// Collects the evidence of format.md §5.6.1: every stroke of every
    /// snapshot (`origin`, `parent`, `replaces`) and every `addStroke` of every
    /// delta, covered or not. Deterministic for any order of the inputs: one
    /// id is added by one revision, and should hostile input disagree, the
    /// smallest `(group, parent)` is kept and `replaces` is or-ed over equal ones.
    init(snapshots: [NoteReducer.Snap], deltas: [Revision]) {
        for s in snapshots {
            for r in s.state.tombstones?.lineage ?? [] {
                // An unreadable record is skipped: at worst a replacement is kept that would have lost.
                guard let g = ReplacementGroup(r.by) else { continue }
                offer(r.stroke, LineageEntry(parent: r.parent, group: g, replaces: true))
            }
            recordedSuperseded.formUnion(s.state.tombstones?.superseded ?? [])
            for p in s.state.pages {
                for (j, st) in p.strokes.enumerated() {
                    guard let parent = st.parent else { continue }
                    let origin = st.origin.flatMap(Origin.init) ?? Origin(s.name, op: j)
                    offer(st.id, LineageEntry(parent: parent, group: ReplacementGroup(origin), replaces: st.replaces))
                }
            }
        }
        for d in deltas {
            var removed = Set<UUID>()
            for case .removeStroke(_, let id) in d.ops { removed.insert(id) }
            for case .addStroke(_, let st) in d.ops {
                guard let parent = st.parent else { continue }
                // `replaces` inside an op is ignored: the op list says it.
                offer(st.id, LineageEntry(parent: parent, group: ReplacementGroup(Origin(d.name, op: 0)),
                                          replaces: removed.contains(parent)))
            }
        }
    }

    private mutating func offer(_ id: UUID, _ e: LineageEntry) {
        guard let cur = entries[id] else { entries[id] = e; return }
        if cur.group == e.group && cur.parent == e.parent {
            if e.replaces && !cur.replaces { entries[id]?.replaces = true }
        } else if (e.group, e.parent.uuidString) < (cur.group, cur.parent.uuidString) {
            entries[id] = e
        }
    }

    /// True when `id` replaces its parent.
    func replaces(_ id: UUID) -> Bool { entries[id]?.replaces ?? false }

    /// The groups of every replaced stroke.
    private func groupsByParent() -> [UUID: [ReplacementGroup: [UUID]]] {
        var groups: [UUID: [ReplacementGroup: [UUID]]] = [:]
        for (id, e) in entries where e.replaces { groups[e.parent, default: [:]][e.group, default: []].append(id) }
        return groups
    }

    /// Strokes superseded by a concurrent replacement (format.md §5.6.1 rules
    /// 2 and 3), recorded ones included. Linear in the number of entries;
    /// parent cycles in hostile input end the walk.
    func superseded() -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for (id, e) in entries where e.replaces { children[e.parent, default: []].append(id) }
        var out = recordedSuperseded
        var queue = Array(recordedSuperseded)
        for byGroup in groupsByParent().values where byGroup.count > 1 {
            guard let winner = byGroup.keys.max() else { continue }
            for (g, ids) in byGroup where g != winner {
                for id in ids where out.insert(id).inserted { queue.append(id) }
            }
        }
        while let x = queue.popLast() {
            for c in children[x] ?? [] where out.insert(c).inserted { queue.append(c) }
        }
        return out
    }

    /// `tombstones.lineage` for a snapshot holding `held` (format.md
    /// §5.6.1): every replacing stroke not held and not superseded that is
    /// an ancestor, over replacements, of a held stroke, and for each
    /// replaced stroke whose winning group has nothing held or listed, that
    /// group's first stroke id. Sorted by stroke id; linear in the entries.
    func records(held: Set<UUID>, superseded: Set<UUID>) -> [Tombstones.Lineage] {
        var keep = Set<UUID>()
        for h in held {
            var c = h
            var steps = 0
            while let e = entries[c], e.replaces, steps <= entries.count {
                steps += 1
                let p = e.parent
                guard let pe = entries[p], pe.replaces, !held.contains(p), !superseded.contains(p),
                      keep.insert(p).inserted else { break }
                c = p
            }
        }
        for byGroup in groupsByParent().values {
            guard let winner = byGroup.keys.max(), let ids = byGroup[winner],
                  !ids.contains(where: { held.contains($0) || keep.contains($0) }),
                  let first = ids.filter({ !superseded.contains($0) }).min(by: { $0.uuidString < $1.uuidString })
            else { continue }
            keep.insert(first)
        }
        return keep.compactMap { id in
            entries[id].map { Tombstones.Lineage(stroke: id, parent: $0.parent, by: $0.group.description) }
        }.sorted { $0.stroke.uuidString.lowercased() < $1.stroke.uuidString.lowercased() }
    }

    /// Of `visible`, the strokes that descend (over any edge, re-creations
    /// included) from one stroke through two or more groups: duplicates the
    /// merge could not resolve (a re-creation concurrent with a replacement,
    /// or snapshots without `replaces`). Keeps, at every such ancestor, the
    /// descendants through the greatest group and returns the others.
    /// Linear in the number of entries.
    func unresolved(visible: Set<UUID>) -> Set<UUID> {
        // Edges (child → parent) that lead to a visible stroke, each marked once.
        var maxAt: [UUID: ReplacementGroup] = [:]
        var marked = Set<UUID>()
        for v in visible {
            var c = v
            while let e = entries[c], marked.insert(c).inserted {
                if maxAt[e.parent].map({ $0 < e.group }) ?? true { maxAt[e.parent] = e.group }
                c = e.parent
            }
        }
        // losing(c): c's edge, or one above it, is not the greatest at its parent.
        var losing: [UUID: Bool] = [:]
        func isLosing(_ start: UUID) -> Bool {
            var path: [UUID] = []
            var c = start
            var result = false
            var seen = Set<UUID>()
            while true {
                if let known = losing[c] { result = known; break }
                guard let e = entries[c], seen.insert(c).inserted else { result = false; break }
                if let m = maxAt[e.parent], e.group < m { result = true; path.append(c); break }
                path.append(c)
                c = e.parent
            }
            for p in path { losing[p] = result }
            return result
        }
        return Set(visible.filter { entries[$0] != nil && isLosing($0) })
    }
}

/// A stroke on a page.
public struct StrokeRef: Hashable, Sendable, Comparable {
    public var page: UUID
    public var stroke: UUID

    public init(page: UUID, stroke: UUID) { self.page = page; self.stroke = stroke }

    public static func < (l: StrokeRef, r: StrokeRef) -> Bool {
        (l.page.uuidString, l.stroke.uuidString) < (r.page.uuidString, r.stroke.uuidString)
    }
}

/// Strokes of one note left over by concurrent edits of the same stroke
/// (format.md §5.6.1), and the removals that settle them.
public struct StrokeConflicts: Equatable, Sendable {
    /// Strokes that revisions still add but the merge hides, superseded by a
    /// concurrent replacement. Removing them changes nothing a reader shows.
    public var superseded: [StrokeRef]
    /// Live strokes that duplicate others descending from the same stroke
    /// through another revision, which the merge cannot resolve (a re-creation
    /// concurrent with a replacement). The descendants through the greatest
    /// revision are kept.
    public var duplicates: [StrokeRef]

    public init(superseded: [StrokeRef], duplicates: [StrokeRef]) {
        self.superseded = superseded; self.duplicates = duplicates
    }

    /// Nothing to settle.
    public var isEmpty: Bool { superseded.isEmpty && duplicates.isEmpty }

    /// One `removeStroke` per stroke, superseded ones first, each list sorted.
    public var ops: [Op] {
        (superseded + duplicates).map { .removeStroke(page: $0.page, strokeId: $0.stroke) }
    }
}

extension NoteReducer {
    /// The strokes of a note that concurrent edits of one stroke left over
    /// (format.md §5.6.1): superseded ones the merge already hides, and
    /// duplicates it cannot resolve. `ops` writes the removals; after them the
    /// note has neither.
    public static func strokeConflicts(_ revisions: [Revision]) throws -> StrokeConflicts {
        let r = resolve(try canonical(revisions))
        var pageOf: [UUID: UUID] = [:]
        for p in r.state.pages { for s in p.strokes { pageOf[s.id] = p.id } }
        let duplicates = r.lineage.unresolved(visible: Set(pageOf.keys)).compactMap { id in
            pageOf[id].map { StrokeRef(page: $0, stroke: id) }
        }
        return StrokeConflicts(superseded: r.superseded.sorted(), duplicates: duplicates.sorted())
    }
}

extension Vault {
    /// What concurrent edits of one stroke left over in a note (format.md
    /// §5.6.1; `NoteReducer.strokeConflicts`).
    ///
    /// - Throws: `VaultError.revision` when a revision is unreadable.
    public func strokeConflicts(of noteId: UUID) throws -> StrokeConflicts {
        return try NoteReducer.strokeConflicts(Self.strictRevisions(of: try loadNote(noteId)))
    }

    /// Writes one delta that removes every stroke `strokeConflicts(of:)`
    /// reports, computed from the note as it is on disk now, as this device
    /// (`apply`). Returns what was found and the delta, nil when there was
    /// nothing to remove.
    @discardableResult
    public func dedupeStrokes(of noteId: UUID, deviceState: URL, app: String,
                              wall: Date = Date()) throws -> (conflicts: StrokeConflicts, revision: Revision?) {
        guard canRead else { throw VaultError.locked }
        let loaded = try loadNote(noteId)
        let conflicts = try NoteReducer.strokeConflicts(Self.strictRevisions(of: loaded))
        guard !conflicts.isEmpty else { return (conflicts, nil) }
        let revision = try writeDelta(conflicts.ops, to: noteId, loaded: loaded, deviceState: deviceState, app: app,
                                      wall: wall)
        return (conflicts, revision)
    }
}
