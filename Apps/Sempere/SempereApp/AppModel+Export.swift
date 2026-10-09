import Foundation
import Sempere
import SempereRender

/// A request whose sheet shows in the window that asked for it.
protocol WindowTargeted {
    /// The window that asked (`WindowUI.id`): its sheet shows there. Nil: the
    /// library window with the canvas.
    var window: UUID? { get }
}

extension WindowTargeted {
    /// `request` when window `window` shows it: the window that asked, or for
    /// a request without one, the library window with the canvas (or any, when
    /// none has it: `OpenedFile.shows`).
    static func shown(_ request: Self?, in window: UUID, canvasWindow: UUID?) -> Self? {
        guard let request else { return nil }
        if let asker = request.window { return asker == window ? request : nil }
        return OpenedFile.shows(in: window, canvasWindow: canvasWindow) ? request : nil
    }
}

/// What the export sheet was asked to export.
struct ExportRequest: Identifiable, Equatable, WindowTargeted {
    let id = UUID()
    var noteIDs: [UUID]
    var format: ShareFormat
    /// The window that asked (`WindowUI.id`): its sheet shows there. Nil: the
    /// library window with the canvas.
    var window: UUID?
}

/// How far an export has come: notes read from the vault, then notes rendered.
struct ExportProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case reading, rendering }
    var phase: Phase
    var done: Int
    var total: Int

    /// 0 ... 1 over both phases.
    var fraction: Double {
        guard total > 0 else { return 0 }
        let steps = Double(done) + (phase == .rendering ? Double(total) : 0)
        return min(1, steps / Double(2 * total))
    }

    var description: String {
        switch phase {
        case .reading: return String(localized: "Reading note \(min(done + 1, total)) of \(total)…")
        case .rendering: return done >= total ? String(localized: "Finishing…", comment: "Export progress: last step") : String(localized: "Exporting note \(done + 1) of \(total)…")
        }
    }
}

/// Share and export (docs/io.md "Share and export").
extension AppModel {
    /// The notes the export commands act on: the ticked notes while selecting
    /// (still in the vault), else the open note. In list order.
    var exportTargetIDs: [UUID] {
        let wanted: Set<UUID> = isSelectingNotes ? multiSelection : (selectedNoteID.map { [$0] } ?? [])
        return notes.filter { wanted.contains($0.id) && !placeholderNoteIDs.contains($0.id) }.map(\.id)
    }

    /// True when `format` can export `ids` (`ExportCommand.isAvailable`):
    /// the text export needs a note with recognised handwriting.
    func canExport(_ format: ShareFormat, ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return false }
        let wanted = Set(ids)
        return ExportCommand.isAvailable(format, for: notes.filter { wanted.contains($0.id) })
    }

    /// Opens the export sheet for `ids` with the command's format.
    func requestExport(_ command: ExportCommand, ids: [UUID], window: UUID? = nil) {
        // One export at a time: replacing the request would dismiss a running sheet.
        guard phase == .unlocked, canExport(command.format, ids: ids), exportRequest == nil, bulkExportRequest == nil else { return }
        exportRequest = ExportRequest(noteIDs: ids, format: command.format, window: window)
    }

    /// Reads `ids` from the vault and renders them into `scratch`.
    ///
    /// Reading and rendering run off the main actor; cancelling the calling
    /// task stops both between notes. A note that cannot be read or rendered
    /// is reported in `failures` and the rest are exported. Writes nothing
    /// to the vault. iCloud notes are downloaded first, like for editing.
    ///
    /// - Throws: `CancellationError` (also when the vault is closed meanwhile),
    ///   `ModelError.noVaultOpen`, or a file error for `scratch`.
    func exportNotes(_ ids: [UUID], options: ShareOptions, into scratch: URL,
                     progress: @escaping @MainActor @Sendable (ExportProgress) -> Void) async throws -> ShareResult {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        var loaded: [(NoteSummary, NoteState)] = []
        var failures: [String] = []
        for (i, id) in ids.enumerated() {
            try Task.checkCancellation()
            try ensureCurrent(gen)
            progress(ExportProgress(phase: .reading, done: i, total: ids.count))
            do {
                let item = try await loadNoteForExport(id, vault: vault)
                try ensureCurrent(gen)
                loaded.append((item.summary, item.state))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(id.uuidString.lowercased()): \(error)")
            }
        }
        try Task.checkCancellation()
        if options.format == .pdf && options.pdfAttachments {
            // "PDF + attachments": iCloud fetches audio only when it is used (docs/attachments.md §4).
            // One that cannot be fetched is left out and reported by the export.
            for (summary, state) in loaded {
                for r in state.recordings {
                    try? await ensureBlobLocal(r.blob, of: summary.id)
                    if let t = r.transcript { try? await ensureBlobLocal(t, of: summary.id) }
                }
                // Video clips too (format.md §8.2.7): fetched only now, when they are embedded.
                for clip in ExportVideos.clips(of: state) { try? await ensureBlobLocal(clip.ref, of: summary.id) }
            }
            try ensureCurrent(gen)
        } else if options.format == .media {
            // "Media": every file the export writes, fetched now; one that cannot be is left out and reported.
            for (summary, state) in loaded { await ensureMediaLocal(state, of: summary.id) }
            try ensureCurrent(gen)
        }
        let source = "sempere:\(vault.vaultId.uuidString.lowercased())"
        let total = ids.count
        let skipped = total - loaded.count
        // PDF page backgrounds: the note's attachments and Core Graphics (docs/attachments.md §10);
        // text boxes laid out by CoreText exactly as the canvas shows them (`CoreTextShaper`).
        // An attachment that cannot be read is a placeholder in the export, never a failure.
        let render = Task.detached(priority: .userInitiated) { [loaded, vault] in
            try ShareExport.run(loaded, options: options, into: scratch, vaultSource: source,
                                blobs: { vault.blobSource(note: $0) }, pdfRasterizer: PDFKitRasterizer(),
                                shaper: CoreTextShaper(),
                                progress: { done, _ in
                let shown = done + skipped
                Task { @MainActor in progress(ExportProgress(phase: .rendering, done: shown, total: total)) }
            })
        }
        var result = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
        try ensureCurrent(gen)
        result.failures = failures + result.failures
        return result
    }
}

extension AppModel {
    /// Downloads (iCloud) every blob a media export of `state` writes:
    /// recordings and their transcripts, clips, images and PDFs
    /// (`MediaExport.plan`). Failures are left to the export, which reports them.
    func ensureMediaLocal(_ state: NoteState, of id: UUID) async {
        for p in MediaExport.plan(state) {
            try? await ensureBlobLocal(p.ref, of: id)
            if let t = p.transcript { try? await ensureBlobLocal(t, of: id) }
        }
    }

    /// Reads one note for an export: downloaded first in iCloud Drive, read
    /// inside one coordinated read that checks every revision is local before
    /// and after (an evicted or newly listed revision would export an older
    /// note without a word).
    func loadNoteForExport(_ id: UUID, vault: Vault) async throws -> LoadedForExport {
        try await downloadNote(id)
        let coordinate = coordinationURL
        let cloud = isCloudVault
        let hooks = cloudHooks
        let url = vault.url
        return try await offMain {
            try CloudVault.coordinatedRead(coordinate) { () throws -> LoadedForExport in
                if cloud { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
                let note = try vault.loadNote(id)
                if cloud { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
                return LoadedForExport(summary: vault.summary(of: id, loaded: note), state: try vault.reconstruct(note),
                                       version: BulkExportPlan.version(of: note))
            }
        }
    }
}

struct LoadedForExport: Sendable {
    let summary: NoteSummary
    let state: NoteState
    /// `BulkExportPlan.version` of the revisions read.
    var version = ""
}
