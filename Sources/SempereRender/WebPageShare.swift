import Age
import Crypto
import Foundation
import Sempere
import SemperePDF

// Share one note as a single encrypted HTML file (docs/design/1.3-share.md, docs/web-viewer.md "Share files").
//
// The file is the web viewer's template (`ShareTemplate`, built from `web/` and committed in `SempereShareViewer`)
// with an age file in its data block: one scrypt recipient, armored. Inside is the payload, `sempere-share/1`:
// the note's current state flattened to what a reader needs to draw it, plus its pictures and, if asked, audio.

/// What a share leaves in and out of the note (the CLI's `share` flags, the app's export sheet).
public struct WebShareOptions: Sendable, Equatable {
    /// How hard pictures are compressed.
    public enum ImageQuality: String, Sendable, CaseIterable, Equatable {
        case low, normal, high

        /// The longest side and JPEG quality to try, in order, until the file fits.
        var steps: [(side: Int, quality: Int)] {
            switch self {
            case .low: return [(1280, 70), (1024, 62)]
            case .normal: return [(2048, 82), (1600, 78), (1280, 72)]
            case .high: return [(2048, 90), (1600, 85), (1280, 80)]
            }
        }
    }

    /// Recordings and their transcripts (AAC as stored). Off: audio cards are left out too.
    public var includeAudio = false
    /// The recognized text of each page (search and copy in the page). On by default.
    public var includeText = true
    public var includeTags = false
    public var includeNotebookPath = false
    /// The note's creation date. Off: the share carries no date at all.
    public var includeDates = false
    /// The file's size budget in bytes (the page, the template and the armor included).
    public var maxFileBytes = WebShareOptions.defaultMaxFileBytes
    public var imageQuality = ImageQuality.normal
    /// log2 of the scrypt N. Writers use 18 and never go below 17 (design §3.4); tests pass less.
    public var scryptLog2N = WebShareOptions.defaultScryptLog2N

    public static let defaultMaxFileBytes = 20 << 20
    public static let maxFileBytesLimit = 200 << 20
    public static let defaultScryptLog2N = 18
    public static let maxPages = 200

    public init() {}
}

/// Why a note cannot be shared.
public enum WebShareError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Even at the smallest pictures and without recordings the file would exceed the budget.
    case tooLarge(budget: Int, needed: Int, sections: WebShareSections)
    case tooManyPages(Int)
    case emptyPassphrase
    case badTemplate
    case badOption(String)
    case payloadUnreadable(String)

    public var description: String {
        switch self {
        case .tooLarge(let budget, let needed, let s):
            return "The note needs about \(Self.mb(needed)) MB as a web page and the limit is \(Self.mb(budget)) MB "
                + "(ink and text \(Self.mb(s.ink)), pictures \(Self.mb(s.images)), audio \(Self.mb(s.audio)), "
                + "viewer \(Self.mb(s.template))). Turn off recordings, or raise --max-size."
        case .tooManyPages(let n): return "A shared note has at most \(WebShareOptions.maxPages) pages; this one has \(n)."
        case .emptyPassphrase: return "The passphrase is empty."
        case .badTemplate: return "The web viewer template is missing or malformed."
        case .badOption(let s): return s
        case .payloadUnreadable(let s): return "The shared note's payload is unreadable: \(s)."
        }
    }

    static func mb(_ n: Int) -> String { String(format: "%.1f", Double(n) / 1_048_576) }
}

/// Where the bytes of a share file go, for the size line before Create.
public struct WebShareSections: Sendable, Equatable {
    /// The note's text and ink (compressed).
    public var ink = 0
    public var images = 0
    public var audio = 0
    /// The viewer: the floor of every share.
    public var template = 0

    public var total: Int { ink + images + audio + template }
    public init(ink: Int = 0, images: Int = 0, audio: Int = 0, template: Int = 0) {
        self.ink = ink; self.images = images; self.audio = audio; self.template = template
    }
}

/// A finished share.
public struct WebShareResult: Sendable {
    /// The HTML file.
    public var file: Data
    /// Payload bytes by kind (before encryption and armor), plus the template.
    public var sections: WebShareSections
    public var scryptLog2N: Int
    /// The viewer script's SHA-256 (base64, as in the file's CSP).
    public var scriptSha256: String
    /// Things left out, one line each (a recording over the budget, a video, a PDF page that would not draw).
    public var skipped: [String]
    /// Pages in the note.
    public var pages: Int
}

/// The shared page's template: the viewer's HTML with a placeholder where the data goes.
public struct ShareTemplate: Sendable, Equatable {
    /// Where the sender's data goes (web/scripts/build-share.ts).
    public static let placeholder = "@@SEMPERE-SHARE-DATA@@"
    static let dataTag = #"<script type="text/plain" id="share-data" data-format="sempere-share/1">"#

    public let text: String

    /// - Returns: nil unless `html` is UTF-8 with the placeholder exactly once inside the data block.
    public init?(html: Data) {
        guard let s = String(data: html, encoding: .utf8), s.components(separatedBy: Self.placeholder).count == 2,
              s.contains(Self.dataTag + Self.placeholder + "</script>") else { return nil }
        text = s
    }

    /// The file with `armored` (an armored age file) in the data block, on lines of its own so that
    /// `sed -n '/-----BEGIN AGE/,/-----END AGE/p'` takes exactly the armor.
    func fill(_ armored: Data) -> Data {
        Data(text.replacingOccurrences(of: Self.placeholder, with: "\n" + String(decoding: armored, as: UTF8.self)).utf8)
    }

    /// The script's and the style's SHA-256 (base64, as a CSP names them), from the template itself.
    public var scriptSha256: String { Self.hash(of: Self.element("<script>", in: text) ?? "") }
    public var styleSha256: String { Self.hash(of: Self.element("<style>", in: text) ?? "") }

    static func hash(of s: String) -> String { Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString() }

    /// The text between `open` and its closing tag.
    static func element(_ open: String, in s: String) -> String? {
        guard let a = s.range(of: open) else { return nil }
        let close = "</" + String(open.dropFirst().dropLast()) + ">"
        guard let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    /// What `sempere share --verify` found.
    public struct Verification: Sendable, Equatable {
        /// The file is the template with a data block put in: script, style, CSP and everything else.
        public var matchesTemplate = false
        /// The CSP meta equals the template's.
        public var policyMatches = false
        public var scriptSha256 = ""
        public var styleSha256 = ""
        /// The scrypt work factor in the age header, if the data block holds one scrypt-only age file.
        public var scryptLog2N: Int?
        public var bytes = 0
        public var problems: [String] = []
        public var ok: Bool { problems.isEmpty }
    }

    /// Checks a share file against this template without decrypting anything: the script, the style and the CSP
    /// meta equal the template's (compared as a whole), and the data block is an age file with one scrypt
    /// recipient.
    public func verify(file: Data, minLog2N: Int = ShareTemplate.minViewerLog2N) -> Verification {
        var v = Verification()
        v.bytes = file.count
        guard let s = String(data: file, encoding: .utf8) else { v.problems.append("the file is not UTF-8 text"); return v }
        v.scriptSha256 = Self.hash(of: Self.element("<script>", in: s) ?? "")
        v.styleSha256 = Self.hash(of: Self.element("<style>", in: s) ?? "")
        let open = Self.dataTag
        guard let a = s.range(of: open), s.range(of: open, range: a.upperBound..<s.endIndex) == nil,
              let b = s.range(of: "</script>", range: a.upperBound..<s.endIndex) else {
            v.problems.append("the file has no share data block")
            return v
        }
        let data = String(s[a.upperBound..<b.lowerBound])
        let bare = s.replacingCharacters(in: a.upperBound..<b.lowerBound, with: Self.placeholder)
        v.matchesTemplate = bare == text
        v.policyMatches = Self.policy(in: s) == Self.policy(in: text) && Self.policy(in: s) != nil
        if !v.policyMatches { v.problems.append("the Content-Security-Policy differs from the one this release ships") }
        if v.scriptSha256 != scriptSha256 { v.problems.append("the viewer script differs from the one this release ships") }
        if v.styleSha256 != styleSha256 { v.problems.append("the style differs from the one this release ships") }
        if !v.matchesTemplate && v.problems.isEmpty { v.problems.append("the page differs from the template this release ships") }
        do {
            let binary = try Armor.decode(Data(data.utf8))
            let header = try AgeFile.parseHeader(binary).header
            guard header.stanzas.count == 1, let st = header.stanzas.first, st.type == "scrypt", st.args.count == 2,
                  let n = Int(st.args[1]) else {
                v.problems.append("the data is not an age file with one passphrase recipient")
                return v
            }
            v.scryptLog2N = n
            if n < minLog2N || n > Self.maxViewerLog2N {
                v.problems.append("the scrypt work factor is \(n); the viewer opens only \(minLog2N) to \(Self.maxViewerLog2N)")
            }
        } catch {
            v.problems.append("the data block is not an armored age file")
        }
        return v
    }

    /// The work factors worth trusting in a share: below 17 the passphrase is cheap to guess, and the viewer refuses
    /// above 20 (`maxWorkFactor`, web/src/share/open.ts).
    public static let minViewerLog2N = 17
    public static let maxViewerLog2N = 20

    /// The content of the CSP meta.
    static func policy(in s: String) -> String? {
        let key = #"<meta http-equiv="Content-Security-Policy" content=""#
        guard let a = s.range(of: key), let b = s.range(of: "\"", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}

/// Lowercase hex SHA-256 of `data`.
func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public enum WebPageShare {
    public static let payloadFormat = "sempere-share/1"
    /// The file's name: never the note's title (design D7).
    public static let fileName = "Shared note.html"

    // MARK: The container

    /// `"SHRE" ‖ 0x01 ‖ u32 gzipLength ‖ gzip(JSON) ‖ { u32 64 ‖ sha256 hex ‖ u64 length ‖ bytes } *`, big-endian.
    static func container(json: Data, blobs: [(name: String, data: Data)]) throws -> Data {
        let gz = try Gzip.compress(json, level: 9)
        var out = Data("SHRE".utf8)
        out.append(1)
        out.append(contentsOf: be32(gz.count))
        out.append(gz)
        for b in blobs.sorted(by: { $0.name < $1.name }) {
            out.append(contentsOf: be32(b.name.utf8.count))
            out.append(Data(b.name.utf8))
            out.append(contentsOf: be64(b.data.count))
            out.append(b.data)
        }
        return out
    }

    /// A payload read back: the JSON document and the blobs by SHA-256.
    public struct Parsed: Sendable {
        public var json: Data
        public var blobs: [String: Data]
    }

    /// Reads a container, bounded by its input. Throws `WebShareError.payloadUnreadable` for anything else.
    public static func parse(container data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, Array(bytes[0..<4]) == Array("SHRE".utf8), bytes[4] == 1 else {
            throw WebShareError.payloadUnreadable("not a Sempere share")
        }
        let gzLength = Int(bytes[5]) << 24 | Int(bytes[6]) << 16 | Int(bytes[7]) << 8 | Int(bytes[8])
        var at = 9
        guard gzLength <= bytes.count - at else { throw WebShareError.payloadUnreadable("cut short") }
        let json: Data
        do { json = try Gzip.decompress(Data(bytes[at..<(at + gzLength)]), maxOutput: 64 << 20) } catch {
            throw WebShareError.payloadUnreadable("the text is damaged")
        }
        at += gzLength
        var blobs: [String: Data] = [:]
        while at < bytes.count {
            guard bytes.count - at >= 12, blobs.count < 4096 else { throw WebShareError.payloadUnreadable("cut short") }
            let nameLength = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            at += 4
            guard nameLength == 64, bytes.count - at >= 72 else { throw WebShareError.payloadUnreadable("cut short") }
            let name = String(decoding: bytes[at..<(at + 64)], as: UTF8.self)
            at += 64
            var length: UInt64 = 0
            for i in 0..<8 { length = length << 8 | UInt64(bytes[at + i]) }
            at += 8
            guard length <= UInt64(bytes.count - at) else { throw WebShareError.payloadUnreadable("cut short") }
            let content = Data(bytes[at..<(at + Int(length))])
            at += Int(length)
            guard blobs[name] == nil, sha256Hex(content) == name else {
                throw WebShareError.payloadUnreadable("an attachment is damaged")
            }
            blobs[name] = content
        }
        return Parsed(json: json, blobs: blobs)
    }

    private static func be32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }
    private static func be64(_ n: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: n >> (56 - 8 * $0)) } }

    /// The JSON document of a payload.
    struct Envelope: Encodable {
        var format = WebPageShare.payloadFormat
        var shareId: String
        var generator = WebPageShare.payloadFormat
        var note: NoteState
    }

    // MARK: Size of the finished file

    /// The size of the armored age file for a payload of `payloadBytes` (header, nonce, chunk tags, base64, lines).
    static func armoredSize(payloadBytes p: Int) -> Int {
        let binary = 150 + 16 + p + 16 * max(1, (p + 65535) / 65536)
        let b64 = 4 * ((binary + 2) / 3)
        return 1 + 35 + b64 + (b64 + 63) / 64 + 33   // the line break before the armor, BEGIN, base64 lines, END
    }

    // MARK: Making a share

    /// Builds the share file for `state`.
    ///
    /// - Parameters:
    ///   - blobs: the note's attachments (`Vault.blobSource(note:)`); without them pictures are left out.
    ///   - pdfRasterizer: draws PDF pages into pictures (the CLI's Poppler, the app's PDFKit); without it PDF pages
    ///     are left out with a notice.
    ///   - imageDecoder: decodes what `SempereRender` cannot (HEIC in the app).
    /// - Throws: `WebShareError`, or `CancellationError`.
    public static func make(_ state: NoteState, blobs: (any BlobSource)?, options: WebShareOptions, passphrase: String,
                            template: ShareTemplate, pdfRasterizer: (any PDFPageRasterizer)? = nil,
                            imageDecoder: (any ImageDecoding)? = nil) throws -> WebShareResult {
        guard !passphrase.isEmpty else { throw WebShareError.emptyPassphrase }
        guard (1...30).contains(options.scryptLog2N) else { throw WebShareError.badOption("The scrypt work factor must be 1 to 30.") }
        guard options.maxFileBytes > 0, options.maxFileBytes <= WebShareOptions.maxFileBytesLimit else {
            throw WebShareError.badOption("The size limit must be between 1 and \(WebShareOptions.maxFileBytesLimit >> 20) MB.")
        }
        let planned = try plan(state, blobs: blobs, options: options, template: template, pdfRasterizer: pdfRasterizer,
                               imageDecoder: imageDecoder)
        let encrypted = try AgeFile.encrypt(planned.payload, to: [ScryptRecipient(passphrase: passphrase, workFactor: options.scryptLog2N)],
                                            armor: true)
        let file = template.fill(encrypted)
        return WebShareResult(file: file, sections: planned.sections, scryptLog2N: options.scryptLog2N,
                              scriptSha256: template.scriptSha256, skipped: planned.skipped, pages: state.pages.count)
    }

    /// The payload (the container's bytes) and where its bytes go, without encrypting.
    static func plan(_ state: NoteState, blobs: (any BlobSource)?, options: WebShareOptions, template: ShareTemplate,
                     pdfRasterizer: (any PDFPageRasterizer)?, imageDecoder: (any ImageDecoding)?,
                     shareID: String? = nil) throws -> (payload: Data, sections: WebShareSections, skipped: [String]) {
        guard state.pages.count <= WebShareOptions.maxPages else { throw WebShareError.tooManyPages(state.pages.count) }
        let shareId = shareID ?? UUID().uuidString.lowercased()
        let media = ShareMedia(blobs: blobs, rasterizer: pdfRasterizer, decoder: imageDecoder)
        let steps = options.imageQuality.steps
        let floor = template.text.utf8.count - ShareTemplate.placeholder.utf8.count
        func size(_ b: Built) -> Int { floor + armoredSize(payloadBytes: b.payload.count) }

        // Recordings: as many as fit once the pictures are at their smallest.
        var recordings: [Recording] = []
        var skipped: [String] = []
        if options.includeAudio {
            let smallest = steps[steps.count - 1]
            // Only a size probe: its notes are repeated by the real build below, so they are dropped here.
            var probeNotes: [String] = []
            let base = try build(state, options: options, shareId: shareId, media: media, step: smallest, recordings: [],
                                 skipped: &probeNotes)
            var room = options.maxFileBytes - size(base)
            for r in state.recordings.sorted(by: { ($0.started, $0.id.uuidString) < ($1.started, $1.id.uuidString) }) {
                try Task.checkCancellation()
                let cost = Int(Double(media.audioCost(r)) * 1.4) + 200
                if media.audioCost(r) > 0, cost <= room {
                    recordings.append(r)
                    room -= cost
                } else {
                    skipped.append("recording \(r.title.flatMap { $0.isEmpty ? nil : $0 } ?? r.id.uuidString.lowercased().prefix(8).description) "
                        + "was left out: it does not fit in \(options.maxFileBytes >> 20) MB")
                }
            }
        }
        var last: Built?
        for step in steps {
            try Task.checkCancellation()
            var notes: [String] = []
            let built = try build(state, options: options, shareId: shareId, media: media, step: step, recordings: recordings,
                                  skipped: &notes)
            last = built
            if size(built) <= options.maxFileBytes {
                var sections = built.sections
                sections.template = floor
                return (built.payload, sections, skipped + notes)
            }
        }
        var sections = last?.sections ?? WebShareSections()
        sections.template = floor
        throw WebShareError.tooLarge(budget: options.maxFileBytes, needed: last.map(size) ?? floor, sections: sections)
    }

    struct Built {
        var payload: Data
        var sections: WebShareSections
    }

    static func build(_ state: NoteState, options: WebShareOptions, shareId: String, media: ShareMedia,
                      step: (side: Int, quality: Int), recordings: [Recording], skipped: inout [String]) throws -> Built {
        var attachments: [String: Data] = [:]
        var imageBytes = 0, audioBytes = 0
        var flat = try flatten(state, options: options, media: media, step: step, recordings: recordings,
                               attachments: &attachments, skipped: &skipped)
        // Which blobs are audio (named by the recordings) and which are pictures.
        var audioNames = Set<String>()
        for r in flat.recordings {
            audioNames.insert(r.blob.sha256)
            if let t = r.transcript { audioNames.insert(t.sha256) }
        }
        for (name, data) in attachments {
            if audioNames.contains(name) { audioBytes += data.count + 76 } else { imageBytes += data.count + 76 }
        }
        flat.recordings.sort { ($0.started, $0.id.uuidString) < ($1.started, $1.id.uuidString) }
        let json = try InkJSON.encoder().encode(Envelope(shareId: shareId, note: flat))
        let payload = try container(json: json, blobs: attachments.map { ($0.key, $0.value) })
        let ink = payload.count - imageBytes - audioBytes
        return Built(payload: payload, sections: WebShareSections(ink: ink, images: imageBytes, audio: audioBytes))
    }

    // MARK: Flattening

    /// The note as the viewer needs it: current state only, nothing that names a device, an author or the
    /// note's history, and every attachment replaced by what the page can draw.
    static func flatten(_ state: NoteState, options: WebShareOptions, media: ShareMedia, step: (side: Int, quality: Int),
                        recordings keep: [Recording], attachments: inout [String: Data],
                        skipped: inout [String]) throws -> NoteState {
        let epoch = Date(timeIntervalSince1970: 0)
        var meta = NoteMeta(title: state.meta.title, tags: options.includeTags ? state.meta.tags : [],
                            notebook: options.includeNotebookPath ? state.meta.notebook : nil, favorite: false,
                            created: options.includeDates ? state.meta.created : epoch, paper: state.meta.paper,
                            pageSize: state.meta.pageSize, lang: nil, markersBehindText: state.meta.markersBehindText,
                            recognized: nil)
        meta.title = state.meta.title
        let keptIDs = Set(keep.map(\.id))
        var out = NoteState(deleted: false, meta: meta, pages: [], clocks: nil, tombstones: nil, tagSet: TagSet(), recordings: [])
        for (pageNumber, page) in state.pages.enumerated() {
            try Task.checkCancellation()
            var p = Page(id: page.id, order: page.order, strokes: [], paper: page.paper)
            p.strokes = page.strokes.map { Stroke(id: $0.id, ink: $0.ink, points: $0.points, transform: $0.transform) }
            if options.includeText, var r = page.recognition {
                r.basis = nil
                p.recognition = r
            }
            for item in page.items {
                if let i = try flatten(item, page: pageNumber + 1, options: options, media: media, step: step, keptRecordings: keptIDs,
                                       attachments: &attachments, skipped: &skipped) {
                    p.items.append(i)
                }
            }
            out.pages.append(p)
        }
        for r in keep {
            var rec = Recording(id: r.id, blob: BlobRef(sha256: r.blob.sha256, size: r.blob.size, type: r.blob.type),
                                started: options.includeDates ? r.started : epoch, duration: r.duration, codec: r.codec,
                                sampleRate: r.sampleRate, channels: r.channels, bitRate: r.bitRate, title: r.title)
            if let data = media.audioData(r.blob) {
                attachments[r.blob.sha256] = data
            } else { continue }
            if let t = r.transcript, let data = media.audioData(t) {
                attachments[t.sha256] = data
                rec.transcript = BlobRef(sha256: t.sha256, size: t.size, type: t.type)
            }
            out.recordings.append(rec)
        }
        return out
    }

    static func flatten(_ item: Item, page: Int, options: WebShareOptions, media: ShareMedia, step: (side: Int, quality: Int),
                        keptRecordings: Set<UUID>, attachments: inout [String: Data], skipped: inout [String]) throws -> Item? {
        func note(_ s: String) { skipped.append("page \(page): \(s)") }
        var it = Item(id: item.id, kind: item.kind, layer: item.layer, frame: item.frame, rotation: item.rotation, z: item.z)
        func store(_ image: ShareMedia.Encoded) -> BlobRef {
            let ref = BlobRef(content: image.data, type: image.type)
            attachments[ref.sha256] = image.data
            return ref
        }
        switch item.kind {
        case .text:
            guard var text = item.text else { return nil }
            text.math = nil   // typeset renders are PDFs; the page shows the formula's source
            it.text = text
            return it
        case .image:
            guard let ref = item.blob else { return nil }
            switch media.image(ref, orientation: item.orientation ?? 1, step: step) {
            case .failure(let why):
                note("an image was left out (\(why))")
                return nil
            case .success(let e):
                it.blob = store(e)
                it.pixelSize = Size(w: Double(e.width), h: Double(e.height))
                it.crop = item.crop.map { c in
                    let sx = Double(e.width) / e.orientedWidth, sy = Double(e.height) / e.orientedHeight
                    return Rect(x: c.x * sx, y: c.y * sy, w: c.w * sx, h: c.h * sy)
                }
                return it
            }
        case .pdfPage:
            guard item.blob != nil, item.pageIndex != nil else { return nil }
            switch media.pdfPage(item, step: step) {
            case .failure(let why):
                note("a PDF page was left out (\(why))")
                return nil
            case .success(let e):
                it.kind = .image
                it.blob = store(e)
                it.pixelSize = Size(w: Double(e.width), h: Double(e.height))
                it.crop = item.crop.map { c in
                    let sx = Double(e.width) / e.orientedWidth, sy = Double(e.height) / e.orientedHeight
                    return Rect(x: c.x * sx, y: c.y * sy, w: c.w * sx, h: c.h * sy)
                }
                return it
            }
        case .math:
            guard var math = item.math else { return nil }
            math.extra = [:]
            if let render = math.render, let size = math.renderSize {
                var pseudo = Item(id: item.id, kind: .pdfPage, frame: item.frame, z: item.z, blob: render, pageIndex: 0, pageSize: size)
                pseudo.layer = item.layer
                if case .success(let e) = media.pdfPage(pseudo, step: step, scale: 4) {
                    it.kind = .image
                    it.blob = store(e)
                    it.pixelSize = Size(w: Double(e.width), h: Double(e.height))
                    return it
                }
            }
            math.render = nil
            math.renderSize = nil
            math.engine = nil
            it.math = math
            return it
        case .video:
            guard let poster = item.poster else {
                note("a video was left out (it has no poster frame)")
                return nil
            }
            note("a video was not included; its poster frame is shown")
            switch media.image(poster, orientation: 1, step: step) {
            case .failure: return nil
            case .success(let e):
                it.kind = .image
                it.blob = store(e)
                it.pixelSize = Size(w: Double(e.width), h: Double(e.height))
                return it
            }
        case .audio:
            guard let r = item.recording, keptRecordings.contains(r) else { return nil }
            it.recording = r
            return it
        default:
            return nil
        }
    }
}

/// Pictures and audio of one share: decoded, scaled and re-encoded once per size step, with every original's
/// metadata dropped (only pixels are written). One per share; not thread-safe.
final class ShareMedia {
    struct Encoded {
        var data: Data
        var type: String
        var width: Int
        var height: Int
        /// The size the crop of the item is measured in (an image: after orientation; a PDF page: its points).
        var orientedWidth: Double
        var orientedHeight: Double
    }

    private let blobs: (any BlobSource)?
    let store: ImageStore
    private let backgrounds: PDFBackgrounds
    private let rasterizer: (any PDFPageRasterizer)?
    private var cache: [String: Result<Encoded, ShareFailure>] = [:]

    struct ShareFailure: Error, CustomStringConvertible {
        var description: String
    }

    init(blobs: (any BlobSource)?, rasterizer: (any PDFPageRasterizer)?, decoder: (any ImageDecoding)?) {
        self.blobs = blobs
        self.rasterizer = rasterizer
        var options = RenderOptions(paper: true, imageDecoder: decoder)
        options.blobs = blobs
        store = ImageStore(options: options, blobs: blobs)
        backgrounds = PDFBackgrounds(blobs: blobs, rasterizer: rasterizer, pixelBudget: 400_000_000)
    }

    /// The bytes an audio or transcript blob adds to the file, or 0 when it cannot be read.
    func audioCost(_ r: Recording) -> Int {
        guard blobs != nil else { return 0 }
        var n = Int(r.blob.size) + 76
        if let t = r.transcript { n += Int(t.size) + 76 }
        return r.blob.size > Int64(WebShareOptions.maxFileBytesLimit) ? 0 : n
    }

    func audioData(_ ref: BlobRef) -> Data? {
        guard let blobs, ref.size <= Int64(WebShareOptions.maxFileBytesLimit) else { return nil }
        return try? blobs.data(for: ref, maxBytes: Int(ref.size))
    }

    func image(_ ref: BlobRef, orientation: Int, step: (side: Int, quality: Int)) -> Result<Encoded, ShareFailure> {
        let key = "i/\(ref.sha256)/\(orientation)/\(step.side)/\(step.quality)"
        if let r = cache[key] { return r }
        let r: Result<Encoded, ShareFailure>
        switch store.load(ref) {
        case .failure(let why): r = .failure(ShareFailure(description: "\(why)"))
        case .success(let loaded):
            // Decode no larger than the step needs: JPEG DCT scaling and a box average (`forRaster`, cached per
            // size, so the quality steps of one image decode it once). A format with no known size
            // (HEIC through the platform decoder) is decoded whole, as before.
            var reduction = 1.0
            if loaded.width > 0, loaded.height > 0 { reduction = Double(max(loaded.width, loaded.height)) / Double(max(1, step.side)) }
            switch store.forRaster(ref, loaded, reduction: max(1, reduction)) {
            case .failure(let why): r = .failure(ShareFailure(description: "\(why)"))
            case .success(let rgba):
                let o = (2...8).contains(orientation) ? orientation : 1
                if let oriented = try? LegacyImage.oriented(rgba, o) {
                    var e = Self.encode(oriented, side: step.side, quality: step.quality)
                    // The crop is measured in the full image, not the reduced one decoded here.
                    let full = loaded.width > 0 ? (w: Double(loaded.width), h: Double(loaded.height))
                        : (w: Double(rgba.width), h: Double(rgba.height))
                    let upright = o >= 5 ? (w: full.h, h: full.w) : full
                    e.orientedWidth = upright.w
                    e.orientedHeight = upright.h
                    r = .success(e)
                } else {
                    r = .failure(ShareFailure(description: "it cannot be turned upright"))
                }
            }
        }
        cache.removeAll(keepingCapacity: true)   // one decoded original at a time
        cache[key] = r
        return r
    }

    /// A PDF page (or an equation's render) as a picture: 150 dpi, or `scale` pixels per point, capped by the step.
    func pdfPage(_ item: Item, step: (side: Int, quality: Int), scale: Double? = nil) -> Result<Encoded, ShareFailure> {
        guard let ref = item.blob, let index = item.pageIndex else { return .failure(ShareFailure(description: "no page")) }
        let key = "p/\(ref.sha256)/\(index)/\(step.side)/\(step.quality)/\(scale ?? 0)"
        if let r = cache[key] { return r }
        guard rasterizer != nil else { return .failure(ShareFailure(description: "no PDF rasterizer here")) }
        guard let page = backgrounds.page(item), page.effectiveWidth > 0, page.effectiveHeight > 0 else {
            return .failure(ShareFailure(description: "its geometry is unreadable"))
        }
        let cap = Int(Double(step.side) * 1.5)
        let perPoint = scale ?? 150.0 / 72.0
        var w = page.effectiveWidth * perPoint, h = page.effectiveHeight * perPoint
        let k = min(1, Double(cap) / max(w, h))
        w *= k; h *= k
        guard let pixels = PDFBackgrounds.pixelSize(width: w, height: h, scale: 1, maxPixels: 16_000_000) else {
            return .failure(ShareFailure(description: "its size is unusable"))
        }
        let (pw, ph) = pixels
        let r: Result<Encoded, ShareFailure>
        switch backgrounds.raster(item, pixelWidth: pw, pixelHeight: ph) {
        case .failure(let why): r = .failure(ShareFailure(description: "\(why)"))
        case .success(let img):
            var e = Self.encode(img, side: max(pw, ph), quality: step.quality)
            e.orientedWidth = page.effectiveWidth
            e.orientedHeight = page.effectiveHeight
            r = .success(e)
        }
        cache[key] = r
        return r
    }

    /// `image` scaled to at most `side` on its long side and written as JPEG, or as PNG when it has transparency
    /// and the PNG is small.
    static func encode(_ image: RGBAImage, side: Int, quality: Int) -> Encoded {
        var img = image
        let longest = max(img.width, img.height)
        if longest > side { img = scaled(img, to: side) }
        var transparent = false
        var i = 3
        while i < img.pixels.count { if img.pixels[i] != 255 { transparent = true; break }; i += 4 }
        let ow = Double(image.width), oh = Double(image.height)
        if transparent, let png = try? PNGEncoder.encode(width: img.width, height: img.height, rgba: img.pixels), png.count <= 256 << 10 {
            return Encoded(data: png, type: "image/png", width: img.width, height: img.height, orientedWidth: ow, orientedHeight: oh)
        }
        return Encoded(data: JPEGEncoder.encode(img, quality: quality), type: "image/jpeg", width: img.width, height: img.height,
                       orientedWidth: ow, orientedHeight: oh)
    }

    /// Area-averaging reduction so the long side is `side`. Works a row at a time (each source row is reduced
    /// across, premultiplied, then folded into the destination row it falls in), so memory is the input plus
    /// two output-width rows, never a whole-image float buffer.
    static func scaled(_ img: RGBAImage, to side: Int) -> RGBAImage {
        let k = Double(side) / Double(max(img.width, img.height))
        let nw = max(1, Int((Double(img.width) * k).rounded())), nh = max(1, Int((Double(img.height) * k).rounded()))
        let sw = img.width, sh = img.height
        let ratioX = Double(sw) / Double(nw), ratioY = Double(sh) / Double(nh)
        let normX = Float(1 / ratioX), normY = Float(1 / ratioY)
        var hrow = [Float](repeating: 0, count: nw * 4)
        var hrowIndex = -1
        func reduceRow(_ y: Int) {
            if hrowIndex == y { return }
            hrowIndex = y
            for i in 0..<hrow.count { hrow[i] = 0 }
            img.pixels.withUnsafeBufferPointer { px in
                for o in 0..<nw {
                    let a = Double(o) * ratioX, b = a + ratioX
                    var x = Int(a)
                    while Double(x) < b && x < sw {
                        let wgt = Float(min(b, Double(x + 1)) - max(a, Double(x)))
                        let base = (y * sw + x) * 4
                        let al = Float(px[base + 3]) / 255
                        hrow[o * 4] += Float(px[base]) * al * wgt
                        hrow[o * 4 + 1] += Float(px[base + 1]) * al * wgt
                        hrow[o * 4 + 2] += Float(px[base + 2]) * al * wgt
                        hrow[o * 4 + 3] += al * 255 * wgt
                        x += 1
                    }
                    for c in 0..<4 { hrow[o * 4 + c] *= normX }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        var acc = [Float](repeating: 0, count: nw * 4)
        for o in 0..<nh {
            for i in 0..<acc.count { acc[i] = 0 }
            let a = Double(o) * ratioY, b = a + ratioY
            var y = Int(a)
            while Double(y) < b && y < sh {
                let wgt = Float(min(b, Double(y + 1)) - max(a, Double(y)))
                reduceRow(y)
                for i in 0..<acc.count { acc[i] += hrow[i] * wgt }
                y += 1
            }
            for x in 0..<nw {
                let al = acc[x * 4 + 3] * normY / 255
                let p = (o * nw + x) * 4
                if al > 0 {
                    for c in 0..<3 { out[p + c] = UInt8(max(0, min(255, (acc[x * 4 + c] * normY / al).rounded()))) }
                }
                out[p + 3] = UInt8(max(0, min(255, (acc[x * 4 + 3] * normY).rounded())))
            }
        }
        return (try? RGBAImage(width: nw, height: nh, pixels: out)) ?? img
    }
}
