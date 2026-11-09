import Foundation
import Sempere
import SempereRender

/// A note dragged out of the app to the Finder (Mac): written as a PDF, Markdown or HTML file outside the vault, in
/// the model's `exportFolder` (`NotePDFExport.swift`). Drawing goes through `services.exportRendering` (in the app
/// PDFKit, ImageIO and CoreText; headless, none) with its blobs set to the note's. The item providers and the file
/// types (`UTType`) stay in the app (`NoteFileDrag.swift`); so do the words (`DragExportError`, the format's title).
extension AppModelCore {
    /// Renders a note to a PDF in a fresh folder under the model's `exportFolder` and returns its URL (named after
    /// the title, `ExportFileName`). Pending ink of the note, wherever it is open, is saved first so the PDF shows
    /// what is on screen. The file is plaintext: it is for the Finder drop that asked for it, and
    /// `NotePDFExport.purge` removes it later.
    /// - Throws: `ModelError.noVaultOpen`, `DragExportError`, `CancellationError` once the vault closed meanwhile.
    public func exportPDF(noteID: UUID) async throws -> URL {
        let prepared = try await prepareExport(noteID: noteID)
        let url = try await offMain { try prepared.write() }
        try ensureCurrent(prepared.generation)
        return url
    }

    /// The main-actor part of `exportPDF`: saves the note's pending ink and makes it local (iCloud Drive). What it
    /// returns renders and writes the file on any thread, without the main actor, so a drop that asks for the file
    /// while the main thread waits (a Mac file promise) still gets it.
    public func prepareExport(noteID: UUID) async throws -> PreparedExport {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        if editor?.noteID == noteID { await editor?.flush() }
        await windowEditors[noteID]?.flush()
        try ensureCurrent(gen)
        try await downloadNote(noteID)
        try ensureCurrent(gen)
        return PreparedExport(vault: vault, noteID: noteID, folder: exportFolder, rendering: services.exportRendering,
                              epoch: exportEpoch, generation: gen, startEpoch: exportEpoch.value)
    }
}

/// Why a dragged note was not written. The app words it (the same sentence `AppModel.ExportError` had).
public enum DragExportError: Error, Equatable, Sendable {
    /// `count` revisions of the note could not be read: it is refused rather than exported with pages missing.
    case unreadableRevisions(Int)
}

/// A note ready to be written outside the vault (`AppModelCore.prepareExport`).
public struct PreparedExport: Sendable {
    public let vault: Vault
    public let noteID: UUID
    /// The model's `exportFolder`: each write makes a folder of its own in it.
    public let folder: URL
    /// What the file is drawn with (`services.exportRendering` when prepared); its blobs are the note's.
    public let rendering: RenderOptions
    let epoch: ExportEpoch
    /// The model's generation when prepared (`ensureCurrent`).
    public let generation: Int
    let startEpoch: Int

    /// Renders the note as a PDF and writes `<folder>/<uuid>/<title>.pdf`. Blocking: call it off the main actor.
    /// Throws `CancellationError` once the vault that prepared it has closed.
    public func write() throws -> URL {
        guard epoch.value == startEpoch else { throw CancellationError() }
        let rendered = try NotePDFExport.render(vault: vault, noteID: noteID, rendering: rendering)
        guard epoch.value == startEpoch else { throw CancellationError() }
        NotePDFExport.purge(olderThan: 3600)   // folders of earlier runs that never closed a vault
        let url = try NotePDFExport.write(rendered, in: folder)
        guard epoch.value == startEpoch else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw CancellationError()
        }
        return url
    }

    /// Renders the note as `format` and writes `<folder>/<uuid>/<title>.<ext>` (Markdown and HTML through the share
    /// exporter, `NoteDragExport`). Blocking: call it off the main actor. Throws `CancellationError` once the vault
    /// that prepared it has closed.
    public func write(format: DragExportFormat) throws -> URL {
        if format == .pdf { return try write() }
        guard epoch.value == startEpoch else { throw CancellationError() }
        NotePDFExport.purge(olderThan: 3600)   // folders of earlier runs that never closed a vault
        NotePDFExport.purge(in: folder)
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url: URL
        do {
            url = try NoteDragExport.write(vault: vault, noteID: noteID, format: format, into: dir, rendering: rendering)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        guard epoch.value == startEpoch else {
            try? FileManager.default.removeItem(at: dir)
            throw CancellationError()
        }
        return url
    }
}

/// Rendering a note to a PDF file outside the vault (Mac drag and drop).
extension NotePDFExport {
    /// A rendered note: its title (the file's name) and the PDF.
    public struct Rendered: Sendable {
        public var title: String
        public var pdf: Data

        public init(title: String, pdf: Data) {
            self.title = title
            self.pdf = pdf
        }
    }

    /// The note's PDF, drawn with `rendering` (its blobs set to the note's). A note with unreadable revisions is
    /// refused rather than exported with pages missing (`DragExportError`).
    public static func render(vault: Vault, noteID: UUID, rendering: RenderOptions) throws -> Rendered {
        let loaded = try vault.loadNote(noteID)
        guard loaded.failures.isEmpty else { throw DragExportError.unreadableRevisions(loaded.failures.count) }
        let state = try NoteReducer.reconstruct(loaded.revisions)
        // PDF page backgrounds are copied from the note's attachments (docs/attachments.md §10); text boxes are laid
        // out by the services' shaper (CoreText in the app) as the canvas shows them.
        var options = rendering
        options.blobs = vault.blobSource(note: noteID)
        return Rendered(title: state.meta.title, pdf: try PDFWriter.render(note: state, options: options))
    }

    /// Writes `rendered` to `<folder>/<uuid>/<title>.pdf`, old exports removed first.
    public static func write(_ rendered: Rendered, in folder: URL = NotePDFExport.folder) throws -> URL {
        purge(in: folder)
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ExportFileName.pdf(title: rendered.title))
        try rendered.pdf.write(to: url, options: .atomic)
        return url
    }
}

/// Markdown and HTML for one dragged note (`PreparedExport.write(format:)`), written by the share exporter
/// (`ShareExport`) as one file, exactly as Share ▸ Text (Markdown) and Share ▸ HTML write it.
public enum NoteDragExport {
    /// The note could not be rendered in the chosen format (the exporter's own reason).
    public struct Failed: Error, CustomStringConvertible, Sendable {
        public var reason: String
        public var description: String { reason }
    }

    /// Writes `noteID` as `format` (Markdown or HTML) into the new folder `dir`, drawn with `rendering`'s PDF
    /// rasterizer, shaper and image decoder, named as a dropped PDF is (`ExportFileName.base`), and returns the file.
    public static func write(vault: Vault, noteID: UUID, format: DragExportFormat, into dir: URL,
                             rendering: RenderOptions) throws -> URL {
        let loaded = try vault.loadNote(noteID)
        guard loaded.failures.isEmpty else { throw DragExportError.unreadableRevisions(loaded.failures.count) }
        let state = try NoteReducer.reconstruct(loaded.revisions)
        let summary = vault.summary(of: noteID, loaded: loaded)
        let share: ShareFormat = format == .html ? .html : .markdown
        let result = try ShareExport.run([(summary, state)], options: ShareOptions(format: share), into: dir,
                                         vaultSource: "sempere:\(vault.vaultId.uuidString.lowercased())",
                                         blobs: { _ in vault.blobSource(note: noteID) },
                                         pdfRasterizer: rendering.pdfRasterizer, shaper: rendering.shaper,
                                         imageDecoder: rendering.imageDecoder)
        guard result.exported == 1, let written = result.items.first else {
            throw Failed(reason: result.failures.first ?? "the note could not be exported")
        }
        let named = dir.appendingPathComponent(ExportFileName.base(title: state.meta.title))
            .appendingPathExtension(format.fileExtension)
        guard written != named else { return written }
        try FileManager.default.moveItem(at: written, to: named)
        return named
    }
}

/// Settings ▸ General ▸ Drag to Finder: the file a note dragged out of the note list becomes (Mac). Only formats the
/// share exporter writes as one file for one note (`ShareExport`); synced as `drag.format` (Mac only). Its titles and
/// whether Settings shows it are the app's.
public enum DragExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf, markdown, html

    public var id: String { rawValue }

    public static let key = "Sempere.dragFormat"
    public static let defaultValue = DragExportFormat.pdf

    /// The stored choice, the default when unset or unknown.
    public static func load(from defaults: any KeyValueStore) -> DragExportFormat {
        defaults.string(forKey: key).flatMap(DragExportFormat.init(rawValue:)) ?? defaultValue
    }

    public static func save(_ value: DragExportFormat, to defaults: any KeyValueStore) {
        defaults.set(value.rawValue, forKey: key)
    }

    /// The dropped file's extension.
    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .html: return "html"
        }
    }
}

/// File names for exported notes (drag to Finder).
public enum ExportFileName {
    /// The longest base name in bytes (file systems allow 255 for the whole name).
    public static let maxBytes = 120

    /// `title` as a safe `.pdf` file name: no path separators, colons or control characters, no leading dot,
    /// bounded length, "Untitled" when nothing is left.
    public static func pdf(title: String) -> String {
        base(title: title) + ".pdf"
    }

    /// The name without its extension (a dropped file's suggested name; the system adds `.pdf`, `.md`, `.html`).
    public static func base(title: String) -> String {
        var cleaned = ""
        for scalar in title.unicodeScalars {
            switch scalar {
            case "/", ":", "\\", "\0": cleaned.unicodeScalars.append(" ")
            default:
                if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                    cleaned.unicodeScalars.append(" ")
                } else {
                    cleaned.unicodeScalars.append(scalar)
                }
            }
        }
        var words = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        while let first = words.first, first == "." || first == " " { words.removeFirst() }
        var base = ""
        for character in words {
            if base.utf8.count + String(character).utf8.count > maxBytes { break }
            base.append(character)
        }
        base = base.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Untitled" : base
    }
}
