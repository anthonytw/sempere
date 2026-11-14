import Age
import Foundation

// MARK: - Note insights files (format.md §16; docs/design/1.2-note-insights.md §3.2-§3.4, §11)
//
// `insights/` holds derived data, one writer per file: a note's summary, keywords and concepts (`gen`) and its vector
// (`emb`) in `<noteId>.<device>.insights.age`, the work device's map in `map.<device>.insights.age`, every device's
// record in `device.<device>.insights.age` and its notebook and tag summaries in `topics.<device>.insights.age`.
// Each is an age file to the current epoch's `v_e` whose plaintext is the body framing of format.md §4 with the label
// `insights` and the file name in the tag, so a file renamed onto another note or device fails. Readers take a file
// only when it decrypts and verifies under the CURRENT key (never through the chain), parses and validates; anything
// else is ignored, never an error. Files are replaced whole; copies of one file are ordered by `written`, then the
// larger SHA-256 of the file.

/// The kinds of file in `insights/`.
public enum InsightsFileKind: String, Hashable, Sendable, CaseIterable, Codable {
    case note, map, device, topics

    /// The most a file of this kind may hold, on disk and after gunzip (format.md §9, §16).
    public var maxBytes: Int {
        switch self {
        case .note, .device: return 64 << 10
        case .topics: return 1 << 20
        case .map: return 8 << 20
        }
    }

    /// The `format` member this version reads and writes.
    public var format: String {
        switch self {
        case .note: return "sempere-insights/1"
        case .map: return "sempere-insights-map/1"
        case .device: return "sempere-insights-device/1"
        case .topics: return "sempere-insights-topics/1"
        }
    }
}

/// A name in `insights/`: `<noteId>.<device>.insights.age`, `map.<device>.insights.age`,
/// `device.<device>.insights.age` or `topics.<device>.insights.age` (format.md §16.1). Any other name is not an
/// insights file (ignored, never deleted, format.md §1).
public struct InsightsFileName: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let suffix = ".insights.age"

    public var kind: InsightsFileKind
    /// The note, for `kind == .note`.
    public var noteId: UUID?
    /// The writer's id in the vault (format.md §15.4).
    public var device: DeviceID

    public init(note: UUID, device: DeviceID) { kind = .note; noteId = note; self.device = device }
    public init(_ kind: InsightsFileKind, device: DeviceID) {
        precondition(kind != .note, "a note file names its note")
        self.kind = kind; noteId = nil; self.device = device
    }

    /// Parses a file name; nil for anything that is not exactly an insights file name.
    public init?(_ name: String) {
        guard name.utf8.count <= 128, name.hasSuffix(Self.suffix) else { return nil }
        let stem = name.dropLast(Self.suffix.count)
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let device = DeviceID(String(parts[1])) else { return nil }
        let first = String(parts[0])
        switch first {
        case "map": kind = .map; noteId = nil
        case "device": kind = .device; noteId = nil
        case "topics": kind = .topics; noteId = nil
        default:
            guard first.count == 36, first == first.lowercased(), let id = UUID(uuidString: first) else { return nil }
            kind = .note; noteId = id
        }
        self.device = device
    }

    public var fileName: String {
        switch kind {
        case .note: return "\(noteId?.uuidString.lowercased() ?? "").\(device.rawValue)\(Self.suffix)"
        case .map, .device, .topics: return "\(kind.rawValue).\(device.rawValue)\(Self.suffix)"
        }
    }

    public var description: String { fileName }
    public static func < (a: Self, b: Self) -> Bool { a.fileName < b.fileName }
}

/// Why an insights file was not taken (it is then ignored; these never make a vault unhealthy).
public enum InsightsFileError: Error, Hashable, Sendable, CustomStringConvertible {
    case tooLarge
    /// Does not decrypt with the current vault identity (another key, damaged, not an age file).
    case undecryptable
    /// Decrypts, but the framing or its tag does not verify under the current key (renamed, or another key's).
    case framing
    case gzip
    /// A `format` this version does not implement.
    case unknownFormat(String)
    /// Does not parse, or a value is out of bounds.
    case invalid(String)
    /// Its `noteId` or `device` is not the file name's.
    case nameMismatch
    /// The vault is locked, read-only for writes, or not opened as a listed device.
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .tooLarge: return "too large"
        case .undecryptable: return "does not decrypt under the current key"
        case .framing: return "its tag does not verify under the current key"
        case .gzip: return "not valid gzip"
        case .unknownFormat(let f): return "unknown format \(InsightsLimits.printable(f))"
        case .invalid(let why): return "invalid: \(why)"
        case .nameMismatch: return "names another note or device than its file name"
        case .cannotWrite(let why): return why
        }
    }
}

/// Bounds of the decoded content (format.md §9, §16.7): a file over any of them is ignored.
public enum InsightsLimits {
    public static let maxSummary = 2_000
    public static let maxTerm = 120
    public static let maxKeywords = 32
    public static let maxConcepts = 16
    public static let maxShortString = 64
    public static let maxDimension = 4_096
    public static let maxClusters = 20_000
    public static let maxNotesInMap = 200_000
    public static let maxCanaries = 32
    public static let maxTopics = 10_000
    public static let maxTopicSummary = 4_000
    public static let maxScopeName = 1_200
    public static let maxTitle = 300
    public static let maxRevisionsPerLanguage = 64
    public static let maxLanguages = 64
    /// `written` is Unix milliseconds in 1 … 2^53 − 1.
    public static let maxWritten: Int64 = (1 << 53) - 1
    /// A copy whose `written` is more than this ahead of the reader's clock is not ordered (as format.md §12.5).
    public static let futureWindow: TimeInterval = 7 * 24 * 3600

    /// `s` cut to 64 characters with control characters escaped, for messages.
    public static func printable(_ s: String) -> String {
        String(s.prefix(64).unicodeScalars.map { $0.properties.generalCategory == .control ? "?" : Character($0) })
    }
}

// MARK: - JSON (format.md §16.2-§16.5)

/// An embedding's key (design §3.8): model, language, pinned revision and Sempere's input-cleaning revision.
public struct EmbeddingKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var model: String
    public var lang: String
    public var rev: Int
    public var input: Int
    /// A contextual model's identifier (never used in 1.2); nil for the sentence model.
    public var modelId: String?

    public init(model: String, lang: String, rev: Int, input: Int, modelId: String? = nil) {
        self.model = model; self.lang = lang; self.rev = rev; self.input = input; self.modelId = modelId
    }

    public var description: String { "\(model)/\(lang)/r\(rev)/i\(input)" + (modelId.map { "/\($0)" } ?? "") }
    public static func < (a: Self, b: Self) -> Bool { a.description < b.description }

    func check() throws {
        try InsightsValidate.short(model, "key.model"); try InsightsValidate.short(lang, "key.lang")
        if let modelId { try InsightsValidate.short(modelId, "key.modelId") }
        guard (0...1_000_000).contains(rev), (0...1_000_000).contains(input) else { throw InsightsFileError.invalid("key revision") }
    }
}

/// Who made a generation (design §3.4): model, OS version and Sempere's prompt revision.
public struct GenerationIdentity: Hashable, Sendable, Codable {
    public var model: String
    public var os: String
    public var prompt: Int

    public init(model: String, os: String, prompt: Int) { self.model = model; self.os = os; self.prompt = prompt }

    /// The OS major version ("27" of "27.2"), the part that decides staleness (D10).
    public var osMajor: String { String(os.split(separator: ".").first ?? "") }

    /// Current for a reader that generates as `reader`: the same prompt revision and OS major (design §3.4, D10).
    public func isCurrent(for reader: GenerationIdentity) -> Bool { prompt == reader.prompt && osMajor == reader.osMajor }

    func check() throws {
        try InsightsValidate.short(model, "model"); try InsightsValidate.short(os, "os")
        guard (0...1_000_000).contains(prompt) else { throw InsightsFileError.invalid("prompt") }
    }
}

/// One weighted keyword.
public struct InsightsKeyword: Hashable, Sendable, Codable {
    public var t: String
    public var w: Double
    public init(t: String, w: Double) { self.t = t; self.w = w }
}

/// A note's sidecar (`<noteId>.<device>.insights.age`, format.md §16.2).
public struct InsightsNoteFile: Hashable, Sendable, Codable {
    public struct Gen: Hashable, Sendable, Codable {
        /// 32 hex digits: the first 16 bytes of SHA-256 of the insight text (`hashBasis`).
        public var hash: String
        public var model: String
        public var os: String
        public var prompt: Int
        public var summary: String?
        public var keywords: [InsightsKeyword]
        public var concepts: [String]
        /// Summary sentences the fact check dropped.
        public var dropped: Int
        /// A voice note's suggested title (D14), fact-checked; only on voice notes.
        public var slug: String?

        public init(hash: String, identity: GenerationIdentity, summary: String?, keywords: [InsightsKeyword],
                    concepts: [String], dropped: Int, slug: String? = nil) {
            self.hash = hash; model = identity.model; os = identity.os; prompt = identity.prompt
            self.summary = summary; self.keywords = keywords; self.concepts = concepts; self.dropped = dropped; self.slug = slug
        }

        public var identity: GenerationIdentity { GenerationIdentity(model: model, os: os, prompt: prompt) }
    }

    public struct Emb: Hashable, Sendable, Codable {
        public var hash: String
        public var key: EmbeddingKey
        public var dim: Int
        public var enc: String
        public var v: String

        public init(hash: String, key: EmbeddingKey, vector: [Float]) {
            self.hash = hash; self.key = key; dim = vector.count; enc = Float16Codec.encoding; v = Float16Codec.encode(vector)
        }

        /// The vector, nil when `v` does not decode to `dim` values.
        public var vector: [Float]? { Float16Codec.decode(v, count: dim) }
    }

    /// The voice-note title this device applied (D14): the stamp of the revision that set it and the title.
    public struct TitleOp: Hashable, Sendable, Codable {
        /// `"<hlc>-<device>"` of the revision holding the op (a `Stamp`).
        public var stamp: String
        public var title: String
        public init(stamp: String, title: String) { self.stamp = stamp; self.title = title }
    }

    public var format: String
    public var noteId: String
    public var device: String
    public var written: Int64
    public var hashBasis: String
    public var lang: String?
    public var gen: Gen?
    public var emb: Emb?
    public var titleOp: TitleOp?

    public init(noteId: UUID, device: DeviceID, written: Int64, lang: String? = nil, gen: Gen? = nil, emb: Emb? = nil,
                titleOp: TitleOp? = nil) {
        format = InsightsFileKind.note.format; self.noteId = noteId.uuidString.lowercased(); self.device = device.rawValue
        self.written = written; hashBasis = InsightsText.hashBasis; self.lang = lang; self.gen = gen; self.emb = emb
        self.titleOp = titleOp
    }

    /// No `gen` and no `emb`: the device removed what it had for the note (format.md §16.6).
    public var isTombstone: Bool { gen == nil && emb == nil }

    func check() throws {
        try InsightsValidate.short(hashBasis, "hashBasis")
        if let lang { try InsightsValidate.short(lang, "lang") }
        if let g = gen {
            try InsightsValidate.hash(g.hash)
            try g.identity.check()
            if let s = g.summary { try InsightsValidate.text(s, max: InsightsLimits.maxSummary, "summary") }
            guard g.keywords.count <= InsightsLimits.maxKeywords, g.concepts.count <= InsightsLimits.maxConcepts,
                  (0...1000).contains(g.dropped) else { throw InsightsFileError.invalid("gen counts") }
            for k in g.keywords {
                try InsightsValidate.text(k.t, max: InsightsLimits.maxTerm, "keyword")
                guard k.w.isFinite, (0...1000).contains(k.w) else { throw InsightsFileError.invalid("keyword weight") }
            }
            for c in g.concepts { try InsightsValidate.text(c, max: InsightsLimits.maxTerm, "concept") }
            if let slug = g.slug { try InsightsValidate.text(slug, max: InsightsLimits.maxTitle, "slug") }
        }
        if let e = emb {
            try InsightsValidate.hash(e.hash)
            try e.key.check()
            guard e.enc == Float16Codec.encoding, (1...InsightsLimits.maxDimension).contains(e.dim), e.vector != nil else {
                throw InsightsFileError.invalid("emb vector")
            }
        }
        if let t = titleOp {
            guard Stamp(t.stamp) != nil else { throw InsightsFileError.invalid("titleOp stamp") }
            try InsightsValidate.text(t.title, max: InsightsLimits.maxTitle, "titleOp title")
        }
    }
}

/// Vectors of the 8 canary sentences (design §3.8; format.md §16.5), Float16 base64 each.
public struct InsightsCanaries: Hashable, Sendable, Codable {
    public var set: Int
    public var enc: String
    public var v: [String]

    public init(set: Int, vectors: [[Float]]) {
        self.set = set; enc = Float16Codec.encoding; v = vectors.map(Float16Codec.encode)
    }

    /// The vectors, nil when one does not decode.
    public func vectors(dimension: Int) -> [[Float]]? {
        var out: [[Float]] = []
        for s in v { guard let x = Float16Codec.decode(s, count: dimension) else { return nil }; out.append(x) }
        return out
    }

    func check() throws {
        guard enc == Float16Codec.encoding, (0...1000).contains(set), v.count <= InsightsLimits.maxCanaries,
              v.allSatisfy({ $0.utf8.count <= InsightsLimits.maxDimension * 4 }) else {
            throw InsightsFileError.invalid("canaries")
        }
    }
}

/// The work device's map (`map.<device>.insights.age`, format.md §16.3).
public struct InsightsMapFile: Hashable, Sendable, Codable {
    public struct Cluster: Hashable, Sendable, Codable {
        public var id: Int
        /// The cluster of the level above (Louvain's second level); nil at the top.
        public var parent: Int?
        /// 0 for note clusters, 1 for the level above.
        public var level: Int
        public var label: [String]
        public var centroid: String
        public var members: [String]

        public init(id: Int, parent: Int?, level: Int, label: [String], centroid: [Float], members: [UUID]) {
            self.id = id; self.parent = parent; self.level = level; self.label = label
            self.centroid = Float16Codec.encode(centroid); self.members = members.map { $0.uuidString.lowercased() }
        }
    }

    public struct Built: Hashable, Sendable, Codable {
        public var notes: Int
        /// SHA-256 hex over the sorted `noteId:emb.hash` lines the map was built from.
        public var hashes: String
        public init(notes: Int, hashes: String) { self.notes = notes; self.hashes = hashes }
    }

    public var format: String
    public var device: String
    public var written: Int64
    /// Nil: the device no longer holds the role (a tombstone, format.md §16.6).
    public var key: EmbeddingKey?
    public var dim: Int?
    public var canaries: InsightsCanaries?
    public var mean: String?
    public var clusters: [Cluster]
    public var layout: [String: [Double]]
    public var built: Built?

    public init(device: DeviceID, written: Int64, key: EmbeddingKey?, dim: Int?, canaries: InsightsCanaries?, mean: [Float]?,
                clusters: [Cluster], layout: [UUID: (Double, Double)], built: Built?) {
        format = InsightsFileKind.map.format; self.device = device.rawValue; self.written = written; self.key = key
        self.dim = dim; self.canaries = canaries; self.mean = mean.map(Float16Codec.encode); self.clusters = clusters
        self.layout = Dictionary(uniqueKeysWithValues: layout.map { ($0.key.uuidString.lowercased(), [$0.value.0, $0.value.1]) })
        self.built = built
    }

    public var isTombstone: Bool { key == nil }

    /// The mean vector (Float16 decoded), nil without one.
    public var meanVector: [Float]? { mean.flatMap { m in dim.flatMap { Float16Codec.decode(m, count: $0) } } }

    /// Positions by note.
    public var positions: [UUID: (x: Double, y: Double)] {
        var out: [UUID: (x: Double, y: Double)] = [:]
        for (k, p) in layout { if let id = UUID(uuidString: k), p.count == 2 { out[id] = (p[0], p[1]) } }
        return out
    }

    func check() throws {
        guard clusters.count <= InsightsLimits.maxClusters, layout.count <= InsightsLimits.maxNotesInMap else {
            throw InsightsFileError.invalid("map size")
        }
        guard let key else { return }
        try key.check()
        guard let dim, (1...InsightsLimits.maxDimension).contains(dim) else { throw InsightsFileError.invalid("map dim") }
        try canaries?.check()
        if let mean, Float16Codec.decode(mean, count: dim) == nil { throw InsightsFileError.invalid("map mean") }
        var members = 0
        for c in clusters {
            guard (0...1).contains(c.level), c.label.count <= 8, Float16Codec.decode(c.centroid, count: dim) != nil else {
                throw InsightsFileError.invalid("cluster")
            }
            for l in c.label { try InsightsValidate.text(l, max: InsightsLimits.maxTerm, "cluster label") }
            members += c.members.count
            guard members <= 2 * InsightsLimits.maxNotesInMap else { throw InsightsFileError.invalid("cluster members") }
            for m in c.members where UUID(uuidString: m) == nil { throw InsightsFileError.invalid("cluster member") }
        }
        for (k, p) in layout {
            guard UUID(uuidString: k) != nil, p.count == 2, p.allSatisfy({ $0.isFinite && abs($0) <= 1e6 }) else {
                throw InsightsFileError.invalid("layout")
            }
        }
        if let built {
            guard built.notes >= 0, built.notes <= InsightsLimits.maxNotesInMap else { throw InsightsFileError.invalid("built") }
            try InsightsValidate.short(built.hashes, "built.hashes")
        }
    }
}

/// A device's record (`device.<device>.insights.age`, format.md §16.4; D15).
public struct InsightsDeviceRecord: Hashable, Sendable, Codable {
    public struct Model: Hashable, Sendable, Codable {
        public var available: Bool
        /// Why not: `disabled`, `notReady`, `deviceNotEligible`, `unsupported`.
        public var reason: String?
        public var identity: GenerationIdentity?
        public init(available: Bool, reason: String?, identity: GenerationIdentity?) {
            self.available = available; self.reason = reason; self.identity = identity
        }
    }

    public struct CanaryVectors: Hashable, Sendable, Codable {
        public var key: EmbeddingKey
        public var dim: Int
        public var canaries: InsightsCanaries
        public init(key: EmbeddingKey, vectors: [[Float]], set: Int) {
            self.key = key; dim = vectors.first?.count ?? 0; canaries = InsightsCanaries(set: set, vectors: vectors)
        }
    }

    public var format: String
    public var device: String
    public var written: Int64
    /// The OS and its version (`macOS 27.2`).
    public var os: String
    /// `mac`, `ipad`, `iphone`, `linux` (the CLI on Linux).
    public var platform: String
    public var model: Model
    /// Supported sentence-embedding revisions per language.
    public var supported: [String: [Int]]
    /// Canary vectors at the revisions this device embeds (at the pin, when it supports it).
    public var canaries: [CanaryVectors]
    /// `compatible`, `incompatible`, `vectorReader` or `local`, against the map whose `written` is `against`.
    public var compatibility: String?
    public var against: Int64?

    public init(device: DeviceID, written: Int64, os: String, platform: String, model: Model, supported: [String: [Int]],
                canaries: [CanaryVectors], compatibility: String?, against: Int64?) {
        format = InsightsFileKind.device.format; self.device = device.rawValue; self.written = written; self.os = os
        self.platform = platform; self.model = model; self.supported = supported; self.canaries = canaries
        self.compatibility = compatibility; self.against = against
    }

    func check() throws {
        try InsightsValidate.short(os, "os"); try InsightsValidate.short(platform, "platform")
        if let r = model.reason { try InsightsValidate.short(r, "model.reason") }
        try model.identity?.check()
        guard supported.count <= InsightsLimits.maxLanguages, canaries.count <= InsightsLimits.maxLanguages else {
            throw InsightsFileError.invalid("device record size")
        }
        for (lang, revs) in supported {
            try InsightsValidate.short(lang, "supported language")
            guard revs.count <= InsightsLimits.maxRevisionsPerLanguage, revs.allSatisfy({ (0...1_000_000).contains($0) }) else {
                throw InsightsFileError.invalid("supported revisions")
            }
        }
        for c in canaries {
            try c.key.check(); try c.canaries.check()
            guard (0...InsightsLimits.maxDimension).contains(c.dim) else { throw InsightsFileError.invalid("canary dim") }
        }
        if let compatibility { try InsightsValidate.short(compatibility, "compatibility") }
    }
}

/// A device's notebook and tag summaries (`topics.<device>.insights.age`, format.md §16.5; D8).
public struct InsightsTopicsFile: Hashable, Sendable, Codable {
    public struct Scope: Hashable, Sendable, Codable {
        public var notebook: String?
        public var tag: String?
        public init(notebook: String) { self.notebook = notebook; tag = nil }
        public init(tag: String) { notebook = nil; self.tag = tag }
    }

    public struct Gen: Hashable, Sendable, Codable {
        public var model: String
        public var os: String
        public var prompt: Int
        /// Unix milliseconds.
        public var at: Int64
        public var summary: String
        public init(identity: GenerationIdentity, at: Int64, summary: String) {
            model = identity.model; os = identity.os; prompt = identity.prompt; self.at = at; self.summary = summary
        }
        public var identity: GenerationIdentity { GenerationIdentity(model: model, os: os, prompt: prompt) }
    }

    public struct Topic: Hashable, Sendable, Codable {
        public var scope: Scope
        public var members: Int
        public var membersHash: String
        public var gen: Gen
        public init(scope: Scope, members: Int, membersHash: String, gen: Gen) {
            self.scope = scope; self.members = members; self.membersHash = membersHash; self.gen = gen
        }
    }

    public var format: String
    public var device: String
    public var written: Int64
    public var topics: [Topic]

    public init(device: DeviceID, written: Int64, topics: [Topic]) {
        format = InsightsFileKind.topics.format; self.device = device.rawValue; self.written = written; self.topics = topics
    }

    func check() throws {
        guard topics.count <= InsightsLimits.maxTopics else { throw InsightsFileError.invalid("topics count") }
        for t in topics {
            guard (t.scope.notebook == nil) != (t.scope.tag == nil), t.members >= 0 else { throw InsightsFileError.invalid("topic scope") }
            try InsightsValidate.text(t.scope.notebook ?? t.scope.tag ?? "", max: InsightsLimits.maxScopeName, "scope")
            try InsightsValidate.short(t.membersHash, "membersHash")
            try t.gen.identity.check()
            try InsightsValidate.text(t.gen.summary, max: InsightsLimits.maxTopicSummary, "topic summary")
        }
    }
}

/// One decoded insights file.
public enum InsightsFileContent: Hashable, Sendable {
    case note(InsightsNoteFile)
    case map(InsightsMapFile)
    case device(InsightsDeviceRecord)
    case topics(InsightsTopicsFile)

    public var written: Int64 {
        switch self {
        case .note(let f): return f.written
        case .map(let f): return f.written
        case .device(let f): return f.written
        case .topics(let f): return f.written
        }
    }
}

enum InsightsValidate {
    static func short(_ s: String, _ what: String) throws {
        guard !s.isEmpty, s.utf8.count <= InsightsLimits.maxShortString else { throw InsightsFileError.invalid(what) }
    }
    static func text(_ s: String, max: Int, _ what: String) throws {
        guard s.count <= max, s.utf8.count <= 4 * max else { throw InsightsFileError.invalid(what) }
    }
    static func hash(_ s: String) throws {
        guard s.utf8.count == 32, s.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw InsightsFileError.invalid("hash")
        }
    }
}

// MARK: - Codec

/// Encodes and decodes the JSON of insights files, and orders copies (format.md §16.2, §16.6).
public enum InsightsCodec {
    /// The tag label of format.md §4 for every insights file.
    public static let tagScope = "insights"

    /// The JSON of `content` (sorted keys, no slash escaping).
    public static func encode(_ content: InsightsFileContent) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch content {
        case .note(let f): return try e.encode(f)
        case .map(let f): return try e.encode(f)
        case .device(let f): return try e.encode(f)
        case .topics(let f): return try e.encode(f)
        }
    }

    /// Decodes and validates the JSON of a file named `name` (untrusted): its `format`, its writer and note against
    /// the name, and the bounds of `InsightsLimits`.
    public static func decode(_ json: Data, name: InsightsFileName) throws -> InsightsFileContent {
        guard json.count <= name.kind.maxBytes else { throw InsightsFileError.tooLarge }
        struct Header: Decodable { var format: String?; var device: String?; var written: Int64? }
        let d = JSONDecoder()
        let header: Header
        do { header = try d.decode(Header.self, from: json) } catch { throw InsightsFileError.invalid("not a JSON object") }
        guard let format = header.format else { throw InsightsFileError.invalid("no format") }
        guard format == name.kind.format else { throw InsightsFileError.unknownFormat(format) }
        guard header.device == name.device.rawValue else { throw InsightsFileError.nameMismatch }
        guard let written = header.written, (1...InsightsLimits.maxWritten).contains(written) else {
            throw InsightsFileError.invalid("written")
        }
        do {
            switch name.kind {
            case .note:
                let f = try d.decode(InsightsNoteFile.self, from: json)
                guard f.noteId == name.noteId?.uuidString.lowercased() else { throw InsightsFileError.nameMismatch }
                try f.check()
                return .note(f)
            case .map:
                let f = try d.decode(InsightsMapFile.self, from: json)
                try f.check()
                return .map(f)
            case .device:
                let f = try d.decode(InsightsDeviceRecord.self, from: json)
                try f.check()
                return .device(f)
            case .topics:
                let f = try d.decode(InsightsTopicsFile.self, from: json)
                try f.check()
                return .topics(f)
            }
        } catch let e as InsightsFileError {
            throw e
        } catch {
            throw InsightsFileError.invalid("does not decode")
        }
    }

    /// `written` for a new write: `max(now, previous + 1)` in Unix milliseconds (format.md §16.2).
    public static func nextWritten(after previous: Int64?, now: Date) -> Int64 {
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        return min(InsightsLimits.maxWritten, max(ms, (previous ?? 0) + 1))
    }

    /// True when a copy written at `written` is ordered for a reader at `now`: at most the window ahead of its clock.
    public static func isOrdered(_ written: Int64, now: Date) -> Bool {
        Double(written) / 1000 <= now.timeIntervalSince1970 + InsightsLimits.futureWindow
    }

    /// Which of two copies of one file is later (format.md §16.2): the greater `written`, then the greater SHA-256
    /// (hex) of the file. A copy not ordered (nil `written`, or beyond the window) never wins over one that is.
    /// Returns true when `a` is later than `b`.
    public static func isLater(_ a: (written: Int64?, sha256: String), than b: (written: Int64?, sha256: String),
                               now: Date) -> Bool {
        let aw = a.written.flatMap { isOrdered($0, now: now) ? $0 : nil }
        let bw = b.written.flatMap { isOrdered($0, now: now) ? $0 : nil }
        switch (aw, bw) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case let (x?, y?): return x != y ? x > y : a.sha256 > b.sha256
        }
    }
}

// MARK: - Float16 vectors

/// Vectors as little-endian IEEE 754 binary16, base64 (format.md §16.2 `f16le-base64`). Pure Swift (no `Float16`
/// type, which Intel Macs lack): round to nearest even, overflow to infinity, NaN kept.
public enum Float16Codec {
    public static let encoding = "f16le-base64"

    public static func encode(_ v: [Float]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(v.count * 2)
        for x in v {
            let h = half(x)
            bytes.append(UInt8(h & 0xff)); bytes.append(UInt8(h >> 8))
        }
        return Data(bytes).base64EncodedString()
    }

    /// The `count` values of `s`; nil when it is not base64 of exactly `count` halves, or a value is not finite.
    public static func decode(_ s: String, count: Int) -> [Float]? {
        guard count >= 0, count <= InsightsLimits.maxDimension, s.utf8.count <= (count * 2 + 2) / 3 * 4 + 4,
              let data = Data(base64Encoded: s), data.count == count * 2 else { return nil }
        var out = [Float]()
        out.reserveCapacity(count)
        let b = [UInt8](data)
        for i in 0..<count {
            let f = float(UInt16(b[2 * i]) | UInt16(b[2 * i + 1]) << 8)
            guard f.isFinite else { return nil }
            out.append(f)
        }
        return out
    }

    /// `x` as binary16 bits.
    public static func half(_ x: Float) -> UInt16 {
        let bits = x.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp = Int((bits >> 23) & 0xff)
        var mant = bits & 0x7f_ffff
        if exp == 0xff { return sign | 0x7c00 | (mant != 0 ? 0x200 : 0) }
        var e = exp - 127 + 15
        if e >= 0x1f { return sign | 0x7c00 }
        if e <= 0 {
            if e < -10 { return sign }
            mant |= 0x80_0000
            let shift = UInt32(14 - e)
            var m = mant >> shift
            let rem = mant & ((1 << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if rem > halfway || (rem == halfway && (m & 1) == 1) { m += 1 }
            return sign | UInt16(m)
        }
        var m = mant >> 13
        let rem = mant & 0x1fff
        if rem > 0x1000 || (rem == 0x1000 && (m & 1) == 1) {
            m += 1
            if m == 0x400 { m = 0; e += 1; if e >= 0x1f { return sign | 0x7c00 } }
        }
        return sign | UInt16(e << 10) | UInt16(m)
    }

    /// binary16 bits as a `Float`.
    public static func float(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32((h >> 10) & 0x1f)
        let mant = UInt32(h & 0x3ff)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            // Subnormal: value = mant × 2^-24.
            let v = Float(mant) * Float(sign == 0 ? 1 : -1) / Float(1 << 24)
            return v
        }
        if exp == 0x1f { return Float(bitPattern: sign | 0x7f80_0000 | (mant << 13)) }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (mant << 13))
    }
}

// MARK: - Insight text (format.md §16.2 `hashBasis`)

/// The text insights are made from and its hash (`hashBasis` `text/1`, D14): `PageText.texts(of:)` of the pages joined
/// by blank lines, then each recording's transcript in recording order. The hash is taken after NFKC, with white-space
/// runs collapsed to one space and the ends trimmed, so a recognition re-run that changes no text keeps it.
public enum InsightsText {
    public static let hashBasis = "text/1"

    /// The insight text of pages and transcripts, paragraphs kept (each transcript's segments joined by spaces): what
    /// the model and the embedder read.
    public static func text(pageTexts: [PageText], transcripts: [String]) -> String {
        let parts = (pageTexts.map(\.text) + transcripts).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// NFKC, white-space runs collapsed to one space, trimmed.
    public static func normalize(_ s: String) -> String {
        let nfkc = s.precomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in nfkc.unicodeScalars {
            if u.properties.isWhitespace || u.properties.generalCategory == .control {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(u)
        }
        return String(out)
    }

    /// 32 hex digits: the first 16 bytes of SHA-256 of the UTF-8 of `normalize(text)`.
    public static func hash(_ text: String) -> String {
        String(FileDigest.sha256(Data(normalize(text).utf8)).prefix(32))
    }
}
