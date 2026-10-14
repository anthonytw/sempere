import Foundation

// MARK: - Merge (docs/format.md §5.2–§5.6)
//
// Reconstruction is collect-then-resolve. Every snapshot and every delta not
// covered by any snapshot is folded into commutative structures (removal
// sets, min-origin evidence per page and stroke, max-key LWW registers); the
// state is then built from those. Nothing depends on visiting order, and no
// single snapshot is privileged.

/// Full deterministic LWW key: the stamp, then `seq` and op index inside the
/// revision, then the source revision (which only separates snapshot values
/// that carry the same recorded clock).
struct OpKey: Comparable {
    var stamp: Stamp
    var seq: Int
    var index: Int
    var src: RevisionName

    /// A value held by snapshot `src`, last set at `stamp`: beats any op with the same stamp.
    static func base(_ stamp: Stamp, _ src: RevisionName) -> OpKey {
        OpKey(stamp: stamp, seq: .max, index: .max, src: src)
    }

    /// A register nobody set: loses to everything.
    static let unset = OpKey(stamp: .zero, seq: .min, index: .min,
                             src: RevisionName(hlc: .zero, device: .zero, seq: 0, kind: .delta))

    static func < (l: OpKey, r: OpKey) -> Bool {
        (l.stamp, l.seq, l.index, l.src) < (r.stamp, r.seq, r.index, r.src)
    }
}

/// Last-writer-wins register; commutative, associative, idempotent.
struct Register<Value> {
    var value: Value
    var key: OpKey

    mutating func offer(_ v: Value, _ k: OpKey) {
        if k > key { value = v; key = k }
    }
}

/// Rebuilds note state from revisions.
public enum NoteReducer {
    /// Reconstructs a note (format.md §5.3): the merge of every snapshot plus
    /// every delta no snapshot's `included` covers.
    ///
    /// The result is identical for any permutation of `revisions`. It carries
    /// what a snapshot needs: all `clocks`, `orderClock` and `origin` on every
    /// page, `origin` on every stroke, `origin` and `clocks` on every item and
    /// recording, and `tombstones` (nil when empty).
    public static func reconstruct(_ revisions: [Revision]) throws -> NoteState {
        try resolve(canonical(revisions)).state
    }

    /// Applies deltas to an existing state, e.g. for live editing. `state`
    /// acts as a snapshot that covers nothing; registers without a recorded
    /// clock are treated as stamped `stamp`.
    public static func apply(_ deltas: [Revision], to state: NoteState, stamp: Stamp) throws -> NoteState {
        for d in deltas where d.kind != .delta { throw NoteLogError.notADelta(d.name) }
        let revs = try canonical(deltas)
        let base = Snap(name: RevisionName(hlc: stamp.hlc, device: stamp.device, seq: 0, kind: .snapshot),
                        included: Included(), state: state)
        let earliest = revs.min { $0.name < $1.name }?.wall
        return resolve(snapshots: [base], deltas: revs, earliestWall: earliest).state
    }

    /// Checks one note id, drops exact duplicates, rejects two different
    /// revisions with the same `(device, seq)`.
    static func canonical(_ revisions: [Revision]) throws -> [Revision] {
        guard let first = revisions.first else { throw NoteLogError.noRevisions }
        var byKey: [DeviceID: [Int: Revision]] = [:]
        for r in revisions {
            guard r.noteId == first.noteId else { throw NoteLogError.mixedNotes(first.noteId, r.noteId) }
            if let existing = byKey[r.device]?[r.seq] {
                guard existing == r else { throw NoteLogError.conflictingRevisions(device: r.device, seq: r.seq) }
            } else {
                byKey[r.device, default: [:]][r.seq] = r
            }
        }
        return byKey.values.flatMap(\.values)
    }

    struct Snap {
        var name: RevisionName
        var included: Included
        var state: NoteState
    }

    struct Resolution {
        var state: NoteState
        /// Everything the state reflects in full: every snapshot's `included`,
        /// the snapshots themselves, and every applied delta that is not an orphan.
        var included: Included
        /// Strokes otherwise live that a concurrent replacement superseded (§5.6.1).
        var superseded: [StrokeRef] = []
        /// The stroke forest the merge used.
        var lineage = StrokeLineage(snapshots: [], deltas: [])
    }

    static func resolve(_ revs: [Revision]) -> Resolution {
        var snaps: [Snap] = []
        var deltas: [Revision] = []
        for r in revs {
            switch r.body {
            case .delta: deltas.append(r)
            case .snapshot(let included, let state): snaps.append(Snap(name: r.name, included: included, state: state))
            }
        }
        let earliest = revs.min { $0.name < $1.name }?.wall
        return resolve(snapshots: snaps, deltas: deltas, earliestWall: earliest)
    }

    /// Item evidence: where a page or stroke was seen and which op added it.
    struct Evidence<Item> {
        var origin: Origin
        var src: RevisionName
        var item: Item
        var page: UUID?

        func beats(_ other: Evidence) -> Bool { (origin, src) < (other.origin, other.src) }
    }

    static func resolve(snapshots: [Snap], deltas: [Revision], earliestWall: Date?) -> Resolution {
        let uncovered = deltas.filter { d in !snapshots.contains { $0.included.covers(device: d.device, seq: d.seq) } }

        // Removals: every snapshot's tombstones plus removes in uncovered deltas.
        var removedPages = Set<UUID>()
        var removedStrokes = Set<UUID>()
        var removedItems = Set<UUID>()
        var removedRecordings = Set<UUID>()
        for s in snapshots {
            removedPages.formUnion(s.state.tombstones?.pages ?? [])
            removedStrokes.formUnion(s.state.tombstones?.strokes ?? [])
            removedItems.formUnion(s.state.tombstones?.items ?? [])
            removedRecordings.formUnion(s.state.tombstones?.recordings ?? [])
        }
        for d in uncovered {
            for case .removeStroke(_, let id) in d.ops { removedStrokes.insert(id) }
        }
        // Page, item and recording tombstones are permanent (§5.4), so every
        // remove of one counts. So are removed tag instances (§5.4.1).
        var tagRemovals = Set<TagSet.Removal>()
        for d in deltas {
            for op in d.ops {
                switch op {
                case .removePage(let id): removedPages.insert(id)
                case .removeItem(_, let id): removedItems.insert(id)
                case .removeRecording(let id): removedRecordings.insert(id)
                case .removeTag(let tag, let observed):
                    let key = NoteOps.tagKey(tag)
                    for o in observed { tagRemovals.insert(TagSet.Removal(key: key, origin: o)) }
                default: break
                }
            }
        }

        // Orphans (§5.3): a delta whose page-targeting op names a page nobody
        // has seen, or whose `setItem` / `setRecording` names an item or
        // recording nobody has seen, is applied but not listed in `included`,
        // so it is applied again once the page, item or recording arrives. A
        // removed one is known (its tombstone is permanent), so ops on it are
        // covered no-ops, never orphans.
        var knownPages = removedPages
        var knownItems = removedItems
        var knownRecordings = removedRecordings
        for s in snapshots {
            knownPages.formUnion(s.state.pages.map(\.id))
            for p in s.state.pages { knownItems.formUnion(p.items.map(\.id)) }
            knownRecordings.formUnion(s.state.recordings.map(\.id))
        }
        for d in deltas {
            for op in d.ops {
                switch op {
                case .addPage(let p): knownPages.insert(p.id)
                case .addItem(_, let item): knownItems.insert(item.id)
                case .addRecording(let r): knownRecordings.insert(r.id)
                default: break
                }
            }
        }
        func isOrphan(_ d: Revision) -> Bool {
            d.ops.contains { op in
                switch op {
                case .addStroke(let page, _): return !knownPages.contains(page)
                case .setPageOrder(let page, _): return !knownPages.contains(page)
                case .setPageRecognition(let page, _): return !knownPages.contains(page)
                case .setPagePaper(let page, _): return !knownPages.contains(page)
                case .addItem(let page, _): return !knownPages.contains(page)
                // On a removed page, a no-op whatever the item: removing a page
                // tombstones the page, not its items, so after compaction the
                // item's id may be known nowhere.
                case .setItem(let page, let id, _):
                    return !knownPages.contains(page) || (!removedPages.contains(page) && !knownItems.contains(id))
                case .setRecording(let id, _): return !knownRecordings.contains(id)
                default: return false
                }
            }
        }
        let orphans = Set(uncovered.filter(isOrphan).map(\.name))

        // LWW registers, one per `NoteState.ClockKey`.
        let defaults = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)))
        var registers: [NoteState.ClockKey: Register<RegisterValue>] = [:]
        for k in NoteState.ClockKey.allCases {
            registers[k] = Register(value: RegisterValue(k, in: defaults), key: .unset)
        }
        func offer(_ value: RegisterValue, _ k: OpKey) { registers[value.clockKey]?.offer(value, k) }
        var created = earliestWall
        var order: [UUID: Register<String>] = [:]
        var recognition: [UUID: Register<Recognition?>] = [:]
        var pagePaper: [UUID: Register<Paper?>] = [:]
        var pages: [UUID: Evidence<Page>] = [:]
        var strokes: [UUID: Evidence<Stroke>] = [:]
        var snapPageIds: [RevisionName: Set<UUID>] = [:]
        var snapStrokeIds: [RevisionName: Set<UUID>] = [:]
        // Items and recordings: set evidence like strokes, plus one LWW
        // register per (id, field) (§8.2.2, §8.3.1).
        var items: [UUID: Evidence<Item>] = [:]
        var recordings: [UUID: Evidence<Recording>] = [:]
        var itemRegisters: [UUID: [String: Register<ItemChange>]] = [:]
        var recordingRegisters: [UUID: [String: Register<RecordingChange>]] = [:]
        var snapItemIds: [RevisionName: Set<UUID>] = [:]
        var snapRecordingIds: [RevisionName: Set<UUID>] = [:]

        func offerOrder(_ id: UUID, _ value: String, _ k: OpKey) {
            order[id, default: Register(value: value, key: k)].offer(value, k)
        }
        func offerRecognition(_ id: UUID, _ value: Recognition?, _ k: OpKey) {
            recognition[id, default: Register(value: nil, key: .unset)].offer(value, k)
        }
        func offerPaper(_ id: UUID, _ value: Paper?, _ k: OpKey) {
            pagePaper[id, default: Register(value: nil, key: .unset)].offer(value, k)
        }
        func offerPage(_ e: Evidence<Page>) {
            if let cur = pages[e.item.id], !e.beats(cur) { return }
            pages[e.item.id] = e
        }
        func offerStroke(_ e: Evidence<Stroke>) {
            if let cur = strokes[e.item.id], !e.beats(cur) { return }
            strokes[e.item.id] = e
        }
        func offerItemRegister(_ id: UUID, _ change: ItemChange, _ k: OpKey) {
            itemRegisters[id, default: [:]][change.field, default: Register(value: change, key: .unset)].offer(change, k)
        }
        func offerRecordingRegister(_ id: UUID, _ change: RecordingChange, _ k: OpKey) {
            recordingRegisters[id, default: [:]][change.field, default: Register(value: change, key: .unset)]
                .offer(change, k)
        }
        /// `stamp` is the source's for every register without a recorded clock.
        func offerItem(_ e: Evidence<Item>, registers k: (String) -> OpKey) {
            if items[e.item.id].map({ e.beats($0) }) ?? true { items[e.item.id] = e }
            for (field, change) in e.item.registers { offerItemRegister(e.item.id, change, k(field)) }
        }
        func offerRecording(_ e: Evidence<Recording>, registers k: (String) -> OpKey) {
            if recordings[e.item.id].map({ e.beats($0) }) ?? true { recordings[e.item.id] = e }
            for (field, change) in e.item.registers { offerRecordingRegister(e.item.id, change, k(field)) }
        }

        var tags = TagMerge()
        for s in snapshots {
            let stamp = s.name.stamp
            for k in NoteState.ClockKey.allCases {
                let clock = s.state.clocks?[k.rawValue].flatMap(Stamp.init)
                offer(RegisterValue(k, in: s.state), .base(clock ?? stamp, s.name))
            }
            tags.add(s.state.tagSet)
            let m = s.state.meta
            created = min(created ?? m.created, m.created)

            var pageIds = Set<UUID>(), strokeIds = Set<UUID>(), itemIds = Set<UUID>()
            for (pos, p) in s.state.pages.enumerated() {
                pageIds.insert(p.id)
                // Without a recorded origin, the holding snapshot is the origin (§5.5).
                let origin = p.origin.flatMap(Origin.init) ?? Origin(s.name, op: pos)
                offerPage(Evidence(origin: origin, src: s.name, item: p, page: nil))
                offerOrder(p.id, p.order, .base(p.orderClock.flatMap(Stamp.init) ?? stamp, s.name))
                // A page with neither recognition nor its clock never had one set (§5.5).
                if p.recognition != nil || p.recognitionClock != nil {
                    offerRecognition(p.id, p.recognition,
                                     .base(p.recognitionClock.flatMap(Stamp.init) ?? stamp, s.name))
                }
                // Likewise a page with neither paper nor its clock follows the note (§5.4.2).
                if p.paper != nil || p.paperClock != nil {
                    offerPaper(p.id, p.paper, .base(p.paperClock.flatMap(Stamp.init) ?? stamp, s.name))
                }
                for (j, st) in p.strokes.enumerated() {
                    strokeIds.insert(st.id)
                    let so = st.origin.flatMap(Origin.init) ?? Origin(s.name, op: j)
                    offerStroke(Evidence(origin: so, src: s.name, item: st, page: p.id))
                }
                for (j, it) in p.items.enumerated() {
                    itemIds.insert(it.id)
                    let io = it.origin.flatMap(Origin.init) ?? Origin(s.name, op: j)
                    // A register without a clock is stamped by the snapshot (§8.2.1).
                    offerItem(Evidence(origin: io, src: s.name, item: it, page: p.id)) { field in
                        .base(it.clocks?[field].flatMap(Stamp.init) ?? stamp, s.name)
                    }
                }
            }
            var recordingIds = Set<UUID>()
            for (j, r) in s.state.recordings.enumerated() {
                recordingIds.insert(r.id)
                let ro = r.origin.flatMap(Origin.init) ?? Origin(s.name, op: j)
                offerRecording(Evidence(origin: ro, src: s.name, item: r, page: nil)) { field in
                    .base(r.clocks?[field].flatMap(Stamp.init) ?? stamp, s.name)
                }
            }
            snapPageIds[s.name] = pageIds
            snapStrokeIds[s.name] = strokeIds
            snapItemIds[s.name] = itemIds
            snapRecordingIds[s.name] = recordingIds
        }

        for d in uncovered {
            for (i, op) in d.ops.enumerated() {
                let k = OpKey(stamp: d.stamp, seq: d.seq, index: i, src: d.name)
                switch op {
                case .addStroke(let page, let stroke):
                    offerStroke(Evidence(origin: Origin(d.name, op: i), src: d.name, item: stroke, page: page))
                case .addPage(let page):
                    // §5.2: the page is added empty.
                    offerPage(Evidence(origin: Origin(d.name, op: i), src: d.name, item: page, page: nil))
                    offerOrder(page.id, page.order, k)
                case .setPageOrder(let id, let value):
                    offerOrder(id, value, k)
                case .setPageRecognition(let id, let value):
                    offerRecognition(id, value, k)
                case .setPagePaper(let id, let value):
                    offerPaper(id, value, k)
                case .setMeta(let change): offer(.meta(change), k)
                case .addTag(let tag): tags.add(tag, Origin(d.name, op: i))
                case .deleteNote: offer(.deleted(true), k)
                case .restoreNote: offer(.deleted(false), k)
                case .addItem(let page, let item):
                    // §8.2.2: the add sets every register at its own stamp.
                    offerItem(Evidence(origin: Origin(d.name, op: i), src: d.name, item: item, page: page)) { _ in k }
                case .setItem(_, let id, let change):
                    offerItemRegister(id, change, k)
                case .addRecording(let recording):
                    offerRecording(Evidence(origin: Origin(d.name, op: i), src: d.name, item: recording, page: nil)) { _ in k }
                case .setRecording(let id, let change):
                    offerRecordingRegister(id, change, k)
                case .removeStroke, .removePage, .removeTag, .removeItem, .removeRecording: break
                }
            }
        }

        // An item is gone if a snapshot covers the revision that added it but
        // does not contain it: that snapshot saw the add and later the removal.
        func removedByCoverage(_ origin: Origin, _ id: UUID, _ held: [RevisionName: Set<UUID>]) -> Bool {
            snapshots.contains { s in
                s.included.covers(device: origin.device, seq: origin.seq) && !(held[s.name]?.contains(id) ?? false)
            }
        }

        let livePages = Set(pages.values.filter { e in
            !removedPages.contains(e.item.id) && !removedByCoverage(e.origin, e.item.id, snapPageIds)
        }.map(\.item.id))

        // Concurrent replacements of one stroke (§5.6.1): the losers count as removed.
        let lineage = StrokeLineage(snapshots: snapshots, deltas: deltas)
        let superseded = lineage.superseded()
        var supersededLive: [StrokeRef] = []
        var byPage: [UUID: [Evidence<Stroke>]] = [:]
        for e in strokes.values {
            guard let page = e.page, livePages.contains(page), !removedStrokes.contains(e.item.id),
                  !removedByCoverage(e.origin, e.item.id, snapStrokeIds) else { continue }
            if superseded.contains(e.item.id) {
                supersededLive.append(StrokeRef(page: page, stroke: e.item.id))
                continue
            }
            byPage[page, default: []].append(e)
        }

        var itemsByPage: [UUID: [Item]] = [:]
        for e in items.values {
            guard let page = e.page, livePages.contains(page), !removedItems.contains(e.item.id),
                  !removedByCoverage(e.origin, e.item.id, snapItemIds) else { continue }
            var item = e.item
            item.origin = emitted(e.origin)
            var clocks: [String: String] = [:]
            for (field, reg) in itemRegisters[item.id] ?? [:] {
                item.apply(reg.value)
                clocks[field] = reg.key.stamp.description
            }
            item.clocks = clocks
            itemsByPage[page, default: []].append(item)
        }

        var outRecordings: [Recording] = []
        for e in recordings.values {
            guard !removedRecordings.contains(e.item.id),
                  !removedByCoverage(e.origin, e.item.id, snapRecordingIds) else { continue }
            var recording = e.item
            recording.origin = emitted(e.origin)
            var clocks: [String: String] = [:]
            for (field, reg) in recordingRegisters[recording.id] ?? [:] {
                recording.apply(reg.value)
                clocks[field] = reg.key.stamp.description
            }
            recording.clocks = clocks
            outRecordings.append(recording)
        }
        outRecordings.sort(by: Recording.sortsBefore)

        var outPages: [Page] = []
        for id in livePages {
            guard let e = pages[id], let reg = order[id] else { continue }
            // `(origin, id string)` order; the string is only built on an origin tie.
            let list = (byPage[id] ?? []).sorted {
                $0.origin != $1.origin ? $0.origin < $1.origin : $0.item.id.uuidString < $1.item.id.uuidString
            }
            let rec = recognition[id]
            let pp = pagePaper[id]
            outPages.append(Page(id: id, order: reg.value,
                                 strokes: list.map { e in
                                     var s = e.item
                                     s.origin = emitted(e.origin)
                                     s.replaces = s.parent != nil && lineage.replaces(s.id)
                                     return s
                                 },
                                 orderClock: reg.key.stamp.description, origin: emitted(e.origin),
                                 recognition: rec?.value, recognitionClock: rec?.key.stamp.description,
                                 parent: e.item.parent,
                                 paper: pp?.value, paperClock: pp?.key.stamp.description,
                                 items: (itemsByPage[id] ?? []).sorted(by: Item.drawsBefore)))
        }
        // Byte-wise (code point) order, not Swift's normalising String `<`.
        outPages.sort { l, r in
            if l.order != r.order { return l.order.utf8.lexicographicallyPrecedes(r.order.utf8) }
            return l.id.uuidString.lowercased() < r.id.uuidString.lowercased()
        }

        // What the new `included` will reflect.
        var included = Included()
        for s in snapshots {
            included = included.union(s.included)
            if s.name.seq >= 1 { included.insert(device: s.name.device, seq: s.name.seq) }
        }
        for d in uncovered where !orphans.contains(d.name) {
            included.insert(device: d.device, seq: d.seq)
        }

        // A stroke tombstone may be dropped only once the revision that added
        // the stroke is covered by that `included` (§5.4). What an input
        // snapshot merely held proves nothing: it may hold an orphan's stroke.
        var addOrigins: [UUID: [Origin]] = [:]
        for e in strokes.values { addOrigins[e.item.id, default: []].append(e.origin) }
        for d in deltas {
            for case (let i, .addStroke(_, let st)) in d.ops.enumerated() {
                addOrigins[st.id, default: []].append(Origin(d.name, op: i))
            }
        }
        let keptStrokes = removedStrokes.union(superseded).filter { id in
            !(addOrigins[id] ?? []).contains { included.covers(device: $0.device, seq: $0.seq) }
        }
        let held = Set(outPages.flatMap { $0.strokes.map(\.id) })
        let tomb = Tombstones(strokes: sortedIds(keptStrokes), pages: sortedIds(removedPages),
                              items: sortedIds(removedItems), recordings: sortedIds(removedRecordings),
                              lineage: lineage.records(held: held, superseded: superseded),
                              superseded: sortedIds(superseded))

        var state = NoteState(meta: defaults.meta, pages: outPages,
                              tombstones: tomb.isEmpty ? nil : tomb, recordings: outRecordings)
        state.meta.created = created ?? defaults.meta.created
        var clocks: [String: String] = [:]
        for (k, reg) in registers {
            reg.value.apply(to: &state)
            clocks[k.rawValue] = reg.key.stamp.description
        }
        state.clocks = clocks
        tags.removed.formUnion(tagRemovals)
        state.tagSet = tags.resolve()
        state.meta.tags = state.tagSet.tags
        return Resolution(state: state, included: included, superseded: supersededLive, lineage: lineage)
    }

    private static func sortedIds(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }
}

/// Tag instances and removals collected from every source (format.md §5.4.1).
struct TagMerge {
    /// Instance identity is (key, origin); the spelling is the instance's.
    var added: [TagSet.Removal: String] = [:]
    var removed = Set<TagSet.Removal>()

    /// Adds one instance. The spelling is normalised as writers must have
    /// done; an instance whose tag is empty (blank) is ignored (§5.4.1).
    mutating func add(_ tag: String, _ origin: Origin) {
        let tag = NoteOps.normalizedTag(tag)
        guard !tag.isEmpty else { return }
        let id = TagSet.Removal(key: NoteOps.tagKey(tag), origin: origin)
        // One identity always has one spelling; pick deterministically regardless.
        if let cur = added[id], !tag.utf8.lexicographicallyPrecedes(cur.utf8) { return }
        added[id] = tag
    }

    /// A snapshot's set.
    mutating func add(_ set: TagSet) {
        for i in set.instances { add(i.tag, i.origin) }
        removed.formUnion(set.removed)
    }

    /// The tag set: every added instance that no removal names.
    func resolve() -> TagSet {
        let live = added.filter { id, _ in !removed.contains(id) }
        let instances = live.map { TagSet.Instance(tag: $0.value, origin: $0.key.origin) }
            .sorted { ($0.origin, $0.key) < ($1.origin, $1.key) }
        let removals = removed.sorted { ($0.origin, $0.key) < ($1.origin, $1.key) }
        return TagSet(instances: instances, removed: removals)
    }
}

extension TagSet {
    /// The tags on the note, one per key: the spelling of the key's earliest
    /// live instance, in the order of those instances (format.md §5.4.1).
    public var tags: [String] {
        var seen = Set<String>()
        return instances.sorted { ($0.origin, $0.key) < ($1.origin, $1.key) }
            .filter { seen.insert($0.key).inserted }.map(\.tag)
    }
}

/// An origin is written only when it names a real revision (`seq ≥ 1`);
/// `apply`'s stand-in base has none to give.
private func emitted(_ origin: Origin) -> String? { origin.seq >= 1 ? origin.description : nil }

/// The value of one LWW register (`NoteState.ClockKey`).
enum RegisterValue: Equatable {
    case meta(MetaChange)
    case deleted(Bool)

    /// Reads register `key` from `state`.
    init(_ key: NoteState.ClockKey, in state: NoteState) {
        let m = state.meta
        switch key {
        case .title: self = .meta(.title(m.title))
        case .notebook: self = .meta(.notebook(m.notebook))
        case .favorite: self = .meta(.favorite(m.favorite))
        case .paper: self = .meta(.paper(m.paper))
        case .pageSize: self = .meta(.pageSize(m.pageSize))
        case .lang: self = .meta(.lang(m.lang))
        case .markersBehindText: self = .meta(.markersBehindText(m.markersBehindText))
        case .recognized: self = .meta(.recognized(m.recognized))
        case .deleted: self = .deleted(state.deleted)
        }
    }

    var clockKey: NoteState.ClockKey {
        switch self {
        case .deleted: return .deleted
        case .meta(let change):
            switch change {
            case .title: return .title
            case .notebook: return .notebook
            case .favorite: return .favorite
            case .paper: return .paper
            case .pageSize: return .pageSize
            case .lang: return .lang
            case .markersBehindText: return .markersBehindText
            case .recognized: return .recognized
            }
        }
    }

    func apply(to state: inout NoteState) {
        switch self {
        case .meta(let change): change.apply(to: &state.meta)
        case .deleted(let v): state.deleted = v
        }
    }
}

extension Revision {
    /// The ops of a delta; empty for a snapshot.
    var ops: [Op] {
        if case .delta(let ops) = body { return ops }
        return []
    }


}

// MARK: - Snapshots

public enum SnapshotBuilder {
    /// Writes a snapshot of every given revision. `included` lists only what
    /// the state reflects in full (§5.3): every input snapshot's `included`,
    /// the input snapshots, every applied delta except orphans, and the new
    /// snapshot itself. `clock` observes every input first, so the snapshot
    /// sorts after every input it adopts (see `HybridClock.observe`).
    public static func makeSnapshot(from revisions: [Revision], device: DeviceID, seq: Int,
                                    clock: inout HybridClock, wall: Date, app: String) throws -> Revision {
        let revs = try NoteReducer.canonical(revisions)
        let res = NoteReducer.resolve(revs)
        for r in revs { clock.observe(r.hlc, wall: wall) }
        var included = res.included
        included.insert(device: device, seq: seq)
        let hlc = clock.tick(wall: wall)
        return Revision(noteId: revs[0].noteId, device: device, seq: seq, hlc: hlc, wall: wall, app: app,
                        body: .snapshot(included: included, state: res.state))
    }
}
