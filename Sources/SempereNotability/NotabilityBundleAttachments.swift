import Foundation
import SempereImport
import Sempere
import SemperePDF
import SempereRender

/// The attachments of an `.ntb` bundle (docs/import-notability.md ".ntb
/// attachments"): newer bundles keep each PDF and image as a top-level file
/// named by its SHA-256 (`<64 hex>.pdf`, `.jpeg`, `.png`), named by the
/// bundle's PDF (2) and media (22) records. Placed exactly as the `.note`
/// import places them (D1, D2): PDF pages as layer-0 backgrounds, one
/// Notability page per PDF page, stacked every `⌈W · H'/W'⌉`; images as
/// layer-100 items.
///
/// The record layout is decoded without a schema, so the placement rules are
/// hypotheses the warnings name: a PDF's pages follow one another from the
/// first page, in the order the records name the PDFs; an image is placed by
/// its record's rectangle (or origin and size) on its record's page.
extension NotabilityAttachments {
    /// Kinds of top-level bundle files and the blob types they are stored as.
    static func bundleFileKind(_ name: String) -> NotabilityNote.BundleAttachment.Kind? {
        switch name.split(separator: ".").last?.lowercased() ?? "" {
        case "pdf": return .pdf
        case "jpeg", "jpg", "png", "heic", "heif", "gif", "tif", "tiff", "webp": return .image
        default: return nil
        }
    }

    /// The bundle file a record names: a whole name, else a hash whose file
    /// has the record's kind.
    static func bundleFile(for a: NotabilityNote.BundleAttachment, in files: [String]) -> String? {
        bundleFile(for: a, in: BundleFileIndex(files))
    }

    /// The bundle's files by name and by (hash, kind), built once per bundle:
    /// matching each record against every file cost (records × files).
    struct BundleFileIndex {
        var names: Set<String>
        var byStem: [String: String] = [:]   // "<kind>:<lowercased 64- or 128-digit hash>" → first file, in name order
        init(_ files: [String]) {
            names = Set(files)
            for f in files {
                // Notability 16 keeps them under `assets/`; older bundles at the top level.
                let last = f.split(separator: "/").last.map(String.init) ?? f
                guard let kind = NotabilityAttachments.bundleFileKind(f),
                      let stem = last.split(separator: ".", maxSplits: 1).first,
                      BundleFileName.hashByteCounts.map({ $0 * 2 }).contains(stem.count) else { continue }
                let key = "\(kind):\(stem.lowercased())"
                if byStem[key] == nil { byStem[key] = f }
            }
        }
    }

    static func bundleFile(for a: NotabilityNote.BundleAttachment, in index: BundleFileIndex) -> String? {
        for n in a.fileNames where index.names.contains(n) { return n }
        for n in a.fileNames {
            let hash = String(n.split(separator: ".", maxSplits: 1).first ?? Substring(n)).lowercased()
            if let f = index.byStem["\(a.kind):\(hash)"] { return f }
        }
        return nil
    }

    mutating func resolveBundle(_ note: NotabilityNote, _ pkg: NotePackage, keepMetadata: Bool) {
        let files = note.bundleFiles
        let fileIndex = BundleFileIndex(files)
        let prefix = NotabilityBundle.prefix(pkg)
        imported.bundleFiles = files.count
        imported.bundlePDFRecords = note.bundleAttachments.filter { $0.kind == .pdf }.count
        imported.bundleMediaRecords = note.bundleAttachments.filter { $0.kind == .image }.count
        var used = Set<String>()

        // PDFs, in the order their records name them.
        var pdfNames: [String] = []
        for a in note.bundleAttachments where a.kind == .pdf {
            guard let f = Self.bundleFile(for: a, in: fileIndex) else {
                dropped.bundleRecordsWithoutFile += 1
                warnings.append(".ntb PDF record \(a.index + 1): names no file of the bundle (fields \(a.layout); "
                                + "\(a.fileNames.isEmpty ? "no hash found" : "\(a.fileNames.count) hash(es) found"))")
                continue
            }
            if !pdfNames.contains(f) { pdfNames.append(f) }
        }
        let loosePDFs = files.filter { Self.bundleFileKind($0) == .pdf && !pdfNames.contains($0) }.sorted()
        if pdfNames.isEmpty, !loosePDFs.isEmpty {
            pdfNames = loosePDFs
            warnings.append(".ntb: \(loosePDFs.count) PDF file(s) no record names; placed in file-name order (a guess)")
        }

        let w = note.paper.width
        var cache: [String: LoadedPDF?] = [:]
        var top = 0.0
        var stride: Double?
        var heights = Set<Double>()
        var n = 0
        for name in pdfNames {
            guard let pdf = loadPDF(path: prefix + name, name: name, pkg, cache: &cache) else {
                dropped.pdfs += 1
                continue
            }
            used.insert(name)
            imported.pdfs += 1
            for (index, size) in pdf.pages.enumerated() {
                guard placements.count < Self.maxItems else { dropped.pdfPages += 1; continue }
                guard let size, size.w >= 1, size.h >= 1, NotabilityNote.plausibleAspect(size.h / size.w) != nil else {
                    dropped.pdfPages += 1
                    warnings.append(".ntb PDF \(name): page \(index + 1) has no plausible page box")
                    continue
                }
                let h = w * size.h / size.w
                let height = (h - 1e-6).rounded(.up)
                if stride == nil { stride = height }
                heights.insert(height)
                placements.append(Placement(content: .pdfPage(blob: pdf.ref, pageIndex: index, pageSize: size),
                                            layer: .background, frame: Rect(x: 0, y: top, w: w, h: h), rotation: nil,
                                            tag: "pdf:\(n)"))
                pageTops.append(top)
                pageHeights.append(height)
                imported.pdfPages += 1
                extent = max(extent, top + h)
                top += height
                n += 1
            }
        }
        pageStride = stride
        if heights.count > 1 {
            warnings.append(".ntb: PDF pages of \(heights.count) heights; each placed below the one before (unverified)")
        }
        if !pdfNames.isEmpty {
            warnings.append(".ntb: \(imported.pdfPages) PDF page(s) of \(imported.pdfs) file(s) placed one per Notability page "
                            + "from the first (record layout unconfirmed on real notes)")
        }

        // Images.
        var prepared: [String: Result<ImageImport.Prepared, ImageImport.Failure>] = [:]
        var unreadable: [String: String] = [:]   // never read twice (security review S18)
        var z = 0
        for a in note.bundleAttachments where a.kind == .image {
            let label = ".ntb media record \(a.index + 1)"
            func drop(_ why: String) {
                dropped.media += 1
                warnings.append("\(label): \(why) (fields \(a.layout))")
            }
            guard placements.count < Self.maxItems else { drop("over \(Self.maxItems) items on the page"); continue }
            guard let name = Self.bundleFile(for: a, in: fileIndex) else {
                dropped.bundleRecordsWithoutFile += 1
                drop("names no file of the bundle")
                continue
            }
            if let why = unreadable[name] { drop(why); continue }
            let result: Result<ImageImport.Prepared, ImageImport.Failure>
            if let hit = prepared[name] { result = hit } else {
                do {
                    let p = try ImageImport.prepare(try pkg.read(prefix + name), keepMetadata: keepMetadata)
                    guard hold(p.data.count) else {
                        unreadable[name] = "\(name): over the attachment budget for one note"
                        drop(unreadable[name]!); continue
                    }
                    result = .success(p)
                } catch let f as ImageImport.Failure {
                    result = .failure(f)
                } catch {
                    unreadable[name] = "\(name) cannot be read (\(NotabilityImporter.describe(error)))"
                    drop(unreadable[name]!); continue
                }
                prepared[name] = result
            }
            let image: ImageImport.Prepared
            switch result {
            case .success(let p): image = p
            case .failure(let f): drop("\(name): \(f)"); continue
            }
            let px = Size(w: Double(image.width), h: Double(image.height))
            // Geometry: a rectangle, else an origin and a size, else an origin and the image's own size.
            var frame: Rect?
            var source = ""
            if let r = a.rect, r.2 >= 1, r.3 >= 1 {
                frame = Rect(x: r.0, y: r.1, w: r.2, h: r.3); source = "rect"
            } else if a.pairs.count >= 2, a.pairs[1].1 >= 1, a.pairs[1].2 >= 1 {
                frame = Rect(x: a.pairs[0].1, y: a.pairs[0].2, w: a.pairs[1].1, h: a.pairs[1].2)
                source = "origin (field \(a.pairs[0].0)) + size (field \(a.pairs[1].0))"
            } else if let o = a.pairs.first {
                let scale = min(1, (w - o.1) / max(px.w, 1))
                frame = Rect(x: o.1, y: o.2, w: px.w * max(scale, 0.05), h: px.h * max(scale, 0.05))
                source = "origin (field \(o.0)) + pixel size (a guess)"
            }
            guard var f = frame else { drop("\(name): no geometry found"); continue }
            let page = a.page ?? 0
            f.y += self.top(ofPage: page + 1, pageHeight: pageStride ?? note.paper.pageHeight)
            guard [f.x, f.y, f.w, f.h].allSatisfy({ $0.isFinite && abs($0) <= NotabilityNote.maxCoordinate }),
                  Self.fitsExtent(f, rotation: nil, note: note) else {
                drop("\(name): frame \(f) lies beyond the page extent a renderer draws"); continue
            }
            let ref = BlobRef(content: image.data, type: image.type)
            if blobs[ref.sha256] == nil { blobs[ref.sha256] = (ref, image.data) }
            used.insert(name)
            placements.append(Placement(content: .image(blob: ref, pixelSize: px, orientation: image.orientation, crop: nil),
                                        layer: .content, frame: f, rotation: nil, tag: "image:\(z)"))
            z += 1
            imported.images += 1
            extent = max(extent, f.y + f.h)
            warnings.append("\(label): \(name.prefix(8))… placed on page \(page + 1) from \(source) (fields \(a.layout); unconfirmed)")
        }
        imported.bundleFilesImported = used.count
        let unreferenced = files.filter { !used.contains($0) }
        dropped.bundleFilesUnreferenced = unreferenced.count
        if !unreferenced.isEmpty {
            warnings.append(".ntb: \(unreferenced.count) attachment file(s) not imported: "
                            + unreferenced.prefix(8).map { String($0.prefix(8)) + "…" + ($0.split(separator: ".").last.map { "." + $0 } ?? "") }
                                .joined(separator: ", "))
        }
    }
}

extension NotabilityBundle {
    /// The directory holding `noteBundle` (`""` at the root).
    static func prefix(_ pkg: NotePackage) -> String {
        if pkg.paths.contains("noteBundle") { return "" }
        if let p = pkg.paths.first(where: { $0.hasSuffix("/noteBundle") && $0.split(separator: "/").count == 2 }) {
            return String(p.dropLast("noteBundle".count))
        }
        return ""
    }

    /// Files of the bundle named like attachments (`<hash>.<ext>`), at the top
    /// level or (Notability 16) under `assets/`, sorted.
    static func attachmentFiles(_ pkg: NotePackage) -> [String] {
        let prefix = prefix(pkg)
        return pkg.paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            .filter { path in
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 1 || (parts.count == 2 && parts[0] == "assets") else { return false }
                return BundleFileName.isAttachment(String(parts[parts.count - 1]))
            }.sorted()
    }
}
