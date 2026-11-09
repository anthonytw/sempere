import Foundation
import Sempere
import SempereRender
import SempereAppCore

// The words of export's values (`AppModel+Export.swift`, `AppModel+BulkExport.swift` and `ExportJob.swift` in
// SempereAppCore): the progress lines, the bulk export's title, why a run failed and why a note was left out.

extension ExportProgress {
    var description: String {
        switch phase {
        case .reading: return String(localized: "Reading note \(min(done + 1, total)) of \(total)…")
        case .rendering: return done >= total ? String(localized: "Finishing…", comment: "Export progress: last step") : String(localized: "Exporting note \(done + 1) of \(total)…")
        }
    }
}

extension BulkExportProgress {
    var description: String {
        done >= total ? String(localized: "Finishing…") : String(localized: "Exporting note \(done + 1) of \(total)…")
    }
}

extension BulkExportRequest {
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
}

extension ExportRunFailure {
    /// The sheet's line under "Export failed".
    var text: String {
        switch self {
        case .error(let message), .noteFailed(let message): return message
        case .noMedia: return String(localized: "The notes have no recordings, videos, images or PDFs.")
        case .nothingExported: return String(localized: "There was nothing to export.")
        case .noNotes: return String(localized: "There are no notes to export.")
        case .folderInsideVault: return String(localized: "Choose a folder outside the vault: exported notes are not encrypted.")
        }
    }
}

extension UnsavedChangesError {
    var text: String {
        String(localized: "Its latest changes could not be saved, so it was not exported.")
    }
}

/// Why a note dragged out (`PreparedExport` in SempereAppCore) was not written: the sentence `AppModel.ExportError`
/// had in the app, same string and catalog key.
extension DragExportError {
    var text: String {
        switch self {
        case .unreadableRevisions(let n):
            return String(localized: "\(n) revisions of this note could not be read, so it cannot be exported completely.")
        }
    }
}
