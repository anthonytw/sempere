import Foundation
import Sempere

/// How far a bulk export has come, in notes. Its line (`description`) is the app's.
public struct BulkExportProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var skipped: Int = 0
    public var failed: Int = 0

    public init(done: Int, total: Int, skipped: Int = 0, failed: Int = 0) {
        self.done = done
        self.total = total
        self.skipped = skipped
        self.failed = failed
    }

    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

/// One note read for an export: its state and `BulkExportPlan.version` of the revisions read, and its summary when
/// asked for (a share export lists it; a bulk export plans from the listing and never needs it).
public struct LoadedForExport: Sendable {
    public let summary: NoteSummary?
    public let state: NoteState
    /// `BulkExportPlan.version` of the revisions read.
    public var version = ""

    public init(summary: NoteSummary?, state: NoteState, version: String = "") {
        self.summary = summary
        self.state = state
        self.version = version
    }

    /// Reads and reconstructs note `id` (blocking). `verify` runs first (the app's check that a partial copy
    /// holds the whole note). `withSummary` also builds `summary` (a second pass over the note).
    public static func read(_ id: UUID, from vault: Vault, withSummary: Bool = false,
                            verify: (@Sendable () throws -> Void)? = nil) throws -> LoadedForExport {
        try verify?()
        let note = try vault.loadNote(id)
        return LoadedForExport(summary: withSummary ? vault.summary(of: id, loaded: note) : nil,
                               state: try vault.reconstruct(note),
                               version: BulkExportPlan.version(of: note))
    }
}

/// The loop of a bulk export, shared by the app's "Export to Folder or Zip…" and `sempere export --all`
/// (docs/io.md "Bulk export"): per job, skip it when the destination holds it unchanged, else read, render and
/// write it, recording a note that cannot be read or rendered and going on. A `BulkExportError` (the zip cannot be
/// written) ends the run.
///
/// Notes are rendered one at a time, in order, but the next ones are read while the current one renders
/// (`LoadAhead`: in order, one read at a time, at most `readAheadDepth` notes after the current one, and the
/// estimated bytes of all the notes held at once stay under `memoryBudget`). Everything that records an outcome
/// (`skip`, `fail`, `export`) happens in job order from `run`; reading ahead only asks `wouldSkip`, so an up-to-date
/// note is not read.
///
/// What differs between the two callers is a hook: the app saves open notes first (`failedBeforeReading`), lists
/// revisions from its index (`revisionNames`), downloads from iCloud (`read`, `prepare`), stops when the vault
/// closes (`check`) and shows progress; the CLI sets none of them and stops at its Ctrl-C (`stopRequested`).
public struct BulkExportDriver: Sendable {
    /// What happened to a job, in job order (`onEvent`).
    public enum Event: Sendable {
        /// Up to date in the destination (recorded as skipped).
        case skipped(BulkExportJob)
        /// Rendered and written, or recorded as failed by the session (`outcome.status`).
        case written(BulkNoteOutcome)
        /// Could not be read (or was refused before reading); recorded as failed with this text.
        case failed(BulkExportJob, message: String)
    }

    /// In memory, a note is several times its revision files (they are compressed and encrypted).
    public static let decodeFactor = 8
    /// Assumed size of a note whose files cannot be measured (evicted from iCloud): in memory.
    public static let unknownNoteBytes = 64 << 20
    /// Most estimated bytes of notes held at once: the note being rendered plus those read ahead. A note over it
    /// is read and rendered on its own, as one note always was.
    public static let defaultMemoryBudget = 256 << 20
    /// How many notes after the current one are read ahead.
    public static let defaultReadAheadDepth = 2

    public let vault: Vault
    public let session: BulkExportSession
    public let jobs: [BulkExportJob]
    public var readAheadDepth = BulkExportDriver.defaultReadAheadDepth
    public var memoryBudget = BulkExportDriver.defaultMemoryBudget
    /// False renders every note even when the destination holds it unchanged (`--overwrite`, zip).
    public var skipUnchanged = true
    /// Jobs that fail without being read, with the reason (the app: notes whose pending changes cannot be saved).
    public var failedBeforeReading: [UUID: any Error] = [:]
    /// The text recorded for a failed note.
    public var describeError: @Sendable (any Error) -> String = { "\($0)" }
    /// The revision file names of a note, for the skip check and the version (nil: not known). Default: listed from the vault.
    public var revisionNames: (@Sendable (UUID) async -> [String]?)?
    /// Reads a note. Default: `LoadedForExport.read`, off the calling task.
    public var read: (@Sendable (UUID) async throws -> LoadedForExport)?
    /// Called on a note just read, before it renders (the app: iCloud downloads of its media).
    public var prepare: (@Sendable (UUID, LoadedForExport) async throws -> Void)?
    /// Called between steps; throws `CancellationError` to end the run (the app: the vault closed).
    public var check: (@Sendable () async throws -> Void)?
    /// True ends the run after the note being written, as a canceled task does, but without interrupting that note.
    public var stopRequested: (@Sendable () -> Bool)?
    public var progress: (@MainActor @Sendable (BulkExportProgress) -> Void)?
    public var onEvent: (@Sendable (Event) -> Void)?

    public init(vault: Vault, session: BulkExportSession, jobs: [BulkExportJob]) {
        self.vault = vault
        self.session = session
        self.jobs = jobs
    }

    /// The estimated bytes of `id` in memory once read.
    public static func estimate(of id: UUID, vault: Vault) -> Int {
        guard let disk = vault.revisionBytes(of: id) else { return unknownNoteBytes }
        return max(1 << 20, disk * decodeFactor)
    }

    /// What reading a note ahead found: the revision names it listed, and the note when it was read.
    private struct Prefetched: Sendable {
        var names: [String]?
        /// nil: not read here (the consumer reads it, in turn).
        var item: Result<LoadedForExport, any Error>?
    }

    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func names(of id: UUID) async -> [String]? {
        if let revisionNames { return await revisionNames(id) }
        let vault = vault
        return try? await Self.offThread { try vault.revisionNames(of: id).map(\.filename) }
    }

    private func load(_ id: UUID) async throws -> LoadedForExport {
        let vault = vault
        let item: LoadedForExport
        if let read {
            item = try await read(id)
        } else {
            item = try await Self.offThread { try LoadedForExport.read(id, from: vault) }
        }
        try await check?()
        if let prepare {
            try await prepare(id, item)
            try await check?()
        }
        return item
    }

    private func finish(cancelled: Bool) async throws -> BulkExportResult {
        let session = session
        return try await Self.offThread { try session.finish(cancelled: cancelled) }
    }

    /// Exports the jobs into the session.
    ///
    /// Canceling the calling task stops between notes (and between a PDF's pages): the result then says
    /// `cancelled`, and what was written stays in a folder (a zip is deleted).
    ///
    /// - Throws: `CancellationError` from `check`, or `BulkExportError` when the zip cannot be written.
    public func run() async throws -> BulkExportResult {
        let budget = ByteBudget(limit: memoryBudget)
        let ahead = LoadAhead<Prefetched>(count: jobs.count, depth: readAheadDepth) { index in
            if Task.isCancelled { return .declined }
            let id = jobs[index].noteId
            if failedBeforeReading[id] != nil { return .nothing }
            let names = await self.names(of: id)
            if skipUnchanged, let names, session.wouldSkip(jobs[index], version: BulkExportPlan.version(ofFileNames: names)) {
                // Declined, not ready: reads after it wait until the consumer has decided (and, if the
                // note turns out not to be skippable after all, reserved it), so the budget holds.
                return .declined
            }
            let estimate = Self.estimate(of: id, vault: vault)
            guard budget.tryReserve(estimate) else { return .declined }
            do {
                let item = try await self.load(id)
                return .ready(Prefetched(names: names, item: .success(item)), bytes: estimate)
            } catch {
                budget.release(estimate)
                return .ready(Prefetched(names: names, item: .failure(error)), bytes: 0)
            }
        }
        do {
            let result = try await loop(ahead: ahead, budget: budget)
            await ahead.cancelAndWait()
            return result
        } catch {
            await ahead.cancelAndWait()
            throw error
        }
    }

    private func loop(ahead: LoadAhead<Prefetched>, budget: ByteBudget) async throws -> BulkExportResult {
        var state = BulkExportProgress(done: 0, total: jobs.count)
        ahead.schedule(after: -1)
        for (index, job) in jobs.enumerated() {
            if let progress { await progress(state) }
            if Task.isCancelled || stopRequested?() == true { return try await finish(cancelled: true) }
            try await check?()
            let id = job.noteId
            // What was read ahead of this job, and the bytes it holds in the budget.
            let early = await withTaskCancellationHandler { await ahead.take(index) } onCancel: { ahead.cancel() }
            var held = 0
            var prefetched: Prefetched?
            if case .ready(let p, let bytes)? = early { prefetched = p; held = bytes }
            defer { budget.release(held) }
            // Reads go on after this job (`schedule(after:)`) only once it holds its bytes in the
            // budget, so a read ahead never reserves room this job is about to need.
            if let error = failedBeforeReading[id] {
                ahead.schedule(after: index)
                session.fail(job, error, text: describeError)
                onEvent?(.failed(job, message: describeError(error)))
                state.failed += 1
                state.done += 1
                continue
            }
            // An unchanged note is skipped before anything is downloaded or read.
            var names = prefetched?.names
            if names == nil { names = await self.names(of: id) }
            if skipUnchanged, let names, session.skip(job, version: BulkExportPlan.version(ofFileNames: names)) {
                ahead.schedule(after: index)
                onEvent?(.skipped(job))
                state.done += 1; state.skipped += 1
                continue
            }
            // Not read ahead (over the budget, never started, or read ahead as "up to date" and no
            // longer so): reserved here and read in turn.
            if held == 0, prefetched?.item.map({ _ in true }) == nil {
                held = Self.estimate(of: id, vault: vault)
                budget.force(held)
            }
            ahead.schedule(after: index)
            do {
                let item: LoadedForExport
                if let early = prefetched?.item {
                    item = try early.get()
                } else {
                    item = try await load(id)
                }
                try await check?()
                let describe = describeError
                let render = Task.detached(priority: .userInitiated) { [session, vault] in
                    try session.export(job, state: item.state, version: item.version, blobs: vault.blobSource(note: id),
                                       text: describe)
                }
                let outcome = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
                if case .failed = outcome.status { state.failed += 1 }
                onEvent?(.written(outcome))
            } catch is CancellationError {
                try await check?()
                return try await finish(cancelled: true)
            } catch let e as BulkExportError {
                _ = try? await finish(cancelled: true)
                throw e
            } catch {
                session.fail(job, error, text: describeError)
                onEvent?(.failed(job, message: describeError(error)))
                state.failed += 1
            }
            state.done += 1
        }
        if let progress { await progress(state) }
        try await check?()
        return try await finish(cancelled: false)
    }
}
