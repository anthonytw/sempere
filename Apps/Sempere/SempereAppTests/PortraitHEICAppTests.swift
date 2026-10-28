import CoreGraphics
import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// Device check c35 ("Portrait HEIC from Notability") without an iPhone photo: `notability/portrait-heic.note`
/// holds a landscape HEIC whose `irot` turns it upright to portrait, red on top, blue below, a green square top
/// right (`PortraitHEICTests` in the package builds it). Imported through the app, the photo must be upright in
/// PNG and PDF exports, which decode HEIC with the app's ImageIO decoder.
@MainActor
@Suite(.serialized)
struct PortraitHEICAppTests {
    /// Where each colour lies in a bitmap: the mean position of its pixels (nil when absent).
    struct Layout {
        var red: CGPoint?, blue: CGPoint?, green: CGPoint?

        init(_ image: CGImage) {
            let w = image.width, h = image.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sums = [(0.0, 0.0, 0), (0.0, 0.0, 0), (0.0, 0.0, 0)]
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let (r, g, b) = (px[i], px[i + 1], px[i + 2])
                    let k: Int? = r > 180 && g < 90 && b < 90 ? 0 : b > 180 && r < 90 && g < 90 ? 1 : g > 180 && r < 90 && b < 90 ? 2 : nil
                    if let k { sums[k].0 += Double(x); sums[k].1 += Double(y); sums[k].2 += 1 }
                }
            }
            // Bitmap rows run top to bottom here (y grows downward).
            func mean(_ s: (Double, Double, Int)) -> CGPoint? { s.2 < 20 ? nil : CGPoint(x: s.0 / Double(s.2), y: s.1 / Double(s.2)) }
            red = mean(sums[0]); blue = mean(sums[1]); green = mean(sums[2])
        }

        /// Upright: red above blue (same column), green in the top right.
        func expectUpright(_ what: String) {
            guard let red, let blue, let green else {
                Issue.record("\(what): the photo is missing or a placeholder (red \(String(describing: red)), blue \(String(describing: blue)))")
                return
            }
            #expect(red.y < blue.y, "\(what): red is on top")
            #expect(abs(red.x - blue.x) < abs(red.y - blue.y), "\(what): portrait, not landscape")
            #expect(green.x > red.x && green.y < blue.y, "\(what): the green corner is top right")
        }
    }

    static func importPortrait() async throws -> AppModel {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let bundle = Bundle(for: PortraitToken.self)
        let fixture = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("notability/portrait-heic.note")
        let dir = TestTemp.root.appendingPathComponent("heic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("Portrait photo.note")
        try FileManager.default.copyItem(at: fixture, to: copy)
        try await model.importFromApp(try #require(AppImporters.primary), urls: [copy], notebook: nil)
        #expect(model.importSummary?.imported == 1, "\(model.importSummary?.failures ?? [])")
        return model
    }

    static func portraitID(_ model: AppModel) throws -> UUID {
        try #require(model.notes.first { $0.title == "Portrait photo" }).id
    }

    @Test(.enabled(if: AppImporters.primary != nil)) func thePhotoIsUprightInAPNGExport() async throws {
        let model = try await Self.importPortrait()
        let dir = TestTemp.root.appendingPathComponent("heic-png-\(UUID().uuidString)")
        let r = try await model.exportNotes([try Self.portraitID(model)], options: ShareOptions(format: .png, paper: false, dpi: 72),
                                            into: dir) { _ in }
        let png = try #require(r.items.first { $0.pathExtension == "png" })
        let image = try #require(UIImage(contentsOfFile: png.path)?.cgImage)
        Layout(image).expectUpright("PNG")
        model.close()
    }

    @Test(.enabled(if: AppImporters.primary != nil)) func thePhotoIsUprightInAPDFExport() async throws {
        let model = try await Self.importPortrait()
        let dir = TestTemp.root.appendingPathComponent("heic-pdf-\(UUID().uuidString)")
        let r = try await model.exportNotes([try Self.portraitID(model)], options: ShareOptions(format: .pdf, paper: false),
                                            into: dir) { _ in }
        let file = try #require(r.items.first)
        let pdf = try #require(CGPDFDocument(file as CFURL))
        let page = try #require(pdf.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let ctx = try #require(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: box.size))
        ctx.drawPDFPage(page)
        let rendered = try #require(ctx.makeImage())
        Layout(rendered).expectUpright("PDF")
        model.close()
    }

    @Test(.enabled(if: AppImporters.primary != nil)) func thePhotoIsUprightInABulkPNGExport() async throws {
        let model = try await Self.importPortrait()
        let dir = TestTemp.root.appendingPathComponent("heic-bulk-\(UUID().uuidString)")
        // Through Export to Folder's own run (`BulkExportRun`), which picks the renderers.
        let run = BulkExportRun()
        run.start(model: model, request: BulkExportRequest(scope: .notes([try Self.portraitID(model)])),
                  options: BulkExportOptions(format: .png, layout: .flat, paper: false, dpi: 72), target: .folder(dir, scoped: false))
        let finished = await TS.waitUntil(timeout: .seconds(60)) { if case .finished = run.state { return true } else { return false } }
        #expect(finished, "\(run.state)")
        guard case .finished(let result) = run.state else { return }
        let file = try #require(result.exported.first?.files.first { $0.hasSuffix(".png") })
        let image = try #require(UIImage(contentsOfFile: dir.appendingPathComponent(file).path)?.cgImage)
        Layout(image).expectUpright("bulk PNG")
        model.close()
    }
}

private final class PortraitToken {}
