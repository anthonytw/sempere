import Foundation
import Sempere
import SempereAppCore
import SempereRender
import UniformTypeIdentifiers

/// The app's `AttachmentPreparing` (`AppModelServices.attachmentPreparation`): PDFs through Core Graphics and PDFKit
/// (`PDFPreparation`: an encrypted PDF is unlocked and redrawn, page text read by PDFKit), images through ImageIO
/// (`ImagePreparation`), clips through AVFoundation (`VideoPreparation`, `VideoPoster`), and an opened file's type
/// through `UTType`.
struct AppAttachmentPreparation: AttachmentPreparing {
    func preparePDF(_ copy: URL, password: String?) throws -> PreparedPDF {
        try PDFPreparation.prepare(copy, password: password)
    }

    func prepareImage(_ data: Data, privacy: Bool) throws -> PreparedImage {
        try ImagePreparation.prepare(data, privacy: privacy)
    }

    func prepareVideo(_ file: URL, privacy: Bool) async throws -> PreparedVideo {
        try await VideoPreparation.prepare(file, privacy: privacy)
    }

    func videoPoster(file: URL, mediaType: String?) async throws -> PreparedImage? {
        try await VideoPoster.jpeg(file: file, mediaType: mediaType)
    }

    func isPDFType(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .pdf) == true
    }
}
