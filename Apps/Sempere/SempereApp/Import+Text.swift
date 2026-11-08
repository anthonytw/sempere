import Foundation
import Sempere
import SempereAppCore
import SempereImport
import UniformTypeIdentifiers

// The words of an import's values (`AppModel+Import.swift` in SempereAppCore): the report's row names, the alert's
// title and lines, the saved report, and the picker's types.

extension AppModel {
    /// What `importer` reads (`importFileKinds`) as the file picker's types.
    static func importTypes(for importer: any VaultImporter) -> [UTType] {
        importFileKinds(for: importer).compactMap { kind in
            switch kind {
            case .zip: return .zip
            case .folder: return .folder
            case .fileExtension(let ext): return UTType(filenameExtension: ext)
            }
        }
    }
}

extension ImportDetails.Row {
    /// The localized name of the line (`ImportDetails.label`).
    var label: String { ImportDetails.label(key: key, english: english) }
}

extension ImportDetails {
    /// The localized name of a counted line: the ids the importers use today have catalog entries; an id
    /// the app does not know shows the importer's English words.
    static func label(key: String, english: String) -> String {
        switch key {
        // Imported
        case "pdfPages": return String(localized: "PDF pages", comment: "Import report row")
        case "pdfTextPages": return String(localized: "PDF pages with text for search", comment: "Import report row")
        case "images": return String(localized: "Images", comment: "Import report row")
        case "textItems": return String(localized: "Text boxes", comment: "Import report row")
        case "recordings": return String(localized: "Recordings", comment: "Import report row")
        case "transcripts": return String(localized: "Transcripts", comment: "Import report row")
        case "recLinkedStrokes": return String(localized: "Strokes linked to a recording", comment: "Import report row")
        // Left out
        case "typedTextCharacters": return String(localized: "Typed text (characters)", comment: "Import report: not imported")
        case "pdfs": return String(localized: "PDF files", comment: "Import report: not imported")
        case "media": return String(localized: "Images and other media", comment: "Import report: not imported")
        case "pdfHighlights": return String(localized: "PDF highlights", comment: "Import report: not imported")
        case "templatePDFs": return String(localized: "Template PDF paper", comment: "Import report: not imported")
        case "recLinks": return String(localized: "Links from strokes to recordings", comment: "Import report: not imported")
        case "dashedStrokes": return String(localized: "Dashed strokes (imported solid)", comment: "Import report: not imported")
        case "unknownStyleStrokes":
            return String(localized: "Strokes of an unknown style (imported as pen)", comment: "Import report: not imported")
        case "defaultedAttributeStrokes":
            return String(localized: "Strokes with a missing style, color or width", comment: "Import report: not imported")
        case "unsupportedShapes": return String(localized: "Shapes not converted", comment: "Import report: not imported")
        case "unsupportedStrokes": return String(localized: "Strokes of a kind not understood", comment: "Import report: not imported")
        case "clampedStrokes": return String(localized: "Strokes whose position was not stored", comment: "Import report: not imported")
        case "bundleRecordsWithoutFile":
            return String(localized: "Attachments with no file in the backup", comment: "Import report: not imported")
        case "bundleFilesUnreferenced": return String(localized: "Attachment files no note names", comment: "Import report: not imported")
        default: return english
        }
    }
}

extension ImportSummary {
    var title: String {
        if wasCancelled { return String(localized: "Import Canceled", comment: "Alert title after an import from another app was stopped") }
        return failed > 0 ? String(localized: "Import Finished with Errors", comment: "Alert title after an import from another app")
            : String(localized: "\(source) Import", comment: "Alert title after an import from another app (the app's name)")
    }

    /// Whole sentences, one per line (never joined fragments: docs/localization.md).
    var message: String {
        if nothingFound {
            return String(localized: "No notes from \(source) were found in what you picked.",
                          comment: "Import result when the chosen files held nothing to import (the app's name)")
        }
        var lines = [String(localized: "\(imported) notes imported.", comment: "Import result: notes written")]
        if skipped > 0 {
            lines.append(String(localized: "\(skipped) notes skipped (already in the vault, or a copy of a note imported from another file).",
                                comment: "Import result"))
        }
        if cancelled > 0 {
            lines.append(String(localized: "\(cancelled) notes not imported because you canceled. Import the same files again to continue: notes already in the vault are skipped.",
                                comment: "Import result after Cancel"))
        }
        if details.recognitionAsked, details.recognizedPages > 0 {
            lines.append(String(localized: "Handwriting read on \(details.recognizedPages) pages.",
                                comment: "Import result: pages the app read after the import"))
        }
        if details.recognitionFailed > 0 {
            lines.append(String(localized: "Handwriting could not be read in \(details.recognitionFailed) notes.",
                                comment: "Import result: notes the app could not read after the import"))
        }
        if failed > 0 {
            lines.append(String(localized: "\(failed) notes failed:", comment: "Import result, followed by one line per note"))
            lines += failures.prefix(5)
            if failures.count > 5 {
                lines.append(String(localized: "…and \(failures.count - 5) more.", comment: "After the first failed notes of an import"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The whole report as text, for Save Report… (`ImportReportText`): the summary, the totals and every note's
    /// line as `sempere import <id> -v` prints it (file names and titles of the user's own backup).
    var reportText: String { ImportReportText.text(summary: self) }
}

/// The import report as a text file (Save Report… in `ImportReportView`): the alert's title and lines, the
/// date, the localized totals, then the importer's own per-note lines (English, as `sempere import <id> -v`
/// prints them).
enum ImportReportText {
    /// The text of `summary`'s report; empty for a summary not made from an importer's result.
    static func text(summary: ImportSummary) -> String {
        guard let date = summary.details.date else { return "" }
        var out = [summary.title, date.formatted(date: .long, time: .standard), "", summary.message]
        if !summary.details.imported.isEmpty {
            out += ["", String(localized: "Imported", comment: "Import report heading")]
            out += summary.details.imported.map { "  \($0.label): \($0.count)" }
        }
        if !summary.details.notImported.isEmpty {
            out += ["", String(localized: "Not Imported", comment: "Import report heading")]
            out += summary.details.notImported.map { "  \($0.label): \($0.count)" }
        }
        let lines = summary.details.noteLines
        if !lines.isEmpty {
            out += ["", String(localized: "Notes", comment: "Import report heading: one line per imported file")]
            out += lines
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Writes `text` to a new file under the temporary folder for the share sheet or save panel; the caller
    /// removes the folder (`discard`) when the report closes.
    static func write(_ text: String, name: String = String(localized: "Import Report", comment: "File name of a saved import report")) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SempereImportReports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name + ".txt")
        try Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
