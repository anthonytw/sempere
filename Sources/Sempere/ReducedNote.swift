import Foundation

// MARK: - Incremental reconstruction for an open note (docs/io.md "Changes from other devices while a note is open")
//
// `NoteReducer.reconstruct` is collect-then-resolve over the whole log, so a
// note open while another device writes to it would replay every revision
// again for each one that arrives. `ReducedNote` keeps the result of a read
// together with the few indexes needed to prove that a later delta can be
// applied to it directly. `applying` takes only deltas whose effect it can
// decide exactly (stroke adds and removes, registers it can compare by stamp)
// and refuses everything else, so callers fall back to the full read; the
// result is then identical to `reconstruct` of every revision (tombstones
// aside, see `state`). `ReducedNoteTests` compares both over random logs.

/// A note reduced from its revisions, kept so that revisions read later can
/// be applied without replaying the whole log (`updated(with:)`).
public struct ReducedNote: Sendable {
    /// `NoteReducer.reconstruct` of the revisions this was reduced from,
    /// without `tombstones` (nil): what the note shows, never what a
    /// snapshot may be written from.
    public private(set) var state: NoteState
    /// The file names of the revisions it was reduced from.
    public private(set) var names: Set<String>

    private var noteId: UUID
    /// The greatest revision name reduced; a delta applied incrementally must sort after it.
    private var last: RevisionName
    /// Every `seq` reduced, per device (a new one equal to one of them is a conflict or a duplicate).
    private var seqs: [DeviceID: Set<Int>]
    /// The `included` of every snapshot reduced: a delta one of them covers is not applied (§5.3).
    private var covered: [Included]
    /// Every stroke id any reduced revision names: added, removed, held, tombstoned, or as a
    /// parent. A delta that adds one of them again is left to the full read.
    private var knownStrokes: Set<UUID>
    /// Every stroke some stroke names as its `parent` (format.md §5.6.1), and every superseded one.
    private var lineageParents: Set<UUID>
    private var superseded: Set<UUID>
    /// The page of every live stroke.
    private var strokePage: [UUID: UUID]
    /// The index in `state.pages` of every live page.
    private var pageIndex: [UUID: Int]

    /// Reduces `revisions` in full (`NoteReducer.reconstruct`).
    public init(revisions: [Revision]) throws {
        let revs = try NoteReducer.canonical(revisions)
        let res = NoteReducer.resolve(revs)
        var state = res.state
        state.tombstones = nil
        self.state = state
        names = Set(revs.map(\.name.filename))
        noteId = revs[0].noteId
        last = revs.map(\.name).max() ?? revs[0].name
        var seqs: [DeviceID: Set<Int>] = [:]
        var covered: [Included] = []
        var known = Set<UUID>()
        for r in revs {
            seqs[r.device, default: []].insert(r.seq)
            switch r.body {
            case .snapshot(let included, let snap):
                covered.append(included)
                for p in snap.pages {
                    for s in p.strokes {
                        known.insert(s.id)
                        if let parent = s.parent { known.insert(parent) }
                    }
                }
                if let t = snap.tombstones {
                    known.formUnion(t.strokes)
                    known.formUnion(t.superseded)
                    for l in t.lineage { known.insert(l.stroke); known.insert(l.parent) }
                }
            case .delta(let ops):
                for op in ops {
                    switch op {
                    case .addStroke(_, let s):
                        known.insert(s.id)
                        if let parent = s.parent { known.insert(parent) }
                    case .removeStroke(_, let id): known.insert(id)
                    default: break
                    }
                }
            }
        }
        self.seqs = seqs
        self.covered = covered
        let superseded = res.lineage.superseded()
        self.superseded = superseded
        lineageParents = Set(res.lineage.entries.values.map(\.parent)).union(superseded)
        known.formUnion(superseded)
        knownStrokes = known
        var strokePage: [UUID: UUID] = [:]
        var pageIndex: [UUID: Int] = [:]
        for (i, p) in state.pages.enumerated() {
            pageIndex[p.id] = i
            for s in p.strokes { strokePage[s.id] = p.id }
        }
        self.strokePage = strokePage
        self.pageIndex = pageIndex
    }

    /// What `updated(with:)` did.
    public struct Update: Sendable {
        /// The note reduced from the revisions given.
        public var note: ReducedNote
        /// The pages whose strokes, recognition, paper or order may differ from
        /// the previous `state`'s, with the page list itself unchanged; nil
        /// when the note was reduced in full (anything may differ).
        public var changedPages: Set<UUID>?
        /// How many revisions were reduced: the new ones, or all of them.
        public var reduced: Int
    }

    /// `base.updated(with: revisions)`, or with no base all of them reduced.
    public static func update(_ base: ReducedNote?, with revisions: [Revision]) throws -> Update {
        if let base { return try base.updated(with: revisions) }
        return Update(note: try ReducedNote(revisions: revisions), changedPages: nil, reduced: revisions.count)
    }

    /// The note reduced from `revisions` (every readable revision of the note
    /// as now listed): only the revisions not in `names` are applied when
    /// that is exact (`applying`), else all of them are reduced again.
    public func updated(with revisions: [Revision]) throws -> Update {
        let listed = Set(revisions.map(\.name.filename))
        if names.isSubset(of: listed) {
            let new = revisions.filter { !names.contains($0.name.filename) }
            if let (note, changed) = applying(new) {
                return Update(note: note, changedPages: changed, reduced: new.count)
            }
        }
        return Update(note: try ReducedNote(revisions: revisions), changedPages: nil, reduced: revisions.count)
    }

    /// `self` with `deltas` applied, and the pages they changed; nil when that
    /// cannot be decided without the whole log: a snapshot, a revision that
    /// does not sort after every one reduced (or is covered by a snapshot, or
    /// repeats a `seq`), an op other than stroke adds and removes, page order,
    /// recognition and paper of a live page, meta and delete/restore, a stroke
    /// id seen before, a replacement of a stroke already replaced or
    /// superseded (§5.6.1), or a register whose current stamp is not older.
    public func applying(_ deltas: [Revision]) -> (ReducedNote, Set<UUID>)? {
        var next = self
        guard !deltas.isEmpty else { return (next, []) }
        let revs = deltas.sorted { $0.name < $1.name }
        var newSeqs: [DeviceID: Set<Int>] = [:]
        for r in revs {
            guard r.kind == .delta, r.noteId == noteId, last < r.name,
                  !(seqs[r.device]?.contains(r.seq) ?? false),
                  newSeqs[r.device, default: []].insert(r.seq).inserted,
                  !covered.contains(where: { $0.covers(device: r.device, seq: r.seq) }) else { return nil }
        }

        // Collect, as `NoteReducer.resolve` does, then decide.
        var adds: [(page: UUID, stroke: Stroke)] = []
        var added = Set<UUID>()
        var removed = Set<UUID>()
        var newParents: [UUID: RevisionName] = [:]
        var registers: [NoteState.ClockKey: (RegisterValue, OpKey)] = [:]
        var order: [UUID: (String, OpKey)] = [:]
        var recognition: [UUID: (Recognition?, OpKey)] = [:]
        var paper: [UUID: (Paper?, OpKey)] = [:]
        func offer<V>(_ map: inout [UUID: (V, OpKey)], _ id: UUID, _ v: V, _ k: OpKey) {
            if let cur = map[id], cur.1 > k { return }
            map[id] = (v, k)
        }
        for d in revs {
            var removedHere = Set<UUID>()
            for case .removeStroke(_, let id) in d.ops { removedHere.insert(id) }
            for (i, op) in d.ops.enumerated() {
                let k = OpKey(stamp: d.stamp, seq: d.seq, index: i, src: d.name)
                switch op {
                case .addStroke(let page, var s):
                    guard pageIndex[page] != nil, !knownStrokes.contains(s.id), added.insert(s.id).inserted else { return nil }
                    if let parent = s.parent {
                        // A second replacement of one stroke, or one under a superseded stroke, can hide others.
                        guard !lineageParents.contains(parent) else { return nil }
                        if let other = newParents[parent], other != d.name { return nil }
                        newParents[parent] = d.name
                    }
                    s.origin = Origin(d.name, op: i).description
                    s.replaces = s.parent.map { removedHere.contains($0) } ?? false
                    adds.append((page, s))
                case .removeStroke(_, let id):
                    removed.insert(id)
                case .setPageOrder(let page, let value):
                    guard pageIndex[page] != nil else { return nil }
                    offer(&order, page, value, k)
                case .setPageRecognition(let page, let value):
                    guard pageIndex[page] != nil else { return nil }
                    offer(&recognition, page, value, k)
                case .setPagePaper(let page, let value):
                    guard pageIndex[page] != nil else { return nil }
                    offer(&paper, page, value, k)
                case .setMeta(let change):
                    let v = RegisterValue.meta(change)
                    if let cur = registers[v.clockKey], cur.1 > k { break }
                    registers[v.clockKey] = (v, k)
                case .deleteNote, .restoreNote:
                    var deleted = false
                    if case .deleteNote = op { deleted = true }
                    if let cur = registers[.deleted], cur.1 > k { break }
                    registers[.deleted] = (RegisterValue.deleted(deleted), k)
                default:
                    return nil
                }
            }
        }
        func newer(_ clock: String?, than k: OpKey) -> Bool? {
            guard let clock else { return nil }
            guard let stamp = Stamp(clock) else { return false }
            return stamp < k.stamp
        }
        var changed = Set<UUID>()
        var reorder = false
        var clocks = next.state.clocks ?? [:]
        for (key, (value, k)) in registers {
            guard newer(clocks[key.rawValue] ?? Stamp.zero.description, than: k) == true else { return nil }
            value.apply(to: &next.state)
            clocks[key.rawValue] = k.stamp.description
        }
        next.state.clocks = clocks
        for (id, (value, k)) in order {
            guard let i = pageIndex[id], newer(next.state.pages[i].orderClock, than: k) == true else { return nil }
            next.state.pages[i].order = value
            next.state.pages[i].orderClock = k.stamp.description
            changed.insert(id)
            reorder = true
        }
        for (id, (value, k)) in recognition {
            guard let i = pageIndex[id] else { return nil }
            let p = next.state.pages[i]
            if p.recognition != nil || p.recognitionClock != nil {
                guard newer(p.recognitionClock, than: k) == true else { return nil }
            }
            next.state.pages[i].recognition = value
            next.state.pages[i].recognitionClock = k.stamp.description
            changed.insert(id)
        }
        for (id, (value, k)) in paper {
            guard let i = pageIndex[id] else { return nil }
            let p = next.state.pages[i]
            if p.paper != nil || p.paperClock != nil {
                guard newer(p.paperClock, than: k) == true else { return nil }
            }
            next.state.pages[i].paper = value
            next.state.pages[i].paperClock = k.stamp.description
            changed.insert(id)
        }

        // Strokes: removal is by id on any page; a new stroke removed by a new delta never shows.
        var strokesChanged = Set<UUID>()
        var removedLive: [UUID: Set<UUID>] = [:]
        for id in removed {
            if let page = strokePage[id] { removedLive[page, default: []].insert(id) }
        }
        for (page, ids) in removedLive {
            guard let i = pageIndex[page] else { return nil }
            next.state.pages[i].strokes.removeAll { ids.contains($0.id) }
            for id in ids { next.strokePage[id] = nil }
            strokesChanged.insert(page)
        }
        for (page, s) in adds where !removed.contains(s.id) {
            guard let i = pageIndex[page] else { return nil }
            next.state.pages[i].strokes.append(s)
            next.strokePage[s.id] = page
            strokesChanged.insert(page)
        }
        for page in strokesChanged {
            guard let i = pageIndex[page], let sorted = Self.sortedByOrigin(next.state.pages[i].strokes) else { return nil }
            next.state.pages[i].strokes = sorted
        }
        changed.formUnion(strokesChanged)
        if reorder {
            next.state.pages.sort { l, r in
                if l.order != r.order { return l.order.utf8.lexicographicallyPrecedes(r.order.utf8) }
                return l.id.uuidString.lowercased() < r.id.uuidString.lowercased()
            }
            next.pageIndex = Dictionary(uniqueKeysWithValues: next.state.pages.enumerated().map { ($1.id, $0) })
        }

        for r in revs {
            next.names.insert(r.name.filename)
            next.seqs[r.device, default: []].insert(r.seq)
        }
        next.last = max(last, revs[revs.count - 1].name)
        next.knownStrokes.formUnion(added)
        next.knownStrokes.formUnion(removed)
        next.knownStrokes.formUnion(newParents.keys)
        next.lineageParents.formUnion(newParents.keys)
        return (next, changed)
    }

    /// `strokes` in render order, `(origin, id string)` as `NoteReducer`
    /// sorts them; nil if one has no readable origin. Already sorted (the
    /// usual case: new strokes come last) costs one pass.
    private static func sortedByOrigin(_ strokes: [Stroke]) -> [Stroke]? {
        var keyed: [(Origin, Stroke)] = []
        keyed.reserveCapacity(strokes.count)
        for s in strokes {
            guard let o = s.origin.flatMap(Origin.init) else { return nil }
            keyed.append((o, s))
        }
        func before(_ a: (Origin, Stroke), _ b: (Origin, Stroke)) -> Bool {
            a.0 != b.0 ? a.0 < b.0 : a.1.id.uuidString < b.1.id.uuidString
        }
        if zip(keyed, keyed.dropFirst()).allSatisfy({ before($0, $1) }) { return strokes }
        return keyed.sorted(by: before).map(\.1)
    }
}
