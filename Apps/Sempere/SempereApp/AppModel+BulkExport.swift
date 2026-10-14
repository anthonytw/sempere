import Foundation
import Observation
import Sempere
import SempereRender

/// What "Export to Folder or Zip…" was asked to export (docs/io.md "Bulk export").
struct BulkExportRequest: Identifiable, Equatable, WindowTargeted {
    let id = UUID()
    var scope: BulkExportScope
    /// The window that asked (`WindowUI.id`): its sheet shows there. Nil: the
    /// library window with the canvas, as for `ExportRequest`.
    var window: UUID?

    /// "3 Notes", "Notebook “School”", "All Notes".
    var title: String {
        switch scope {
        case .notes(let ids): return String(localized: "\(ids.count) Notes")
        case .notebook(let path):
            let name = NotebookPath.components(path).last ?? path
            return String(localized: "Notebook “\(name)”")
        case .vault: return String(localized: "All Notes")
        }
    }

    /// The zip archive's name: the notebook's, else "Sempere Notes".
    var archiveName: String {
        if case .notebook(let path) = scope, let last = NotebookPath.components(path).last {
            return ExportName.folderComponent(last) + ".zip"
        }
        return "Sempere Notes.zip"
    }
}

extension BulkExportRequest {
    /// The `sempere export` invocation that writes the same files (docs/cli.md
    /// "Bulk export"), for the sheet and the docs. A list selection has no
    /// one-line equivalent: the CLI exports one named note or `--all`.
    func cliEquivalent(_ options: BulkExportOptions, zip: Bool) -> String? {
        var args = ["sempere", "export", "--all"]
        switch scope {
        case .notes: return nil
        case .notebook(let path): args += ["--notebook", Self.shellQuoted(NotebookPath.canonical(path) ?? path)]
        case .vault: break
        }
        switch options.format {
        case .png: args += ["--format", "png"]
        case .media: args += ["--format", "media"]
        case .pdf, .pdfAttachments: args += ["--format", "pdf"]
        }
        if options.format == .pdfAttachments { args.append("--attachments") }
        if options.format == .png && options.dpi != 144 { args += ["--dpi", String(Int(options.dpi))] }
        if !options.paper && options.format != .media { args.append("--no-paper") }
        if options.layout == .notebooks { args += ["--layout", "notebooks"] }
        if zip { args += ["--zip", "--out", Self.shellQuoted(archiveName)] } else { args += ["--out", "FOLDER"] }
        return args.joined(separator: " ")
    }

    /// `s` as one shell word: unchanged when plain, else in single quotes.
    static func shellQuoted(_ s: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.isASCII && plain.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where a bulk export goes.
enum BulkExportTarget: Equatable, Sendable {
    /// Files into a folder the user picked (resumable: a re-run skips unchanged notes).
    /// `scoped`: the URL came from the folder picker and needs its security scope.
    case folder(URL, scoped: Bool)
    /// One zip archive, staged in the app's temporary folder, then shared or saved.
    case zip
}

/// How far a bulk export has come, in notes.
struct BulkExportProgress: Equatable, Sendable {
    var done: Int
    var total: Int
    var skipped: Int = 0
    var failed: Int = 0

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    var description: String {
        done >= total ? String(localized: "Finishing…") : String(localized: "Exporting note \(done + 1) of \(total)…")
    }
}

/// Bulk export: many notes, one at a time (`BulkExportSession`, shared with
/// `sempere export --all`).
extension AppModel {
    /// Opens the "Export to Folder or Zip…" sheet for `scope`.
    func requestBulkExport(_ scope: BulkExportScope, window: UUID? = nil) {
        // One export at a time, either kind.
        guard phase == .unlocked, bulkExportRequest == nil, exportRequest == nil else { return }
        if case .notes(let ids) = scope, ids.isEmpty { return }
        bulkExportRequest = BulkExportRequest(scope: scope, window: window)
    }

    /// The scope File ▸ Export to Folder or Zip… takes in a library window: the ticked
    /// notes while selecting, else the sidebar's notebook, else the vault.
    var bulkExportScope: BulkExportScope {
        if isSelectingNotes, !exportTargetIDs.isEmpty { return .notes(exportTargetIDs) }
        if case .notebook(let path) = sidebarSelection { return .notebook(path) }
        return .vault
    }

    /// The notes `scope` takes and where each goes (`BulkExportPlan.jobs`),
    /// from the listed summaries; notes still downloading without a summary
    /// are left out.
    func bulkExportJobs(_ scope: BulkExportScope, options: BulkExportOptions) -> [BulkExportJob] {
        let listed = notes.filter { !placeholderNoteIDs.contains($0.id) }
        return BulkExportPlan.jobs(for: scope, from: listed, format: options.format, layout: options.layout)
    }

    /// What reading a note ahead found (`LoadAhead`): the revision names it listed, and the note
    /// when it was read.
    struct BulkPrefetched: Sendable {
        var names: [String]?
        /// nil: not read here (the consumer reads it, in turn).
        var item: Result<LoadedForExport, any Error>?
    }

    /// In memory, a note is several times its revision files (they are compressed and encrypted).
    nonisolated static let bulkDecodeFactor = 8
    /// Assumed size of a note whose files cannot be measured (evicted from iCloud): in memory.
    nonisolated static let bulkUnknownNoteBytes = 64 << 20
    /// Most estimated bytes of notes held by a bulk export at once: the note being rendered plus
    /// those read ahead. A note over it is read and rendered on its own, as one note always was.
    nonisolated static let bulkMemoryBudget = 256 << 20
    /// How many notes after the current one are read ahead.
    nonisolated static let bulkReadAheadDepth = 2

    /// The estimated bytes of `id` in memory once read.
    nonisolated static func bulkEstimate(of id: UUID, vault: Vault) -> Int {
        guard let disk = vault.revisionBytes(of: id) else { return bulkUnknownNoteBytes }
        return max(1 << 20, disk * bulkDecodeFactor)
    }

    /// The revision names the skip check and the version come from: the listing's (an iCloud
    /// listing knows evicted revisions too), a plain listing for a note just saved, which may
    /// not be indexed under its new revision yet.
    private func bulkNames(of id: UUID, isOpen: Bool, vault: Vault) async -> [String]? {
        if !isOpen, let names = indexedNames[id] { return names }
        return try? await offMain { try vault.revisionNames(of: id).map(\.filename) }
    }

    /// Downloads, reads and prepares one note for `session.export`: iCloud fetches the
    /// recordings and clips only when they are embedded (one that cannot be fetched is left out
    /// of the PDF and reported there), or every blob of a media export.
    private func bulkLoad(_ id: UUID, vault: Vault, session: BulkExportSession, gen: Int) async throws -> LoadedForExport {
        let item = try await loadNoteForExport(id, vault: vault)
        try ensureCurrent(gen)
        if session.options.format == .pdfAttachments {
            await ensurePDFAttachmentsLocal(item.state, of: id)
            try ensureCurrent(gen)
        } else if session.options.format == .media {
            await ensureMediaLocal(item.state, of: id)
            try ensureCurrent(gen)
        }
        return item
    }

    /// Exports `jobs` into `session`: skipped when the destination already holds a note
    /// unchanged, else downloaded (iCloud), read, rendered and written, then let go. A note that
    /// cannot be read or rendered is recorded and the rest go on. An open note's pending
    /// changes are saved first (`flushEditors`), and one whose changes cannot be saved is
    /// recorded as failed; nothing else is written to the vault.
    ///
    /// Notes are rendered one at a time, in order, but the next ones are downloaded and read
    /// while the current one renders (`LoadAhead`: in order, one read at a time, at most
    /// `bulkReadAheadDepth` notes after the current one, and the estimated bytes of all the
    /// notes held at once stay under `bulkMemoryBudget`). Everything that records an outcome
    /// (`skip`, `fail`, `export`) still happens in job order from this loop; reading ahead
    /// never touches the session, except to ask `wouldSkip` so an up-to-date note is not read.
    ///
    /// Cancelling the calling task stops between notes (and between a PDF's
    /// pages): the result then says `cancelled`, and what was written stays
    /// in a folder (a zip is deleted).
    ///
    /// - Throws: `ModelError.noVaultOpen`, `CancellationError` when the vault
    ///   closes meanwhile, or `BulkExportError` when the zip cannot be written.
    func runBulkExport(_ jobs: [BulkExportJob], session: BulkExportSession,
                       progress: @escaping @MainActor (BulkExportProgress) -> Void) async throws -> BulkExportResult {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        // An open note's pending changes first, so the export holds what the canvas shows.
        let open = Set([editor?.noteID].compactMap { $0 } + windowEditors.keys)
        let unsaved = await flushEditors(for: Set(jobs.map(\.noteId)))
        try ensureCurrent(gen)
        let budget = ByteBudget(limit: Self.bulkMemoryBudget)
        let ahead = LoadAhead<BulkPrefetched>(count: jobs.count, depth: Self.bulkReadAheadDepth) { [weak self] index in
            guard let self, !Task.isCancelled else { return .declined }
            let id = jobs[index].noteId
            if unsaved.contains(id) { return .nothing }
            let names = await self.bulkNames(of: id, isOpen: open.contains(id), vault: vault)
            if let names, session.wouldSkip(jobs[index], version: BulkExportPlan.version(ofFileNames: names)) {
                // Declined, not ready: reads after it wait until the consumer has decided (and, if the
                // note turns out not to be skippable after all, reserved it), so the budget holds.
                return .declined
            }
            let estimate = Self.bulkEstimate(of: id, vault: vault)
            guard budget.tryReserve(estimate) else { return .declined }
            do {
                let item = try await self.bulkLoad(id, vault: vault, session: session, gen: gen)
                return .ready(BulkPrefetched(names: names, item: .success(item)), bytes: estimate)
            } catch {
                budget.release(estimate)
                return .ready(BulkPrefetched(names: names, item: .failure(error)), bytes: 0)
            }
        }
        do {
            let result = try await exportJobs(jobs, session: session, ahead: ahead, budget: budget, vault: vault,
                                              gen: gen, open: open, unsaved: unsaved, progress: progress)
            await ahead.cancelAndWait()
            return result
        } catch {
            await ahead.cancelAndWait()
            throw error
        }
    }

    private func exportJobs(_ jobs: [BulkExportJob], session: BulkExportSession, ahead: LoadAhead<BulkPrefetched>,
                            budget: ByteBudget, vault: Vault, gen: Int, open: Set<UUID>, unsaved: Set<UUID>,
                            progress: @escaping @MainActor (BulkExportProgress) -> Void) async throws -> BulkExportResult {
        var state = BulkExportProgress(done: 0, total: jobs.count)
        ahead.schedule(after: -1)
        for (index, job) in jobs.enumerated() {
            progress(state)
            if Task.isCancelled { return try await finishBulk(session, cancelled: true) }
            try ensureCurrent(gen)
            let id = job.noteId
            // What was read ahead of this job, and the bytes it holds in the budget.
            let early = await withTaskCancellationHandler { await ahead.take(index) } onCancel: { ahead.cancel() }
            var held = 0
            var prefetched: BulkPrefetched?
            if case .ready(let p, let bytes)? = early { prefetched = p; held = bytes }
            defer { budget.release(held) }
            // Reads go on after this job (`schedule(after:)`) only once it holds its bytes in the
            // budget, so a read ahead never reserves room this job is about to need.
            if unsaved.contains(id) {
                ahead.schedule(after: index)
                session.fail(job, UnsavedChangesError())
                state.failed += 1
                state.done += 1
                continue
            }
            // An unchanged note is skipped before anything is downloaded or read.
            var names = prefetched?.names
            if names == nil { names = await bulkNames(of: id, isOpen: open.contains(id), vault: vault) }
            if let names, session.skip(job, version: BulkExportPlan.version(ofFileNames: names)) {
                ahead.schedule(after: index)
                state.done += 1; state.skipped += 1
                continue
            }
            // Not read ahead (over the budget, never started, or read ahead as "up to date" and no
            // longer so): reserved here and read in turn.
            if held == 0, prefetched?.item.map({ _ in true }) == nil {
                held = Self.bulkEstimate(of: id, vault: vault)
                budget.force(held)
            }
            ahead.schedule(after: index)
            do {
                let item: LoadedForExport
                if let early = prefetched?.item {
                    item = try early.get()
                } else {
                    item = try await bulkLoad(id, vault: vault, session: session, gen: gen)
                }
                try ensureCurrent(gen)
                let render = Task.detached(priority: .userInitiated) { [session] in
                    try session.export(job, state: item.state, version: item.version, blobs: vault.blobSource(note: id))
                }
                let outcome = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
                if case .failed = outcome.status { state.failed += 1 }
            } catch is CancellationError {
                try ensureCurrent(gen)
                return try await finishBulk(session, cancelled: true)
            } catch let e as BulkExportError {
                _ = try? await finishBulk(session, cancelled: true)
                throw e
            } catch {
                session.fail(job, error)
                state.failed += 1
            }
            state.done += 1
        }
        progress(state)
        try ensureCurrent(gen)
        return try await finishBulk(session, cancelled: false)
    }

    /// True when `url` is the vault folder or inside it.
    func isInsideVault(_ url: URL) -> Bool {
        guard let root = vault?.url ?? vaultURL else { return false }
        return url.isSameOrInside(root)
    }

    private func finishBulk(_ session: BulkExportSession, cancelled: Bool) async throws -> BulkExportResult {
        try await offMain { try session.finish(cancelled: cancelled) }
    }
}

/// One "Export to Folder or Zip…" run for its sheet: owns the session, the picked
/// folder's security scope while it runs, and for a zip the staging folder
/// (deleted by `discard`, and by `purgeStale` at launch).
@MainActor
@Observable
final class BulkExportRun {
    enum State: Equatable {
        case idle
        case running(BulkExportProgress)
        case finished(BulkExportResult)
        case failed(String)
    }

    private(set) var state = State.idle
    private var task: Task<Void, Never>?
    private var staging: URL?
    /// The current run: a run that ended after `discard` (or a newer start) changes nothing.
    private var token = UUID()

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Where zip exports are staged (under the temporary directory, never in the vault).
    nonisolated static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereBulkExports", isDirectory: true)
    }

    /// Deletes every staged archive: plaintext copies of notes. Call when the
    /// app starts, when no export can be running.
    nonisolated static func purgeStale() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    /// Starts exporting `request` to `target`. Does nothing while a run is in flight.
    func start(model: AppModel, request: BulkExportRequest, options: BulkExportOptions, target: BulkExportTarget) {
        guard !isRunning else { return }
        discard()
        let jobs = model.bulkExportJobs(request.scope, options: options)
        guard !jobs.isEmpty else {
            state = .failed(String(localized: "There are no notes to export."))
            return
        }
        let destination: BulkExportSession.Destination
        /// The picked folder whose security scope this run holds until it ends.
        let scopedURL: URL?
        switch target {
        case .folder(let url, let scoped):
            // Plaintext never goes into the vault folder (it syncs wherever the vault does).
            if model.isInsideVault(url) {
                state = .failed(String(localized: "Choose a folder outside the vault: exported notes are not encrypted."))
                return
            }
            destination = .folder(url)
            scopedURL = scoped && url.startAccessingSecurityScopedResource() ? url : nil
        case .zip:
            let dir = Self.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            staging = dir
            scopedURL = nil
            destination = .zip(archive: dir.appendingPathComponent(request.archiveName),
                               staging: dir.appendingPathComponent("work", isDirectory: true))
        }
        state = .running(BulkExportProgress(done: 0, total: jobs.count))
        let mine = staging
        let current = UUID()
        token = current
        task = Task { [weak self] in
            defer { scopedURL?.stopAccessingSecurityScopedResource() }
            var next: State
            do {
                if let mine {
                    try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
                    #if os(iOS)
                    // Plaintext copies of notes: readable only while the device is unlocked.
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: mine.path)
                    #endif
                }
                let session = try BulkExportSession(destination: destination, options: options, jobs: jobs,
                                                    renderBase: RenderOptions(pdfRasterizer: PDFKitRasterizer(),
                                                                              shaper: CoreTextShaper()))
                let result = try await model.runBulkExport(jobs, session: session) { progress in
                    self?.advance(to: progress)
                }
                next = .finished(result)
            } catch is CancellationError {
                // The vault closed: nothing to show.
                if let mine { try? FileManager.default.removeItem(at: mine) }
                self?.reset(current)
                return
            } catch {
                if let mine { try? FileManager.default.removeItem(at: mine) }
                next = .failed("\(error)")
            }
            guard let self, self.token == current else {
                if let mine { try? FileManager.default.removeItem(at: mine) }
                return
            }
            self.task = nil
            self.state = next
        }
    }

    /// Stops after the note being exported. A folder keeps what was written
    /// (a re-run skips it); a zip is deleted.
    func cancel() {
        task?.cancel()
    }

    /// Cancels, forgets the result and deletes a staged zip. Call when the sheet goes away.
    func discard() {
        task?.cancel()
        task = nil
        token = UUID()
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
        state = .idle
    }

    private func advance(to progress: BulkExportProgress) {
        guard isRunning else { return }
        state = .running(progress)
    }

    private func reset(_ run: UUID) {
        guard token == run else { return }
        task = nil
        staging = nil
        state = .idle
    }
}
