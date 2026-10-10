import PDFKit
import Sempere
import SempereRender
import SwiftUI

/// A small preview of a blob in Settings → Storage: images and the first
/// page of a PDF are decrypted (verified, in memory only,
/// `AppModel.attachmentPreviewData`) and drawn small; other kinds show an icon.
/// Images are decoded only as the canvas decodes them (`ImagePreview`).
struct AttachmentThumbnail: View {
    let note: UUID
    let fileName: String
    let kind: BlobKind
    @AppModelEnvironment private var model
    @State private var image: UIImage?

    static let side: CGFloat = 44

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: Self.symbol(kind)).font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: fileName) {
            guard let data = await model.attachmentPreviewData(note: note, fileName: fileName, kind: kind) else { return }
            let side = Self.side * 3
            image = await Task.detached(priority: .utility) { Thumb(image: Self.thumbnail(data, kind: kind, side: side)) }.value.image
        }
        .accessibilityHidden(true)
    }

    /// A finished thumbnail handed back from its background task (never touched there again).
    private struct Thumb: @unchecked Sendable { let image: UIImage? }

    /// The SF Symbol of a kind with no picture.
    static func symbol(_ kind: BlobKind) -> String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "film"
        case .transcript: return "text.quote"
        default: return "doc"
        }
    }

    /// A picture at most `side` points across, or nil when the bytes are not one.
    nonisolated static func thumbnail(_ data: Data, kind: BlobKind, side: CGFloat) -> UIImage? {
        let size = CGSize(width: side, height: side)
        if kind == .pdf {
            return PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: size, for: .cropBox)
        }
        // Decoded as the canvas decodes image items: JPEG and PNG by SempereRender, HEIC/HEIF alone through
        // ImageIO (`ImageIODecoder`), within `ImageLimits.maxPixels`. The blob may come from another person
        // (a shared vault): no other ImageIO codec ever sees it.
        guard let pixels = ImagePreview.image(data, type: "", side: Int(side.rounded(.up)), decoder: ImageIODecoder()),
              let cg = ItemRendering.cgImage(pixels) else { return nil }
        return UIImage(cgImage: cg)
    }
}
