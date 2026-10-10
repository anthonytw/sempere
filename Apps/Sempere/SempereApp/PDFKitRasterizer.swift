import CoreGraphics
import Foundation
import SempereRender

/// The app's `PDFPageRasterizer` (`docs/attachments.md` §10, §13): Core
/// Graphics' PDF renderer, the one PDFKit draws with, so exports show PDF
/// page backgrounds as the canvas does. The CLI uses Poppler instead.
///
/// The page is drawn through the effective-page matrix of `format.md`
/// §8.5.1 (`PDFPageGeometry`), not `CGPDFPage.getDrawingTransform`, which
/// never scales up and centres instead of stretching. White underneath, as
/// viewers and Poppler show a page.
struct PDFKitRasterizer: PDFPageRasterizer {
    enum Failure: Error, Equatable {
        case unreadable
        case locked
        case noPage(Int)
        case tooLarge
        case context
    }

    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= RenderLimits.maxBackgroundPixels / pixelHeight else { throw Failure.tooLarge }
        guard let document = CGPDFDocument(pdf as CFURL) else { throw Failure.unreadable }
        // Stored PDFs carry no /Encrypt (format.md §8.2.6); a locked one is not drawn.
        guard document.isUnlocked else { throw Failure.locked }
        guard pageIndex >= 0, pageIndex < document.numberOfPages,
              let page = document.page(at: pageIndex + 1) else { throw Failure.noPage(pageIndex) }
        guard let geometry = page.effectiveGeometry else { throw Failure.unreadable }
        let width = geometry.size.width, height = geometry.size.height
        // PDF user space → effective page (y down) → pixels (y down) → Core Graphics (y up).
        let toPixels = CGAffineTransform(a: CGFloat(pixelWidth) / width, b: 0, c: 0, d: -CGFloat(pixelHeight) / height,
                                         tx: 0, ty: CGFloat(pixelHeight))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: pixelWidth * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.context
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.concatenate(geometry.toEffective.concatenating(toPixels))
        context.drawPDFPage(page)
        guard let data = context.data else { throw Failure.context }
        // Opaque (white underneath), so premultiplied equals straight alpha. Row 0 is the top.
        let bytes = [UInt8](UnsafeRawBufferPointer(start: data, count: pixelWidth * pixelHeight * 4))
        return try RGBAImage(width: pixelWidth, height: pixelHeight, pixels: bytes)
    }
}

extension CGPDFPage {
    /// The effective page of `format.md` §8.5.1: its size (the visible box,
    /// CropBox ∩ MediaBox, turned by /Rotate) and the matrix from PDF user
    /// space onto it (y down, `PDFPageGeometry`). Nil when the box is empty
    /// or not finite. Quartz returns the CropBox as stored.
    var effectiveGeometry: (size: CGSize, toEffective: CGAffineTransform)? {
        let box = getBoxRect(.cropBox).intersection(getBoxRect(.mediaBox))
        guard !box.isNull, box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { return nil }
        let rotation = ((Int(rotationAngle) % 360) + 360) % 360
        let m = PDFPageGeometry.userToEffective(x0: box.minX, y0: box.minY, x1: box.maxX, y1: box.maxY,
                                                rotation: rotation)
        let turned = rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : CGSize(width: box.width, height: box.height)
        return (size, CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
    }
}
