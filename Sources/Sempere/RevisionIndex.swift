import Foundation

// MARK: - Revision metadata, indexed once (docs/format.md §5.8, §10)
//
// Thinning and compaction decide what may go from names, `wall`s, checkpoint
// and session fields, snapshot coverage and `asOf` alone
// (`CompactionPlanner.select`). Revision files are write-once, so that
// metadata never changes for a file name: the per-device `SummaryCache` keeps
// it next to the summary made from the same files, and a thinning pass reads
// in full only the notes that have something to delete.

/// What compaction needs to know about one revision, without its ops or state.
public struct RevisionMeta: Hashable, Sendable {
    public var name: RevisionName
    public var wall: Date
    /// Deltas only (format.md §5.8.1).
    public var checkpoint: Checkpoint?
    /// Deltas only (format.md §5.8.2).
    public var session: String?
    /// Snapshots only (format.md §5.8.3).
    public var asOf: RevisionKey?
    /// Snapshots only: their `included`.
    public var included: Included?

    public init(_ revision: Revision) {
        name = revision.name
        wall = revision.wall
        switch revision.body {
        case .delta:
            checkpoint = revision.checkpoint
            session = revision.session
        case .snapshot(let inc, _):
            asOf = revision.asOf
            included = inc
        }
    }

    /// A revision with this metadata and no content (no ops; a snapshot with
    /// an empty state), for the metadata-only planning stage.
    public func hollow(noteId: UUID) -> Revision {
        let body: Revision.Body = name.kind == .delta
            ? .delta(ops: []) : .snapshot(included: included ?? Included(), state: NoteState(meta: NoteMeta(created: wall)))
        return Revision(noteId: noteId, device: name.device, seq: name.seq, hlc: name.hlc, wall: wall, app: "",
                        body: body, session: session, checkpoint: checkpoint, asOf: asOf)
    }
}

extension RevisionMeta: Codable {
    private enum CodingKeys: String, CodingKey { case n, w, c, s, a, i }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = RevisionName(try c.decode(String.self, forKey: .n)) else {
            throw DecodingError.dataCorruptedError(forKey: .n, in: c, debugDescription: "revision name")
        }
        self.name = name
        wall = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .w))
        if let cp = try c.decodeIfPresent(String.self, forKey: .c) { checkpoint = Checkpoint(read: cp) }
        session = try c.decodeIfPresent(String.self, forKey: .s)
        if let a = try c.decodeIfPresent(String.self, forKey: .a) {
            guard let key = RevisionKey(a) else {
                throw DecodingError.dataCorruptedError(forKey: .a, in: c, debugDescription: "asOf")
            }
            asOf = key
        }
        included = try c.decodeIfPresent(Included.self, forKey: .i)
        guard (name.kind == .snapshot) == (included != nil) else {
            throw DecodingError.dataCorruptedError(forKey: .i, in: c, debugDescription: "included on a delta, or none on a snapshot")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name.filename, forKey: .n)
        try c.encode(wall.timeIntervalSince1970, forKey: .w)
        if let checkpoint { try c.encode(checkpoint.name ?? "", forKey: .c) }
        try c.encodeIfPresent(session, forKey: .s)
        try c.encodeIfPresent(asOf?.description, forKey: .a)
        try c.encodeIfPresent(included, forKey: .i)
    }
}

/// A note's revision metadata, oldest first, and whether it came from the cache.
public struct RevisionIndex: Hashable, Sendable {
    public var noteId: UUID
    public var revisions: [RevisionMeta]
    /// True when nothing was decrypted (the `SummaryCache` had it).
    public var cached: Bool
}

extension Vault {
    /// The metadata of every revision of `noteId`: from `cache` when its
    /// entry was made from exactly the files on disk, else from a read
    /// without stroke geometry, whose summary and metadata are then stored in
    /// `cache` (not saved; the caller saves once).
    ///
    /// - Throws: `CompactionError.unreadableRevision` when a revision cannot
    ///   be read (nothing may then be deleted), or `VaultError`.
    public func revisionIndex(of noteId: UUID, cache: SummaryCache?) throws -> RevisionIndex {
        try requireMigrated()
        let names = try revisionNames(of: noteId)
        if let hit = cache?.history(for: noteId, revisions: names) {
            return RevisionIndex(noteId: noteId, revisions: hit, cached: true)
        }
        let loaded = try loadNote(noteId, names: names, detail: .withoutStrokePoints)
        if let (name, _) = loaded.failures.min(by: { $0.key < $1.key }) {
            throw CompactionError.unreadableRevision(name.filename)
        }
        let metas = loaded.revisions.sorted { $0.name < $1.name }.map(RevisionMeta.init)
        cache?.store(summary(of: noteId, loaded: loaded), revisions: names, history: metas)
        return RevisionIndex(noteId: noteId, revisions: metas, cached: false)
    }
}

// MARK: - Carrying out a plan with its snapshots encoded once

/// A compaction plan with its snapshots already encoded (framed and
/// encrypted): reporting their size and writing them costs one encoding.
public struct PreparedCompaction: Sendable {
    public var plan: CompactionPlan
    /// The encoded files of `plan.snapshots`, in order; empty once
    /// carried out or dropped (`withoutData`).
    var encoded: [Data]
    /// Bytes on disk of the plan's deletions.
    public var bytesDeleted: Int
    /// Bytes the plan's snapshots take.
    public var bytesAdded: Int

    init(plan: CompactionPlan, encoded: [Data], bytesDeleted: Int) {
        self.plan = plan
        self.encoded = encoded
        self.bytesDeleted = bytesDeleted
        bytesAdded = encoded.reduce(0) { $0 + $1.count }
    }

    /// The plan and its sizes without the encoded snapshots (a dry run's
    /// report holds no note content in memory). Cannot be carried out.
    public var withoutData: PreparedCompaction {
        var p = self
        p.encoded = []
        return p
    }

    /// Nothing to write or delete in note `id`.
    public static func nothing(_ id: UUID) -> PreparedCompaction {
        PreparedCompaction(plan: CompactionPlan(noteId: id, snapshots: [], deletions: [], witnesses: [], targets: []),
                           encoded: [], bytesDeleted: 0)
    }

    /// False once the encoded snapshots were dropped.
    public var canExecute: Bool { encoded.count == plan.snapshots.count }
}

extension Vault {
    /// Encodes the plan's snapshots and sizes its deletions; writes nothing.
    public func prepare(_ plan: CompactionPlan) throws -> PreparedCompaction {
        PreparedCompaction(plan: plan, encoded: try plan.snapshots.map { try encodedRevision($0) },
                           bytesDeleted: deletedBytes(plan))
    }

    /// Carries out a prepared plan: writes its snapshots, then deletes its
    /// files (as `execute(_:)`; every prefix is safe).
    public func execute(_ prepared: PreparedCompaction) throws {
        precondition(prepared.canExecute, "a prepared compaction without its snapshots")
        try requireMigrated()
        try requireWritable()
        for (s, data) in zip(prepared.plan.snapshots, prepared.encoded) { try writeEncoded(data, of: s) }
        let dir = noteURL(prepared.plan.noteId)
        for n in prepared.plan.deletions { try FileIO.remove(dir.appendingPathComponent(n.filename)) }
    }
}

extension Vault {
    /// Plans and prepares compacting one note (format.md §5.3, §5.8.4) as
    /// this device; writes nothing. A note whose revision metadata
    /// (`revisionIndex`, from `cache` when it can) shows nothing to delete is
    /// not read in full and gets an empty plan: what `planCompaction` would
    /// return for it. Otherwise the note is read in full, planned with
    /// `clock` and its snapshots encoded once (`prepare`).
    ///
    /// - Throws: as `revisionIndex` and `planCompaction`.
    public func prepareCompaction(_ noteId: UUID, mode: CompactionMode, now: Date = Date(), device: DeviceID,
                                  clock: inout HybridClock, app: String, cache: SummaryCache?) throws -> PreparedCompaction {
        guard let loaded = try loadForCompaction(noteId, mode: mode, now: now, cache: cache) else {
            return .nothing(noteId)
        }
        let plan = try planCompaction(noteId, loaded: loaded, mode: mode, now: now, device: device,
                                      clock: &clock, app: app)
        return try prepare(plan)
    }

    /// The note read in full for compacting it, or nil when its revision
    /// metadata (`revisionIndex`, from `cache` when it can) shows nothing
    /// `mode` may delete; then nothing more of it is read.
    ///
    /// - Throws: as `revisionIndex` and `loadNote`.
    public func loadForCompaction(_ noteId: UUID, mode: CompactionMode, now: Date = Date(),
                                  cache: SummaryCache?) throws -> LoadedNote? {
        let index = try revisionIndex(of: noteId, cache: cache)
        guard CompactionPlanner.mayDelete(index.revisions, noteId: noteId, mode: mode, now: now) else { return nil }
        return try loadNote(noteId)
    }
}

extension Vault {
    /// `prepareCompaction` for many notes on up to `maxConcurrency` threads
    /// (0: `Parallel.defaultWidth`). Each note is planned with its own copy of
    /// `clock`; `clock` then observes every snapshot planned, so later
    /// readings sort after them. Two notes may get snapshots with the same
    /// reading, which is harmless: readings order the revisions of one note
    /// (`(hlc, device, seq)`, format.md §5) and stamp its registers, never
    /// across notes. With `execute`, each note's plan is carried out as soon
    /// as it is made (snapshots, then deletions); a note that fails is left
    /// as it was or, part way, in a safe state (format.md §5.8.4). Encoded
    /// snapshots are not kept in the results, so memory stays at about
    /// `maxConcurrency` notes. `progress(done, total)` is called once per
    /// note, from worker threads.
    ///
    /// The caller saves `clock` afterwards; a crash before that is harmless,
    /// since every writer observes a note's revisions before writing to it.
    ///
    /// - Returns: per note, in `ids` order, the prepared plan or the error.
    public func prepareCompactions(_ ids: [UUID], mode: CompactionMode, now: Date = Date(), device: DeviceID,
                                   clock: inout HybridClock, app: String, cache: SummaryCache?, execute: Bool,
                                   maxConcurrency: Int = 0, progress: (@Sendable (Int, Int) -> Void)? = nil)
        -> [(id: UUID, result: Result<PreparedCompaction, Error>)] {
        let start = clock
        let counter = ProgressCounter()
        let total = ids.count
        let results = Parallel.map(ids, width: maxConcurrency > 0 ? maxConcurrency : Parallel.defaultWidth) { id in
            Result { () throws -> PreparedCompaction in
                var c = start
                let p = try prepareCompaction(id, mode: mode, now: now, device: device, clock: &c, app: app, cache: cache)
                if execute, !p.plan.isEmpty { try self.execute(p) }
                return p.withoutData
            }.mapError { $0 as Error }
        } done: { _, _ in
            progress?(counter.increment(), total)
        }
        for case .success(let p) in results {
            for s in p.plan.snapshots { _ = clock.observe(s.hlc, wall: now) }
        }
        return zip(ids, results).map { ($0, $1) }
    }
}

// MARK: - The two thinning rules users choose from

/// What a thinning run applies (format.md §5.8.4), with the words the CLI and
/// the app show for it, so a preview always states its rule and what it keeps.
public enum ThinningRule: Hashable, Sendable {
    /// The configured window: only versions older than this many days are thinned.
    case olderThan(days: Int)
    /// No window: every autosave goes except each editing session's newest
    /// save; checkpoints stay.
    case allButCheckpoints

    /// The compaction mode: a cutoff of `days`, or of zero for `allButCheckpoints`
    /// (every revision whose `wall` is not in the future is in the thinned range).
    public var mode: CompactionMode {
        switch self {
        case .olderThan(let days): return .thin(olderThan: Double(max(days, 0)) * 86_400)
        case .allButCheckpoints: return .thin(olderThan: 0)
        }
    }

    /// "Thin versions older than 30 days" / "Thin everything except checkpoints".
    public var title: String {
        switch self {
        case .olderThan(let days): return "Thin versions older than \(Self.days(days))"
        case .allButCheckpoints: return "Thin everything except checkpoints"
        }
    }

    /// The rule and what it keeps, in one sentence.
    public var explanation: String {
        switch self {
        case .olderThan(let days):
            return "Removes autosaves older than \(Self.days(days)). Keeps every checkpoint (saved and imported "
                + "versions), the newest save of each editing session, the note's newest version and everything "
                + "from the last \(Self.days(days))."
        case .allButCheckpoints:
            return "Removes every autosave, however recent, except the newest save of each editing session. Keeps "
                + "every checkpoint (saved and imported versions) and the note's newest version."
        }
    }

    static func days(_ n: Int) -> String {
        switch n {
        case 365: return "1 year"
        case 1: return "1 day"
        default: return "\(n) days"
        }
    }
}
