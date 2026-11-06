import Foundation

/// Builds small PDFs for tests: objects in order, a correct classic xref
/// table unless told otherwise.
enum PDFBuild {
    static func file(_ objects: [(Int, String)], trailer: String = "/Root 1 0 R", header: String = "%PDF-1.4\n",
                     xref: Bool = true) -> [UInt8] {
        var out = Array(header.utf8)
        var offsets: [Int: Int] = [:]
        for (num, body) in objects {
            offsets[num] = out.count
            out += Array("\(num) 0 obj\n\(body)\nendobj\n".utf8)
        }
        guard xref else { return out }
        let size = (offsets.keys.max() ?? 0) + 1
        let pos = out.count
        var x = "xref\n0 \(size)\n"
        for n in 0..<size {
            if let o = offsets[n] {
                x += String(repeating: "0", count: 10 - String(o).count) + String(o) + " 00000 n \n"
            } else {
                x += "0000000000 65535 f \n"
            }
        }
        x += "trailer\n<< /Size \(size) \(trailer) >>\nstartxref\n\(pos)\n%%EOF\n"
        return out + Array(x.utf8)
    }

    /// Catalog 1, Pages 2 with one page 3 whose contents are object 4.
    static func onePage(contents: String = "0 0 1 rg 0 0 10 10 re f", extra: [(Int, String)] = [],
                        pageExtra: String = "") -> [UInt8] {
        file([(1, "<< /Type /Catalog /Pages 2 0 R >>"),
              (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 100] >>"),
              (3, "<< /Type /Page /Parent 2 0 R /Contents 4 0 R \(pageExtra) >>"),
              (4, "<< /Length \(contents.utf8.count) >>\nstream\n\(contents)\nendstream")] + extra)
    }
}

extension PDFBuild {
    /// `pages` pages sharing indirect Type 0 font 5 (a ToUnicode CMap of
    /// `entries` codes), a header form 7, and a direct font named /F2 that
    /// differs between odd and even pages.
    static func sharedFonts(pages: Int, entries: Int) -> Data {
        var cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n"
            + "1 begincodespacerange <0000> <FFFF> endcodespacerange\n"
        var k = 0
        while k < entries {
            let n = min(100, entries - k)
            cmap += "\(n) beginbfchar\n"
            for c in k..<(k + n) { cmap += String(format: "<%04X> <%04X>\n", c + 1, 0x4E00 + c % 20_000) }
            cmap += "endbfchar\n"
            k += n
        }
        cmap += "endcmap CMapName currentdict /CMap defineresource pop end end"
        let form = "BT /F1 9 Tf 10 90 Td <00010002> Tj ET"
        var objects: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [\((0..<pages).map { "\(100 + 2 * $0) 0 R" }.joined(separator: " "))] "
                + "/Count \(pages) /MediaBox [0 0 100 100] >>"),
            (5, "<< /Type /Font /Subtype /Type0 /BaseFont /F /Encoding /Identity-H /ToUnicode 6 0 R >>"),
            (6, "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream"),
            (7, "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /Font << /F1 5 0 R >> >> "
                + "/Length \(form.utf8.count) >>\nstream\n\(form)\nendstream"),
        ]
        for p in 0..<pages {
            let direct = p % 2 == 0 ? "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
                : "<< /Type /Font /Subtype /Type1 /BaseFont /X /Encoding << /Differences [65 /eacute] >> >>"
            let codes = (0..<20).map { String(format: "%04X", ($0 * 37 + p) % entries + 1) }.joined()
            let contents = "/X1 Do BT /F1 10 Tf 10 50 Td <\(codes)> Tj 0 -12 Td /F2 10 Tf (AB page \(p)) Tj ET"
            objects.append((100 + 2 * p, "<< /Type /Page /Parent 2 0 R /Contents \(101 + 2 * p) 0 R /Resources "
                + "<< /Font << /F1 5 0 R /F2 \(direct) >> /XObject << /X1 7 0 R >> >> >>"))
            objects.append((101 + 2 * p, "<< /Length \(contents.utf8.count) >>\nstream\n\(contents)\nendstream"))
        }
        return Data(PDFBuild.file(objects))
    }
}
