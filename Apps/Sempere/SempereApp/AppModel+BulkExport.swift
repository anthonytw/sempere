import Foundation
import Observation
import Sempere
import SempereRender

/// What "Export Notes…" was asked to export (docs/io.md "Bulk export").
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
    /// Opens the "Export Notes…" sheet for `scope`.
    func requestBulkExport(_ scope: BulkExportScope, window: UUID? = nil) {
        // One export at a time, either kind.
        guard phase == .unlocked, bulkExportRequest == nil, exportRequest == nil else { return }
        if case .notes(let ids) = scope, ids.isEmpty { return }
        bulkExportRequest = BulkExportRequest(scope: scope, window: window)
    }

    /// The scope File ▸ Export Notes… takes in a library window: the ticked
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

    /// Exports `jobs` into `session`, one note at a time: skipped when the
    /// destination already holds it unchanged, else downloaded (iCloud), read,
    /// rendered and written, then let go. A note that cannot be read or
    /// rendered is recorded and the rest go on. Never writes to the vault.
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
        var state = BulkExportProgress(done: 0, total: jobs.count)
        let attachments = session.options.format == .pdfAttachments
        for job in jobs {
            progress(state)
            if Task.isCancelled { return try await finishBulk(session, cancelled: true) }
            try ensureCurrent(gen)
            let id = job.noteId
            // An unchanged note is skipped before anything is downloaded or read.
            // The listing's names (an iCloud listing knows evicted revisions too); a plain listing otherwise.
            var names = indexedNames[id]
            if names == nil { names = try? await offMain { try vault.revisionNames(of: id).map(\.filename) } }
            if let names, session.skip(job, version: BulkExportPlan.version(ofFileNames: names)) {
                state.done += 1; state.skipped += 1
                continue
            }
            do {
                let item = try await loadNoteForExport(id, vault: vault)
                try ensureCurrent(gen)
                if attachments {
                    // iCloud fetches recordings and clips only when they are embedded; one that
                    // cannot be fetched is left out of the PDF and reported there.
                    for r in item.state.recordings {
                        try? await ensureBlobLocal(r.blob, of: id)
                        if let t = r.transcript { try? await ensureBlobLocal(t, of: id) }
                    }
                    for clip in ExportVideos.clips(of: item.state) { try? await ensureBlobLocal(clip.ref, of: id) }
                    try ensureCurrent(gen)
                } else if session.options.format == .media {
                    await ensureMediaLocal(item.state, of: id)
                    try ensureCurrent(gen)
                }
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
        let a = root.standardizedFileURL.resolvingSymlinksInPath().path
        let b = url.standardizedFileURL.resolvingSymlinksInPath().path
        return b == a || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    private func finishBulk(_ session: BulkExportSession, cancelled: Bool) async throws -> BulkExportResult {
        try await offMain { try session.finish(cancelled: cancelled) }
    }
}

/// One "Export Notes…" run for its sheet: owns the session, the picked
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
