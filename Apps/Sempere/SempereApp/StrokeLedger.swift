import Foundation
import Sempere

/// What the ledger knows about one canvas stroke without converting it:
/// cheap fingerprints taken from the PencilKit stroke (see
/// `CanvasStrokeInfo.init(_: PKStroke)`). Pure values, so the ledger is
/// testable without PencilKit.
struct CanvasStrokeInfo: Hashable, Sendable {
    /// Identity: equal keys mean "the same canvas stroke, unchanged". Built
    /// from ink, colour, transform, path length, creation date, a few control
    /// points, texture seed and mask ranges. Any edit (move, recolour,
    /// partial erase) changes it.
    struct Key: Hashable, Sendable {
        let ink: String
        let values: [Double]
        /// Hashed once: the ledger looks keys up on every drawing change, and
        /// hashing `values` (about 40 numbers) each time cost more than the lookups.
        private let hash: Int

        init(ink: String, values: [Double]) {
            self.ink = ink
            self.values = values
            var hasher = Hasher()
            hasher.combine(ink)
            hasher.combine(values)
            hash = hasher.finalize()
        }

        static func == (a: Key, b: Key) -> Bool {
            a.hash == b.hash && a.ink == b.ink && a.values == b.values
        }

        func hash(into hasher: inout Hasher) { hasher.combine(hash) }
    }

    /// Strokes that share a family (ink, colour, transform, path creation
    /// date) can be pieces of one another.
    struct Family: Hashable, Sendable {
        var ink: String
        var values: [Double]

        /// The path's creation date: the last value (`init(_: PKStroke)`).
        /// A lasso move, resize or recolour changes the colour or transform
        /// but keeps the path and this date.
        var created: Double? { values.last }
    }

    /// Axis-aligned bounds in page points.
    struct Bounds: Hashable, Sendable {
        var minX: Double, minY: Double, maxX: Double, maxY: Double

        func contains(_ o: Bounds, slack: Double = 1) -> Bool {
            o.minX >= minX - slack && o.minY >= minY - slack && o.maxX <= maxX + slack && o.maxY <= maxY + slack
        }
    }

    var key: Key
    var family: Family
    /// Control-point count plus first and last location: equal for the pieces
    /// of a masked (pixel-erased) stroke and the stroke they came from.
    var pathSignature: [Double]
    var bounds: Bounds
    /// The canvas stroke's `PKStroke.id` (iOS 27): the stored id for a loaded
    /// stroke, PencilKit's own for one drawn since. Not part of `key`; it only
    /// names the parent of an edit that kept it (`StrokeLedger`).
    var canvasID: UUID? = nil
}

/// The stable-id side table for one page.
///
/// The ledger keeps, in canvas order, which stored strokes (our ids) each
/// canvas stroke stands for, keyed by `CanvasStrokeInfo.Key`. On every
/// drawing change it matches the new canvas strokes against that table as a
/// multiset, in order: a matched stroke keeps its ids; an unmatched old one
/// was removed; an unmatched new one was added and gets fresh ids.
///
/// `PKStroke.id` (iOS 27) is not the key: an edit changes the content but
/// may keep the id, and PencilKit gives the pieces of a pixel erase (and a
/// `substroke`) new ids, so matching stays by content. The id only names a
/// parent (2 below).
///
/// A new stroke's `parent` (format.md §5.6) is, in order of preference:
/// 1. the stroke retired under the same key (an undo of an erase, or a redo,
///    brings back identical content). If that stroke's removal has not been
///    written yet, it simply comes back with its old ids; once the removal is
///    on disk it must get new ids (format.md §5.2) and becomes the parent;
/// 2. a stroke removed in the same change with the same `PKStroke.id`
///    (`CanvasStrokeInfo.canvasID`): PencilKit edited it and kept its id;
/// 3. a stroke removed in the same change with the same path signature and
///    family (PencilKit's pixel eraser keeps the path and adds a mask);
/// 4. a stroke removed in the same change of the same family whose bounds
///    contain the new one (a slice that rewrote the path);
/// 5. a stroke removed in the same change with the same ink type, path
///    signature and path creation date (a lasso move, resize or recolour:
///    the path stays, colour or transform change). So the edit replaces the
///    original (format.md §5.6.1) and a concurrent edit of it on another
///    device does not leave both.
/// A parent that was never written to disk is replaced by its own parent.
///
/// Ops are the net difference between what is on disk (`committed`) and
/// what is live, so a stroke drawn and erased within one autosave pause
/// never reaches the log.
struct StrokeLedger {
    /// One canvas stroke and the stored strokes it stands for (several for a
    /// masked stroke with several visible ranges, none for a fully masked one).
    struct Entry {
        var info: CanvasStrokeInfo
        var strokes: [Stroke]
    }

    /// One canvas stroke as reported by the canvas.
    struct Item {
        var info: CanvasStrokeInfo
        /// Converts the canvas stroke; called only for strokes the ledger has
        /// not seen. Ids of the result are ignored.
        var make: () -> [Stroke]
    }

    /// What one `update` changed.
    struct Change: Equatable {
        var added: [Stroke] = []
        var removed: [Stroke] = []
        var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    private(set) var entries: [Entry]
    /// Strokes on disk for this page, in their stored order.
    private(set) var committed: [Stroke]
    /// Every id ever written to disk for this page (live or since removed).
    private var written: Set<UUID>
    /// Removed canvas strokes by key, most recent last.
    private var retired: [CanvasStrokeInfo.Key: [[Stroke]]] = [:]
    /// False only when `live` is known to be what is committed (no ops are
    /// pending), so a save of an unchanged page scans nothing. Set by every
    /// change that can make ops pending (`update`, `mergeStored`,
    /// `saveFailed`); cleared by `beginSave`.
    private var mayHavePending = false

    /// A ledger for a page loaded from disk; `info` fingerprints the canvas
    /// stroke each stored stroke will be shown as.
    init(stored: [Stroke], info: (Stroke) -> CanvasStrokeInfo) {
        entries = stored.map { Entry(info: info($0), strokes: [$0]) }
        committed = stored
        written = Set(stored.map(\.id))
    }

    /// A ledger for a page loaded from disk whose canvas strokes were
    /// prepared elsewhere (`DrawingPreparation`): `infos[i]` fingerprints the
    /// canvas stroke shown for `stored[i]`. Nil when the counts differ.
    init?(stored: [Stroke], infos: [CanvasStrokeInfo]) {
        guard stored.count == infos.count else { return nil }
        entries = zip(infos, stored).map { Entry(info: $0, strokes: [$1]) }
        committed = stored
        written = Set(stored.map(\.id))
    }

    /// Live strokes, in canvas order.
    var live: [Stroke] { entries.flatMap(\.strokes) }

    /// Re-keys the table for a canvas rebuilt from `live` (one canvas stroke
    /// per stored stroke), keeping ids, history and what is committed.
    mutating func rebase(info: (Stroke) -> CanvasStrokeInfo) {
        entries = live.map { Entry(info: info($0), strokes: [$0]) }
    }

    /// `rebase(info:)` with fingerprints prepared elsewhere: `infos[i]` is
    /// the canvas stroke shown for `live[i]`. False (and nothing changes)
    /// when the counts differ.
    @discardableResult
    mutating func rebase(infos: [CanvasStrokeInfo]) -> Bool {
        let live = self.live
        guard live.count == infos.count else { return false }
        entries = zip(infos, live).map { Entry(info: $0, strokes: [$1]) }
        return true
    }

    /// Matches the canvas's strokes against the table and assigns ids.
    @discardableResult
    mutating func update(_ items: [Item]) -> Change {
        let old = entries
        return update(count: items.count, unchanged: { i, j, _ in items[i].info.key == old[j].info.key },
                      item: { items[$0] })
    }

    /// `update(_:)` for a canvas of `count` strokes handed over lazily, so a
    /// change of a few strokes on a dense page fingerprints only those:
    /// `unchanged(i, j, info)` is true only when canvas stroke `i` is the
    /// canvas stroke entry `j` (fingerprinted as `info`) was made from,
    /// unchanged, so its key is `info.key`; it may say false whenever it
    /// cannot tell cheaply. `item(i)` fingerprints canvas stroke `i`.
    ///
    /// The canvas strokes that are unchanged at the start and the end of the
    /// canvas keep their entries without being fingerprinted; the strokes in
    /// between are matched as `update(_:)` matches them, with the same
    /// result: equal keys pair up in order (the n-th canvas stroke with a key
    /// takes the n-th entry with it), so a run at the start pairs as it would
    /// anyway, and one at the end does too unless a key in it occurs a
    /// different number of times among the strokes and the entries in
    /// between. Then the end is matched in full.
    @discardableResult
    mutating func update(count: Int, unchanged: (_ item: Int, _ entry: Int, _ info: CanvasStrokeInfo) -> Bool,
                         item: (Int) -> Item) -> Change {
        let n = entries.count
        var head = 0
        while head < count, head < n, unchanged(head, head, entries[head].info) { head += 1 }
        var tail = 0
        while tail < count - head, tail < n - head, unchanged(count - 1 - tail, n - 1 - tail, entries[n - 1 - tail].info) {
            tail += 1
        }
        var middle = (head..<(count - tail)).map(item)
        if tail > 0 {
            var balance: [CanvasStrokeInfo.Key: Int] = [:]
            for item in middle { balance[item.info.key, default: 0] += 1 }
            for e in entries[head..<(n - tail)] { balance[e.info.key, default: 0] -= 1 }
            balance = balance.filter { $0.value != 0 }
            if !balance.isEmpty, entries[(n - tail)...].contains(where: { balance[$0.info.key] != nil }) {
                middle += ((count - tail)..<count).map(item)
                tail = 0
            }
        }
        return match(middle, replacing: head..<(n - tail))
    }

    /// Matches `items` against the entries in `old` as a multiset, in order,
    /// and puts the result in their place.
    private mutating func match(_ items: [Item], replacing old: Range<Int>) -> Change {
        var pool: [CanvasStrokeInfo.Key: [Int]] = [:]
        for i in old { pool[entries[i].info.key, default: []].append(i) }
        var keptIndex: [Int?] = []   // per item: matched old entry index
        keptIndex.reserveCapacity(items.count)
        var used = Set<Int>()
        for item in items {
            if var queue = pool[item.info.key], !queue.isEmpty {
                let i = queue.removeFirst()
                pool[item.info.key] = queue
                used.insert(i)
                keptIndex.append(i)
            } else {
                keptIndex.append(nil)
            }
        }
        var change = Change()
        var removedEntries: [Entry] = []
        for i in old where !used.contains(i) {
            removedEntries.append(entries[i])
            change.removed += entries[i].strokes
        }
        for e in removedEntries { retired[e.info.key, default: []].append(e.strokes) }

        var next: [Entry] = []
        next.reserveCapacity(items.count)
        var onDisk: Set<UUID>?   // committed ids, made on the first revive
        var removedIndex: RemovedIndex?   // made on the first stroke that needs a parent
        for (item, kept) in zip(items, keptIndex) {
            if let kept {
                next.append(entries[kept])
                continue
            }
            if let revived = revive(item.info.key, onDisk: &onDisk) {
                change.added += revived
                next.append(Entry(info: item.info, strokes: revived))
                continue
            }
            let parents = parentCandidates(for: item.info, removed: removedEntries, index: &removedIndex)
            var strokes = item.make()
            for k in strokes.indices {
                strokes[k].id = UUID()
                strokes[k].origin = nil
                let parent = choose(parents, for: strokes[k], index: k)
                strokes[k].parent = resolveParent(parent)
                // A piece of a sliced stroke keeps the stroke's link to the audio (format.md §8.3.3).
                if let rec = parent?.rec { strokes[k].rec = rec }
            }
            change.added += strokes
            next.append(Entry(info: item.info, strokes: strokes))
        }
        entries.replaceSubrange(old, with: next)
        if !change.isEmpty { mayHavePending = true }
        return change
    }

    /// The ops that bring the disk up to `live`: removals, then additions in
    /// canvas order.
    func pendingOps(page: UUID, live: [Stroke]) -> [Op] {
        let liveIDs = Set(live.map(\.id))
        let committedIDs = Set(committed.map(\.id))
        let removes = committed.filter { !liveIDs.contains($0.id) }.map { Op.removeStroke(page: page, strokeId: $0.id) }
        let adds = live.filter { !committedIDs.contains($0.id) }.map { Op.addStroke(page: page, stroke: $0) }
        return removes + adds
    }

    /// A save in flight (`beginSave`): the ops it writes and what was on
    /// disk before it.
    struct Save: Equatable {
        var ops: [Op]
        fileprivate var previous: [Stroke]
    }

    /// Starts writing the live strokes: returns the ops that bring the disk up
    /// to them and records them as committed at once, before the write
    /// finishes. Committing late would let an undo during the write revive an
    /// id whose removal is being written, and the next save would add that
    /// removed id again (format.md §5.2), so the stroke would vanish on disk.
    /// Nil when nothing is pending. Call `saveFailed(_:)` if the write fails.
    mutating func beginSave(page: UUID) -> Save? {
        guard mayHavePending else { return nil }
        let live = self.live
        let ops = pendingOps(page: page, live: live)
        mayHavePending = false
        guard !ops.isEmpty else { return nil }
        let save = Save(ops: ops, previous: committed)
        commit(live)
        return save
    }

    /// Whether any op is pending (`pendingOps` of `live` is not empty);
    /// scans only a ledger that changed since its last save.
    var hasPending: Bool {
        mayHavePending && !pendingOps(page: UUID(), live: live).isEmpty
    }

    /// The write started by `save` failed: its ops stay pending. Ids it added
    /// stay marked as written (the file may have landed), so they are never
    /// revived after a removal; at worst a later stroke names one as `parent`.
    mutating func saveFailed(_ save: Save) {
        committed = save.previous
        mayHavePending = true
    }

    /// Records that `live` (as passed to `pendingOps`) is now on disk.
    mutating func commit(_ live: [Stroke]) {
        let liveIDs = Set(live.map(\.id))
        var kept = committed.filter { liveIDs.contains($0.id) }
        let have = Set(kept.map(\.id))
        kept += live.filter { !have.contains($0.id) }
        committed = kept
        written.formUnion(liveIDs)
    }

    // MARK: - Revisions written elsewhere

    /// What `mergeStored` did to the page.
    struct RemoteMerge: Equatable {
        /// Where each new entry's canvas stroke comes from, in canvas order.
        enum Source: Equatable {
            /// The canvas stroke the old entry at this index stood for, unchanged.
            case kept(Int)
            /// A new canvas stroke converted from this stored stroke.
            case converted(Stroke)
        }

        var sources: [Source] = []
        /// How many entries (canvas strokes) the ledger had before.
        var previousCount = 0
        /// Strokes another writer added that are now live.
        var added: [Stroke] = []
        /// Live strokes another writer removed.
        var removed: [Stroke] = []

        /// True when the canvas must show something else: strokes came or
        /// went, or the order changed.
        var changesCanvas: Bool {
            sources != (0..<previousCount).map(Source.kept)
        }
    }

    /// Takes `stored`, the page's strokes as now merged on disk (format.md
    /// §5.3: revisions of other devices, and of this editor, which has saved
    /// first), as what is committed, keeping what is pending here: strokes
    /// added on this canvas and not written yet stay live (on top), strokes
    /// erased here and not written yet stay removed, and their ops stay
    /// pending. A stroke another writer removed leaves the canvas, one it
    /// added appears; neither is ever reported as a change of this canvas
    /// (no echo: `pendingOps` holds only what this canvas did).
    ///
    /// Canvas strokes are reused wherever every stored stroke they stand for
    /// is still live, so only strokes that are new here are converted. The
    /// new canvas order is the stored order, then the pending additions.
    /// `info` fingerprints the canvas stroke a stored stroke is shown as
    /// (`CanvasStrokeInfo.init(stored:)`).
    mutating func mergeStored(_ stored: [Stroke], info: (Stroke) -> CanvasStrokeInfo) -> RemoteMerge {
        mayHavePending = true   // what is committed changes under what is live
        let committedIDs = Set(committed.map(\.id))
        let liveIDs = Set(live.map(\.id))
        var storedByID: [UUID: Stroke] = [:]
        for s in stored where storedByID[s.id] == nil { storedByID[s.id] = s }
        // Live after the merge: a stored stroke that is live here or new from
        // elsewhere (never committed nor written by this canvas, which would
        // make its absence here a pending erase), and a pending addition.
        func fromElsewhere(_ id: UUID) -> Bool { !committedIDs.contains(id) && !written.contains(id) && !liveIDs.contains(id) }
        func pendingAdd(_ id: UUID) -> Bool { storedByID[id] == nil && !committedIDs.contains(id) }
        func staysLive(_ id: UUID) -> Bool {
            storedByID[id] != nil ? (liveIDs.contains(id) || fromElsewhere(id)) : pendingAdd(id)
        }

        var merge = RemoteMerge(previousCount: entries.count)
        var entryOf: [UUID: Int] = [:]
        for (i, e) in entries.enumerated() { for s in e.strokes { entryOf[s.id] = i } }
        // A fully masked canvas stroke (no stored strokes) shows nothing and stays as it is.
        let intact = Set(entries.indices.filter { i in entries[i].strokes.allSatisfy { staysLive($0.id) } })
        for e in entries { merge.removed += e.strokes.filter { !staysLive($0.id) } }
        let unchanged = intact.count == entries.count
            && !stored.contains { fromElsewhere($0.id) }
        if unchanged {
            // Nothing came or went: the canvas stays exactly as it is.
            entries = entries.map { e in
                var e = e
                e.strokes = e.strokes.map { storedByID[$0.id] ?? $0 }
                return e
            }
            merge.sources = entries.indices.map(RemoteMerge.Source.kept)
            committed = stored
            written.formUnion(storedByID.keys)
            return merge
        }

        var next: [Entry] = []
        var placed = Set<Int>()
        var seen = Set<UUID>()
        for s in stored where seen.insert(s.id).inserted && staysLive(s.id) {
            if let i = entryOf[s.id], intact.contains(i) {
                guard placed.insert(i).inserted else { continue }
                var e = entries[i]
                e.strokes = e.strokes.map { storedByID[$0.id] ?? $0 }
                next.append(e)
                merge.sources.append(.kept(i))
            } else {
                // New from elsewhere, or a piece of a canvas stroke that lost another piece.
                if fromElsewhere(s.id) { merge.added.append(s) }
                next.append(Entry(info: info(s), strokes: [s]))
                merge.sources.append(.converted(s))
            }
        }
        for (i, e) in entries.enumerated() where !placed.contains(i) {
            if intact.contains(i) {
                next.append(e)
                merge.sources.append(.kept(i))
            } else {
                // Pending additions that shared a canvas stroke with something now gone.
                for s in e.strokes where pendingAdd(s.id) && staysLive(s.id) {
                    next.append(Entry(info: info(s), strokes: [s]))
                    merge.sources.append(.converted(s))
                }
            }
        }
        entries = next
        committed = stored
        written.formUnion(storedByID.keys)
        return merge
    }

    // MARK: - Parents

    /// The entries one update removed, looked up by the parent rules: the
    /// first entry in order for each rule's key, as a scan would find it.
    private struct RemovedIndex {
        struct Created: Hashable { var ink: String, created: Double, pathSignature: [Double] }
        struct Path: Hashable { var family: CanvasStrokeInfo.Family, pathSignature: [Double] }
        var canvasID: [UUID: Int] = [:]
        var path: [Path: Int] = [:]
        var family: [CanvasStrokeInfo.Family: [Int]] = [:]
        var created: [Created: Int] = [:]

        init(_ removed: [Entry]) {
            for (i, e) in removed.enumerated() {
                let info = e.info
                if let id = info.canvasID, canvasID[id] == nil { canvasID[id] = i }
                let p = Path(family: info.family, pathSignature: info.pathSignature)
                if path[p] == nil { path[p] = i }
                family[info.family, default: []].append(i)
                if let date = info.family.created {
                    let c = Created(ink: info.family.ink, created: date, pathSignature: info.pathSignature)
                    if created[c] == nil { created[c] = i }
                }
            }
        }
    }

    private mutating func parentCandidates(for info: CanvasStrokeInfo, removed: [Entry],
                                           index: inout RemovedIndex?) -> [Stroke] {
        if var stack = retired[info.key], let last = stack.popLast() {
            retired[info.key] = stack
            return last
        }
        guard !removed.isEmpty else { return [] }
        let x = index ?? RemovedIndex(removed)
        index = x
        if let id = info.canvasID, let i = x.canvasID[id] {
            return removed[i].strokes
        }
        if let i = x.path[RemovedIndex.Path(family: info.family, pathSignature: info.pathSignature)] {
            return removed[i].strokes
        }
        if let i = x.family[info.family]?.first(where: { removed[$0].info.bounds.contains(info.bounds) }) {
            return removed[i].strokes
        }
        if let created = info.family.created,
           let i = x.created[RemovedIndex.Created(ink: info.family.ink, created: created, pathSignature: info.pathSignature)] {
            return removed[i].strokes
        }
        return []
    }

    /// Identical content coming back (undo, redo) keeps its old ids when none
    /// of them has been removed on disk yet: either still committed, or never
    /// written. Otherwise nil, and the stroke gets new ids (format.md §5.2).
    /// `onDisk` caches the committed ids for one update.
    private mutating func revive(_ key: CanvasStrokeInfo.Key, onDisk: inout Set<UUID>?) -> [Stroke]? {
        guard var stack = retired[key], let last = stack.last else { return nil }
        let committedIDs = onDisk ?? Set(committed.map(\.id))
        onDisk = committedIDs
        guard last.allSatisfy({ committedIDs.contains($0.id) || !written.contains($0.id) }) else { return nil }
        stack.removeLast()
        retired[key] = stack
        return last
    }

    /// Of several candidate parents, the one nearest the piece's first point.
    private func choose(_ candidates: [Stroke], for piece: Stroke, index: Int) -> Stroke? {
        guard candidates.count > 1, let start = piece.points.first else { return candidates.first }
        func distance(_ s: Stroke) -> Double {
            s.points.map { ($0.x - start.x) * ($0.x - start.x) + ($0.y - start.y) * ($0.y - start.y) }.min() ?? .infinity
        }
        return candidates.min { distance($0) < distance($1) }
    }

    /// A parent that never reached disk is replaced by its own parent.
    private func resolveParent(_ p: Stroke?) -> UUID? {
        guard let p else { return nil }
        return written.contains(p.id) ? p.id : p.parent
    }
}
