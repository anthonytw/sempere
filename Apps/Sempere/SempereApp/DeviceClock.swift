import Foundation
import Sempere

/// This installation's device id and hybrid clock (format.md §5), kept in
/// the package's `DeviceState` file inside the app container and saved after
/// every reading, so readings never repeat across launches.
actor DeviceClock {
    /// This installation's device id.
    nonisolated let device: DeviceID
    private var state: DeviceState
    private let url: URL
    /// Told the note of every revision a `NoteWriter` wrote with this clock
    /// (the model updates that note's attachment index).
    private let onWrite: (@Sendable (UUID) -> Void)?

    /// `Application Support/Sempere/device.json` in the app's container
    /// (on iPad and in the Catalyst sandbox that is per installation).
    static var defaultURL: URL { AppSupport.sempere.appendingPathComponent("device.json") }

    /// Loads the state file at `url`, creating it with a fresh device id.
    init(url: URL = DeviceClock.defaultURL, onWrite: (@Sendable (UUID) -> Void)? = nil) throws {
        let loaded = try DeviceState.loadOrCreate(at: url)
        self.url = url
        self.onWrite = onWrite
        self.state = loaded
        self.device = loaded.device
    }

    /// A reading for a revision about to be written; saved before it is returned.
    func tick(wall: Date = Date()) throws -> HLC {
        var clock = state.clock
        let hlc = clock.tick(wall: wall)
        state.clock = clock
        try state.save(to: url)
        return hlc
    }

    /// Runs `body` on the clock; with `save`, keeps (and saves) what it did to
    /// it, otherwise forgets it (a dry run). Thinning builds its snapshots this way.
    func withClock<T: Sendable>(save: Bool, _ body: @Sendable (inout HybridClock) throws -> T) throws -> T {
        var clock = state.clock
        let out = try body(&clock)
        if save, clock != state.clock {
            state.clock = clock
            try state.save(to: url)
        }
        return out
    }

    /// A revision of `note` stamped by this clock was written.
    func didWrite(_ note: UUID) { onWrite?(note) }

    /// Merges readings seen in revisions read from the vault, so the next
    /// local reading sorts after them.
    func observe(_ readings: [HLC], wall: Date = Date()) {
        guard !readings.isEmpty else { return }
        var clock = state.clock
        for r in readings { clock.observe(r, wall: wall) }
        guard clock != state.clock else { return }
        state.clock = clock
        try? state.save(to: url)   // a lost observation only weakens ordering, never correctness
    }
}

/// Appends one note's deltas: picks `seq`, stamps the clock, writes the
/// revision (format.md §5). Vault I/O runs on this actor, off the main actor.
/// In iCloud Drive (`coordinated`) each write is a coordinated write on the
/// note's folder, so iCloud uploads it (`CloudVault`).
actor NoteWriter {
    let vault: Vault
    let noteID: UUID
    let clock: DeviceClock
    let app: String
    let coordinated: Bool
    /// The wall-clock time of every revision this writer writes; nil: the time of each write.
    /// Only the demo vault for the App Store screenshots sets it (`DemoVault`).
    let wall: Date?
    /// The editing session written on every delta (format.md §5.8.2): an
    /// editor's writer has one per opening of the note; browser edits none.
    let session: String?
    private var nextSeq: Int

    init(vault: Vault, noteID: UUID, clock: DeviceClock, nextSeq: Int, app: String = NoteWriter.appName,
         coordinated: Bool = false, wall: Date? = nil, session: String? = nil) {
        self.vault = vault; self.noteID = noteID; self.clock = clock; self.nextSeq = nextSeq; self.app = app
        self.coordinated = coordinated; self.wall = wall; self.session = session
    }

    /// Makes the next `seq` at least `seq`: a revision of this device that
    /// another writer (a browser edit) added since this one started.
    func raiseNextSeq(to seq: Int) {
        nextSeq = max(nextSeq, seq)
    }

    /// `sempere-ios/<version>` (format.md §5.1 `app`).
    static var appName: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "sempere-ios/\(v)"
    }

    /// The note's folder, coordinated on for writes; nil outside iCloud Drive.
    private var coordinationURL: URL? {
        guard coordinated else { return nil }
        return CloudScan.noteFolder(inVault: vault.url, id: noteID)
    }

    /// Writes one delta of `ops` to a note that is not loaded (the browser's
    /// edits): the clock first observes every readable revision of the note,
    /// so these ops win last-writer-wins races against what is already there.
    /// Creates the note when it has no revisions yet. `verify` runs inside
    /// that read, before and after the note is loaded, and throws to refuse a
    /// note whose files are not all local (`CloudVault.requireLocal`): `seq`
    /// and the clock must never come from a partial log.
    @discardableResult
    static func append(_ ops: [Op], to noteID: UUID, vault: Vault, clock: DeviceClock, app: String = NoteWriter.appName,
                       coordinated: Bool = false, wall: Date? = nil, checkpoint: Checkpoint? = nil,
                       verify: (@Sendable () throws -> Void)? = nil) async throws -> RevisionName {
        let (readings, seq, _) = try await read(noteID, vault: vault, device: clock.device, coordinated: coordinated,
                                                verify: verify, build: nil)
        await clock.observe(readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: seq, app: app, coordinated: coordinated,
                                wall: wall)
        return try await writer.write(ops, checkpoint: checkpoint)
    }

    /// Like `append(_:to:...)`, but `build` computes the ops from the note as
    /// it is on disk at write time (nil: no readable revision). Writes nothing
    /// when it returns no ops. Tag edits use this: a `removeTag` observes
    /// every instance on disk, not just those in a possibly stale summary
    /// (format.md §5.4.1). `verify` is as for `append(_:to:...)`.
    @discardableResult
    static func append(to noteID: UUID, vault: Vault, clock: DeviceClock, app: String = NoteWriter.appName,
                       coordinated: Bool = false,
                       verify: (@Sendable () throws -> Void)? = nil,
                       building build: @escaping @Sendable (NoteState?) -> [Op]) async throws -> RevisionName? {
        let (readings, seq, ops) = try await read(noteID, vault: vault, device: clock.device, coordinated: coordinated,
                                                  verify: verify, build: { loaded in
            build(loaded.revisions.isEmpty ? nil : try NoteReducer.reconstruct(loaded.revisions))
        })
        guard !ops.isEmpty else { return nil }
        await clock.observe(readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: seq, app: app, coordinated: coordinated)
        return try await writer.write(ops)
    }

    /// Restores a note to the revision `point` (format.md §5.7) by writing one
    /// delta, through the same path as every other edit. Everything is decided
    /// inside one read of the note on disk: the note's revisions must all be
    /// readable (the current state has to be known exactly), `point` must be a
    /// complete restore point, and the ops are `NoteHistory.restoreOps` from
    /// the merged current state to the state as of `point`. `verify` is as for
    /// `append(_:to:...)`.
    ///
    /// - Returns: the delta written and what it changes; nil when the note
    ///   already matches `point` (nothing is written).
    /// - Throws: `VaultError.revision` if any revision is unreadable,
    ///   `HistoryError`, `NoteLogError`, or a write error.
    @discardableResult
    static func restore(_ noteID: UUID, to point: RevisionName, vault: Vault, clock: DeviceClock,
                        app: String = NoteWriter.appName, coordinated: Bool = false,
                        verify: (@Sendable () throws -> Void)? = nil) async throws -> (name: RevisionName, summary: RestoreSummary)? {
        let (readings, seq, ops) = try await read(noteID, vault: vault, device: clock.device, coordinated: coordinated,
                                                  verify: verify, build: { loaded in
            if let (name, error) = loaded.failures.min(by: { $0.key < $1.key }) {
                throw VaultError.revision(name: name.filename, error)
            }
            let target = try NoteHistory.state(loaded.revisions, at: point)
            return NoteHistory.restoreOps(current: try NoteReducer.reconstruct(loaded.revisions), target: target)
        })
        guard !ops.isEmpty else { return nil }
        await clock.observe(readings)
        let writer = NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: seq, app: app, coordinated: coordinated)
        return (try await writer.write(ops), RestoreSummary(ops))
    }

    /// The note's revision clocks, this device's next `seq`, and the ops
    /// `build` makes from the loaded note (empty without `build`).
    /// `verify` runs inside the coordinated read, before and after loading.
    private static func read(_ noteID: UUID, vault: Vault, device: DeviceID, coordinated: Bool,
                             verify: (@Sendable () throws -> Void)?,
                             build: (@Sendable (LoadedNote) throws -> [Op])?) async throws -> ([HLC], Int, [Op]) {
        try await Task.detached(priority: .userInitiated) {
            try CloudVault.coordinatedRead(coordinated ? vault.url : nil) { () throws -> ([HLC], Int, [Op]) in
                try verify?()
                let loaded = try vault.loadNote(noteID)
                try verify?()
                let seq = loaded.failures.isEmpty
                    ? Vault.nextSeq(from: loaded.revisions, device: device)
                    : try vault.nextSeq(noteId: noteID, device: device)
                let ops = try build?(loaded) ?? []
                return (loaded.revisions.map(\.hlc), seq, ops)
            }
        }.value
    }

    // MARK: Attachments (format.md §8.1.4)

    /// Writes the file at `file` as a blob of this note (streamed: steps 1–3
    /// of format.md §8.1.4) and returns its reference; write the delta that
    /// references it afterwards (step 4). In iCloud Drive this is a
    /// coordinated write on the note's folder, so iCloud uploads the blob.
    /// Picked files and recordings are copied into the app container first:
    /// security-scoped URLs expire (docs/attachments.md §13).
    func addBlob(from file: URL, type: String, edits: [ByteEdit] = []) throws -> BlobRef {
        let vault = self.vault, note = noteID
        return try CloudVault.coordinatedWrite(coordinationURL) {
            try vault.writeBlob(note: note, contentsOf: file, type: type, edits: edits)
        }
    }

    /// `addBlob(from:type:)` for content in memory (at most 16 MiB is sensible).
    func addBlob(_ data: Data, type: String) throws -> BlobRef {
        let vault = self.vault, note = noteID
        return try CloudVault.coordinatedWrite(coordinationURL) { try vault.writeBlob(note: note, data, type: type) }
    }

    /// Copies the blob `ref` of note `source` into this note (copy and paste
    /// of items between notes), before the delta that references it. The
    /// source is verified as it is read; the caller makes it local first in
    /// iCloud Drive. No-op when this note already has a valid copy.
    func copyBlob(_ ref: BlobRef, from source: UUID) throws {
        let vault = self.vault, note = noteID
        try CloudVault.coordinatedWrite(coordinationURL) { try vault.copyBlob(ref, from: source, to: note) }
    }

    /// Writes one delta holding `ops`. A `seq` already taken (another window
    /// of this app, or a browser edit, wrote to the note) is re-read from disk
    /// and the write retried once.
    @discardableResult
    func write(_ ops: [Op], checkpoint: Checkpoint? = nil) async throws -> RevisionName {
        do {
            return try await attempt(ops, checkpoint: checkpoint)
        } catch VaultError.seqInUse {
            let vault = self.vault, noteID = self.noteID, device = clock.device
            nextSeq = try CloudVault.coordinatedRead(coordinated ? vault.url : nil) {
                try vault.nextSeq(noteId: noteID, device: device)
            }
            return try await attempt(ops, checkpoint: checkpoint)
        }
    }

    private func attempt(_ ops: [Op], checkpoint: Checkpoint?) async throws -> RevisionName {
        let now = wall ?? Date()
        let hlc = try await clock.tick(wall: now)
        let rev = Revision(noteId: noteID, device: clock.device, seq: nextSeq, hlc: hlc, wall: now, app: app,
                           body: .delta(ops: ops), session: session, checkpoint: checkpoint)
        try CloudVault.coordinatedWrite(coordinationURL) { try vault.write(rev) }
        nextSeq += 1
        await clock.didWrite(noteID)
        return rev.name
    }
}
