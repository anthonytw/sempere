import CZlib
import Foundation
import ImportTestSupport
@testable import SempereImport
@testable import SempereNotability

/// Synthetic attachments for `.note` fixtures: PDFs, images and Notability-
/// shaped media objects. Nothing here comes from a real note.
enum AttachmentFixtures {
    /// A minimal PDF with one page per size (points, `/MediaBox [0 0 w h]`),
    /// classic xref table. `rotate` sets `/Rotate` on every page; `encrypt`
    /// adds an `/Encrypt` entry to the trailer (refused by readers).
    static func pdf(pages: [(Double, Double)], rotate: Int = 0, encrypt: Bool = false, texts: [String] = []) -> Data {
        var objects: [String] = []
        let kids = (0..<pages.count).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
        for (i, (w, h)) in pages.enumerated() {
            let rot = rotate == 0 ? "" : " /Rotate \(rotate)"
            let font = texts.isEmpty ? "" : " /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)]\(rot)\(font) /Contents \(4 + 2 * i) 0 R >>")
            var content = "0 0 1 rg 10 10 50 50 re f"
            if i < texts.count { content += " BT /F1 12 Tf 72 700 Td (\(texts[i])) Tj ET" }
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        let enc = encrypt ? " /Encrypt << /Filter /Standard /V 1 /R 2 >>" : ""
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R\(enc) >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// A structurally valid baseline JPEG header (`w` × `h`, three components)
    /// with an `Exif` APP1 segment holding `orientation` (none when nil) and a
    /// COM segment, then a short scan. Enough for frame-header reading and
    /// metadata stripping, not for decoding.
    static func jpeg(width w: Int, height h: Int, orientation: Int? = 6) -> Data {
        var d: [UInt8] = [0xFF, 0xD8]
        func segment(_ code: UInt8, _ body: [UInt8]) {
            d += [0xFF, code, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)] + body
        }
        segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        if let o = orientation {
            // "Exif\0\0", little-endian TIFF header, IFD0 at 8 with one entry: 0x0112 SHORT 1 = o.
            let tiff: [UInt8] = [0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0,
                                 UInt8(o), 0, 0, 0, 0, 0, 0, 0]
            segment(0xE1, Array("Exif".utf8) + [0, 0] + tiff + Array("GPS 51.5N 0.1W".utf8))
        }
        segment(0xFE, Array("camera comment".utf8))
        segment(0xDB, [0] + [UInt8](repeating: 1, count: 64))
        segment(0xC0, [8, UInt8(h >> 8), UInt8(h & 0xFF), UInt8(w >> 8), UInt8(w & 0xFF), 3,
                       1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0])
        segment(0xDA, [3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0])
        d += [0x12, 0x34, 0x56, 0x78, 0xFF, 0x00, 0x9A]
        d += [0xFF, 0xD9]
        return Data(d)
    }

    /// A valid 8-bit RGBA PNG of `w` × `h` with a `tEXt` metadata chunk.
    static func png(width w: Int, height h: Int) -> Data {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let tb = Array(type.utf8) + body
            let crc = tb.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
            return be32(body.count) + tb + be32(Int(crc))
        }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var raw: [UInt8] = []
        for _ in 0..<h { raw += [0] + [UInt8](repeating: 0x80, count: 4 * w) }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(w) + be32(h) + [8, 6, 0, 0, 0])
        out += chunk("tEXt", Array("Author\0Someone".utf8))
        out += chunk("IDAT", [UInt8](zlib(Data(raw))))
        out += chunk("IEND", [])
        return Data(out)
    }

    static func zlib(_ data: Data) -> Data {
        var bound = compressBound(uLong(data.count))
        var out = [UInt8](repeating: 0, count: Int(bound))
        let input = [UInt8](data)
        _ = compress(&out, &bound, input, uLong(input.count))
        return Data(out[0..<Int(bound)])
    }

    /// A GIF signature with no image in it (unreadable).
    static let gif = Data("GIF89a\u{1}\0\u{1}\0\0\0\0;".utf8)

    /// A WebP signature (a format the importer leaves out).
    static let webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8 ".utf8) + Data(count: 16)

    /// A real GIF: 2 × 1 pixels, red and blue, opaque.
    static let realGIF = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 2, 0, 1, 0, 0x80, 0, 0,
                               255, 0, 0, 0, 0, 255,
                               0x2C, 0, 0, 0, 0, 2, 0, 1, 0, 0, 2, 2, 0x44, 0x54, 0, 0x3B])

    /// An image media object shaped as real Notability notes store one
    /// (confirmed on the maintainer's backup, values here synthetic):
    /// `documentContentOrigin` and `unscaledContentSize` as
    /// `NSStringFromCGPoint`/`Size` strings, and the file under `figure →
    /// FigureBackgroundObjectKey → kImageObjectSnapshotKey → relativePath`. The
    /// background object also carries a placeholder `rect` of `{{0, 0}, {0, 0}}`
    /// and the figure a pixel `FigureCropRectKey`; `realLayout: false` leaves
    /// both out (the older synthetic shape).
    static func imageObject(_ a: inout KeyedArchiveBuilder, file: String, origin: (Double, Double),
                            size: (Double, Double), scale: Double = 1, realLayout: Bool = true,
                            cropPixels: (Double, Double)? = nil, extra: [(String, BValue)] = []) -> BValue {
        let snapshot = a.object("ImageSnapshot", [("relativePath", a.string(file))])
        let background = a.object("ImageObject", [("kImageObjectSnapshotKey", snapshot)]
                                  + (realLayout ? [("rect", a.string("{{0, 0}, {0, 0}}"))] : []))
        var figureFields: [(String, BValue)] = [("FigureBackgroundObjectKey", background)]
        if realLayout, let c = cropPixels { figureFields.append(("FigureCropRectKey", a.string("{{0, 0}, {\(c.0), \(c.1)}}"))) }
        let figure = a.object("Figure", figureFields)
        return a.object("ImageMediaObject", [
            ("documentContentOrigin", a.string("{\(origin.0), \(origin.1)}")),
            ("unscaledContentSize", a.string("{\(size.0), \(size.1)}")),
            ("contentScale", .real(scale)),
            ("figure", figure),
        ] + extra)
    }

    /// The synthetic note's files with `session` as its `Session.plist`, the
    /// PDF (if any) and extra files (paths inside the package directory).
    static func package(session: Data, pdf: Data? = nil, extra: [(String, Data)] = [],
                        thumbnails: [(String, Int, Int)] = [("thumb.png", 48, 63)], handwriting: Bool = true) -> Data {
        let dir = "Synthetic note/"
        let replaced = Set(extra.map { dir + $0.0 })
        var files = SyntheticNote.files(thumbnails: thumbnails, handwriting: handwriting)
            .filter { !$0.0.hasSuffix("Session.plist") && !replaced.contains($0.0) }
        files.append((dir + "Session.plist", session))
        if let pdf { files.append((dir + "PDFs/" + SyntheticNote.pdfName, pdf)) }
        files += extra.map { (dir + $0.0, $0.1) }
        return TestZip.write(files.map { .init(path: $0.0, data: $0.1) })
    }

    // MARK: Recordings

    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let n = body.count + 8
        return [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + body
    }

    static func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(v >> (8 * UInt64($0)) & 0xFF) } }

    /// A minimal `.m4a`: `ftyp`, `moov` with `mvhd` (timescale 1000) and an
    /// `mp4a` sample entry (mono, 48 kHz), and a few bytes of `mdat`.
    static func m4a(seconds: Double) -> Data {
        let mvhd = box("mvhd", [0, 0, 0, 0] + be(0, 4) + be(0, 4) + be(1000, 4) + be(UInt64(seconds * 1000), 4)
            + [UInt8](repeating: 0, count: 80))
        let mp4a = box("mp4a", [UInt8](repeating: 0, count: 6) + [0, 1] + [UInt8](repeating: 0, count: 8)
            + be(1, 2) + be(16, 2) + [0, 0, 0, 0] + be(48000 << 16, 4))
        let stsd = box("stsd", [0, 0, 0, 0] + be(1, 4) + mp4a)
        // A sound track: `AudioProbe` reads the first trak whose handler is `soun`.
        let hdlr = box("hdlr", [UInt8](repeating: 0, count: 8) + Array("soun".utf8) + [UInt8](repeating: 0, count: 13))
        let trak = box("trak", box("mdia", hdlr + box("minf", box("stbl", stsd))))
        return Data(box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0] + Array("M4A mp42isom".utf8))
            + box("moov", mvhd + trak) + box("mdat", [1, 2, 3, 4]))
    }

    /// A minimal `.caf`: AAC at 48 kHz, mono, with a `pakt` giving the frames.
    static func caf(seconds: Double) -> Data {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { Array(type.utf8) + be(UInt64(body.count), 8) + body }
        let desc = be(Double(48000).bitPattern, 8) + Array("aac ".utf8) + be(0, 4) + be(0, 4) + be(1024, 4) + be(1, 4) + be(0, 4)
        let pakt = be(10, 8) + be(UInt64(seconds * 48000), 8) + be(0, 4) + be(0, 4)
        return Data(Array("caff".utf8) + [0, 1, 0, 0] + chunk("desc", desc) + chunk("pakt", pakt) + chunk("data", [0, 0, 0, 1, 9, 9]))
    }

    /// `Recordings/library.plist` with the given entries (key → XML body of its dictionary).
    static func library(_ entries: [(String, String)]) -> Data {
        let body = entries.map { "\t\t<key>\($0.0)</key>\n\t\t<dict>\($0.1)</dict>\n" }.joined()
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>recordings</key>
            \t<dict>
            \(body)\t</dict>
            </dict>
            </plist>

            """.utf8)
    }
}
