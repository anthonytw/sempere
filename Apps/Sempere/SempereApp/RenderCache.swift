import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Sempere
import SempereAppCore
import SempereRender
import UIKit
import UniformTypeIdentifiers

/// The app's cache of drawn attachments (pictures and PDF page previews): the library's `RenderStore`
/// (labels, the sealed files, the memory and disk limits) of CoreGraphics pictures (`CGPictureCodec`). See
/// `RenderStore` for what is kept and when it goes.
typealias RenderCache = RenderStore<CGPictureCodec>

/// A drawn picture: pixels covering `bounds` (page points).
struct RenderPicture: @unchecked Sendable {
    var image: CGImage
    var bounds: Rect
}

/// What CoreText's drawing depends on beyond the item: the system version and the installed font
/// families (read once per launch).
private let renderNativeSalt: String = {
    let families = Data(UIFont.familyNames.sorted().joined(separator: "\n").utf8)
    let digest = SHA256.hash(data: families).prefix(8).map { String(format: "%02x", $0) }.joined()
    return ProcessInfo.processInfo.operatingSystemVersionString + "|" + digest
}()

extension RenderStore where Codec == CGPictureCodec {
    /// The app's cache of `vault` under `root` (nil: memory only), its size limit from Settings, its salt the
    /// system's fonts; UIKit's memory warnings drop the memory level.
    convenience init(root: URL?, vault: Vault, capBytes: Int = RenderCache.configuredCapBytes,
                     salt: String = RenderCache.nativeSalt) {
        self.init(root: root, vault: vault, capBytes: capBytes, salt: salt,
                  memoryWarning: UIApplication.didReceiveMemoryWarningNotification)
    }

    /// `Library/Caches/Sempere/Renders` in the app's container.
    static var defaultRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sempere/Renders", isDirectory: true)
    }

    /// The configured disk size limit (`capDefaultsKey` in `UserDefaults.standard`).
    static var configuredCapBytes: Int { configuredCapBytes(in: UserDefaults.standard) }

    /// What CoreText's drawing depends on (`renderNativeSalt`).
    static var nativeSalt: String { renderNativeSalt }

    /// `pictureLabel` with the system-and-fonts salt (`nativeSalt`).
    static func pictureLabel(_ key: ItemRenderKey) -> String? { pictureLabel(key, salt: nativeSalt) }

    // MARK: - PDF page previews

    /// Draws the preview of PDF page item `item` of `document` at `scale`
    /// pixels per page point: the page in the item's rotated frame, transparent
    /// around it (bounds: the rotated frame's, page points). Nil when it cannot be drawn.
    static func drawPreview(_ item: Item, document: PDFDocumentBox, scale: Double) -> RenderPicture? {
        let bounds = ItemFrames.bounds(item.frame, rotation: item.rotation)
        // Sizes as Double first: a frame from the vault can be huge (or make the
        // bounds infinite or NaN), and Int(_:) traps on any of those.
        let wd = (bounds.w * scale).rounded(.up), hd = (bounds.h * scale).rounded(.up)
        guard wd.isFinite, hd.isFinite, wd > 0, hd > 0, wd * hd <= Double(maxPreviewPixels * 2),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int(wd), h = Int(hd)
        let rotated = (item.rotation ?? 0).truncatingRemainder(dividingBy: 360) != 0
        let info = rotated ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: info) else { return nil }
        if !rotated {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // y down, page points, origin at the bounds' top left; then the frame's center, turned.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        ctx.translateBy(x: CGFloat(item.frame.x + item.frame.w / 2 - bounds.x), y: CGFloat(item.frame.y + item.frame.h / 2 - bounds.y))
        ctx.rotate(by: CGFloat(ItemFrames.radians(item.rotation)))
        ctx.translateBy(x: -CGFloat(item.frame.w / 2), y: -CGFloat(item.frame.h / 2))
        let drawn = document.lock.withLock { PDFItemDrawing.draw(document.document, item: item, in: ctx) }
        guard drawn, let image = ctx.makeImage() else { return nil }
        return RenderPicture(image: image, bounds: bounds)
    }
}

/// CoreGraphics pictures in a `RenderStore`: opaque ones as JPEG, others as premultiplied RGBA (LZFSE).
enum CGPictureCodec: RenderPictureCodec {
    typealias Picture = RenderPicture

    static func byteCount(_ picture: RenderPicture) -> Int { picture.image.bytesPerRow * picture.image.height }

    private struct Header: Codable {
        var width: Int
        var height: Int
        var bounds: Rect
        /// "jpeg" (opaque pictures) or "rgba" (premultiplied RGBA, LZFSE).
        var format: String
    }

    /// `header length (4 bytes, big endian) ‖ header JSON ‖ payload`.
    static func encode(_ picture: RenderPicture) -> Data? {
        let image = picture.image
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let opaque = [CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        var payload: Data?
        var format = "rgba"
        if opaque {
            let out = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                if CGImageDestinationFinalize(dest) { payload = out as Data; format = "jpeg" }
            }
        }
        if payload == nil {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let raw = ctx.data else { return nil }
            let pixels = NSData(bytes: raw, length: w * h * 4)
            payload = try? pixels.compressed(using: .lzfse) as Data
            format = "rgba"
        }
        guard let payload, let header = try? JSONEncoder().encode(Header(width: w, height: h, bounds: picture.bounds, format: format))
        else { return nil }
        var data = Data()
        var length = UInt32(header.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(payload)
        return data
    }

    /// The picture in `data`, nil when it is not one (a damaged or older file).
    static func decode(_ data: Data) -> RenderPicture? {
        guard data.count > 4 else { return nil }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 4096, data.count >= 4 + length,
              let header = try? JSONDecoder().decode(Header.self, from: data.dropFirst(4).prefix(length)),
              header.width > 0, header.height > 0, header.width <= 16_384, header.height <= 16_384,
              header.width * header.height <= 64_000_000 else { return nil }
        let payload = Data(data.dropFirst(4 + length))
        switch header.format {
        case "jpeg":
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == header.width, image.height == header.height else { return nil }
            return RenderPicture(image: image, bounds: header.bounds)
        case "rgba":
            let expected = header.width * header.height * 4
            guard let pixels = try? (payload as NSData).decompressed(using: .lzfse) as Data, pixels.count == expected,
                  let provider = CGDataProvider(data: pixels as CFData),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: header.width, height: header.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: header.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            return RenderPicture(image: image, bounds: header.bounds)
        default:
            return nil
        }
    }

}
