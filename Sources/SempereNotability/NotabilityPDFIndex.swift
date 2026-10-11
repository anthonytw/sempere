import Foundation
import SempereImport
import Sempere
import SemperePDF
import SempereRender

/// Notability's index of the text of a note's PDF (docs/import-notability.md
/// "PDF text"): `NBPDFIndex/PDFIndex.zip` in a `.note` package (holding
/// `PDFTextIndex.txt`, `PDFLayoutIndex.nbpdflayout`, `PDFMetadataIndex.plist`
/// and `PDFImageIndex.plist`), `ios/PDFIndex.fb` in an `.ntb` bundle. Their
/// layouts are not documented and were not seen with content, so they are read
/// only when they can be tied to pages unambiguously:
///
/// - `PDFTextIndex.txt` split at form feeds (`\f`, one part per page, as
///   `pdftotext` writes), when that gives exactly the PDF's page count; else
///   at offsets found in `PDFMetadataIndex.plist` (an array of page count or
///   page count + 1 ascending integers within the text, read as UTF-16 then
///   UTF-8 offsets);
/// - `PDFIndex.fb` like `ios/HandwritingIndex.fb`: root field 2 → table whose
///   field 0 lists page tables (field 0 three words, the third the 0-based
///   page; field 1 the text);
///
/// and only for a note whose pages show one PDF. Pages the index does not
/// cover get their text from the extractor (`PDFTextExtracting`). The
/// warnings describe the index's structure (entry names and sizes, part
/// counts, top-level keys), never its text.
public enum NotabilityPDFIndex {
    /// Largest index entry read (each).
    static let maxEntryBytes: UInt64 = 64 << 20

    /// Page texts by 0-based page from a `.note`'s `PDFIndex.zip`; nil when it
    /// cannot be tied to pages. `notes` collects what was found.
    static func noteIndex(_ zipData: Data, pageCount: Int, notes: inout [String]) -> [Int: String]? {
        guard let zip = try? ZipArchive(data: zipData) else { notes.append("PDF index: PDFIndex.zip is not a zip"); return nil }
        func entry(_ name: String) -> Data? {
            guard let e = zip.entries.first(where: { $0.path == name || $0.path.hasSuffix("/" + name) }) else { return nil }
            return try? zip.read(e, maxSize: maxEntryBytes)
        }
        notes.append("PDF index: " + zip.entries.filter { !$0.isDirectory }.prefix(16)
            .map { "\($0.path.split(separator: "/").last ?? "") \($0.uncompressedSize) B" }.joined(separator: ", "))
        guard let textData = entry("PDFTextIndex.txt") else { notes.append("PDF index: no PDFTextIndex.txt"); return nil }
        let text = String(decoding: textData, as: UTF8.self)
        var parts = text.split(separator: "\u{0C}", omittingEmptySubsequences: false).map(String.init)
        if parts.count == pageCount + 1, parts.last?.allSatisfy(\.isWhitespace) == true { parts.removeLast() }
        if parts.count == pageCount, pageCount > 0 {
            notes.append("PDF index: PDFTextIndex.txt split at form feeds into \(pageCount) page(s)")
            return Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($0, $1) })
        }
        var metaNote = "no PDFMetadataIndex.plist"
        if let meta = entry("PDFMetadataIndex.plist"), let plist = try? PlistValue.parse(meta, allowXML: true) {
            metaNote = "PDFMetadataIndex.plist keys: " + topKeys(plist).prefix(12).joined(separator: ", ")
            if let pages = split(text, offsetsIn: plist, pageCount: pageCount) {
                notes.append("PDF index: PDFTextIndex.txt split at page offsets from PDFMetadataIndex.plist")
                return pages
            }
        }
        notes.append("PDF index: PDFTextIndex.txt (\(textData.count) B, \(parts.count) form-feed part(s)) does not map to "
                     + "the PDF's \(pageCount) page(s); \(metaNote)")
        return nil
    }

    static func topKeys(_ p: PlistValue) -> [String] {
        switch p {
        case .dict(let d): return d.keys.sorted()
        case .array(let a): return ["[\(a.count) entries]"]
        default: return []
        }
    }

    /// `text` cut at the first array of `pageCount` (start offsets) or
    /// `pageCount + 1` (boundaries) ascending integers within it found in
    /// `plist` (four levels deep, 10 000 values at most).
    static func split(_ text: String, offsetsIn plist: PlistValue, pageCount: Int) -> [Int: String]? {
        guard pageCount > 0 else { return nil }
        var budget = 10_000
        var candidates: [[Int]] = []
        func walk(_ v: PlistValue, depth: Int) {
            guard budget > 0, depth <= 4 else { return }
            budget -= 1
            switch v {
            case .array(let a):
                // Only an array of the right length is scanned, and its scan is charged: a binary
                // plist can list one large array any number of times.
                if a.count == pageCount || a.count == pageCount + 1, a.count <= budget {
                    budget -= a.count
                    let ints = a.compactMap { x -> Int? in if case .int(let i) = x, i >= 0, i < Int64(Int32.max) { return Int(i) }; return nil }
                    if ints.count == a.count, zip(ints, ints.dropFirst()).allSatisfy({ $0 <= $1 }) {
                        candidates.append(ints)
                    }
                }
                for x in a.prefix(max(budget, 0)) { walk(x, depth: depth + 1) }
            case .dict(let d):
                guard d.count <= budget else { budget = 0; return }
                budget -= d.count
                for k in d.keys.sorted() { if let x = d[k] { walk(x, depth: depth + 1) } }
            default: break
            }
        }
        walk(plist, depth: 0)
        let utf16 = Array(text.utf16), utf8 = Array(text.utf8)
        for c in candidates {
            var bounds = c
            if bounds.count == pageCount { bounds.append(Int.max) }
            for useUTF16 in [true, false] {
                let total = useUTF16 ? utf16.count : utf8.count
                guard bounds[0] <= total, bounds[pageCount - 1] <= total else { continue }
                var out: [Int: String] = [:]
                for i in 0..<pageCount {
                    let a = bounds[i], b = min(bounds[i + 1], total)
                    guard a <= b else { out = [:]; break }
                    out[i] = useUTF16 ? String(decoding: utf16[a..<b], as: UTF16.self) : String(decoding: utf8[a..<b], as: UTF8.self)
                }
                if out.count == pageCount { return out }
            }
        }
        return nil
    }

    /// Page texts by 0-based page from an `.ntb`'s `ios/PDFIndex.fb`; nil when
    /// it does not read as the handwriting index's layout.
    static func bundleIndex(_ data: Data, notes: inout [String]) -> [Int: String]? {
        let fb = FlatBuffer(data)
        do {
            let root = try fb.root()
            guard let listField = try fb.field(root, 2) else { throw ImportError.package("no field 2") }
            let list = try fb.table(atRef: listField)
            guard let pagesField = try fb.field(list, 0) else { throw ImportError.package("no page list") }
            var out: [Int: String] = [:]
            // Page tables can all reference one text: charge each text's bytes (as strokes are).
            var budget = NotabilityBundle.Budget(limit: NotabilityBundle.decodeBudgetFactor * data.count + 65_536)
            for page in try fb.tables(atVectorRef: pagesField).prefix(100_000) {
                guard let header = try fb.field(page, 0), let textField = try fb.field(page, 1) else { continue }
                let index = Int(try fb.u32(header + 8))
                guard index < 100_000, out[index] == nil else { continue }
                try budget.spend(try fb.vector(atRef: textField, elementSize: 1).count)
                out[index] = try fb.string(atRef: textField)
            }
            notes.append("PDF index: ios/PDFIndex.fb read as \(out.count) page(s)")
            return out.isEmpty ? nil : out
        } catch {
            let fields = (try? fb.inlineFields(try fb.root()))?.map { "\($0.index):\($0.size)" }.joined(separator: ",") ?? "?"
            notes.append("PDF index: ios/PDFIndex.fb (\(data.count) B, root fields \(fields)) not read: "
                         + NotabilityImporter.describe(error))
            return nil
        }
    }
}

extension NotabilityAttachments {
    /// Gives every placed PDF page its text (format.md §8.2.6): from
    /// Notability's index where it maps to the page, else from `extractor`.
    mutating func resolvePDFText(_ note: NotabilityNote, _ pkg: NotePackage, extractor: (any PDFTextExtracting)?) {
        // Template paper repeats one page on every page: its text would match everywhere.
        let pdfIndices = placements.indices.filter {
            if case .pdfPage = placements[$0].content { return !placements[$0].tag.hasPrefix("template:") }
            return false
        }
        guard !pdfIndices.isEmpty else { return }
        func key(_ i: Int) -> (blob: String, page: Int) {
            if case let .pdfPage(blob, page, _) = placements[i].content { return (blob.sha256, page) }
            return ("", 0)
        }
        let blobsShown = Set(pdfIndices.map { key($0).blob })
        var index: [Int: String]?
        var notes: [String] = []
        if blobsShown.count == 1, let sha = blobsShown.first, let pdf = blobs[sha] {
            let pageCount = (try? PDFFile(data: pdf.data).pageCount) ?? 0
            switch note.sourceFormat {
            case .note:
                let prefix = NotabilityNote.packagePrefix(pkg) ?? ""
                let path = prefix + "NBPDFIndex/PDFIndex.zip"
                if pkg.contains(path), let data = try? pkg.read(path) {
                    index = NotabilityPDFIndex.noteIndex(data, pageCount: pageCount, notes: &notes)
                }
            case .ntb:
                let prefix = NotabilityBundle.prefix(pkg)
                let path = prefix + "ios/PDFIndex.fb"
                if pkg.contains(path), let data = try? pkg.read(path) {
                    index = NotabilityPDFIndex.bundleIndex(data, notes: &notes)
                }
            }
        } else if blobsShown.count > 1 {
            notes.append("PDF index: the note shows \(blobsShown.count) PDFs; the index is not tied to one, text is extracted instead")
        }
        warnings += notes
        let indexEngine = "notability" + (note.bundleVersion.map { "-" + $0 } ?? "")
        var missing: [String: [Int]] = [:]
        for i in pdfIndices {
            let k = key(i)
            if let t = index?[k.page] {
                let text = PDFPageText(text: t, engine: indexEngine)
                if !text.text.isEmpty {
                    placements[i].pageText = text
                    imported.pdfTextFromIndex += 1
                    continue
                }
            }
            missing[k.blob, default: []].append(k.page)
        }
        if let extractor, !missing.isEmpty {
            let engine = extractor.engine   // may run a process (`pdftotext -v`): once, not per page
            for (sha, pages) in missing.sorted(by: { $0.key < $1.key }) {
                guard let pdf = blobs[sha] else { continue }
                let texts: [Int: String]
                do { texts = try extractor.pageTexts(pdf.data, pages: Array(Set(pages)).sorted()) } catch {
                    warnings.append("PDF text: \(engine) cannot read \(sha.prefix(8))… (\(NotabilityImporter.describe(error)))")
                    continue
                }
                for i in pdfIndices where key(i).blob == sha && placements[i].pageText == nil {
                    guard let t = texts[key(i).page] else { continue }
                    let text = PDFPageText(text: t, engine: engine)
                    guard !text.text.isEmpty else { continue }
                    placements[i].pageText = text
                    imported.pdfTextExtracted += 1
                }
            }
        }
        imported.pdfTextPages = pdfIndices.filter { placements[$0].pageText != nil }.count
        dropped.pdfTextPages = pdfIndices.count - imported.pdfTextPages
    }
}
