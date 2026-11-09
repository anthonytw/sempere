import Foundation
import Sempere
import SempereRender

/// What turns picked images, PDFs and clips into what is stored (docs/attachments.md §7, §8, §14 G2): the platform's
/// part of an insert, behind `AppModelServices.attachmentPreparation`. The app's is PDFKit and Core Graphics (an
/// encrypted PDF is unlocked and redrawn), ImageIO (HEIC, WebP, CMYK conversions) and AVFoundation (a clip in another
/// codec is converted; the poster frame); `PortableAttachmentPreparation` is the package's own, as the CLI on Linux
/// does it. Each method runs off the main actor.
public protocol AttachmentPreparing: Sendable {
    /// What to store for the PDF at `copy` (a work copy, `ImportWorkFolder`). `password` unlocks a PDF with a user
    /// password; a PDF that needs one throws `PDFLocked`.
    func preparePDF(_ copy: URL, password: String?) throws -> PreparedPDF
    /// What to store for image bytes; `privacy` is the photo privacy setting (`PhotoPrivacy`).
    func prepareImage(_ data: Data, privacy: Bool) throws -> PreparedImage
    /// What to store for the clip at `file` (a work copy); a converted clip replaces it in its work folder.
    func prepareVideo(_ file: URL, privacy: Bool) async throws -> PreparedVideo
    /// A poster frame for a stored clip that has none (the clip at `file`, of media type `mediaType`); nil when this
    /// platform cannot take one.
    func videoPoster(file: URL, mediaType: String?) async throws -> PreparedImage?
    /// Whether the system types the file at `url` as a PDF (the app reads its `UTType`); its extension is checked
    /// apart (`OpenedFile.kind`).
    func isPDFType(_ url: URL) -> Bool
}

/// A PDF that cannot be prepared without its password: ask for it (`PDFImportOutcome.needsPassword`).
public enum PDFLocked: Error, Equatable, Sendable {
    /// Encrypted with a user password.
    case needsPassword
    /// The password given does not open it.
    case wrongPassword
}

/// A picked file over the format's limit (format.md §8.4), with its size in bytes. The app words it.
public enum AttachmentTooLarge: Error, Equatable, Sendable {
    case pdf(Int64)
    case video(Int64)
}

/// The photo privacy setting (docs/attachments.md §7, §15): *Remove location and camera data from photos and
/// convert HEIC to JPEG*, on by default, per device. Exports strip location and camera data whatever it says.
public enum PhotoPrivacy {
    public static let key = "Sempere.photoPrivacy"
    public static let defaultValue = true

    /// The setting as stored (on when never set, or when what is stored is not a Bool).
    public static func isOn(_ settings: any KeyValueStore) -> Bool {
        settings.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// The work folders picked files are copied into before they are prepared (plaintext: removed once stored, and all
/// of them at launch and quit, `purge`): one folder per import under `SempereImport` in the temporary directory.
public enum ImportWorkFolder {
    /// Largest PDF accepted (format.md §8.4: 1 GiB per blob).
    public static let maxPDFBytes = 1 << 30

    /// `SempereImport` in the temporary directory.
    public static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereImport", isDirectory: true)
    }

    /// A folder of its own for one import.
    public static func make() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a picked file (security-scoped, from a picker, a drop or the system's Open With: its scope is taken
    /// through `bookmarks`) into a new work folder. A file larger than `limit` (nil: none) is refused before it is
    /// copied (`AttachmentTooLarge.pdf`: only PDFs have a limit before they are prepared).
    public static func copyPicked(_ url: URL, fallbackName: String = "picked.pdf", limit: Int? = maxPDFBytes,
                                  bookmarks: any FolderBookmarks) throws -> URL {
        try bookmarks.withAccess(to: url) {
            if let limit {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= limit else { throw AttachmentTooLarge.pdf(Int64(size)) }
            }
            let copy = try make().appendingPathComponent(url.lastPathComponent.isEmpty ? fallbackName : url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
    }

    /// Removes a work file and its folder (plaintext); a file outside the work folders alone.
    public static func discard(_ file: URL) {
        let dir = file.deletingLastPathComponent()
        if dir.deletingLastPathComponent().lastPathComponent == "SempereImport" {
            try? FileManager.default.removeItem(at: dir)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes every work folder (a crash may leave one behind).
    public static func purge() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The package's own preparation, as `sempere attach` and `sempere import pdf` do it on Linux: PDFs are read by
/// `PDFIngest` (an encrypted or damaged PDF is refused, never redrawn), images by `ImageIngest` with no converter
/// (JPEG and PNG only), clips by `VideoProbe` with their metadata removed by `VideoMetadata` (no conversion, no
/// poster). `AppModelServices.headless()` uses it.
public struct PortableAttachmentPreparation: AttachmentPreparing {
    /// Reads each PDF page's text for search (`BuiltinPDFTextExtractor`, as the CLI); nil: none.
    public var pdfText: (any PDFTextExtracting)?

    public init(pdfText: (any PDFTextExtracting)? = BuiltinPDFTextExtractor()) {
        self.pdfText = pdfText
    }

    public func preparePDF(_ copy: URL, password: String?) throws -> PreparedPDF {
        let data: Data
        do {
            data = try BoundedRead.contents(of: copy, maxBytes: ImportWorkFolder.maxPDFBytes)
        } catch VaultError.fileTooLarge {
            let size = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            throw AttachmentTooLarge.pdf(Int64(size))
        }
        let pages = PDFIngest.withText(try PDFIngest.inspect(data).pages, pdf: data, extractor: pdfText).refs
        return PreparedPDF(file: copy, pages: pages, decrypted: false, name: copy.deletingPathExtension().lastPathComponent)
    }

    public func prepareImage(_ data: Data, privacy: Bool) throws -> PreparedImage {
        try ImageIngest.prepare(data, privacy: privacy, converter: nil)
    }

    public func prepareVideo(_ file: URL, privacy: Bool) async throws -> PreparedVideo {
        let info = try VideoProbe.probe(file: file)
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size <= VideoIngestRules.maxBytes else { throw AttachmentTooLarge.video(size) }
        return PreparedVideo(file: file, info: info, edits: privacy ? VideoMetadata.strippingEdits(info) : [], poster: nil)
    }

    public func videoPoster(file: URL, mediaType: String?) async throws -> PreparedImage? { nil }

    public func isPDFType(_ url: URL) -> Bool { false }
}
