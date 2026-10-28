import Foundation
import SempereImport
import Sempere

// Attachments as `Session.plist` describes them (docs/import-notability.md
// "Attachments"): the PDF page layout of a note made from a PDF, and the media
// objects (images). Only descriptions live here; the bytes are read from the
// package when the note is written (`NotabilityAttachments`).

extension NotabilityNote {
    /// One entry of `richText.pageLayoutArray`: a Notability page of a note
    /// made from a PDF.
    public struct PDFLayoutEntry: Hashable, Sendable {
        /// `kPageLayoutDocumentPageNumberKey`: the Notability page, 1-based.
        public var documentPage: Int?
        /// `kPageLayoutPDFFileNameKey`, else `kPageLayoutPDFFileKey.pdfFileName`:
        /// the file under `PDFs/`; nil for a page that is not a PDF page.
        public var fileName: String?
        /// True when the entry names a PDF (by name or by `PDFFile` object),
        /// even if the name cannot be read.
        public var isPDF: Bool
        /// `kPageLayoutPDFPageNumberKey`: the PDF page, 1-based (0-based when
        /// some entry of the note holds 0).
        public var pdfPage: Int?
        /// `kPageLayoutPDFIsOriginalPageKey`.
        public var isOriginal: Bool?

        public init(documentPage: Int? = nil, fileName: String? = nil, isPDF: Bool = false, pdfPage: Int? = nil,
                    isOriginal: Bool? = nil) {
            self.documentPage = documentPage; self.fileName = fileName; self.isPDF = isPDF || fileName != nil
            self.pdfPage = pdfPage; self.isOriginal = isOriginal
        }
    }

    /// One entry of `richText.mediaObjects` (an image, or a class not known),
    /// read without a schema: Notability's field names for media objects are
    /// not confirmed (docs/attachments.md §11, unknown 1), so the reader looks
    /// for the candidate names below anywhere in the object (up to
    /// `MediaObject.maxDepth` levels) and records which ones it used.
    public struct MediaObject: Hashable, Sendable {
        /// The archived class (`ImageMediaObject`, …).
        public var className: String
        /// Top-level field names, sorted: for the report when nothing maps.
        public var fieldNames: [String]
        /// Every string value found in the object (paths of strings in
        /// `stringPaths`): one of them names the media file.
        public var strings: [String]
        /// Key path of each entry of `strings`, `.`-joined.
        public var stringPaths: [String]
        /// The placed box in ink coordinates (document units, before the x
        /// inset), from a rect field or an origin and a size.
        public var frame: Rect?
        /// Degrees clockwise.
        public var rotation: Double?
        /// Crop: in pixels, or in unit coordinates when `cropIsUnit`.
        public var crop: Rect?
        /// True when `crop` is a fraction of the image (all values in 0…1).
        public var cropIsUnit = false
        /// The fields the geometry came from, e.g. `documentContentOrigin +
        /// unscaledContentSize × contentScale`; nil when there is none.
        public var geometrySource: String?

        public init(className: String, fieldNames: [String] = [], strings: [String] = [], stringPaths: [String] = [],
                    frame: Rect? = nil, rotation: Double? = nil, crop: Rect? = nil, cropIsUnit: Bool = false,
                    geometrySource: String? = nil) {
            self.className = className; self.fieldNames = fieldNames; self.strings = strings
            self.stringPaths = stringPaths; self.frame = frame; self.rotation = rotation; self.crop = crop
            self.cropIsUnit = cropIsUnit; self.geometrySource = geometrySource
        }

        /// Deepest nesting the reader follows (keyed archives can be cyclic).
        static let maxDepth = 6
        /// Values visited per object at most.
        static let maxValues = 4096
        /// Elements read per nested array.
        static let maxArray = 64
        /// Values visited by all schema-less walks of one note together (media
        /// objects, typed text styles, recording entries). An archive can list
        /// one shared object any number of times, so a budget per object alone
        /// would let a small file cost (objects × `maxValues`).
        static let maxValuesPerNote = 1 << 18

        /// Candidate field names (compared case-insensitively with the last
        /// key of a path that is not an `NS.` key) for each part of the geometry.
        static let frameKeys: Set<String> = ["frame", "documentframe", "contentframe", "mediaframe", "bounds",
                                             "documentrect", "boundingrect", "rect", "documentbounds"]
        static let originKeys: Set<String> = ["documentcontentorigin", "documentorigin", "contentorigin", "origin",
                                              "position", "documentposition"]
        static let sizeKeys: Set<String> = ["unscaledcontentsize", "contentsize", "documentsize", "size",
                                            "imagesize", "displaysize"]
        static let scaleKeys: Set<String> = ["contentscale", "scale", "zoomscale", "scalefactor"]
        static let rotationKeys: Set<String> = ["rotation", "rotationangle", "angle", "contentrotation",
                                                "rotationdegrees", "rotationradians"]
        static let cropKeys: Set<String> = ["croprect", "crop", "cropframe", "imagecroprect", "contentsrect",
                                            "croppingrect", "cropbounds", "figurecroprectkey"]
        static let transformKeys: Set<String> = ["transform", "affinetransform", "contenttransform"]

        /// Reads one media object, its walk counted against `total`.
        static func read(_ a: KeyedArchive, _ node: KeyedArchive.Node, total: inout Int) -> MediaObject {
            let leaves = Self.leaves(a, node, total: &total)
            var m = MediaObject(className: node.className ?? "dictionary", fieldNames: topLevelKeys(node))
            for l in leaves {
                if case .string(let s) = l.node {
                    m.strings.append(s); m.stringPaths.append(l.path.joined(separator: "."))
                }
            }
            m.readGeometry(leaves)
            return m
        }

        /// Reads one media object on a budget of its own (tests).
        static func read(_ a: KeyedArchive, _ node: KeyedArchive.Node) -> MediaObject {
            var total = maxValues
            return read(a, node, total: &total)
        }

        /// The leaves under `n` (at most `maxValues`), the walk's cost taken from `total`.
        static func leaves(_ a: KeyedArchive, _ n: KeyedArchive.Node,
                           total: inout Int) -> [(path: [String], node: KeyedArchive.Node)] {
            let start = min(maxValues, max(total, 0))
            var budget = start
            var out: [(path: [String], node: KeyedArchive.Node)] = []
            collect(a, n, path: [], depth: 0, budget: &budget, into: &out)
            total -= start - budget
            return out
        }

        static func topLevelKeys(_ n: KeyedArchive.Node) -> [String] {
            switch n {
            case .object(_, let f) where f.count <= maxValues: return f.keys.sorted()
            case .dict(let d) where d.count <= maxValues: return d.keys.sorted()
            default: return []
            }
        }

        static func collect(_ a: KeyedArchive, _ n: KeyedArchive.Node, path: [String], depth: Int, budget: inout Int,
                            into out: inout [(path: [String], node: KeyedArchive.Node)]) {
            guard budget > 0 else { return }
            budget -= 1
            // A container costs its size (copied and sorted at every visit): one larger
            // than what is left ends the walk.
            func children(_ fields: [String: PlistValue]) {
                guard depth < maxDepth else { return }
                guard fields.count <= budget else { budget = 0; return }
                budget -= fields.count
                for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
                    guard budget > 0 else { return }
                    guard let child = try? a.node(v) else { continue }
                    collect(a, child, path: path + [k], depth: depth + 1, budget: &budget, into: &out)
                }
            }
            switch n {
            case .object(_, let f): children(f)
            case .dict(let d): children(d)
            case .array(let items):
                guard depth < maxDepth else { return }
                budget -= min(items.count, maxArray, budget)
                for (i, v) in items.prefix(maxArray).enumerated() {
                    guard budget > 0 else { return }
                    guard let child = try? a.node(v) else { continue }
                    collect(a, child, path: path + ["[\(i)]"], depth: depth + 1, budget: &budget, into: &out)
                }
            case .null: break
            default: out.append((path, n))
            }
        }

        /// The key a value is known by: the last path component that is not a
        /// Foundation coding key (`NS.rectval` of an `NSValue`) or an index.
        static func semanticKey(_ path: [String]) -> String? {
            path.last { !$0.hasPrefix("NS.") && !$0.hasPrefix("$") && !$0.hasPrefix("[") }?.lowercased()
        }

        mutating func readGeometry(_ leaves: [(path: [String], node: KeyedArchive.Node)]) {
            // Shallowest match first: the media object's own fields before nested ones.
            func first<T>(_ keys: Set<String>, _ parse: (KeyedArchive.Node) -> T?) -> (T, String)? {
                var best: (T, String, Int)?
                for l in leaves {
                    guard let k = MediaObject.semanticKey(l.path), keys.contains(k), let v = parse(l.node) else { continue }
                    if l.path.count < best?.2 ?? Int.max { best = (v, l.path.joined(separator: "."), l.path.count) }
                }
                return best.map { ($0.0, $0.1) }
            }
            let transform = first(MediaObject.transformKeys) { MediaObject.numbers($0, count: 6) }
            // An empty rect is a placeholder (Notability 13+ keeps a `{{0, 0}, {0, 0}}`
            // `rect` on the figure's background object): fall through to origin + size.
            if let (r, key) = first(MediaObject.frameKeys, { MediaObject.rect($0).flatMap { $0.w >= 1 && $0.h >= 1 ? $0 : nil } }) {
                frame = r; geometrySource = key
            } else if let (o, ok) = first(MediaObject.originKeys, { MediaObject.numbers($0, count: 2) }),
                      let (s, sk) = first(MediaObject.sizeKeys, { MediaObject.numbers($0, count: 2) }) {
                var scale = 1.0, scaleKey = ""
                if let (v, k) = first(MediaObject.scaleKeys, { $0.double }), v.isFinite, v > 0 {
                    scale = v; scaleKey = " × " + k
                } else if let t = transform?.0 {
                    let sx = hypot(t[0], t[1])
                    if sx.isFinite, sx > 0 { scale = sx; scaleKey = " × scale of " + (transform?.1 ?? "") }
                }
                frame = Rect(x: o[0], y: o[1], w: s[0] * scale, h: s[1] * scale)
                geometrySource = "\(ok) + \(sk)\(scaleKey)"
            }
            if let (v, k) = first(MediaObject.rotationKeys, { $0.double }), v.isFinite {
                rotation = k.lowercased().contains("degree") ? v : v * 180 / .pi
                geometrySource = (geometrySource ?? "") + ", rotation " + k
            } else if let (t, k) = transform, atan2(t[1], t[0]).isFinite, abs(atan2(t[1], t[0])) > 1e-9 {
                rotation = atan2(t[1], t[0]) * 180 / .pi
                geometrySource = (geometrySource ?? "") + ", rotation from " + k
            }
            if let (c, k) = first(MediaObject.cropKeys, MediaObject.rect) {
                crop = c
                cropIsUnit = [c.x, c.y, c.w, c.h].allSatisfy { (0...1).contains($0) }
                geometrySource = (geometrySource ?? "") + ", crop " + k + (cropIsUnit ? " (unit)" : "")
            }
        }

        /// A rectangle from `{{x, y}, {w, h}}` (`NSStringFromCGRect`, how keyed
        /// archives store `CGRect`) or four numbers.
        static func rect(_ n: KeyedArchive.Node) -> Rect? {
            guard let v = numbers(n, count: 4) else { return nil }
            return Rect(x: v[0], y: v[1], w: v[2], h: v[3])
        }

        /// Exactly `count` finite numbers from a string such as `{1.5, -2}` or
        /// `[a, b, c, d, tx, ty]`, or from data holding that many float64s.
        static func numbers(_ n: KeyedArchive.Node, count: Int) -> [Double]? {
            switch n {
            case .string(let s):
                guard s.utf8.count <= 256 else { return nil }
                let parts = s.split(whereSeparator: { "{}[](), ".contains($0) })
                guard parts.count == count else { return nil }
                let v = parts.compactMap { Double($0) }
                return v.count == count && v.allSatisfy(\.isFinite) ? v : nil
            case .data(let d) where d.count == 8 * count:
                let v = d.withUnsafeBytes { raw in
                    (0..<count).map { Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8 * $0, as: UInt64.self))) }
                }
                return v.allSatisfy(\.isFinite) ? v : nil
            default:
                return nil
            }
        }
    }
}
