import Foundation

// MARK: - Thinning and checkpoint-safe compaction (docs/format.md §5.3, §5.8.4)

/// What a compaction deletes.
public enum CompactionMode: Hashable, Sendable {
    /// Retention compaction (format.md §5.3): covered deltas and subsumed
    /// snapshots older than the window; checkpoints stay and stay complete.
    case retention(TimeInterval)
    /// Thinning (format.md §5.8.4): in the revisions older than this, keep
    /// checkpoints and the newest point of each editing session.
    case thin(olderThan: TimeInterval)
}

/// Errors from planning a compaction.
public enum CompactionError: Error, Hashable, Sendable {
    /// A revision of the note cannot be read: its effect and coverage are
    /// unknown, so nothing may be deleted.
    case unreadableRevision(String)
    /// A positioned snapshot did not make its point complete (an internal
    /// inconsistency or a malformed revision); nothing is written.
    case cannotProtect(String)
    /// The plan failed its own check that the note's state is unchanged.
    case stateWouldChange
    /// The plan failed its own check that this kept version (a target) is
    /// unchanged; nothing is written.
    case versionWouldChange(String)
}

/// What compacting one note writes and deletes (`CompactionPlanner.plan`).
public struct CompactionPlan: Hashable, Sendable {
    public var noteId: UUID
    /// Snapshots to write first, in order (positioned ones carry `asOf`).
    public var snapshots: [Revision]
    /// Revision files to delete once the snapshots are written, sorted.
    public var deletions: [RevisionName]
    /// Revisions kept only as ordering witnesses (format.md §5.8.4 rule 3).
    public var witnesses: [RevisionName]
    /// The restore points the plan keeps complete (rule 2), sorted.
    public var targets: [RevisionName]

    /// True when nothing would be written or deleted.
    public var isEmpty: Bool { deletions.isEmpty && snapshots.isEmpty }
}

extension CompactionPlanner {
    /// Plans compacting one note (format.md §5.3, §5.8.4) from **all** its
    /// revisions, all readable; nothing is written. Snapshots the plan needs
    /// are built with `device`, consecutive `seq`s from the next free one, and
    /// `clock` (which observes every revision first).
    ///
    /// Guarantees, checked before returning (and property-tested):
    /// the note's current state is unchanged; checkpoints are never deleted;
    /// every target (checkpoints, and for `.thin` also the newest point of
    /// each session, the newest revision and everything after the thinned
    /// range) that was complete stays complete with the same state; each
    /// deleted revision is covered by a snapshot that stays (a delta) or
    /// dominated by one (a snapshot), so any subset of the deletions is safe.
    ///
    /// Cost: about (snapshots planned + 1) × (completeness sweep + coverage
    /// check), plus one `NoteReducer` pass per snapshot built; the snapshots
    /// planned are at most one per target.
    public static func plan(_ revisions: [Revision], mode: CompactionMode, now: Date, device: DeviceID,
                            clock: inout HybridClock, wall: Date, app: String) throws -> CompactionPlan {
        let revs = revisions.sorted { $0.name < $1.name }
        guard let last = revs.last else { throw NoteLogError.noRevisions }
        let noteId = last.noteId
        let newest = last.name
        let selection = select(revs, mode: mode, now: now)
        var candidates = selection.candidates
        let witnesses = selection.witnesses
        let positioned = selection.positioned
        func position(_ r: Revision) -> RevisionKey { positioned[r.name] ?? RevisionKey(r.name) }
        // Reconstructions are memoized by the set of revisions they merge: the
        // snapshot built at the newest target, the current state and the state
        // as of that target are often the same merge.
        var memo: [Set<RevisionName>: NoteState] = [:]
        func merged(_ source: [Revision]) throws -> NoteState {
            let key = Set(source.map(\.name))
            if let s = memo[key] { return s }
            let s = try NoteReducer.reconstruct(source)
            memo[key] = s
            return s
        }
        func state(_ source: [Revision], at point: RevisionName) throws -> NoteState {
            let pos = NoteHistory.positions(source)
            guard pos[point] == nil, source.contains(where: { $0.name == point }) else {
                return try NoteHistory.state(source, at: point)   // throws as it would
            }
            guard Completeness(source, unreadable: [], positions: pos).isComplete(at: [point]) == [true] else {
                throw HistoryError.incompleteHistory(point)
            }
            let key = RevisionKey(point)
            return try merged(source.filter { (pos[$0.name] ?? RevisionKey($0.name)) <= key })
        }

        var planned: [Revision] = []
        var seq = Vault.nextSeq(from: revs, device: device)
        for r in revs { clock.observe(r.hlc, wall: wall) }
        func build(at point: RevisionName?) throws -> Revision {
            let source = point.map { p in revs.filter { position($0) <= RevisionKey(p) } } ?? revs
            var snap = try SnapshotBuilder.makeSnapshot(from: source, device: device, seq: seq, clock: &clock,
                                                        wall: wall, app: app)
            if case .snapshot(_, let st) = snap.body { memo[Set(source.map(\.name))] = memo[Set(source.map(\.name))] ?? st }
            snap.asOf = point.map(RevisionKey.init)
            seq += 1
            return snap
        }
        let sortedTargets = selection.targets
        var coverPlanned = false
        // Each pass either finishes, plans one snapshot (at most one per target
        // plus one cover) or keeps at least one candidate, so the passes are
        // bounded by targets + candidates + 2.
        for _ in 0...(sortedTargets.count + candidates.count + 2) {
            if candidates.isEmpty { planned = []; break }
            let survivors = revs.filter { !candidates.contains($0.name) } + planned
            // Completeness learns what is gone only from snapshots; a stand-in
            // ordered after everything tells it which candidates go, and covers
            // nothing at or before any target.
            var goneSet = Included()
            for r in revs where candidates.contains(r.name) {
                switch r.body {
                case .delta: goneSet.insert(device: r.device, seq: r.seq)
                case .snapshot(let inc, _): goneSet = goneSet.union(inc).union(Included([r.device: .init(upTo: 0, extra: [r.seq])]))
                }
            }
            let standIn = Revision(noteId: noteId, device: .zero, seq: 1, hlc: HLC(millis: HLC.maxMillis, counter: HLC.maxCounter) ?? .zero,
                                   wall: wall, app: app, body: .snapshot(included: goneSet, state: NoteState(meta: NoteMeta(created: wall))))
            let after = Completeness(survivors + [standIn], unreadable: []).isComplete(at: sortedTargets)
            if let bad = zip(sortedTargets, after).first(where: { !$0.1 })?.0 {
                if let snap = planned.first(where: { $0.asOf == RevisionKey(bad) }),
                   case .snapshot(let inc, _) = snap.body {
                    // Its snapshot cannot cover some revision before it (a delta not
                    // applied in full there, §5.3): keep those instead.
                    let keep = revs.filter { r in
                        candidates.contains(r.name) && r.name <= bad && !inc.covers(device: r.device, seq: r.seq)
                    }
                    guard !keep.isEmpty else { throw CompactionError.cannotProtect(bad.filename) }
                    candidates.subtract(keep.map(\.name))
                    continue
                }
                planned.append(try build(at: bad))
                continue
            }
            let covers = survivors.compactMap { r -> (RevisionName, Included)? in
                guard case .snapshot(let inc, _) = r.body else { return nil }
                return (r.name, inc)
            }
            let uncovered = revs.filter { r in
                guard candidates.contains(r.name) else { return false }
                switch r.body {
                case .delta:
                    return !covers.contains { $0.1.covers(device: r.device, seq: r.seq) }
                case .snapshot(let inc, _):
                    return !covers.contains { c in
                        c.1.isSuperset(of: inc) && (!inc.isSuperset(of: c.1) || c.0 > r.name)
                    }
                }
            }
            if uncovered.isEmpty { break }
            if !coverPlanned {
                coverPlanned = true
                if case .thin = mode { planned.append(try build(at: newest)) } else { planned.append(try build(at: nil)) }
                continue
            }
            // Not even a snapshot of everything covers it (an orphan delta, §5.3): keep it.
            candidates.subtract(uncovered.map(\.name))
        }

        // Safety net: the current state must not change (G1), nor the note as
        // of any target that a deletion or a planned snapshot is positioned at
        // or before (G2). A target after every deletion sees all of them and
        // all the snapshots, as the current state does.
        if let lastGone = candidates.max() {
            let survivors = revs.filter { !candidates.contains($0.name) } + planned
            guard try merged(survivors).comparable == merged(revs).comparable else {
                throw CompactionError.stateWouldChange
            }
            for t in sortedTargets where t <= lastGone {
                guard try state(survivors, at: t).comparable == state(revs, at: t).comparable else {
                    throw CompactionError.versionWouldChange(t.filename)
                }
            }
        }
        return CompactionPlan(noteId: noteId, snapshots: planned, deletions: candidates.sorted(),
                              witnesses: witnesses.sorted(), targets: sortedTargets)
    }
}

/// Which revisions a compaction may delete, decided from the revisions'
/// names, `wall`s, checkpoint and session fields, snapshot coverage and
/// `asOf` only: no ops or states are looked at, so it runs as well on
/// metadata (`RevisionMeta.hollow`) as on decoded revisions.
public struct CompactionSelection: Hashable, Sendable {
    /// Revisions that may be deleted (the plan may still keep some).
    public var candidates: Set<RevisionName>
    /// The kept restore points that must stay complete (format.md §5.8.4 rule 2), sorted.
    public var targets: [RevisionName]
    /// Revisions kept only as ordering witnesses (rule 3).
    public var witnesses: Set<RevisionName>
    /// The snapshots with a valid `asOf` (format.md §5.8.3), mapped to it.
    public var positioned: [RevisionName: RevisionKey]
}

extension CompactionPlanner {
    /// The first stage of `plan`: candidates, targets and witnesses
    /// (format.md §5.3, §5.8.4). `plan` never deletes a revision that is not
    /// a candidate here, so an empty `candidates` means an empty plan.
    ///
    /// Cost: O(n log n) for n revisions, plus `NoteHistory.restorePoints`.
    public static func select(_ revisions: [Revision], mode: CompactionMode, now: Date) -> CompactionSelection {
        let revs = revisions.sorted { $0.name < $1.name }
        guard let last = revs.last else { return CompactionSelection(candidates: [], targets: [], witnesses: [], positioned: [:]) }
        let names = revs.map(\.name)
        let positioned = NoteHistory.positions(revs)
        let points = NoteHistory.restorePoints(revs)
        let completeBefore = Set(points.filter(\.complete).map(\.name))
        let checkpoints = Set(points.filter(\.isCheckpoint).map(\.name))
        let newest = last.name

        var candidates: Set<RevisionName>
        var targets: Set<RevisionName>
        switch mode {
        case .retention(let window):
            let loaded = LoadedNote(revisions: revs, failures: [:])
            let needs = loaded.needsSnapshotBeforeCompaction(retention: window, now: now)
            candidates = Set(loaded.compactionPlan(retention: window, now: now, assumingSnapshot: needs,
                                                    protectingCheckpoints: false))
            targets = checkpoints.intersection(completeBefore)
        case .thin(let age):
            var range = Set<RevisionName>()
            for r in revs {
                guard now.timeIntervalSince(r.wall) > age else { break }
                range.insert(r.name)
            }
            var kept = checkpoints
            kept.insert(newest)
            for case .session(let s) in NoteHistory.groups(points) { kept.insert(s.newest.name) }
            candidates = range.subtracting(kept)
            targets = kept.union(points.map(\.name).filter { !range.contains($0) }).intersection(completeBefore)
        }
        if let anchor = createdAnchor(revs) { candidates.remove(anchor) }

        // Rule 3: witnesses. Per device, names in order.
        var lanes: [DeviceID: [RevisionName]] = [:]
        for n in names { lanes[n.device, default: []].append(n) }
        var witnesses = Set<RevisionName>()
        for t in targets {
            for (device, lane) in lanes where device != t.device {
                var lo = 0, hi = lane.count
                while lo < hi {
                    let mid = lo + (hi - lo) / 2
                    if lane[mid] <= t { lo = mid + 1 } else { hi = mid }
                }
                if lo < lane.count, candidates.contains(lane[lo]) { witnesses.insert(lane[lo]) }
            }
        }
        candidates.subtract(witnesses)
        // A positioned snapshot of a revision that stays is kept (it is what makes it complete).
        let staying = Set(names).subtracting(candidates)
        let stayingKeys = Set(staying.map(RevisionKey.init))
        for (name, asOf) in positioned where stayingKeys.contains(asOf) { candidates.remove(name) }
        return CompactionSelection(candidates: candidates, targets: targets.sorted(), witnesses: witnesses,
                                   positioned: positioned)
    }

    /// True when compacting a note with these revisions' metadata in `mode`
    /// may delete something; false means `plan` would return an empty plan,
    /// so the note need not be read in full.
    public static func mayDelete(_ index: [RevisionMeta], noteId: UUID, mode: CompactionMode, now: Date) -> Bool {
        !select(index.map { $0.hollow(noteId: noteId) }, mode: mode, now: now).candidates.isEmpty
    }
}

extension CompactionPlanner {
    /// The revision compaction keeps so that the note's `created` cannot move
    /// (format.md §5.3, §5.4): `created` is the earliest of the snapshots'
    /// recorded `created` and the `wall` of the first revision by
    /// `(hlc, device, seq)`. When another revision has an earlier `wall` (its
    /// device's clock was behind, its HLC ahead from what it had seen),
    /// deleting the first revision would make that one first and move
    /// `created`, in the current state and in every version. Nil when no
    /// revision has a `wall` earlier than the first's.
    public static func createdAnchor(_ revisions: [Revision]) -> RevisionName? {
        guard let first = revisions.min(by: { $0.name < $1.name }),
              revisions.contains(where: { $0.wall < first.wall }) else { return nil }
        return first.name
    }
}

extension NoteState {
    /// The state without the bookkeeping that legitimately differs between
    /// equivalent sets of revisions: stroke tombstones are dropped once the
    /// adding revision is covered (format.md §5.4).
    var comparable: NoteState {
        var s = self
        if var t = s.tombstones {
            t.strokes = []
            s.tombstones = t.isEmpty ? nil : t
        }
        return s
    }
}

extension Vault {
    /// Plans compacting note `noteId` as this device (`CompactionPlanner.plan`)
    /// from the note as on disk; nothing is written.
    ///
    /// - Throws: `CompactionError.unreadableRevision` if any revision cannot
    ///   be read, or as `CompactionPlanner.plan`.
    public func planCompaction(_ noteId: UUID, loaded: LoadedNote, mode: CompactionMode, now: Date = Date(),
                               device: DeviceID, clock: inout HybridClock, app: String) throws -> CompactionPlan {
        try requireMigrated()
        // No compaction or thinning, not even planned, once newer content is seen (format.md §7.3).
        if loaded.newer != nil { noteNewerContent(in: noteId) }
        try requireWritable()
        if let (name, _) = loaded.failures.min(by: { $0.key < $1.key }) {
            throw CompactionError.unreadableRevision(name.filename)
        }
        guard !loaded.revisions.isEmpty else {
            return CompactionPlan(noteId: noteId, snapshots: [], deletions: [], witnesses: [], targets: [])
        }
        return try CompactionPlanner.plan(loaded.revisions, mode: mode, now: now, device: device, clock: &clock,
                                          wall: now, app: app)
    }

    /// Carries out a plan: writes its snapshots, then deletes its files.
    /// Every prefix of this is safe (format.md §5.8.4), so an error part way
    /// leaves a correct vault.
    public func execute(_ plan: CompactionPlan) throws {
        try requireMigrated()
        try requireWritable()
        for s in plan.snapshots { try write(s) }
        let dir = noteURL(plan.noteId)
        for n in plan.deletions { try FileIO.remove(dir.appendingPathComponent(n.filename)) }
    }

    /// Bytes on disk of the plan's deletions (files that cannot be sized count 0).
    public func deletedBytes(_ plan: CompactionPlan) -> Int {
        let dir = noteURL(plan.noteId)
        return plan.deletions.reduce(0) { sum, n in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n.filename).path))?[.size]
            return sum + ((size as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Bytes the plan's snapshots will take on disk: each encoded, framed and
    /// encrypted as `write` would (the age header varies by a few bytes).
    public func addedBytes(_ plan: CompactionPlan) throws -> Int {
        try plan.snapshots.reduce(0) { $0 + (try encodedRevision($1).count) }
    }
}

extension CompactionPlanner {
    /// Revisions no compactor or thinner of this format ever deletes
    /// (format.md §5.3, §5.8.1, §5.8.4): checkpoints, and the first revision
    /// while another has an earlier `wall` (`createdAnchor`).
    public static func neverDeleted(_ revisions: [Revision]) -> Set<RevisionName> {
        var out = Set(revisions.filter { $0.kind == .delta && $0.checkpoint != nil }.map(\.name))
        if let anchor = createdAnchor(revisions) { out.insert(anchor) }
        return out
    }

    /// Whether deleting `gone` from `revisions` (all the note's revisions,
    /// readable) keeps every checkpoint that is complete now complete
    /// (format.md §5.8.4 G2): what a compactor or thinner of this format
    /// guarantees, with the positioned snapshots and witnesses it keeps. A
    /// sync judging deletions it did not make (a server's, security review
    /// 2026-10, stage 4, S2) refuses a set that breaks it.
    public static func deletionKeepsCheckpoints(_ gone: Set<RevisionName>, from revisions: [Revision], now: Date) -> Bool {
        let revs = revisions.sorted { $0.name < $1.name }
        guard !gone.isEmpty, let last = revs.last else { return true }
        let targets = NoteHistory.restorePoints(revs).filter { $0.complete && $0.isCheckpoint && !gone.contains($0.name) }
            .map(\.name).sorted()
        guard !targets.isEmpty else { return true }
        // As in `plan`: a stand-in snapshot ordered after everything says which revisions are gone
        // (covered elsewhere) and covers nothing at or before any target.
        var goneSet = Included()
        for r in revs where gone.contains(r.name) {
            switch r.body {
            case .delta: goneSet.insert(device: r.device, seq: r.seq)
            case .snapshot(let inc, _): goneSet = goneSet.union(inc).union(Included([r.device: .init(upTo: 0, extra: [r.seq])]))
            }
        }
        let standIn = Revision(noteId: last.noteId, device: .zero, seq: 1,
                               hlc: HLC(millis: HLC.maxMillis, counter: HLC.maxCounter) ?? .zero, wall: now, app: "",
                               body: .snapshot(included: goneSet, state: NoteState(meta: NoteMeta(created: now))))
        let survivors = revs.filter { !gone.contains($0.name) } + [standIn]
        return Completeness(survivors, unreadable: []).isComplete(at: targets).allSatisfy { $0 }
    }
}
