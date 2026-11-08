import Foundation
import Sempere
import SempereRender

/// A request whose sheet shows in the window that asked for it.
public protocol WindowTargeted {
    /// The window that asked (`WindowUI.id`): its sheet shows there. Nil: the
    /// library window with the canvas.
    var window: UUID? { get }
}

extension WindowTargeted {
    /// `request` when window `window` shows it: the window that asked, or for
    /// a request without one, the library window with the canvas (or any, when
    /// none has it: `OpenedFile.shows`).
    public static func shown(_ request: Self?, in window: UUID, canvasWindow: UUID?) -> Self? {
        guard let request else { return nil }
        if let asker = request.window { return asker == window ? request : nil }
        return OpenedFile.shows(in: window, canvasWindow: canvasWindow) ? request : nil
    }
}

/// What the export sheet was asked to export.
public struct ExportRequest: Identifiable, Equatable, WindowTargeted {
    public let id = UUID()
    public var noteIDs: [UUID]
    public var format: ShareFormat
    /// The window that asked (`WindowUI.id`): its sheet shows there. Nil: the
    /// library window with the canvas.
    public var window: UUID?

    public init(noteIDs: [UUID], format: ShareFormat, window: UUID? = nil) {
        self.noteIDs = noteIDs
        self.format = format
        self.window = window
    }
}

/// How far an export has come: notes read from the vault, then notes rendered. Its line (`description`) is the
/// app's.
public struct ExportProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case reading, rendering }
    public var phase: Phase
    public var done: Int
    public var total: Int

    public init(phase: Phase, done: Int, total: Int) {
        self.phase = phase
        self.done = done
        self.total = total
    }

    /// 0 ... 1 over both phases.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        let steps = Double(done) + (phase == .rendering ? Double(total) : 0)
        return min(1, steps / Double(2 * total))
    }
}

extension ShareFormat {
    /// Whether exporting notes with these summaries in this format makes sense: the text export needs recognized
    /// handwriting in at least one of them (otherwise it would hold titles and tags only), the media export a
    /// recording, video, image or PDF (`MediaExport.mayHaveMedia`). The app's `ExportCommand` enables its items with it.
    public func isAvailable(for notes: [NoteSummary]) -> Bool {
        switch self {
        case .markdown: return notes.contains { $0.recognizedPages > 0 }
        case .media: return notes.contains(where: MediaExport.mayHaveMedia)
        default: return true
        }
    }
}

/// Share and export (docs/io.md "Share and export").
extension AppModelCore {
    /// The notes the export commands act on: the ticked notes while selecting
    /// (still in the vault), else the open note. In list order.
    public var exportTargetIDs: [UUID] {
        let wanted: Set<UUID> = isSelectingNotes ? multiSelection : (selectedNoteID.map { [$0] } ?? [])
        return notes.filter { wanted.contains($0.id) && !placeholderNoteIDs.contains($0.id) }.map(\.id)
    }

    /// True when `format` can export `ids` (`ShareFormat.isAvailable`):
    /// the text export needs a note with recognized handwriting.
    public func canExport(_ format: ShareFormat, ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return false }
        let wanted = Set(ids)
        return format.isAvailable(for: notes.filter { wanted.contains($0.id) })
    }

    /// Opens the export sheet for `ids` in `format` (the app's `ExportCommand` passes its own).
    public func requestExport(_ format: ShareFormat, ids: [UUID], window: UUID? = nil) {
        // One export at a time: replacing the request would dismiss a running sheet.
        guard phase == .unlocked, canExport(format, ids: ids), exportRequest == nil, bulkExportRequest == nil else { return }
        exportRequest = ExportRequest(noteIDs: ids, format: format, window: window)
    }

    /// Reads `ids` from the vault and renders them into `scratch`.
    ///
    /// Reading and rendering run off the main actor; canceling the calling
    /// task stops both between notes. A note that cannot be read or rendered
    /// is reported in `failures` and the rest are exported. An open note's
    /// pending changes are saved first (`flushEditors`); one whose changes
    /// cannot be saved is reported, not exported without them. Writes
    /// nothing else to the vault. iCloud notes are downloaded first, like for
    /// editing.
    ///
    /// - Throws: `CancellationError` (also when the vault is closed meanwhile),
    ///   `ModelError.noVaultOpen`, or a file error for `scratch`.
    public func exportNotes(_ ids: [UUID], options: ShareOptions, into scratch: URL,
                     progress: @escaping @MainActor @Sendable (ExportProgress) -> Void) async throws -> ShareResult {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        let unsaved = await flushEditors(for: Set(ids))
        try ensureCurrent(gen)
        var loaded: [(NoteSummary, NoteState)] = []
        var failures: [String] = []
        for (i, id) in ids.enumerated() {
            try Task.checkCancellation()
            try ensureCurrent(gen)
            progress(ExportProgress(phase: .reading, done: i, total: ids.count))
            do {
                if unsaved.contains(id) { throw UnsavedChangesError() }
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
            for (summary, state) in loaded { await ensurePDFAttachmentsLocal(state, of: summary.id) }
            try ensureCurrent(gen)
        } else if options.format == .media {
            // "Media": every file the export writes, fetched now; one that cannot be is left out and reported.
            for (summary, state) in loaded { await ensureMediaLocal(state, of: summary.id) }
            try ensureCurrent(gen)
        }
        let source = "sempere:\(vault.vaultId.uuidString.lowercased())"
        let total = ids.count
        let skipped = total - loaded.count
        // PDF page backgrounds: the note's attachments and the platform's drawing (`services.exportRendering`: in
        // the app Core Graphics, docs/attachments.md §10); text boxes laid out by CoreText exactly as the canvas
        // shows them (`CoreTextShaper`). An attachment that cannot be read is a placeholder in the export, never a
        // failure.
        let base = services.exportRendering
        let render = Task.detached(priority: .userInitiated) { [loaded, vault] in
            try ShareExport.run(loaded, options: options, into: scratch, vaultSource: source,
                                blobs: { vault.blobSource(note: $0) }, pdfRasterizer: base.pdfRasterizer,
                                shaper: base.shaper, imageDecoder: base.imageDecoder,
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

/// An open note's changes could not be saved (`NoteEditor.saveFailure`): it
/// is not exported, since the export would differ from what the note shows. Its sentence is the app's.
public struct UnsavedChangesError: Error, Equatable {
    public init() {}
}

extension AppModelCore {
    /// Saves the pending changes of every open editor (the main one and note
    /// windows) of a note in `ids`, as a drag-out does (`prepareExport`), so
    /// an export reads what the canvas shows. Returns the notes whose editor
    /// still could not save (`saveFailure`).
    public func flushEditors(for ids: Set<UUID>) async -> Set<UUID> {
        var open: [Editor] = []
        if let editor, ids.contains(editor.noteID) { open.append(editor) }
        open += windowEditors.filter { ids.contains($0.key) }.map(\.value)
        var unsaved = Set<UUID>()
        for editor in open {
            await editor.flush()
            if editor.saveFailure != nil { unsaved.insert(editor.noteID) }
        }
        return unsaved
    }

    /// Downloads (iCloud) every blob "PDF + attachments" embeds for `state`:
    /// recordings and their transcripts, and video clips (format.md §8.2.7),
    /// fetched only now, when they are embedded. Failures are left to the
    /// export, which reports them.
    public func ensurePDFAttachmentsLocal(_ state: NoteState, of id: UUID) async {
        for r in state.recordings {
            try? await ensureBlobLocal(r.blob, of: id)
            if let t = r.transcript { try? await ensureBlobLocal(t, of: id) }
        }
        for clip in ExportVideos.clips(of: state) { try? await ensureBlobLocal(clip.ref, of: id) }
    }

    /// Downloads (iCloud) every blob a media export of `state` writes:
    /// recordings and their transcripts, clips, images and PDFs
    /// (`MediaExport.plan`). Failures are left to the export, which reports them.
    public func ensureMediaLocal(_ state: NoteState, of id: UUID) async {
        for p in MediaExport.plan(state) {
            try? await ensureBlobLocal(p.ref, of: id)
            if let t = p.transcript { try? await ensureBlobLocal(t, of: id) }
        }
    }

    /// Reads one note for an export: fetched first in a partial copy (`downloadNote`), which refuses a note
    /// still incomplete (an export of a partial note would be an older note without a word).
    public func loadNoteForExport(_ id: UUID, vault: Vault) async throws -> LoadedForExport {
        try await downloadNote(id)
        let verify = partialNoteVerifier(id)
        return try await offMain { () throws -> LoadedForExport in
            try verify?()
            let note = try vault.loadNote(id)
            return LoadedForExport(summary: vault.summary(of: id, loaded: note), state: try vault.reconstruct(note),
                                   version: BulkExportPlan.version(of: note))
        }
    }
}

public struct LoadedForExport: Sendable {
    public let summary: NoteSummary
    public let state: NoteState
    /// `BulkExportPlan.version` of the revisions read.
    public var version = ""

    public init(summary: NoteSummary, state: NoteState, version: String = "") {
        self.summary = summary
        self.state = state
        self.version = version
    }
}
