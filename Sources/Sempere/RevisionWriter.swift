import Foundation

// MARK: - The one revision writer (format.md §5)
//
// Every delta any front end writes is stamped, numbered and placed by `Vault.writeDelta(_:to:after:clock:…)`:
// it observes what the writer read of the note, ticks the device clock (saved before the file is placed),
// takes the next `seq`, writes the revision (read-only latch, partial-copy check, write ledger before
// placement: `Vault.write`) and retries once with a re-read `seq` when another writer of this device took
// it. Two holders give it the clock:
//
// - `DeviceClock` (an actor): one per device state file for the life of a process that writes from many
//   tasks (the app). `NoteWriter` writes through it.
// - `DeviceClockFile` (a value): the same file opened for one synchronous call (`Vault.apply` and the CLI).
//   It refuses a file a live `DeviceClock` holds: a second clock ticking on one state file could hand out
//   readings the first already issued, or save an older clock over a newer one.

// Its timings go to a `PerfSink` (Platform/PerfSink.swift; the app's signposts, nothing in the CLI).

/// One device state file (`DeviceState`: this installation's device id and hybrid clock, format.md §5),
/// opened by a synchronous caller for the length of one operation. Every reading it hands out is saved
/// before it is returned, so the clock only moves forward across runs.
public struct DeviceClockFile: Sendable {
    /// The state file.
    public let url: URL
    /// This installation's device id.
    public let device: DeviceID
    private var state: DeviceState

    /// The clock as it is now (last reading issued, or observed).
    public var clock: HybridClock { state.clock }

    /// Opens the state file at `url`, creating it with a fresh device id.
    ///
    /// - Throws: `VaultError.io` when the file cannot be read or created, or when a live `DeviceClock` of
    ///   this process holds it (write through that clock instead: one clock per state file).
    public init(url: URL) throws {
        if DeviceClockHolders.shared.holds(url) {
            throw VaultError.io("device state \(url.path) is held by this process's DeviceClock; write through it")
        }
        try self.init(loading: url)
    }

    /// Opens without the holder check (the `DeviceClock` that is about to hold it).
    init(loading url: URL) throws {
        self.url = url
        state = try DeviceState.loadOrCreate(at: url)
        device = state.device
    }

    /// Writes the clock to the file.
    public func save() throws { try state.save(to: url) }

    /// Merges `readings` seen in revisions of the vault, so the next reading sorts after them (not saved:
    /// the next `tick` saves it). True when the clock moved.
    @discardableResult
    public mutating func observe(_ readings: [HLC], wall: Date) -> Bool {
        var c = state.clock
        for r in readings { c.observe(r, wall: wall) }
        guard c != state.clock else { return false }
        state.clock = c
        return true
    }

    /// The reading of a revision about to be written; saved before it is returned.
    public mutating func tick(wall: Date) throws -> HLC {
        var c = state.clock
        let hlc = c.tick(wall: wall)
        state.clock = c
        try save()
        return hlc
    }

    /// Runs `body` on the clock. With `save`, keeps what it did to the clock and saves it, also when `body`
    /// throws (it may have written revisions with those readings before it failed); without, forgets it
    /// (a dry run).
    public mutating func withClock<T>(save: Bool, _ body: (inout HybridClock) throws -> T) throws -> T {
        var c = state.clock
        let result = Result { try body(&c) }
        if save, c != state.clock {
            state.clock = c
            try self.save()
        }
        return try result.get()
    }
}

/// The state files live `DeviceClock`s hold in this process (`DeviceClockFile` refuses them).
final class DeviceClockHolders: @unchecked Sendable {
    static let shared = DeviceClockHolders()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    func add(_ url: URL) { lock.withLock { counts[Self.key(url), default: 0] += 1 } }

    func remove(_ url: URL) {
        lock.withLock {
            let k = Self.key(url)
            if let n = counts[k], n > 1 { counts[k] = n - 1 } else { counts[k] = nil }
        }
    }

    func holds(_ url: URL) -> Bool { lock.withLock { counts[Self.key(url)] != nil } }
}

/// This installation's device id and hybrid clock (format.md §5), kept in a device state file and saved
/// after every reading, so readings never repeat across launches. One per state file for the life of the
/// process: every `NoteWriter` of the process writes with it, and long work that stamps revisions itself
/// (an import, thinning's snapshots) runs inside `withClock`.
public actor DeviceClock {
    /// This installation's device id.
    public nonisolated let device: DeviceID
    /// The state file.
    public nonisolated let url: URL
    /// The `app` of every revision written with this clock unless the writer names another (format.md §5.1).
    public nonisolated let app: String
    /// Where writers report how long their reads take.
    public nonisolated let perf: any PerfSink
    private var file: DeviceClockFile
    /// Told the note of every revision written with this clock (the app updates that note's attachment index).
    private let onWrite: (@Sendable (UUID) -> Void)?

    /// Loads the state file at `url`, creating it with a fresh device id.
    public init(url: URL, app: String, perf: any PerfSink = NoPerfSink(),
                onWrite: (@Sendable (UUID) -> Void)? = nil) throws {
        let file = try DeviceClockFile(loading: url)
        self.file = file
        self.device = file.device
        self.url = url
        self.app = app
        self.perf = perf
        self.onWrite = onWrite
        DeviceClockHolders.shared.add(url)
    }

    deinit { DeviceClockHolders.shared.remove(url) }

    /// A reading for a revision about to be written; saved before it is returned.
    public func tick(wall: Date = Date()) throws -> HLC { try file.tick(wall: wall) }

    /// Runs `body` on the clock; with `save`, keeps (and saves) what it did to it, also when it throws,
    /// otherwise forgets it (a dry run). Thinning plans its snapshots and an import stamps its notes this way.
    public func withClock<T: Sendable>(save: Bool, _ body: @Sendable (inout HybridClock) throws -> T) throws -> T {
        try file.withClock(save: save, body)
    }

    /// Merges readings seen in revisions read from the vault, so the next local reading sorts after them.
    public func observe(_ readings: [HLC], wall: Date = Date()) {
        guard file.observe(readings, wall: wall) else { return }
        try? file.save()   // a lost observation only weakens ordering, never correctness
    }

    /// Writes one delta with this clock (`Vault.writeDelta(_:to:after:clock:…)`) and tells `onWrite`.
    /// `wall` nil: now.
    public func writeDelta(_ ops: [Op], to noteId: UUID, in vault: Vault, after view: WriteReadings,
                           app: String? = nil, wall: Date? = nil, session: String? = nil,
                           checkpoint: Checkpoint? = nil) throws -> Revision {
        let revision = try vault.writeDelta(ops, to: noteId, after: view, clock: &file, app: app ?? self.app,
                                            wall: wall ?? Date(), session: session, checkpoint: checkpoint)
        onWrite?(noteId)
        return revision
    }
}

/// Appends one note's deltas with a `DeviceClock`: keeps this writer's next `seq`, and reads what a write
/// must observe off the caller's actor. An editor keeps one for the note it shows; browser edits, restores
/// and checkpoints use the static helpers, which read the note first.
public actor NoteWriter {
    public nonisolated let vault: Vault
    public nonisolated let noteID: UUID
    public nonisolated let clock: DeviceClock
    /// The `app` of every revision written (format.md §5.1).
    public nonisolated let app: String
    /// The wall-clock time of every revision this writer writes; nil: the time of each write.
    /// Only the demo vault for the App Store screenshots sets it.
    public nonisolated let wall: Date?
    /// The editing session written on every delta (format.md §5.8.2): an editor's writer has one per
    /// opening of the note; browser edits none.
    public nonisolated let session: String?
    private var nextSeq: Int

    /// `app` nil: the clock's.
    public init(vault: Vault, noteID: UUID, clock: DeviceClock, nextSeq: Int, app: String? = nil,
                wall: Date? = nil, session: String? = nil) {
        self.vault = vault; self.noteID = noteID; self.clock = clock; self.nextSeq = nextSeq
        self.app = app ?? clock.app; self.wall = wall; self.session = session
    }

    /// Makes the next `seq` at least `seq`: a revision of this device that another writer (a browser
    /// edit) added since this one started.
    public func raiseNextSeq(to seq: Int) {
        nextSeq = max(nextSeq, seq)
    }

    /// Writes one delta of `ops` to a note that is not loaded (the browser's edits): the clock first
    /// observes the reading of every authenticated revision of the note (`readClock`: decrypted on
    /// several cores, no stroke geometry decoded), so these ops win last-writer-wins races against what
    /// is already there. Creates the note when it has no revisions yet. `verify` runs inside that read,
    /// before and after the note is loaded, and throws to refuse a note whose files are not all local (a
    /// partial copy's `partialNoteVerifier`): `seq` and the clock must never come from a partial log.
    @discardableResult
    public static func append(_ ops: [Op], to noteID: UUID, vault: Vault, clock: DeviceClock, app: String? = nil,
                              wall: Date? = nil, checkpoint: Checkpoint? = nil,
                              verify: (@Sendable () throws -> Void)? = nil) async throws -> RevisionName {
        let view = try await readClock(noteID, vault: vault, clock: clock, verify: verify)
        await clock.observe(view.readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: view.nextSeq, app: app, wall: wall)
        return try await writer.write(ops, checkpoint: checkpoint)
    }

    /// Like `append(_:to:...)`, but `build` computes the ops from the note as it is on disk at write time
    /// (nil: no readable revision). Writes nothing when it returns no ops. Tag edits use this: a
    /// `removeTag` observes every instance on disk, not just those in a possibly stale summary
    /// (format.md §5.4.1). `verify` is as for `append(_:to:...)`.
    ///
    /// With `detail: .withoutStrokePoints` the note is read without stroke geometry, which is much
    /// cheaper for an inked note: only for builders that look at the note's metadata (`meta`, `tagSet`,
    /// `deleted`) and return only metadata ops (`Op.isMetadataOnly`: move, rename, favorite, tags,
    /// delete). Should such a builder return any other op, it is run again on the note read in full, and
    /// that result is written: ops built from a state without stroke points are never written.
    ///
    /// Unlike `Vault.apply(to:deviceState:app:wall:building:)`, `build` runs on the revisions that read
    /// even when others did not (a note that cannot be read can still be renamed, moved or deleted).
    @discardableResult
    public static func append(to noteID: UUID, vault: Vault, clock: DeviceClock, app: String? = nil,
                              detail: RevisionDetail = .full, verify: (@Sendable () throws -> Void)? = nil,
                              building build: @escaping @Sendable (NoteState?) -> [Op]) async throws -> RevisionName? {
        let (view, ops) = try await read(noteID, vault: vault, clock: clock, detail: detail, verify: verify,
                                         build: { loaded in
            build(loaded.revisions.isEmpty ? nil : try NoteReducer.reconstruct(loaded.revisions))
        }, accept: { ops in detail == .full || ops.allSatisfy(\.isMetadataOnly) })
        guard !ops.isEmpty else { return nil }
        await clock.observe(view.readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: view.nextSeq, app: app)
        return try await writer.write(ops)
    }

    /// Restores a note to the revision `point` (format.md §5.7) by writing one delta, through the same
    /// path as every other edit. Everything is decided inside one read of the note on disk: the note's
    /// revisions must all be readable (the current state has to be known exactly), `point` must be a
    /// complete restore point, and the ops are `NoteHistory.restoreOps` from the merged current state to
    /// the state as of `point`. `verify` is as for `append(_:to:...)`.
    ///
    /// - Returns: the delta written and what it changes; nil when the note already matches `point`
    ///   (nothing is written).
    /// - Throws: `VaultError.revision` if any revision is unreadable, `HistoryError`, `NoteLogError`, or
    ///   a write error.
    @discardableResult
    public static func restore(_ noteID: UUID, to point: RevisionName, vault: Vault, clock: DeviceClock,
                               app: String? = nil, verify: (@Sendable () throws -> Void)? = nil)
        async throws -> (name: RevisionName, summary: RestoreSummary)? {
        let (view, ops) = try await read(noteID, vault: vault, clock: clock, verify: verify, build: { loaded in
            if let (name, error) = loaded.failures.min(by: { $0.key < $1.key }) {
                throw VaultError.revision(name: name.filename, error)
            }
            let target = try NoteHistory.state(loaded.revisions, at: point)
            return NoteHistory.restoreOps(current: try NoteReducer.reconstruct(loaded.revisions), target: target)
        })
        guard !ops.isEmpty else { return nil }
        await clock.observe(view.readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: view.nextSeq, app: app)
        return (try await writer.write(ops), RestoreSummary(ops))
    }

    /// The readings the clock observes before writing to `noteID`, and this device's next `seq` there
    /// (`Vault.writeReadings`, format.md §5 "What a writer observes"): every revision is decrypted (on
    /// several cores) and its header checked, so newer content sets the vault read-only before the
    /// write, but no stroke geometry is decoded. `verify` runs before and after.
    public static func readClock(_ noteID: UUID, vault: Vault, clock: DeviceClock,
                                 verify: (@Sendable () throws -> Void)?) async throws -> WriteReadings {
        let device = clock.device, perf = clock.perf
        return try await Task.detached(priority: .userInitiated) {
            try perf.measure("writer.read", "headers") {
                try verify?()
                let view = try vault.writeReadings(of: noteID, device: device)
                try verify?()
                return view
            }
        }.value
    }

    /// The note's readings and this device's next `seq`, and the ops `build` makes from the note loaded
    /// at `detail`. `verify` runs before and after loading. When `accept` refuses the ops built from a
    /// note read without stroke points, the note is read again in full and `build` runs on that.
    private static func read(_ noteID: UUID, vault: Vault, clock: DeviceClock, detail: RevisionDetail = .full,
                             verify: (@Sendable () throws -> Void)?,
                             build: @escaping @Sendable (LoadedNote) throws -> [Op],
                             accept: @escaping @Sendable ([Op]) -> Bool = { _ in true }) async throws -> (WriteReadings, [Op]) {
        let device = clock.device, perf = clock.perf
        return try await Task.detached(priority: .userInitiated) {
            try perf.measure("writer.read", "load") {
                try verify?()
                var loaded = try vault.loadNoteConcurrently(noteID, detail: detail)
                try verify?()
                var ops = try build(loaded)
                if detail != .full, !accept(ops) {
                    loaded = try vault.loadNoteConcurrently(noteID)
                    try verify?()
                    ops = try build(loaded)
                }
                return (try vault.writeReadings(of: loaded, noteId: noteID, device: device), ops)
            }
        }.value
    }

    // MARK: Attachments (format.md §8.1.4)

    /// Writes the file at `file` as a blob of this note (streamed: steps 1–3 of format.md §8.1.4) and
    /// returns its reference; write the delta that references it afterwards (step 4).
    public func addBlob(from file: URL, type: String, edits: [ByteEdit] = []) throws -> BlobRef {
        try vault.writeBlob(note: noteID, contentsOf: file, type: type, edits: edits)
    }

    /// `addBlob(from:type:)` for content in memory (at most 16 MiB is sensible).
    public func addBlob(_ data: Data, type: String) throws -> BlobRef {
        try vault.writeBlob(note: noteID, data, type: type)
    }

    /// Copies the blob `ref` of note `source` into this note (copy and paste of items between notes),
    /// before the delta that references it. The source is verified as it is read. No-op when this note
    /// already has a valid copy.
    public func copyBlob(_ ref: BlobRef, from source: UUID) throws {
        try vault.copyBlob(ref, from: source, to: noteID)
    }

    /// Writes one delta holding `ops` (`DeviceClock.writeDelta`). A `seq` already taken (a browser edit
    /// wrote to the note) is re-read from disk and the write retried once.
    @discardableResult
    public func write(_ ops: [Op], checkpoint: Checkpoint? = nil) async throws -> RevisionName {
        let revision = try await clock.writeDelta(ops, to: noteID, in: vault, after: WriteReadings(readings: [], nextSeq: nextSeq),
                                                  app: app, wall: wall, session: session, checkpoint: checkpoint)
        nextSeq = revision.seq + 1
        return revision.name
    }
}

extension Op {
    /// True for ops that change only the note's metadata, tags or deleted flag: what a builder may
    /// return from a state read without stroke points (`NoteWriter.append(to:detail:building:)`).
    /// Exhaustive, so a new op kind has to be classified here.
    public var isMetadataOnly: Bool {
        switch self {
        case .setMeta, .addTag, .removeTag, .deleteNote, .restoreNote:
            return true
        case .addStroke, .removeStroke, .addPage, .removePage, .setPageOrder, .setPageRecognition, .setPagePaper,
             .addItem, .removeItem, .setItem, .addRecording, .removeRecording, .setRecording:
            return false
        }
    }
}
