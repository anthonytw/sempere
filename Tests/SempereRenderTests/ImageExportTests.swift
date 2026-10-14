import Foundation
import Age
@testable import Sempere
import FuzzSupport
import XCTest

@testable import SempereRender

/// Image items in exports (format.md §8.2.5, §8.5): every orientation, crops
/// and rotations in PNG, PDF (rasterized by poppler) and SVG, checked against
/// an independent oracle of §8.5.1; passthrough and metadata stripping;
/// placeholders and the report.
final class ImageExportTests: XCTestCase {
    // MARK: Test images

    static let red = (255, 0, 0), green = (0, 255, 0), blue = (0, 0, 255), yellow = (255, 255, 0)

    /// 40 × 30 pixels: red, green over blue, yellow.
    static func quadrants() -> RGBAImage {
        var px = [UInt8]()
        for y in 0..<30 {
            for x in 0..<40 {
                let c = quadrant(a: Double(x) + 0.5, b: Double(y) + 0.5, w: 40, h: 30)
                px += [UInt8(c.0), UInt8(c.1), UInt8(c.2), 255]
            }
        }
        return try! RGBAImage(width: 40, height: 30, pixels: px)
    }

    static func quadrant(a: Double, b: Double, w: Double, h: Double) -> (Int, Int, Int) {
        a < w / 2 ? (b < h / 2 ? red : blue) : (b < h / 2 ? green : yellow)
    }

    static func pngData(_ img: RGBAImage) throws -> Data {
        try PNGEncoder.encode(width: img.width, height: img.height, rgba: img.pixels)
    }

    static func meta(paper: Paper = .blank, size: PageSize = PageSize(width: 300, height: 300)) -> NoteMeta {
        NoteMeta(title: "Images", created: Date(timeIntervalSince1970: 0), paper: paper, pageSize: size)
    }

    // MARK: Oracle (format.md §8.5.1, written independently of Placement)

    struct Case {
        var orientation: Int
        var rotation: Double
        var crop: Rect?
        var frame: Rect
    }

    /// Stored pixel coordinates seen at page point `p`, or nil outside the frame.
    static func oracle(_ c: Case, _ p: Point, w: Double, h: Double) -> (a: Double, b: Double)? {
        let f = c.frame
        let mx = f.x + f.w / 2, my = f.y + f.h / 2
        let t = -c.rotation * .pi / 180
        // Undo the clockwise rotation (y down): rotate by −θ.
        let x = mx + (p.x - mx) * cos(t) - (p.y - my) * sin(t)
        let y = my + (p.x - mx) * sin(t) + (p.y - my) * cos(t)
        guard x > f.x, x < f.x + f.w, y > f.y, y < f.y + f.h else { return nil }
        let (ow, oh) = (5...8).contains(c.orientation) ? (h, w) : (w, h)
        let crop = c.crop ?? Rect(x: 0, y: 0, w: ow, h: oh)
        let u = crop.x + (x - f.x) * crop.w / f.w, v = crop.y + (y - f.y) * crop.h / f.h
        switch c.orientation {
        case 2: return (w - u, v)
        case 3: return (w - u, h - v)
        case 4: return (u, h - v)
        case 5: return (v, u)
        case 6: return (v, h - u)
        case 7: return (w - v, h - u)
        case 8: return (w - v, u)
        default: return (u, v)
        }
    }

    static func cases() -> [Case] {
        var out: [Case] = []
        for o in 1...8 {
            let oriented = (5...8).contains(o) ? (30.0, 40.0) : (40.0, 30.0)
            for rotation in [0.0, 90, 30, -135] {
                for crop in [nil, Rect(x: oriented.0 * 0.25, y: oriented.1 * 0.2, w: oriented.0 * 0.6, h: oriented.1 * 0.7)] {
                    let aspect = (crop?.w ?? oriented.0) / (crop?.h ?? oriented.1)
                    out.append(Case(orientation: o, rotation: rotation, crop: crop,
                                    frame: Rect(x: 90, y: 100, w: 120, h: 120 / aspect)))
                }
            }
        }
        return out
    }

    static func note(_ cases: [Case], blob: BlobRef, w: Double, h: Double, paper: Paper = .blank) -> NoteState {
        let pages = cases.enumerated().map { i, c in
            Page(order: "a\(i)", items: [Item(kind: .image, frame: c.frame, rotation: c.rotation, z: "a", blob: blob,
                                               pixelSize: Size(w: w, h: h), orientation: c.orientation, crop: c.crop)])
        }
        return NoteState(meta: meta(paper: paper), pages: pages)
    }

    /// Checks a rendered page (`scale` pixels per point) against the oracle at
    /// a grid of points well inside or well outside the image.
    static func check(_ img: RGBAImage, scale: Double, _ c: Case, w: Double, h: Double, tolerance: Int,
                      label: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        var checked = 0
        for gy in stride(from: 2.0, to: 298, by: 7) {
            for gx in stride(from: 2.0, to: 298, by: 7) {
                let expected: (Int, Int, Int)
                // Stay clear of every edge: the frame, the image and the quadrant boundaries.
                let probes = [(0.0, 0.0), (2, 0), (-2, 0), (0, 2), (0, -2)].map {
                    oracle(c, Point(x: gx + $0.0, y: gy + $0.1), w: w, h: h)
                }
                if probes.allSatisfy({ $0 == nil }) {
                    expected = (255, 255, 255)
                } else if let s = probes[0], probes.allSatisfy({ $0 != nil }) {
                    // At least 1.5 source pixels from the quadrant boundaries and the
                    // image's edges: resampling blends neighbouring pixels.
                    let margin = 1.5
                    guard abs(s.a - w / 2) >= margin, abs(s.b - h / 2) >= margin, s.a >= margin, s.a <= w - margin,
                          s.b >= margin, s.b <= h - margin else { continue }
                    expected = quadrant(a: s.a, b: s.b, w: w, h: h)
                } else {
                    continue
                }
                let x = Int(gx * scale), y = Int(gy * scale)
                let i = (y * img.width + x) * 4
                let got = (Int(img.pixels[i]), Int(img.pixels[i + 1]), Int(img.pixels[i + 2]))
                let ok = abs(got.0 - expected.0) <= tolerance && abs(got.1 - expected.1) <= tolerance
                    && abs(got.2 - expected.2) <= tolerance
                XCTAssert(ok, "\(label) at (\(gx), \(gy)): got \(got), expected \(expected)", file: file, line: line)
                checked += 1
            }
        }
        return checked
    }

    // MARK: Goldens: every orientation, crop and rotation

    func testPNGExportMatchesOracle() throws {
        let png = try Self.pngData(Self.quadrants())
        let ref = BlobRef(content: png, type: "image/png")
        let cases = Self.cases()
        let note = Self.note(cases, blob: ref, w: 40, h: 30)
        var report = RenderReport()
        let pages = try PNGWriter.render(note: note, options: RenderOptions(blobs: MemoryBlobSource([png])),
                                         png: PNGOptions(scale: 1), report: &report)
        XCTAssertEqual(report, RenderReport())
        XCTAssertEqual(pages.count, cases.count)
        var total = 0
        for (c, data) in zip(cases, pages) {
            let img = try PNG.decode(data)
            total += Self.check(img, scale: 1, c, w: 40, h: 30, tolerance: 8,
                                label: "png o\(c.orientation) r\(c.rotation) crop \(c.crop != nil)")
        }
        XCTAssertGreaterThan(total, cases.count * 300)
    }

    func testPDFExportMatchesOracleThroughPoppler() throws {
        guard let pdftoppm = ExternalTool.find("pdftoppm")?.path else {
            throw XCTSkip("pdftoppm not installed")
        }
        for (name, data, w, h, tolerance) in [("png", try Self.pngData(Self.quadrants()), 40.0, 30.0, 8),
                                               ("jpeg", try ImageCodecTests.fixture("quadrants.jpg"), 40.0, 30.0, 40)] {
            let ref = BlobRef(content: data, type: name == "png" ? "image/png" : "image/jpeg")
            let cases = Self.cases()
            let pdf = try PDFWriter.render(note: Self.note(cases, blob: ref, w: w, h: h),
                                           options: RenderOptions(blobs: MemoryBlobSource([data])))
            // One XObject for all pages; JPEG passed through.
            XCTAssertEqual(T.count(pdf, "/Subtype /Image"), 1, name)
            XCTAssertEqual(T.contains(pdf, "/DCTDecode"), name == "jpeg")
            let pngs = try Self.rasterize(pdf, pdftoppm: pdftoppm, dpi: 72)
            XCTAssertEqual(pngs.count, cases.count)
            var total = 0
            for (c, page) in zip(cases, pngs) {
                total += Self.check(try PNG.decode(page), scale: 1, c, w: w, h: h, tolerance: tolerance,
                                    label: "pdf/\(name) o\(c.orientation) r\(c.rotation) crop \(c.crop != nil)")
            }
            XCTAssertGreaterThan(total, cases.count * 300)
        }
    }

    /// Every page of `pdf` as PNG, rendered by poppler.
    static func rasterize(_ pdf: Data, pdftoppm: String, dpi: Int) throws -> [Data] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("in.pdf")
        try pdf.write(to: file)
        let r = try ExternalTool.run(URL(fileURLWithPath: pdftoppm),
                                     ["-r", "\(dpi)", "-png", "-aa", "no", "-aaVector", "no", file.path, dir.appendingPathComponent("p").path])
        XCTAssertEqual(r.status, 0, r.errText)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        return try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
    }

    /// The SVG matrix maps stored pixels where the oracle says, the clip is
    /// the rotated frame, and the data URI is the image.
    func testSVGExportMatchesOracle() throws {
        let png = try Self.pngData(Self.quadrants())
        let ref = BlobRef(content: png, type: "image/png")
        let cases = Self.cases()
        var report = RenderReport()
        let svgs = try SVGWriter.export(note: Self.note(cases, blob: ref, w: 40, h: 30),
                                        options: RenderOptions(blobs: MemoryBlobSource([png])), report: &report).pages
        XCTAssertEqual(report, RenderReport())
        for (c, svg) in zip(cases, svgs) {
            let m = try XCTUnwrap(Self.matrix(in: svg), "\(c)")
            for (a, b) in [(3.0, 4.0), (37, 2), (20, 15), (5, 27), (31, 22)] {
                let p = Point(x: m.a * a + m.c * b + m.tx, y: m.b * a + m.d * b + m.ty)
                guard let back = Self.oracle(c, p, w: 40, h: 30) else { continue }   // cropped away
                XCTAssertEqual(back.a, a, accuracy: 0.01, "svg o\(c.orientation) r\(c.rotation)")
                XCTAssertEqual(back.b, b, accuracy: 0.01, "svg o\(c.orientation) r\(c.rotation)")
            }
            XCTAssertTrue(svg.contains("<clipPath id=\"clip-0\"><polygon points="))
            XCTAssertTrue(svg.contains("width=\"40\" height=\"30\" preserveAspectRatio=\"none\""))
        }
        let uri = try XCTUnwrap(svgs[0].range(of: "data:image/png;base64,"))
        let b64 = svgs[0][uri.upperBound...].prefix { $0 != "\"" }
        XCTAssertEqual(try PNG.decode(XCTUnwrap(Data(base64Encoded: String(b64)))), Self.quadrants())
    }

    /// The HTML export inlines every page into one document, so each page's
    /// ids must be its own: a different image and clip on each page, every id
    /// unique, and every `#id` reference resolving within its own page.
    func testHTMLExportPageIDsAreUnique() throws {
        let q = Self.quadrants()
        let other = try RGBAImage(width: q.width, height: q.height, pixels: q.pixels.map { 255 - $0 | 1 })
        let pngs = try [Self.pngData(Self.quadrants()), Self.pngData(other)]
        let frames = [Rect(x: 20, y: 30, w: 120, h: 90), Rect(x: 100, y: 60, w: 80, h: 160)]
        let pages = (0..<2).map { i in
            Page(order: "a\(i)", items: [Item(kind: .image, frame: frames[i], rotation: 30 * Double(i), z: "a",
                                              blob: BlobRef(content: pngs[i], type: "image/png"),
                                              pixelSize: Size(w: 40, h: 30))])
        }
        let state = NoteState(meta: Self.meta(), pages: pages)
        var report = RenderReport()
        let options = RenderOptions(blobs: MemoryBlobSource(pngs))
        let svgs = try SVGWriter.export(note: state, options: options, pagePrefixedIDs: true, report: &report).pages
        XCTAssertEqual(report, RenderReport())
        let info = ExportNoteInfo(id: UUID(), title: "Two", tags: [], notebook: nil, created: Date(timeIntervalSince1970: 0),
                                  modified: nil, pages: 2, source: "sempere:v")
        let html = HTMLExport.notePage(info: info, state: state, svgs: svgs, indexHref: nil)

        func matches(_ pattern: String, in s: String) throws -> [String] {
            let re = try NSRegularExpression(pattern: pattern)
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range(at: 1), in: s)!]) }
        }
        let ids = try matches(#"\sid="([^"]+)""#, in: html)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(ids)")
        XCTAssertTrue(ids.contains("p1-img-0") && ids.contains("p2-img-0"), "\(ids)")
        for (i, svg) in svgs.enumerated() {
            let own = Set(try matches(#"\sid="([^"]+)""#, in: svg))
            let refs = try matches(#"url\(#([^)]+)\)"#, in: svg) + matches(##"href="#([^"]+)""##, in: svg)
            XCTAssertFalse(refs.isEmpty)
            for r in refs { XCTAssertTrue(r.hasPrefix("p\(i + 1)-") && own.contains(r), "page \(i + 1): #\(r)") }
        }
        // Standalone SVGs keep their unprefixed ids.
        let plain = try SVGWriter.export(note: state, options: options, report: &report).pages
        XCTAssertTrue(plain[1].contains("<use xlink:href=\"#img-0\"") && plain[1].contains("url(#clip-0)"))
    }

    /// `(a b c d e f)` of the first `<use>`'s matrix.
    static func matrix(in svg: String) -> Affine? {
        guard let r = svg.range(of: "<use xlink:href=\"#img-0\" transform=\"matrix(") else { return nil }
        let nums = svg[r.upperBound...].prefix { $0 != ")" }.split(separator: " ").compactMap { Double($0) }
        guard nums.count == 6 else { return nil }
        return Affine(a: nums[0], b: nums[1], c: nums[2], d: nums[3], tx: nums[4], ty: nums[5])
    }

    /// A textual golden for one placement, so that a change to the content
    /// stream shows in review. Orientation 6, crop the top 30 × 20 of the
    /// oriented 30 × 40, frame 150 × 100 at (72, 144), turned 90° about
    /// (147, 194): the frame's top-left lands at (197, 119); stored pixel
    /// (0, 0) shows at the frame's top-right, turned to (197, 269), and the
    /// unit square's x axis (stored width, 40 px = 200 pt past the crop)
    /// points left.
    func testPDFContentStreamGolden() throws {
        let png = try Self.pngData(Self.quadrants())
        let ref = BlobRef(content: png, type: "image/png")
        let c = Case(orientation: 6, rotation: 90, crop: Rect(x: 0, y: 0, w: 30, h: 20), frame: Rect(x: 72, y: 144, w: 150, h: 100))
        let pdf = try PDFWriter.render(note: Self.note([c], blob: ref, w: 40, h: 30),
                                       options: RenderOptions(compress: false, blobs: MemoryBlobSource([png])))
        let expected = """
            q
            197 119 m
            197 269 l
            97 269 l
            97 119 l
            h W n
            -200 0 0 150 197 119 cm

            """ + "/X"
        let text = String(decoding: pdf, as: UTF8.self)
        XCTAssertTrue(T.contains(pdf, expected), String(text[(text.range(of: " W n")?.lowerBound ?? text.startIndex)...].prefix(80)))
        XCTAssertEqual(Self.imageDraws(pdf), 1)
        XCTAssertTrue(T.contains(pdf, "/Width 40 /Height 30 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode"))
        XCTAssertFalse(T.contains(pdf, "/SMask"))
    }

    /// `/X<n> Do` operators in `pdf` whose object `n` is an image XObject.
    static func imageDraws(_ pdf: Data) -> Int {
        let text = String(decoding: pdf, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: "/X([0-9]+) Do") else { return 0 }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { m in
            guard let r = Range(m.range(at: 1), in: text) else { return false }
            guard let obj = text.range(of: "\n\(text[r]) 0 obj") else { return false }
            return text[obj.upperBound...].prefix(200).contains("/Subtype /Image")
        }.count
    }

    // MARK: Passthrough and metadata

    /// Offset of `needle` in `hay`, byte for byte.
    static func range(of needle: Data, in hay: Data) -> Int? {
        let h = [UInt8](hay), n = [UInt8](needle)
        guard let first = n.first, h.count >= n.count else { return nil }
        for i in 0...(h.count - n.count) where h[i] == first && h[i..<(i + n.count)].elementsEqual(n) { return i }
        return nil
    }

    func testJPEGPassthroughStripsMetadata() throws {
        let jpeg = try ImageCodecTests.fixture("metadata.jpg")
        let ref = BlobRef(content: jpeg, type: "image/jpeg")
        let note = NoteState(meta: Self.meta(), pages: [Page(order: "a", items: [
            Item.image(blob: ref, pixelSize: Size(w: 61, h: 45), frame: Rect(x: 10, y: 10, w: 122, h: 90), z: "a"),
        ])])
        let options = RenderOptions(blobs: MemoryBlobSource([jpeg]))
        let pdf = try PDFWriter.render(note: note, options: options)
        let stripped = try JPEG.stripMetadata(jpeg)
        XCTAssertTrue(T.contains(pdf, "/DCTDecode"))
        XCTAssertNotNil(Self.range(of: stripped, in: pdf), "the stripped JPEG, byte for byte")
        for secret in ["SyntheticCam", "Exif", "synthetic comment", "xmpmeta"] {
            XCTAssertFalse(T.contains(pdf, secret), secret)
        }
        // Asked to keep it: the original bytes.
        var keep = options
        keep.keepImageMetadata = true
        let kept = try PDFWriter.render(note: note, options: keep)
        XCTAssertNotNil(Self.range(of: jpeg, in: kept))
        // SVG: the data URI carries the stripped bytes; assets too.
        var report = RenderReport()
        let svg = try SVGWriter.export(note: note, options: options, report: &report).pages[0]
        XCTAssertTrue(svg.contains("data:image/jpeg;base64," + stripped.base64EncodedString()))
        let linked = try SVGWriter.export(note: note, options: options, assetPrefix: "assets/", report: &report)
        XCTAssertEqual(linked.assets.count, 1)
        XCTAssertEqual(linked.assets[0].data, stripped)
        XCTAssertTrue(linked.assets[0].name.hasSuffix(".jpg"))
        XCTAssertTrue(linked.pages[0].contains("xlink:href=\"assets/\(linked.assets[0].name)\""))
        XCTAssertFalse(linked.pages[0].contains("base64"))
    }

    func testPNGWithAlphaGetsSoftMaskAndGreyStaysGrey() throws {
        let rgba = try ImageCodecTests.fixture("rgba8.png"), grey = try ImageCodecTests.fixture("grey8.png")
        let note = NoteState(meta: Self.meta(), pages: [Page(order: "a", items: [
            Item.image(blob: BlobRef(content: rgba, type: "image/png"), pixelSize: Size(w: 23, h: 17),
                       frame: Rect(x: 10, y: 10, w: 46, h: 34), z: "a"),
            Item.image(blob: BlobRef(content: grey, type: "image/png"), pixelSize: Size(w: 23, h: 17),
                       frame: Rect(x: 100, y: 10, w: 46, h: 34), z: "b"),
        ])])
        let pdf = try PDFWriter.render(note: note, options: RenderOptions(blobs: MemoryBlobSource([rgba, grey])))
        XCTAssertEqual(T.count(pdf, "/SMask"), 1)
        XCTAssertEqual(T.count(pdf, "/ColorSpace /DeviceGray"), 2)   // the grey image and the mask
        XCTAssertEqual(T.count(pdf, "/ColorSpace /DeviceRGB"), 1)
    }

    // MARK: DCT scaling

    func testRasterUsesDCTScalingForSmallFrames() throws {
        let jpeg = try ImageCodecTests.fixture("baseline-444.jpg")
        let ref = BlobRef(content: jpeg, type: "image/jpeg")
        let store = ImageStore(options: RenderOptions(blobs: MemoryBlobSource([jpeg])))
        let image = try store.load(ref).get()
        XCTAssertEqual(try store.forRaster(ref, image, reduction: 1).get().width, 61)
        XCTAssertEqual(try store.forRaster(ref, image, reduction: 3).get().width, 31)    // 1/2
        XCTAssertEqual(try store.forRaster(ref, image, reduction: 9).get().width, 8)     // 1/8
        XCTAssertEqual(try store.forRaster(ref, image, reduction: 20).get().width, 4)    // 1/8, then 2 × 2 boxes
        // A PNG is box-reduced only.
        let png = try ImageCodecTests.fixture("rgb8.png")
        let pref = BlobRef(content: png, type: "image/png")
        let pstore = ImageStore(options: RenderOptions(blobs: MemoryBlobSource([png])))
        XCTAssertEqual(try pstore.forRaster(pref, try pstore.load(pref).get(), reduction: 5.5).get().width, 5)
    }

    // MARK: Placeholders and the report

    /// The placeholder (format.md §8.5.2): grey outline and diagonals.
    static func isPlaceholderGrey(_ img: RGBAImage, _ x: Int, _ y: Int) -> Bool {
        let i = (y * img.width + x) * 4
        let r = Int(img.pixels[i]), g = Int(img.pixels[i + 1]), b = Int(img.pixels[i + 2])
        return r < 235 && abs(r - g) < 16 && b >= g && b - g < 24   // #9AA0A6, possibly blended with white
    }

    func testPlaceholdersAndReport() throws {
        let png = try Self.pngData(Self.quadrants())
        let ref = BlobRef(content: png, type: "image/png")
        let heic = Data([0, 0, 0, 24] + Array("ftypheic".utf8) + [UInt8](repeating: 0, count: 16))
        let heicRef = BlobRef(content: heic, type: "image/heic")
        let frame = Rect(x: 50, y: 50, w: 100, h: 100)
        let unknown = Item(kind: ItemKind(rawValue: "sticker"), frame: Rect(x: 160, y: 50, w: 100, h: 100), z: "c")
        let note = NoteState(meta: Self.meta(), pages: [
            Page(order: "a", items: [Item.image(blob: ref, pixelSize: Size(w: 40, h: 30), frame: frame, z: "a")]),
            Page(order: "b", items: [Item.image(blob: heicRef, pixelSize: Size(w: 4, h: 4), frame: frame, z: "a"), unknown]),
        ])
        // No blob source at all: every image is a placeholder.
        var report = RenderReport()
        let pages = try PNGWriter.render(note: note, options: RenderOptions(), png: PNGOptions(scale: 1), report: &report)
        XCTAssertTrue(Self.isPlaceholderGrey(try PNG.decode(pages[0]), 100, 100), "diagonals cross at the centre")
        XCTAssertTrue(Self.isPlaceholderGrey(try PNG.decode(pages[0]), 50, 75), "outline")
        XCTAssertEqual(report.placeholders.map(\.page), [1, 2, 2])
        XCTAssertEqual(report.placeholders.map(\.reason), [.noBlobSource, .noBlobSource, .unsupportedKind("sticker")])

        // HEIC without a decoder: a placeholder that says so; the rest draws.
        report = RenderReport()
        _ = try PDFWriter.render(note: note, options: RenderOptions(blobs: MemoryBlobSource([png, heic])), report: &report)
        XCTAssertEqual(report.placeholders.count, 2)
        XCTAssertTrue(report.placeholders[0].reason.description.contains("HEIC"), report.placeholders[0].reason.description)
        XCTAssertEqual(report.placeholders[1].reason, .unsupportedKind("sticker"))
        XCTAssertEqual(report.placeholders[1].item, unknown.id)

        // With a decoder hook (the app's ImageIO): drawn.
        struct FakeHEIC: ImageDecoding {
            func decode(_ data: Data, type: String, maxPixels: Int) throws -> RGBAImage? {
                try RGBAImage(width: 2, height: 2, pixels: [UInt8](repeating: 200, count: 16))
            }
        }
        report = RenderReport()
        let svg = try SVGWriter.export(note: note, options: RenderOptions(blobs: MemoryBlobSource([png, heic]),
                                                                         imageDecoder: FakeHEIC()), report: &report)
        XCTAssertEqual(report.placeholders.map(\.item), [unknown.id])   // only the unknown kind
        XCTAssertTrue(svg.pages[1].contains("data:image/png;base64,"))

        // A missing blob, a corrupt one and one over the pixel cap.
        let corrupt = Data(png.prefix(60))
        let corruptRef = BlobRef(content: corrupt, type: "image/png")
        let capped = NoteState(meta: Self.meta(), pages: [Page(order: "a", items: [
            Item.image(blob: BlobRef(content: Data("absent".utf8), type: "image/png"), pixelSize: Size(w: 1, h: 1),
                       frame: frame, z: "a"),
            Item.image(blob: corruptRef, pixelSize: Size(w: 1, h: 1), frame: frame, z: "b"),
            Item.image(blob: ref, pixelSize: Size(w: 40, h: 30), frame: frame, z: "c"),
        ])])
        report = RenderReport()
        _ = try PDFWriter.render(note: capped, options: RenderOptions(blobs: MemoryBlobSource([png, corrupt]),
                                                                     maxImagePixels: 1000), report: &report)
        XCTAssertEqual(report.placeholders.count, 3)
        XCTAssertTrue(report.placeholders[0].reason.description.contains("missing"), report.placeholders[0].reason.description)
        XCTAssertTrue(report.placeholders[2].reason.description.contains("40 × 30"), report.placeholders[2].reason.description)
        XCTAssertEqual(RenderOptions().maxImagePixels, 100_000_000, "format.md §8.4")
    }

    /// A decoder-only (HEIC) image is decoded to learn its size once, not
    /// each time an item or page shows it.
    func testDecoderImagesAreMeasuredOnce() throws {
        final class Counting: ImageDecoding, @unchecked Sendable {
            private let lock = NSLock()
            private var counts: [Int: Int] = [:]
            func decode(_ data: Data, type: String, maxPixels: Int) throws -> RGBAImage? {
                let side = Int(data.last ?? 2)
                lock.lock(); counts[side, default: 0] += 1; lock.unlock()
                return try RGBAImage(width: side, height: side, pixels: [UInt8](repeating: 200, count: side * side * 4))
            }
            var total: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
        }
        let a = Data("....ftypheic-a".utf8) + Data([3]), b = Data("....ftypheic-b".utf8) + Data([5])
        let refA = BlobRef(content: a, type: "image/heic"), refB = BlobRef(content: b, type: "image/heic")
        func item(_ ref: BlobRef, _ x: Double, _ z: String) -> Item {
            Item.image(blob: ref, pixelSize: Size(w: 4, h: 4), frame: Rect(x: x, y: 50, w: 40, h: 40), z: z)
        }
        // A, B, A, B on each of three pages.
        let page = { (o: String) in
            Page(order: o, items: [item(refA, 10, "a"), item(refB, 60, "b"), item(refA, 110, "c"), item(refB, 160, "d")])
        }
        let note = NoteState(meta: Self.meta(), pages: [page("a"), page("b"), page("c")])
        let decoder = Counting()
        var report = RenderReport()
        _ = try PDFWriter.render(note: note, options: RenderOptions(blobs: MemoryBlobSource([a, b]), imageDecoder: decoder),
                                 report: &report)
        XCTAssertTrue(report.placeholders.isEmpty, "\(report.placeholders)")
        // Two to measure (cached; 12 before), and the Image XObjects are shared by content hash.
        XCTAssertEqual(decoder.total, 2)
        let png = Counting()
        _ = try PNGWriter.render(note: note, options: RenderOptions(blobs: MemoryBlobSource([a, b]), imageDecoder: png),
                                 png: PNGOptions(scale: 1), report: &report)
        // Measured once each (12 decodes before), and drawn from the few reduced
        // bitmaps kept: at most one more decode per image (24 before).
        XCTAssertLessThanOrEqual(png.total, 4)
    }

    /// A background item (layer 0) hides the ruling inside its frame; ink and
    /// later items draw over it; infinite pages grow to hold items.
    func testLayersOrderAndExtent() throws {
        let png = try Self.pngData(Self.quadrants())
        let ref = BlobRef(content: png, type: "image/png")
        let background = Item(kind: ItemKind(rawValue: "unknown-bg"), layer: .background,
                              frame: Rect(x: 0, y: 0, w: 300, h: 150), z: "a")
        let image = Item.image(blob: ref, pixelSize: Size(w: 40, h: 30), frame: Rect(x: 200, y: 200, w: 80, h: 60), z: "b")
        let over = Item.image(blob: ref, pixelSize: Size(w: 40, h: 30), crop: Rect(x: 20, y: 15, w: 20, h: 15),
                              frame: Rect(x: 200, y: 200, w: 40, h: 30), z: "c")   // yellow over the red quadrant
        let meta = Self.meta(paper: Paper(kind: .ruled, spacing: 20, lineColor: Color(r: 0, g: 0, b: 255, a: 255)))
        let note = NoteState(meta: meta, pages: [Page(order: "a", items: [over, image, background])])
        let img = try PNG.decode(try PNGWriter.render(note: note, options: RenderOptions(blobs: MemoryBlobSource([png])),
                                                      png: PNGOptions(scale: 1))[0])
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(img.pixels[((y * img.width + x) * 4)..<((y * img.width + x) * 4 + 3)]) }
        // Ruled lines are blue; inside the background item there are none (only its placeholder lines).
        let ruledRows = (150..<300).filter { y in px(10, y)[2] > 200 && px(10, y)[0] < 200 }
        XCTAssertFalse(ruledRows.isEmpty)
        XCTAssertFalse((5..<145).contains { y in px(100, y) == [0, 0, 255] }, "no ruling under the background item")
        XCTAssertEqual(px(220, 215), [255, 255, 0], "the later item (higher z) on top")
        XCTAssertEqual(px(260, 215), [0, 255, 0])

        // Infinite page: an item far below the ink extends the page.
        let tall = NoteState(meta: Self.meta(size: PageSize(width: 300, height: 300, infinite: true, breakHeight: 400)),
                             pages: [Page(order: "a", items: [Item.image(blob: ref, pixelSize: Size(w: 40, h: 30),
                                                                         frame: Rect(x: 10, y: 1500, w: 40, h: 30), z: "a")])])
        let pdf = try PDFWriter.render(note: tall, options: RenderOptions(compress: false, blobs: MemoryBlobSource([png])))
        XCTAssertEqual(T.count(pdf, "/Type /Page "), 4)   // 1530 pt in 400 pt pages
        XCTAssertEqual(T.count(pdf, "/Subtype /Image"), 1)
        XCTAssertEqual(Self.imageDraws(pdf), 1, "drawn on the one page it touches")
    }

    /// One page with a PDF page background (task C3) under an image (C1):
    /// every writer draws both, in order, with no placeholder.
    func testImageOverPDFBackgroundInEveryWriter() throws {
        let png = try Self.pngData(Self.quadrants())
        var blobs = MemoryBlobs()
        let pdfRef = blobs.add(try PDFFixture.data("classic.pdf"))
        let imageRef = blobs.add(png, type: "image/png")
        let background = Item.pdfPage(blob: pdfRef, pageIndex: 0, pageSize: Size(w: 400, h: 300), crop: nil,
                                      frame: Rect(x: 0, y: 0, w: 400, h: 300), z: "a0", layer: .background)
        let image = Item.image(blob: imageRef, pixelSize: Size(w: 40, h: 30), frame: Rect(x: 300, y: 200, w: 80, h: 60), z: "a1")
        let note = PDFFixture.note(size: (400, 300), items: [image, background])
        let options = RenderOptions(compress: false, blobs: blobs, pdfRasterizer: QuadrantRasterizer())

        var report = RenderReport()
        let page = try PNGTestDecoder.decode(try PNGWriter.render(note: note, options: options, png: PNGOptions(scale: 1),
                                                                  report: &report)[0])
        XCTAssertEqual(report, RenderReport())
        XCTAssertEqual(page.rgb(10, 10), [0, 255, 0], "the PDF page's top-left quadrant")
        XCTAssertEqual(page.rgb(10, 290), [255, 0, 0])
        XCTAssertEqual(page.rgb(250, 100), [0, 0, 255])
        XCTAssertEqual(page.rgb(310, 210), [255, 0, 0], "the image's red quadrant, over the PDF's blue")
        XCTAssertEqual(page.rgb(370, 250), [255, 255, 0])

        let svg = try SVGWriter.render(note: note, options: options, report: &report)[0]
        XCTAssertEqual(report, RenderReport())
        let pdfImage = try XCTUnwrap(svg.range(of: "<clipPath id=\"item0\">"))
        let photo = try XCTUnwrap(svg.range(of: "<use xlink:href=\"#img-0\""))
        XCTAssertLessThan(pdfImage.lowerBound, photo.lowerBound, "the background first")

        let pdf = try PDFWriter.render(note: note, options: options, report: &report)
        XCTAssertEqual(report, RenderReport())
        XCTAssertEqual(Self.imageDraws(pdf), 1)
        XCTAssertTrue(T.contains(pdf, "/Subtype /Form"), "the PDF page copied as a form")
    }

    func testOutOfRangeItemsAreSkippedNotFatal() throws {
        let note = NoteState(meta: Self.meta(), pages: [Page(order: "a", items: [
            Item(kind: .pdfPage, frame: Rect(x: 1e12, y: 0, w: 10, h: 10), z: "a"),
        ])])
        var report = RenderReport()
        _ = try PDFWriter.render(note: note, report: &report)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.placeholders.isEmpty)
    }

    /// Placement: the affine map agrees with the formulas of §8.5.1 for every orientation.
    func testPlacementMatchesFormulas() {
        for c in Self.cases() {
            let (ow, oh) = ItemGeometry.orientedSize(c.orientation, width: 40, height: 30)
            let crop = c.crop ?? Rect(x: 0, y: 0, w: ow, h: oh)
            let m = ItemGeometry.placement(crop: crop, frame: c.frame, degrees: c.rotation)
                .after(ItemGeometry.orientation(c.orientation, width: 40, height: 30))
            for (a, b) in [(0.0, 0.0), (40, 0), (40, 30), (0, 30), (13, 7)] {
                let p = m.apply(Point(x: a, y: b))
                guard let back = Self.oracle(c, p, w: 40, h: 30) else { continue }
                XCTAssertEqual(back.a, a, accuracy: 1e-9)
                XCTAssertEqual(back.b, b, accuracy: 1e-9)
            }
            let inv = m.inverse!
            let q = inv.apply(m.apply(Point(x: 11, y: 17)))
            XCTAssertEqual(q.x, 11, accuracy: 1e-9)
            XCTAssertEqual(q.y, 17, accuracy: 1e-9)
        }
    }
}

/// Images read from a real vault's blob store (format.md §8.1) into exports.
final class VaultImageExportTests: XCTestCase {
    func testVaultBlobsDrawAndBadOnesArePlaceholders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-vimg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: dir.appendingPathComponent("V.sempere"), recipients: [id.recipient], identities: [id])
        let note = UUID(), other = UUID()
        let jpeg = try ImageCodecTests.fixture("metadata.jpg")
        let ref = try vault.writeBlob(note: note, jpeg, type: "image/jpeg")
        let elsewhere = try vault.writeBlob(note: other, try ImageCodecTests.fixture("rgb8.png"), type: "image/png")
        let state = NoteState(meta: NoteMeta(title: "Photo", created: Date(timeIntervalSince1970: 0),
                                             pageSize: PageSize(width: 300, height: 300)),
                              pages: [Page(order: "a", items: [
                                  Item.image(blob: ref, pixelSize: Size(w: 61, h: 45), frame: Rect(x: 10, y: 10, w: 122, h: 90), z: "a"),
                                  // A reference to another note's blob does not resolve here (§8.1.1).
                                  Item.image(blob: elsewhere, pixelSize: Size(w: 23, h: 17), frame: Rect(x: 10, y: 150, w: 46, h: 34), z: "b"),
                              ])])
        let opened = try Vault.open(at: vault.url, identities: [id])
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: state, options: RenderOptions(blobs: opened.blobSource(note: note)), report: &report)
        XCTAssertNotNil(ImageExportTests.range(of: try JPEG.stripMetadata(jpeg), in: pdf))
        XCTAssertFalse(T.contains(pdf, "SyntheticCam"))
        XCTAssertEqual(report.placeholders.count, 1)
        XCTAssertTrue(report.placeholders[0].reason.description.contains("missing"), report.placeholders[0].reason.description)
        // Merged PDFs take each note's own blobs.
        var other2 = state
        other2.pages = [Page(order: "a", items: [Item.image(blob: elsewhere, pixelSize: Size(w: 23, h: 17),
                                                            frame: Rect(x: 10, y: 10, w: 46, h: 34), z: "a")])]
        report = RenderReport()
        _ = try PDFWriter.render(notes: [state, other2], blobs: [opened.blobSource(note: note), opened.blobSource(note: other)],
                                 options: RenderOptions(), report: &report)
        XCTAssertEqual(report.placeholders.map(\.page), [1], "only the first note's cross-note reference fails")
    }
}
