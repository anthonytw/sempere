import Sempere
import SempereRender
import SwiftUI

/// The export actions, in one place: the note list's toolbar and context menu,
/// the note's toolbar and the Catalyst menu bar all build their items from
/// this type, so a title, icon or shortcut changes once. HTML is the CLI's
/// only (`sempere export --format html`); the app does not offer it.
enum ExportCommand: String, CaseIterable, Identifiable, Sendable {
    case pdf, png, markdown, media

    var id: String { rawValue }

    var format: ShareFormat {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .markdown: return .markdown
        case .media: return .media
        }
    }

    /// The menu item's title ("Export as PDF…").
    var title: String {
        switch self {
        case .pdf: return String(localized: "PDF…", comment: "Export menu item: export as PDF")
        case .png: return String(localized: "PNG Pages…", comment: "Export menu item: one PNG per page")
        case .markdown: return String(localized: "Text (Markdown)…", comment: "Export menu item: recognized text as Markdown")
        case .media: return String(localized: "Media…", comment: "Export menu item: the notes' recordings, videos, images and PDFs as files")
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .png: return "photo.on.rectangle"
        case .markdown: return "text.document"
        case .media: return "paperclip"
        }
    }

    /// The formats the export sheet offers, in menu order.
    static var formats: [ShareFormat] { allCases.map(\.format) }

    /// Whether the command makes sense for notes with these summaries: the
    /// text export needs recognised handwriting in at least one of them
    /// (otherwise it would hold titles and tags only), the media export a
    /// recording, video, image or PDF (`MediaExport.mayHaveMedia`).
    static func isAvailable(_ format: ShareFormat, for notes: [NoteSummary]) -> Bool {
        switch format {
        case .markdown: return notes.contains { $0.recognizedPages > 0 }
        case .media: return notes.contains(where: MediaExport.mayHaveMedia)
        default: return true
        }
    }

    /// The submenu's title.
    static let menuTitle = String(localized: "Export")
    static let menuImage = "square.and.arrow.up"
}

/// "Export ▸ PDF…, PNG Pages…, Text (Markdown)…, Media…" for `ids` (the notes,
/// in the order given). Disabled without notes; the text export is disabled
/// when no note has recognised handwriting, the media export when none has media.
struct ExportMenu: View {
    @AppModelEnvironment private var model
    /// The window's UI state: the export sheet opens in this window.
    @Environment(WindowUI.self) private var ui: WindowUI?
    let ids: [UUID]

    var body: some View {
        Menu(ExportCommand.menuTitle, systemImage: ExportCommand.menuImage) {
            ForEach(ExportCommand.allCases) { command in
                Button(command.title, systemImage: command.systemImage) {
                    model.requestExport(command, ids: ids, window: ui?.id)
                }
                .disabled(!model.canExport(command.format, ids: ids))
            }
            Divider()
            // Several notes as files in a folder (resumable) or one zip archive (`BulkExportSheet`).
            Button("To Folder or Zip…", systemImage: "folder") {
                model.requestBulkExport(.notes(ids), window: ui?.id)
            }
        }
        .disabled(ids.isEmpty || model.phase != .unlocked)
        .help("Export as PDF, PNG pages or text")
    }
}

/// The same actions in the iPad's keyboard menu (⌘ held), for the notes of
/// the focused window (`CommandRouter.exportIDs`). The Mac's File menu has
/// `MenuCommand.exportNotes` (Export…, ⇧⌘E) instead, whose sheet picks the format.
struct ExportMenuCommands: Commands {
    let model: AppModel
    @FocusedValue(\.commandRouter) private var router

    var body: some Commands {
        CommandGroup(after: .importExport) {
            let ids = router?.exportIDs ?? []
            Menu(ExportCommand.menuTitle) {
                ForEach(ExportCommand.allCases) { command in
                    Button(command.title) { model.requestExport(command, ids: ids, window: router?.windowID) }
                        .disabled(model.phase != .unlocked || !model.canExport(command.format, ids: ids))
                }
            }
        }
    }
}
