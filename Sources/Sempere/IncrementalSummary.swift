import Foundation

// MARK: - Summaries from a note's new revisions only (docs/io.md "Summaries of a changed note")
//
// Revision files are write-once, so when a note only gained files since its
// summary was made, the reduction of the old files is still right; what the
// summary needs is that reduction merged with the new files. A
// `SummaryCheckpoint` keeps it: the merged state of the old files, which
// stands for all of them as a snapshot that includes them all would
// (format.md §5.3: a snapshot merges with later revisions as the revisions it
// includes do; compaction relies on the same). `NoteReducer.advance` merges
// new deltas into it, but only when the result is provably the one a full
// reduction of every file gives, and returns nil otherwise; the caller then
// reads the note in full.

/// The reduction of a set of revisions, for merging later revisions into
/// without reading those again (`NoteReducer.advance`). Never written to
/// disk: `SummaryCache` keeps a few in memory.
struct SummaryCheckpoint: Sendable {
    /// Sorted file names of the revisions reduced.
    var names: [String]
    /// Their merged state (without stroke points when read for a listing).
    var state: NoteState
    /// What the state reflects in full: every revision reduced (there were no orphans).
    var included: Included
    /// `wall` of the first revision by name (what `meta.created` starts from).
    var earliestWall: Date?
    /// The newest `wall`.
    var modified: Date?
    /// The greatest revision name.
    var maxName: RevisionName
    /// The greatest HLC of any name, stamp or origin in the reduction: a new
    /// delta must sort strictly after it, so it ties with nothing reduced.
    var horizon: HLC
    /// Ids of strokes, pages, items and recordings the reduced revisions
    /// added, held or removed that are not live in `state`. A new revision
    /// that adds one of them again needs the full read: the reduction may
    /// have dropped what removed it (a covered stroke tombstone, §5.4).
    var dead: Set<UUID>

    /// Roughly how much memory the checkpoint holds, in elements.
    var cost: Int {
        state.pages.reduce(state.pages.count + state.recordings.count) { $0 + $1.strokes.count + $1.items.count }
            + dead.count + (state.tombstones.map { $0.strokes.count + $0.lineage.count + $0.superseded.count } ?? 0) + 1
    }

    /// True when `name` may be merged into this checkpoint: a delta ordered
    /// after every reduced revision and every stamp, and not already covered.
    func admits(_ name: RevisionName) -> Bool {
        name.kind == .delta && name > maxName && name.hlc > horizon && !included.covers(device: name.device, seq: name.seq)
    }
}

extension NoteReducer {
    /// `reconstruct(revisions)` and, when it can stand for them, the
    /// checkpoint of that reduction: nil when a delta is an orphan (it
    /// would have to be applied again once its page or item arrives).
    static func reconstructWithCheckpoint(_ revisions: [Revision]) throws -> (state: NoteState, checkpoint: SummaryCheckpoint?) {
        let revs = try canonical(revisions)
        let res = resolve(revs)
        guard revs.allSatisfy({ res.included.covers(device: $0.device, seq: $0.seq) }),
              let first = revs.min(by: { $0.name < $1.name }), let maxName = revs.map(\.name).max() else {
            return (res.state, nil)
        }
        var seen = Set<UUID>()
        for r in revs {
            switch r.body {
            case .delta(let ops): for op in ops { seen.formUnion(op.elementIds) }
            case .snapshot(_, let state): seen.formUnion(state.elementIds(withTombstones: true))
            }
        }
        let cp = SummaryCheckpoint(names: revs.map(\.name.filename).sorted(), state: res.state, included: res.included,
                                   earliestWall: first.wall, modified: revs.map(\.wall).max(), maxName: maxName,
                                   horizon: max(maxName.hlc, res.state.maxHLC),
                                   dead: seen.subtracting(res.state.elementIds(withTombstones: false)))
        return (res.state, cp)
    }

    /// Merges `added` into `checkpoint`: the state `reconstruct` gives for
    /// the checkpoint's revisions plus `added`, and the checkpoint of that.
    /// Nil whenever that equality is not certain, and the caller reduces
    /// every revision instead: `added` holds a snapshot, a revision ordered
    /// at or before a reduced one or a reduced stamp, one already covered,
    /// an add of an id the reduction saw go, a replacement of a stroke that
    /// is not live (it may compete with an earlier replacement, §5.6.1), or
    /// an orphan; or the revisions do not merge at all.
    static func advance(_ checkpoint: SummaryCheckpoint, with added: [Revision])
        -> (state: NoteState, checkpoint: SummaryCheckpoint)? {
        guard !added.isEmpty, added.allSatisfy({ $0.kind == .delta && checkpoint.admits($0.name) }),
              let revs = try? canonical(added), revs.count == added.count else { return nil }
        let live = checkpoint.state.elementIds(withTombstones: false)
        var liveStrokes = Set<UUID>()
        for p in checkpoint.state.pages { for s in p.strokes { liveStrokes.insert(s.id) } }
        var addedIds = Set<UUID>()
        for d in revs {
            var removed = Set<UUID>()
            for case .removeStroke(_, let id) in d.ops { removed.insert(id) }
            for op in d.ops {
                let ids = op.elementIds
                addedIds.formUnion(ids)
                switch op {
                case .addStroke(_, let st):
                    if checkpoint.dead.contains(st.id) { return nil }
                    if let p = st.parent, removed.contains(p), !liveStrokes.contains(p) { return nil }
                case .addPage(let p): if checkpoint.dead.contains(p.id) { return nil }
                case .addItem(_, let it): if checkpoint.dead.contains(it.id) { return nil }
                case .addRecording(let r): if checkpoint.dead.contains(r.id) { return nil }
                default: break
                }
            }
        }
        // The old state as a snapshot that includes everything it reduced. Its name has
        // `seq` 0, so it adds nothing to `included` and stamps nothing new: every register
        // and origin in a reduced state carries its own.
        let base = Snap(name: RevisionName(hlc: checkpoint.horizon, device: .zero, seq: 0, kind: .snapshot),
                        included: checkpoint.included, state: checkpoint.state)
        let res = resolve(snapshots: [base], deltas: revs, earliestWall: checkpoint.earliestWall)
        guard revs.allSatisfy({ res.included.covers(device: $0.device, seq: $0.seq) }) else { return nil }
        var next = checkpoint
        next.names = (checkpoint.names + revs.map(\.name.filename)).sorted()
        next.state = res.state
        next.included = res.included
        next.modified = ([checkpoint.modified].compactMap { $0 } + revs.map(\.wall)).max()
        next.maxName = max(checkpoint.maxName, revs.map(\.name).max() ?? checkpoint.maxName)
        next.horizon = max(checkpoint.horizon, next.maxName.hlc, res.state.maxHLC)
        next.dead = checkpoint.dead.union(live).union(addedIds).subtracting(res.state.elementIds(withTombstones: false))
        return (res.state, next)
    }
}

extension Op {
    /// The stroke, page, item and recording ids this op adds or removes.
    var elementIds: [UUID] {
        switch self {
        case .addStroke(_, let s): return [s.id]
        case .removeStroke(_, let id): return [id]
        case .addPage(let p): return [p.id]
        case .removePage(let id): return [id]
        case .addItem(_, let it): return [it.id]
        case .removeItem(_, let id): return [id]
        case .addRecording(let r): return [r.id]
        case .removeRecording(let id): return [id]
        default: return []
        }
    }
}

extension NoteState {
    /// Ids of the strokes, pages, items and recordings held, and with
    /// `withTombstones` every id the tombstones name.
    func elementIds(withTombstones: Bool) -> Set<UUID> {
        var out = Set<UUID>()
        for p in pages {
            out.insert(p.id)
            for s in p.strokes { out.insert(s.id) }
            for i in p.items { out.insert(i.id) }
        }
        for r in recordings { out.insert(r.id) }
        if withTombstones, let t = tombstones {
            out.formUnion(t.strokes); out.formUnion(t.pages); out.formUnion(t.items); out.formUnion(t.recordings)
            out.formUnion(t.superseded); out.formUnion(t.lineage.map(\.stroke))
        }
        return out
    }

    /// The greatest HLC of any stamp or origin the state records (unparsable
    /// ones are skipped: a reduced state writes none).
    var maxHLC: HLC {
        var m = HLC.zero
        func stamp(_ s: String?) { if let s, let v = Stamp(s), v.hlc > m { m = v.hlc } }
        func origin(_ s: String?) { if let s, let v = Origin(s), v.hlc > m { m = v.hlc } }
        for c in (clocks ?? [:]).values { stamp(c) }
        for p in pages {
            origin(p.origin); stamp(p.orderClock); stamp(p.recognitionClock); stamp(p.paperClock)
            for s in p.strokes { origin(s.origin) }
            for i in p.items { origin(i.origin); for c in (i.clocks ?? [:]).values { stamp(c) } }
        }
        for r in recordings { origin(r.origin); for c in (r.clocks ?? [:]).values { stamp(c) } }
        for i in tagSet.instances where i.origin.hlc > m { m = i.origin.hlc }
        for r in tagSet.removed where r.origin.hlc > m { m = r.origin.hlc }
        for l in tombstones?.lineage ?? [] { if let g = ReplacementGroup(l.by), g.hlc > m { m = g.hlc } }
        return m
    }
}
