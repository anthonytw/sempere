import Foundation
import Sempere
import SempereAppCore
import SempereRender

// The words of the inserts' and opened files' values (`AppModel+Insert.swift`, `AppModel+Video.swift` and
// `AppModel+OpenedFiles.swift` in SempereAppCore; moved with wave 5b part 3, step 5c), the strings unchanged.

/// The core's PDF import types under the names the views use.
typealias PDFDestination = AppModel.PDFDestination
typealias PDFImportRequest = AppModel.PDFImportRequest
typealias PDFImportOutcome = AppModel.PDFImportOutcome

extension InsertNotice: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .imageNotAdded(let error):
            return String(localized: "Could not add the image. \(AppModel.describe(error))")
        case .imageNotReplaced(let error):
            return String(localized: "Could not replace the image. \(AppModel.describe(error))")
        case .pdfNotImported(let error):
            return String(localized: "Could not import the PDF. \(AppModel.describe(error))")
        case .videoNotAdded(let error):
            return String(localized: "Could not add the video. \(AppModel.describe(error))", comment: "The value is a sentence saying why")
        case .fileNotOpened(let name, let error):
            return String(localized: "Could not open “\(name)”. \(AppModel.describe(error))",
                          comment: "A file opened with Sempere: its name, then a sentence saying why")
        }
    }
}

extension PDFLocked: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .needsPassword: return String(localized: "This PDF is protected with a password.")
        case .wrongPassword: return String(localized: "That password does not open this PDF.")
        }
    }
}

extension AttachmentTooLarge: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .pdf(let n):
            let size = BlobSizeText.string(n)
            let limit = BlobSizeText.string(Int64(ImportWorkFolder.maxPDFBytes))
            return String(localized: "This PDF is too large to add (\(size); at most \(limit)).", comment: "The values are file sizes")
        case .video(let n):
            let size = BlobSizeText.string(n)
            let limit = BlobSizeText.string(VideoIngestRules.maxBytes)
            return String(localized: "This video is too large to add (\(size); at most \(limit)). Trim it first.",
                          comment: "The values are file sizes")
        }
    }
}

extension AppModel {
    /// A sentence for an import error.
    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let e as ImagePreparation.Failure: return e.description
        case let e as PDFPreparation.Failure: return e.description
        case let e as PDFLocked: return e.description
        case let e as AttachmentTooLarge: return e.description
        case let e as AttachmentOpsError:
            if case .pagelessNote = e { return String(localized: "This note is pageless: switch it to pages first, or import the PDF as a new note.") }
            return "\(e)"
        case let e as ImageIngestError: return e.description
        case let e as VideoPreparation.Failure: return e.description
        case let e as VideoProbeError: return e.description
        default: return "\(error)"
        }
    }
}

extension AppModel.OpenedVaultConfirmation {
    /// The vault open now, as the alert names it.
    var currentName: String {
        current ?? String(localized: "Vault", comment: "Name shown for a vault that has none")
    }
}
