import Foundation
import Observation
import Sempere
import SempereRender

/// What "Export to Folder or Zip…" was asked to export (docs/io.md "Bulk export").
public struct BulkExportRequest: Identifiable, Equatable, WindowTargeted {
    public let id = UUID()
    public var scope: BulkExportScope
    /// The window that asked (`WindowUI.id`): its sheet shows there. Nil: the
    /// library window with the canvas, as for `ExportRequest`.
    public var window: UUID?

    public init(scope: BulkExportScope, window: UUID? = nil) {
        self.scope = scope
        self.window = window
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
    public func cliEquivalent(_ options: BulkExportOptions, zip: Bool) -> String? {
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
public enum BulkExportTarget: Equatable, Sendable {
    /// Files into a folder the user picked (resumable: a re-run skips unchanged notes).
    /// `scoped`: the URL came from the folder picker and needs its security scope.
    case folder(URL, scoped: Bool)
    /// One zip archive, staged in the app's temporary folder, then shared or saved.
    case zip
}

/// Bulk export: many notes, one at a time (`BulkExportSession`, shared with
/// `sempere export --all`).
extension AppModelCore {
    /// Opens the "Export to Folder or Zip…" sheet for `scope`.
    public func requestBulkExport(_ scope: BulkExportScope, window: UUID? = nil) {
        // One export at a time, either kind.
        guard phase == .unlocked, bulkExportRequest == nil, exportRequest == nil else { return }
        if case .notes(let ids) = scope, ids.isEmpty { return }
        bulkExportRequest = BulkExportRequest(scope: scope, window: window)
    }

    /// The scope File ▸ Export to Folder or Zip… takes in a library window: the ticked
    /// notes while selecting, else the sidebar's notebook, else the vault.
    public var bulkExportScope: BulkExportScope {
        if isSelectingNotes, !exportTargetIDs.isEmpty { return .notes(exportTargetIDs) }
        if case .notebook(let path) = sidebarSelection { return .notebook(path) }
        return .vault
    }

    /// The notes `scope` takes and where each goes (`BulkExportPlan.jobs`),
    /// from the listed summaries; notes still downloading without a summary
    /// are left out.
    public func bulkExportJobs(_ scope: BulkExportScope, options: BulkExportOptions) -> [BulkExportJob] {
        let listed = notes.filter { !placeholderNoteIDs.contains($0.id) }
        return BulkExportPlan.jobs(for: scope, from: listed, format: options.format, layout: options.layout)
    }

    /// How many notes after the current one are read ahead (`BulkExportDriver`).
    nonisolated public static var bulkReadAheadDepth: Int { BulkExportDriver.defaultReadAheadDepth }

    /// The revision names the skip check and the version come from: the listing's (an iCloud
    /// listing knows evicted revisions too), a plain listing for a note just saved, which may
    /// not be indexed under its new revision yet.
    private func bulkNames(of id: UUID, isOpen: Bool, vault: Vault) async -> [String]? {
        if !isOpen, let names = indexedNames[id] { return names }
        return try? await offMain { try vault.revisionNames(of: id).map(\.filename) }
    }

    /// Exports `jobs` into `session` with the shared loop (`BulkExportDriver`: order, skips, read-ahead, the
    /// memory budget, one failed note not stopping the rest, cancel between notes). What is the app's: an
    /// open note's pending changes are saved first (`flushEditors`) and one whose changes cannot be saved is
    /// recorded as failed; iCloud notes are downloaded (`loadNoteForExport`) and their media fetched when the
    /// format embeds it (one that cannot be fetched is left out of the PDF and reported there); and the run
    /// stops when the vault closes. Nothing else is written to the vault.
    ///
    /// - Throws: `ModelError.noVaultOpen`, `CancellationError` when the vault
    ///   closes meanwhile, or `BulkExportError` when the zip cannot be written.
    public func runBulkExport(_ jobs: [BulkExportJob], session: BulkExportSession,
                       progress: @escaping @MainActor (BulkExportProgress) -> Void) async throws -> BulkExportResult {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        // An open note's pending changes first, so the export holds what the canvas shows.
        let open = Set([editor?.noteID].compactMap { $0 } + windowEditors.keys)
        let unsaved = await flushEditors(for: Set(jobs.map(\.noteId)))
        try ensureCurrent(gen)
        var driver = BulkExportDriver(vault: vault, session: session, jobs: jobs)
        driver.failedBeforeReading = Dictionary(uniqueKeysWithValues: unsaved.map { ($0, UnsavedChangesError() as any Error) })
        driver.describeError = services.describeError
        driver.revisionNames = { [weak self] id in
            await self?.bulkNames(of: id, isOpen: open.contains(id), vault: vault)
        }
        driver.read = { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.loadNoteForExport(id, vault: vault)
        }
        driver.prepare = { [weak self] id, item in
            guard let self else { throw CancellationError() }
                        if session.options.format == .pdfAttachments {
                await self.ensurePDFAttachmentsLocal(item.state, of: id)
            } else if session.options.format == .media {
                await self.ensureMediaLocal(item.state, of: id)
            }
        }
        driver.check = { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.ensureCurrent(gen)
        }
        driver.progress = progress
        return try await driver.run()
    }

    /// True when `url` is the vault folder or inside it.
    func isInsideVault(_ url: URL) -> Bool {
        guard let root = vault?.url ?? vaultURL else { return false }
        return url.isSameOrInside(root)
    }
}

/// One "Export to Folder or Zip…" run for its sheet: owns the session, the picked
/// folder's security scope while it runs, and for a zip the staging folder
/// (deleted by `discard`, and by `purgeStale` at launch).
@MainActor
@Observable
public final class BulkExportRun {
    public enum State: Equatable {
        case idle
        case running(BulkExportProgress)
        case finished(BulkExportResult)
        case failed(ExportRunFailure)
    }

    public init() {}

    public private(set) var state = State.idle
    private var task: Task<Void, Never>?
    private var staging: URL?
    /// The current run: a run that ended after `discard` (or a newer start) changes nothing.
    private var token = UUID()

    public var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Where zip exports are staged (under the temporary directory, never in the vault).
    nonisolated public static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereBulkExports", isDirectory: true)
    }

    /// Deletes every staged archive: plaintext copies of notes. Call when the
    /// app starts, when no export can be running.
    nonisolated public static func purgeStale() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    /// Starts exporting `request` to `target`. Does nothing while a run is in flight.
    public func start<Host>(model: AppModelCore<Host>, request: BulkExportRequest, options: BulkExportOptions,
                            target: BulkExportTarget) {
        guard !isRunning else { return }
        discard()
        let jobs = model.bulkExportJobs(request.scope, options: options)
        guard !jobs.isEmpty else {
            state = .failed(.noNotes)
            return
        }
        let destination: BulkExportSession.Destination
        /// The picked folder whose security scope this run holds until it ends (`services.bookmarks`).
        let scopedURL: URL?
        let bookmarks = model.services.bookmarks
        switch target {
        case .folder(let url, let scoped):
            // Plaintext never goes into the vault folder (it syncs wherever the vault does).
            if model.isInsideVault(url) {
                state = .failed(.folderInsideVault)
                return
            }
            destination = .folder(url)
            scopedURL = scoped && bookmarks.startAccessing(url) ? url : nil
        case .zip:
            let dir = Self.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            staging = dir
            scopedURL = nil
            destination = .zip(archive: dir.appendingPathComponent(request.archiveName),
                               staging: dir.appendingPathComponent("work", isDirectory: true))
        }
        state = .running(BulkExportProgress(done: 0, total: jobs.count))
        let mine = staging
        let renderBase = model.services.exportRendering
        let current = UUID()
        token = current
        task = Task { [weak self] in
            defer { if let scopedURL { bookmarks.stopAccessing(scopedURL) } }
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
                                                    renderBase: renderBase)
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
                next = .failed(.error(model.services.describeError(error)))
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
    public func cancel() {
        task?.cancel()
    }

    /// Cancels, forgets the result and deletes a staged zip. Call when the sheet goes away.
    public func discard() {
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
