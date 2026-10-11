import Foundation
import Sempere
import SemperePDF

/// One export's access to PDF blobs: each PDF is read and parsed once, each
/// rasterized page is cached by size, and all rasterizing shares one pixel
/// budget. Not thread-safe; one per render call.
///
/// With a rasterizer and a blob source that decrypts on every `withFile`,
/// each PDF that parses is also written once to a private
/// temporary file (mode 0600 in a 0700 folder) that every page of it is
/// rasterized from, with the rotation already parsed; the folder is removed
/// when the object goes (end of the export, or its cancellation). Before,
/// every page decrypted the whole blob to a new temporary file and the
/// rasterizer parsed the PDF again.
final class PDFBackgrounds {
    let blobs: (any BlobSource)?
    let rasterizer: (any PDFPageRasterizer)?
    private var files: [String: Result<PDFFile, PlaceholderReason>] = [:]
    /// Temporary copies of parsed PDFs for the rasterizer, by content hash.
    private var copies: [String: URL] = [:]
    private var copiesFolder: URL?
    private var rasters: [String: Result<RGBAImage, PlaceholderReason>] = [:]
    private var pixelsLeft: Int

    init(blobs: (any BlobSource)?, rasterizer: (any PDFPageRasterizer)?,
         pixelBudget: Int = RenderLimits.maxBackgroundPixelsPerExport) {
        self.blobs = blobs
        self.rasterizer = rasterizer
        pixelsLeft = pixelBudget
    }

    deinit {
        if let copiesFolder { try? FileManager.default.removeItem(at: copiesFolder) }
    }

    /// Keeps `data` (the verified content of blob `sha256`) in a private
    /// temporary file for the rasterizer; nothing when it cannot be written
    /// (pages then go through `blobs.withFile` as before).
    private func keepCopy(_ data: Data, sha256: String) {
        let fm = FileManager.default
        if copiesFolder == nil {
            let dir = fm.temporaryDirectory.appendingPathComponent("sempere-pdf-\(UUID().uuidString.lowercased())")
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])) != nil else { return }
            copiesFolder = dir
        }
        guard let dir = copiesFolder else { return }
        let url = dir.appendingPathComponent("\(sha256).pdf")
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            try? fm.removeItem(at: url)
            return
        }
        copies[sha256] = url
    }

    /// The parsed PDF of a `pdfPage` item.
    func file(_ item: Item) -> Result<PDFFile, PlaceholderReason> {
        guard let ref = item.blob else { return .failure(.blobUnavailable("no blob")) }
        if let r = files[ref.sha256] { return r }
        let r: Result<PDFFile, PlaceholderReason>
        if let blobs {
            do {
                let data = try blobs.withFile(for: ref) { url in
                    try BoundedRead.contents(of: url, maxBytes: PDFLimits.standard.maxFileBytes)
                }
                do {
                    r = .success(try PDFFile(data: data))
                    if rasterizer != nil, !blobs.filesAreCached { keepCopy(data, sha256: ref.sha256) }
                } catch {
                    r = .failure(.pdfUnreadable(Self.describe(error)))
                }
            } catch {
                r = .failure(.blobUnavailable(Self.describe(error)))
            }
        } else {
            r = .failure(.noBlobSource)
        }
        files[ref.sha256] = r
        return r
    }

    /// The page's geometry: from the PDF when it parses, else the item's
    /// `pageSize` as an unrotated box (for rasterizers and placeholders).
    func page(_ item: Item) -> PDFPageInfo? {
        guard let index = item.pageIndex else { return nil }
        if case .success(let f) = file(item), let p = try? f.page(index) { return p }
        guard let s = item.pageSize, s.w > 0, s.h > 0 else { return nil }
        let box = PDFRect(0, 0, s.w, s.h)
        return PDFPageInfo(index: index, mediaBox: box, cropBox: box, visibleBox: box, rotation: 0)
    }

    /// The effective page as pixels, `pixelWidth × pixelHeight`.
    func raster(_ item: Item, pixelWidth: Int, pixelHeight: Int) -> Result<RGBAImage, PlaceholderReason> {
        guard let ref = item.blob, let index = item.pageIndex else { return .failure(.blobUnavailable("no blob")) }
        guard let blobs else { return .failure(.noBlobSource) }
        guard let rasterizer else { return .failure(.noRasterizer) }
        let key = "\(ref.sha256)/\(index)/\(pixelWidth)x\(pixelHeight)"
        if let r = rasters[key] { return r }
        let pixels = pixelWidth * pixelHeight   // both ≤ maxBackgroundPixels, checked by the caller
        guard pixels <= pixelsLeft else { return .failure(.rasterBudget) }
        pixelsLeft -= pixels
        let r: Result<RGBAImage, PlaceholderReason>
        do {
            _ = file(item)   // parsed once: the copy and the rotation
            var rotation: Int?
            if case .success(let f)? = files[ref.sha256] { rotation = try? f.page(index).rotation }
            let img: RGBAImage
            if let url = copies[ref.sha256] {
                img = try rasterizer.rasterize(pdf: url, pageIndex: index, pixelWidth: pixelWidth,
                                               pixelHeight: pixelHeight, rotation: rotation)
            } else {
                img = try blobs.withFile(for: ref) { url in
                    try rasterizer.rasterize(pdf: url, pageIndex: index, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                             rotation: rotation)
                }
            }
            if img.width == pixelWidth, img.height == pixelHeight {
                r = .success(img)
            } else {
                r = .failure(.rasterizerFailed("returned \(img.width)×\(img.height), not \(pixelWidth)×\(pixelHeight)"))
            }
        } catch let e as BlobError {
            r = .failure(.blobUnavailable(Self.describe(e)))
        } catch {
            r = .failure(.rasterizerFailed(Self.describe(error)))
        }
        rasters[key] = r
        return r
    }

    /// Pixel size for drawing the effective page `w × h` points at `scale`
    /// pixels per point, scaled down to fit `maxPixels`.
    static func pixelSize(width w: Double, height h: Double, scale: Double,
                          maxPixels: Int = RenderLimits.maxBackgroundPixels) -> (Int, Int)? {
        guard w.isFinite, h.isFinite, scale.isFinite, w > 0, h > 0, scale > 0, maxPixels > 0 else { return nil }
        var pw = w * scale, ph = h * scale
        let cap = Double(maxPixels)
        if !(pw * ph <= cap) {
            let k = (cap / (pw * ph)).squareRoot()
            pw *= k; ph *= k
        }
        // A very thin page keeps at least one pixel across; the product stays within the cap.
        let iw = max(1, min(Int(min(pw, cap).rounded()), maxPixels)), ih = max(1, min(Int(min(ph, cap).rounded()), maxPixels / iw))
        return (iw, ih)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
