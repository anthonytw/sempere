import Foundation
import ImageIO
import Sempere
import SempereRender
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SempereApp

/// Images into notes (docs/attachments.md §14 task E1): the privacy setting
/// (on by default: HEIC → JPEG, no location or camera data), orientation kept
/// as the item's field and drawn upright, the camera's photos, and one blob
/// plus one delta per image through the editor.
@MainActor
struct ImageInsertTests {
    static let lecture = AppModelTests.lecture

    /// An 8 × 6 photo, red on its top half and blue below (in stored pixels),
    /// encoded as `type` with a GPS position, camera data and `orientation`.
    /// Synthetic: no real location.
    static func photo(_ type: UTType, orientation: Int = 1, gps: Bool = true, alpha: Bool = false) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !alpha
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 3))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 3, width: 8, height: 3))
        }
        guard let cg = image.cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Synthetic Camera", kCGImagePropertyTIFFMake: "Test"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Synthetic Lens"],
        ]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 45.25, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The JPEG markers before the image data (SOS).
    static func jpegMarkers(_ data: Data) -> [UInt8] {
        let b = [UInt8](data)
        var markers: [UInt8] = []
        var i = 2
        while i + 3 < b.count, b[i] == 0xFF {
            let m = b[i + 1]
            markers.append(m)
            if m == 0xDA { break }
            i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
        }
        return markers
    }

    /// What ImageIO reads of `data`'s metadata.
    static func properties(_ data: Data) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func hasLocation(_ data: Data) -> Bool { properties(data)[kCGImagePropertyGPSDictionary] != nil }

    // MARK: The privacy setting

    /// A dropped image file is read with a bound (format.md §9): one over
    /// `maxInputBytes` is refused by its size before its bytes are read.
    @Test func aDroppedFileIsReadWithABound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("small.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: small)
        #expect(try ImagePreparation.readInput(small).count == 4)
        // A sparse file just over the limit: nothing of it is read.
        let huge = dir.appendingPathComponent("huge.tiff")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(ImagePreparation.maxInputBytes) + 1)
        try handle.close()
        #expect(throws: ImagePreparation.Failure.fileTooLarge) { try ImagePreparation.readInput(huge) }
        #expect(throws: ImagePreparation.Failure.unreadable) { try ImagePreparation.readInput(dir) }
    }

    /// The "too large" messages state limits from their constants, in binary
    /// units as the format does: the 1 GiB blob cap is "1 GB" for a PDF and
    /// a video alike.
    @Test func sizeLimitsReadTheSameEverywhere() {
        #expect(BlobSizeText.string(1 << 30) == "1 GB")
        #expect(PDFPreparation.Failure.tooLarge(2 << 30).description.contains("at most 1 GB"))
        #expect(VideoPreparation.Failure.tooLarge(2 << 30).description.contains("at most 1 GB"))
        #expect(ImagePreparation.Failure.fileTooLarge.description.contains("at most 512 MB"))
    }

    @Test func privacyIsOnByDefault() {
        let defaults = UserDefaults(suiteName: "privacy-\(UUID().uuidString)")!
        #expect(PhotoPrivacy.isOn(defaults))
        defaults.set(false, forKey: PhotoPrivacy.key)
        #expect(!PhotoPrivacy.isOn(defaults))
    }

    /// The task's "done when": a HEIC with GPS becomes a JPEG without APP1.
    @Test func heicWithLocationBecomesAJPEGWithoutMetadata() throws {
        let heic = try #require(Self.photo(.heic, orientation: 6), "the simulator encodes HEIC")
        #expect(ImageIngest.format(of: heic) == .heic)
        #expect(Self.hasLocation(heic))
        let stored = try ImagePreparation.prepare(heic, privacy: true)
        #expect(stored.mediaType == "image/jpeg")
        #expect(ImageIngest.format(of: stored.data) == .jpeg)
        let markers = Self.jpegMarkers(stored.data)
        #expect(!markers.contains(0xE1), "no APP1 (Exif, XMP): \(markers.map { String($0, radix: 16) })")
        #expect(!Self.hasLocation(stored.data))
        #expect(Self.properties(stored.data)[kCGImagePropertyTIFFDictionary] == nil)
        // Orientation is the item's field, the pixel size after it (format.md §8.2.5).
        #expect(stored.orientation == 6)
        #expect(stored.pixelSize == Size(w: 6, h: 8))
    }

    @Test func withPrivacyOffTheHEICIsStoredAsPicked() throws {
        let heic = try #require(Self.photo(.heic, orientation: 6))
        let stored = try ImagePreparation.prepare(heic, privacy: false)
        #expect(stored.data == heic)
        #expect(stored.mediaType == "image/heic")
        #expect(stored.orientation == 6)
        #expect(stored.pixelSize == Size(w: 6, h: 8))
    }

    @Test func jpegLocationIsRemovedUnlessTheSettingIsOff() throws {
        let jpeg = try #require(Self.photo(.jpeg, orientation: 3))
        #expect(Self.jpegMarkers(jpeg).contains(0xE1))
        let stripped = try ImagePreparation.prepare(jpeg, privacy: true)
        #expect(!Self.jpegMarkers(stripped.data).contains(0xE1))
        #expect(!Self.hasLocation(stripped.data))
        #expect(stripped.orientation == 3)
        #expect(stripped.pixelSize == Size(w: 8, h: 6))
        let kept = try ImagePreparation.prepare(jpeg, privacy: false)
        #expect(kept.data == jpeg)
        #expect(Self.hasLocation(kept.data))
    }

    @Test func otherFormatsAreAlwaysConverted() throws {
        for (type, alpha) in [(UTType.tiff, false), (UTType.gif, false), (UTType.png, true)] {
            let data = try #require(Self.photo(type, orientation: 1, gps: false, alpha: alpha))
            for privacy in [true, false] {
                let stored = try ImagePreparation.prepare(data, privacy: privacy)
                #expect(["image/jpeg", "image/png"].contains(stored.mediaType), "\(type)")
                #expect([.jpeg, .png].contains(ImageIngest.format(of: stored.data)))
                #expect(stored.pixelSize == Size(w: 8, h: 6))
            }
        }
        #expect(throws: ImagePreparation.Failure.unreadable) { try ImagePreparation.prepare(Data("not an image".utf8), privacy: true) }
    }

    @Test func cameraPhotosKeepTheirOrientation() throws {
        let png = try #require(Self.photo(.png, gps: false))
        let cg = try #require(UIImage(data: png)?.cgImage)
        let shot = UIImage(cgImage: cg, scale: 1, orientation: .right)
        let stored = try ImagePreparation.prepare(try ImagePreparation.jpeg(from: shot), privacy: true)
        #expect(stored.mediaType == "image/jpeg")
        #expect(stored.orientation == 6)
        #expect(!Self.jpegMarkers(stored.data).contains(0xE1))
        #expect(ImagePreparation.exifOrientation(.left) == 8)
        #expect(ImagePreparation.exifOrientation(.up) == 1)
    }

    // MARK: Into the note

    /// One blob, one delta; the stored blob is the GPS-free JPEG; the item
    /// is placed on screen with the orientation field.
    @Test func insertingWritesTheStrippedBlobAndOneDelta() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let page = try #require(editor.currentPage).id
        let heic = try #require(Self.photo(.heic, orientation: 6))
        let item = try #require(await model.insertImage(heic, into: editor, visible: CGRect(x: 0, y: 200, width: 612, height: 400),
                                                         privacy: true))
        await editor.flush()
        #expect(model.errorMessage == nil)
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        #expect(item.orientation == 6)
        #expect(item.pixelSize == Size(w: 6, h: 8))
        #expect(item.frame.y + item.frame.h / 2 == 400, "centred in what was on screen")
        let ref = try #require(item.blob)
        #expect(ref.type == "image/jpeg")
        let blob = try vault.readBlob(note: Self.lecture, ref)
        #expect(!Self.jpegMarkers(blob).contains(0xE1))
        #expect(!Self.hasLocation(blob))
        _ = page
    }

    /// The task's "done when": an orientation 6 photo displays upright. Its
    /// stored top row (red) is the right edge when shown.
    @Test func anOrientationSixPhotoIsDrawnUpright() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let stored = try ImagePreparation.prepare(try #require(Self.photo(.jpeg, orientation: 6, gps: false)), privacy: true)
        let ref = try vault.writeBlob(note: Self.lecture, stored.data, type: stored.mediaType)
        let item = Item.image(blob: ref, pixelSize: stored.pixelSize, orientation: stored.orientation,
                              frame: Rect(x: 0, y: 0, w: 60, h: 80), z: "a")
        let picture = await ItemRendering.render(ItemRenderKey(item, scale: 1, paper: .blank), note: Self.lecture,
                                                 cache: ItemLayerTests.cache(vault))
        guard case .image(let cg, _) = picture else { Issue.record("not drawn: \(picture)"); return }
        #expect(cg.width == 60 && cg.height == 80, "upright: taller than wide")
        let right = try #require(Self.pixel(cg, x: 55, y: 40)), left = try #require(Self.pixel(cg, x: 5, y: 40))
        #expect(right.r > 180 && right.b < 90, "red on the right: \(right)")
        #expect(left.b > 180 && left.r < 90, "blue on the left: \(left)")
    }

    /// The pixel at `x`, `y` (top-left origin) as 8-bit RGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self) + (y * w + x) * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// With the setting off the HEIC is stored as picked, and an export of the
    /// note still has no location: exporters draw pixels, not the file.
    @Test func aStoredHEICExportsWithoutLocation() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let heic = try #require(Self.photo(.heic, orientation: 6))
        let item = try #require(await model.insertImage(heic, into: editor, visible: nil, privacy: false))
        await editor.flush()
        #expect(item.blob?.type == "image/heic")
        let state = try vault.reconstruct(noteId: Self.lecture)
        // Uncompressed, so a byte search would find metadata or the HEIC file if they were copied in.
        let options = RenderOptions(compress: false, blobs: MemoryBlobSource([heic]), pdfRasterizer: PDFKitRasterizer(),
                                    imageDecoder: ImageIODecoder())
        let pdf = try PDFWriter.render(note: state, options: options)
        #expect(pdf.count > 1000)
        #expect(pdf.range(of: Data("Synthetic".utf8)) == nil, "no camera data")
        #expect(pdf.range(of: Data("GPS".utf8)) == nil)
        #expect(pdf.range(of: Data("ftypheic".utf8)) == nil, "the HEIC file is not embedded")
    }

    /// Security review 2026-10 stage 4, S15: Settings ▸ Storage thumbnails decoded blobs with `UIImage(data:)`,
    /// so a GIF or TIFF stored by someone else reached every ImageIO codec. They now decode as the canvas does.
    @Test func storageThumbnailsDecodeOnlyTheCanvasFormats() throws {
        for type in [UTType.jpeg, .png, .heic] {
            let data = try #require(Self.photo(type, gps: false))
            #expect(AttachmentThumbnail.thumbnail(data, kind: .image, side: 132) != nil, "\(type)")
        }
        for other in [UTType.gif, .tiff] {
            let data = try #require(Self.photo(other, gps: false))
            #expect(AttachmentThumbnail.thumbnail(data, kind: .image, side: 132) == nil, "\(other)")
        }
    }

    /// The fallback decoder parses only HEIC/HEIF: a stored blob in another
    /// codec (here GIF and TIFF claiming to be `image/heic`) is not decoded.
    @Test func imageIODecoderReadsOnlyHEIC() throws {
        let heic = try #require(Self.photo(.heic, gps: false))
        let decoded = try #require(try ImageIODecoder().decode(heic, type: "image/heic", maxPixels: 1 << 20))
        #expect(decoded.width == 8 && decoded.height == 6)
        for other in [UTType.gif, .tiff] {
            let data = try #require(Self.photo(other, gps: false))
            #expect(try ImageIODecoder().decode(data, type: "image/heic", maxPixels: 1 << 20) == nil, "\(other)")
        }
    }
}
