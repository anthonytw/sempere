import Foundation
import Sempere

// MARK: - Math recognition models: manifest, catalog, verified store
//
// Models are not bundled with the app (tens to hundreds of MB): the app
// downloads one on demand from a catalog entry that pins the SHA-256 of
// its manifest, and the manifest pins the SHA-256 and size of every file.
// Nothing is used until every file matched. `Sources/` holds no network
// code (CLAUDE.md): the app downloads (`MathModelDownload`), the CLI takes
// a folder (`--model`); both install and check through `MathModelStore`.

/// What `manifest.json` of a model folder says (`format` `sempere-math-model/1`).
public struct MathModelManifest: Hashable, Sendable, Codable {
    public static let formatID = "sempere-math-model/1"
    /// Largest manifest read, bytes.
    public static let maxBytes = 1 << 20
    /// Most files, and most bytes all together, a model may have.
    public static let maxFiles = 64
    public static let maxTotalBytes: Int64 = 2 << 30

    /// One file of the model, relative to the folder.
    public struct File: Hashable, Sendable, Codable {
        /// `/`-separated relative path; components of letters, digits, `.`, `_`, `-`, not starting with `.`.
        public var path: String
        public var sha256: String
        public var size: Int64
        public init(path: String, sha256: String, size: Int64) { self.path = path; self.sha256 = sha256; self.size = size }
    }

    /// How the decoder is driven.
    public struct Decoder: Hashable, Sendable, Codable {
        public var start: Int
        public var end: Int
        public var pad: Int
        /// Most tokens decoded, and the longest token input of the decoder.
        public var maxLength: Int
        /// The token input lengths the decoder accepts (Core ML enumerated
        /// shapes), ascending, the last `maxLength`; nil: `maxLength` only. Each
        /// step pads to the shortest that fits (`length(for:)`): the decoder
        /// has no KV cache, so its cost per step grows with this length.
        public var lengths: [Int]?
        public var vocabularySize: Int
        public var beamWidth: Int
        public init(start: Int, end: Int, pad: Int, maxLength: Int, lengths: [Int]? = nil, vocabularySize: Int,
                    beamWidth: Int = 3) {
            self.start = start; self.end = end; self.pad = pad; self.maxLength = maxLength; self.lengths = lengths
            self.vocabularySize = vocabularySize; self.beamWidth = beamWidth
        }

        /// The token input length for a prefix of `count` tokens: the shortest
        /// accepted length that holds it; nil when none does.
        public func length(for count: Int) -> Int? {
            (lengths ?? [maxLength]).first { $0 >= count }
        }
    }

    /// The token vocabulary file and how its tokens join.
    public struct Vocabulary: Hashable, Sendable, Codable {
        public var file: String
        public var joining: MathVocabulary.Joining
        public init(file: String, joining: MathVocabulary.Joining) { self.file = file; self.joining = joining }
    }

    /// The Core ML encoder and decoder (`.mlpackage` folders) and their
    /// feature names. Encoder: `image` (`[1, channels, height, width]`
    /// Float32) → `encoderOutput`. Decoder: `tokens` (`[1, maxLength]`
    /// Int32, padded with `pad`) and `encoderStates` (the encoder's output)
    /// → `logits` (`[1, maxLength, vocabularySize]`, causal: position i sees
    /// tokens 0...i only).
    public struct CoreML: Hashable, Sendable, Codable {
        public var encoder: String
        public var decoder: String
        public var image: String
        public var encoderOutput: String
        public var tokens: String
        public var encoderStates: String
        public var logits: String
        /// `all`, `cpuAndGPU`, `cpuOnly` or `cpuAndNeuralEngine` (some
        /// encoders compute wrongly on the Neural Engine: measure first).
        public var computeUnits: String
        public init(encoder: String, decoder: String, image: String = "image", encoderOutput: String = "encoder_states",
                    tokens: String = "tokens", encoderStates: String = "encoder_states", logits: String = "logits",
                    computeUnits: String = "cpuAndGPU") {
            self.encoder = encoder; self.decoder = decoder; self.image = image; self.encoderOutput = encoderOutput
            self.tokens = tokens; self.encoderStates = encoderStates; self.logits = logits; self.computeUnits = computeUnits
        }
    }

    public var format: String
    /// Short stable id: letters, digits, `-`, `_`, `.`; the folder's name in the store.
    public var id: String
    /// Shown in Settings and `--json`.
    public var name: String
    /// SPDX license of the weights, and where they came from.
    public var licence: String
    public var source: String
    public var files: [File]
    public var image: MathImageSpec
    public var vocabulary: Vocabulary
    public var decoder: Decoder
    public var coreml: CoreML

    public init(id: String, name: String, licence: String, source: String, files: [File], image: MathImageSpec,
                vocabulary: Vocabulary, decoder: Decoder, coreml: CoreML) {
        format = Self.formatID
        self.id = id; self.name = name; self.licence = licence; self.source = source; self.files = files
        self.image = image; self.vocabulary = vocabulary; self.decoder = decoder; self.coreml = coreml
    }

    /// Bytes of every file together.
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case malformed(String)
        case missing(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .malformed(let why): return "the model's manifest is not usable: \(why)"
            case .missing(let path): return "the model file \(path) is missing"
            case .mismatch(let path): return "the model file \(path) does not match its manifest (size or SHA-256)"
            }
        }
    }

    /// Whether `path` is a relative path a manifest may name.
    public static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512 else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 8 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.first != "." && part.utf8.count <= 128
                && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        }
    }

    /// Why the manifest cannot be used, or nil.
    public var problem: String? {
        guard format == Self.formatID else { return "format \(format) is not \(Self.formatID)" }
        guard Self.isSafePath(id), !id.contains("/") else { return "bad id" }
        guard !files.isEmpty, files.count <= Self.maxFiles else { return "1 to \(Self.maxFiles) files" }
        var seen = Set<String>()
        var total: Int64 = 0
        for f in files {
            guard Self.isSafePath(f.path), f.path != "manifest.json" else { return "bad path \(f.path)" }
            guard seen.insert(f.path.lowercased()).inserted else { return "\(f.path) listed twice" }
            guard f.sha256.count == 64, f.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                return "bad SHA-256 for \(f.path)"
            }
            guard f.size >= 0, f.size <= Self.maxTotalBytes - total else { return "files too large" }
            total += f.size
        }
        // A file may not also be a folder of another (`a` and `a/b`).
        for f in seen where seen.contains(where: { $0.hasPrefix(f + "/") }) { return "\(f) is a file and a folder" }
        if let why = image.problem { return why }
        let d = decoder
        guard (1...4_096).contains(d.maxLength) else { return "maxLength out of range" }
        if let lengths = d.lengths {
            guard !lengths.isEmpty, lengths.count <= 32, lengths.last == d.maxLength,
                  zip(lengths, lengths.dropFirst()).allSatisfy({ $0 < $1 }), lengths[0] >= 1 else {
                return "lengths must ascend to maxLength"
            }
        }
        guard (2...MathVocabulary.maxTokens).contains(d.vocabularySize) else { return "vocabularySize out of range" }
        guard [d.start, d.end, d.pad].allSatisfy({ (0..<d.vocabularySize).contains($0) }) else { return "special token out of range" }
        guard (1...16).contains(d.beamWidth) else { return "beamWidth out of range" }
        let dirs = [coreml.encoder, coreml.decoder]
        for dir in dirs where !(Self.isSafePath(dir) && seen.contains { $0.hasPrefix(dir.lowercased() + "/") }) {
            return "Core ML model \(dir) has no files"
        }
        guard seen.contains(vocabulary.file.lowercased()) else { return "vocabulary \(vocabulary.file) is not listed" }
        guard ["all", "cpuAndGPU", "cpuOnly", "cpuAndNeuralEngine"].contains(coreml.computeUnits) else {
            return "unknown computeUnits \(coreml.computeUnits)"
        }
        return nil
    }

    /// Decodes and checks a manifest.
    public static func parse(_ data: Data) throws -> MathModelManifest {
        guard data.count <= maxBytes else { throw Failure.malformed("larger than \(maxBytes) bytes") }
        let m: MathModelManifest
        do { m = try JSONDecoder().decode(MathModelManifest.self, from: data) } catch {
            throw Failure.malformed("not a sempere-math-model/1 manifest")
        }
        if let why = m.problem { throw Failure.malformed(why) }
        return m
    }
}

/// A model the app can download: the manifest's URL and the SHA-256 that
/// pins it (and through it every file). Shown with its download size before
/// anything is fetched.
public struct MathModelCatalogEntry: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// HTTPS URL of `manifest.json`; files are fetched from the same folder.
    public var manifestURL: String
    public var manifestSHA256: String
    /// Sum of the files' sizes (the manifest's `totalBytes`), shown before download.
    public var downloadBytes: Int64
    public var licence: String

    public init(id: String, name: String, manifestURL: String, manifestSHA256: String, downloadBytes: Int64, licence: String) {
        self.id = id; self.name = name; self.manifestURL = manifestURL; self.manifestSHA256 = manifestSHA256
        self.downloadBytes = downloadBytes; self.licence = licence
    }

    /// The URL of a manifest file, or nil when `path` is not safe or the manifest URL is not HTTPS.
    public func fileURL(_ path: String) -> URL? {
        guard MathModelManifest.isSafePath(path), let base = URL(string: manifestURL), base.scheme == "https" else { return nil }
        return base.deletingLastPathComponent().appendingPathComponent(path)
    }
}

/// The models this build offers. Empty until the maintainer publishes a
/// converted model (tools/math-model/README.md): the training-data question decides which, if any.
public enum MathModelCatalog {
    public static let entries: [MathModelCatalogEntry] = []
}

/// Installed models: `<root>/<id>/manifest.json` and its files, each checked
/// against the manifest when installed. A `verified` marker holding the
/// manifest's SHA-256 records the check; loading re-checks every size and
/// the marker (the folder is the app's own), `verify` re-hashes everything.
public enum MathModelStore {
    static let markerName = ".verified"

    /// Checks every file of `manifest` in `folder`: present, regular, same size and SHA-256.
    public static func verify(_ manifest: MathModelManifest, in folder: URL) throws {
        for f in manifest.files {
            let url = folder.appendingPathComponent(f.path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MathModelManifest.Failure.missing(f.path) }
            let (hex, size) = try FileDigest.sha256(of: url, maxBytes: f.size)
            guard size == f.size, hex == f.sha256 else { throw MathModelManifest.Failure.mismatch(f.path) }
        }
    }

    /// Reads and checks `folder/manifest.json`; with `expectedSHA256`, the
    /// manifest's own bytes must hash to it.
    public static func manifest(in folder: URL, expectedSHA256: String? = nil) throws -> MathModelManifest {
        let data = try BoundedRead.contents(of: folder.appendingPathComponent("manifest.json"),
                                            maxBytes: MathModelManifest.maxBytes)
        if let expectedSHA256, FileDigest.sha256(data) != expectedSHA256 {
            throw MathModelManifest.Failure.mismatch("manifest.json")
        }
        return try MathModelManifest.parse(data)
    }

    /// Moves a complete download in `staging` (its `manifest.json`, hashing
    /// to `manifestSHA256`, and every file) into `root/<id>` after checking
    /// every file, replacing what was there. Returns the installed folder.
    @discardableResult
    public static func install(from staging: URL, manifestSHA256: String, root: URL) throws -> URL {
        let m = try manifest(in: staging, expectedSHA256: manifestSHA256)
        try verify(m, in: staging)
        try Data(manifestSHA256.utf8).write(to: staging.appendingPathComponent(markerName), options: .atomic)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(m.id, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
        return target
    }

    /// The installed folder of `entry` when its manifest still hashes to the
    /// entry's, its marker says it was verified, and every file has its
    /// size; nil otherwise (not installed, or a newer catalog entry).
    public static func installed(_ entry: MathModelCatalogEntry, root: URL) -> (folder: URL, manifest: MathModelManifest)? {
        let folder = root.appendingPathComponent(entry.id, isDirectory: true)
        guard let m = try? manifest(in: folder, expectedSHA256: entry.manifestSHA256),
              let marker = try? BoundedRead.contents(of: folder.appendingPathComponent(markerName), maxBytes: 128),
              String(decoding: marker, as: UTF8.self) == entry.manifestSHA256 else { return nil }
        for f in m.files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(f.path).path)
            guard (attrs?[.size] as? NSNumber)?.int64Value == f.size else { return nil }
        }
        return (folder, m)
    }

    /// Removes the installed copy of model `id` (nothing when there is none).
    public static func remove(id: String, root: URL) throws {
        guard MathModelManifest.isSafePath(id), !id.contains("/") else { return }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}
