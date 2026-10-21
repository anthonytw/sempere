import Foundation

// MARK: - Format identifiers (format.md §7.1)

extension SempereFormat {
    /// The major version this implementation reads and writes.
    public static let major = 1

    /// The largest major a format identifier may name (nine digits).
    static let maxMajor = 999_999_999

    /// The major of a format identifier `sempere/<major>`: a decimal from 1
    /// to 999 999 999 without leading zeros. Nil for anything else (major 0
    /// included), which no reader can open (format.md §7.2).
    public static func major(of identifier: String) -> Int? {
        let prefix = "sempere/"
        guard identifier.hasPrefix(prefix) else { return nil }
        let digits = identifier.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 9, digits.first != "0",
              digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let n = Int(digits), n >= 1 else { return nil }
        return n
    }

    /// True for an identifier of a later major than this implementation's.
    public static func isNewer(_ identifier: String) -> Bool {
        (major(of: identifier) ?? 0) > major
    }
}

// MARK: - What a reader could not show (format.md §7.4)

/// What a reader found newer than it implements in a revision or a note,
/// and what it could not show because of it (format.md §7.2, §7.4).
///
/// Bounded whatever the input claims: names are cut to `maxNameLength`
/// characters and at most `maxNames` distinct names are kept per map, the
/// rest counted under `otherName`.
public struct NewerContent: Hashable, Sendable, Codable {
    /// Longest name kept, in characters.
    public static let maxNameLength = 64
    /// Most distinct names kept per map.
    public static let maxNames = 32
    /// The name everything beyond `maxNames` is counted under.
    public static let otherName = "…"

    /// Revisions read whose `format` or `features` mark them newer.
    public var revisions: Int = 0
    /// Revisions that could not be read because they are newer (a later
    /// body version, or a newer revision whose envelope or state does not
    /// decode).
    public var unreadable: Int = 0
    /// Skipped ops by name: the `op` of an unknown or undecodable op,
    /// `setMeta.<field>` for a `setMeta` of a field this reader does not know.
    public var skippedOps: [String: Int] = [:]
    /// Snapshot elements (pages, strokes, items, recordings) skipped because
    /// they do not decode.
    public var skippedElements: Int = 0
    /// The newer format identifiers seen in revisions (counts).
    public var formats: [String: Int] = [:]
    /// The unknown extensions seen in revisions' `features` (counts).
    public var features: [String: Int] = [:]

    public init() {}

    /// True when nothing newer was seen.
    public var isEmpty: Bool { revisions == 0 && unreadable == 0 }

    /// Total ops skipped.
    public var skippedOpCount: Int { skippedOps.values.reduce(0, Self.add) }

    /// Adds `other`'s counts to these.
    public mutating func merge(_ other: NewerContent) {
        revisions = Self.add(revisions, other.revisions)
        unreadable = Self.add(unreadable, other.unreadable)
        skippedElements = Self.add(skippedElements, other.skippedElements)
        Self.merge(other.skippedOps, into: &skippedOps)
        Self.merge(other.formats, into: &formats)
        Self.merge(other.features, into: &features)
    }

    /// Adds `from`'s counts in a fixed order (names sorted, `otherName`
    /// last), so the names kept do not depend on dictionary order.
    static func merge(_ from: [String: Int], into map: inout [String: Int]) {
        for (k, v) in from.sorted(by: { $0.key < $1.key }) where k != otherName { count(k, v, in: &map) }
        if let rest = from[otherName] { map[otherName] = add(map[otherName] ?? 0, rest) }
    }

    /// Counts `n` more under `name` (cut, or `otherName` once the map holds
    /// `maxNames` names): a map holds at most `maxNames + 1` keys.
    static func count(_ name: String, _ n: Int = 1, in map: inout [String: Int]) {
        let key = String(name.prefix(maxNameLength))
        if map[key] == nil, map.count >= maxNames { map[otherName] = add(map[otherName] ?? 0, n); return }
        map[key] = add(map[key] ?? 0, n)
    }

    /// Saturating addition: counts never trap.
    static func add(_ a: Int, _ b: Int) -> Int {
        let (s, o) = a.addingReportingOverflow(b)
        return o ? Int.max : s
    }

    /// One line for reports: "2 newer revisions (sempere/2), 3 ops skipped (moveStroke ×3)".
    public var summary: String {
        var parts: [String] = []
        if revisions > 0 {
            let f = (formats.keys.sorted() + features.keys.sorted().map { "feature \($0)" }).joined(separator: ", ")
            parts.append("\(revisions) newer revision\(revisions == 1 ? "" : "s")" + (f.isEmpty ? "" : " (\(f))"))
        }
        if unreadable > 0 { parts.append("\(unreadable) unreadable newer revision\(unreadable == 1 ? "" : "s")") }
        let ops = skippedOpCount
        if ops > 0 {
            let names = skippedOps.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            parts.append("\(ops) op\(ops == 1 ? "" : "s") skipped (\(names))")
        }
        if skippedElements > 0 {
            parts.append("\(skippedElements) snapshot element\(skippedElements == 1 ? "" : "s") skipped")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Why a vault is read-only (format.md §7.3)

/// Why a vault is read-only: what newer content its reader has seen
/// (format.md §7.2). Empty when the vault is writable.
public struct ReadOnlyReasons: Hashable, Sendable, Codable {
    /// `vault.json`'s `format` when it names a later major; nil otherwise.
    public var vaultFormat: String?
    /// `vault.json`'s `features` this implementation does not know, sorted.
    public var unknownFeatures: [String] = []
    /// Notes holding newer revisions seen so far, sorted.
    public var newerNotes: [UUID] = []

    public init(vaultFormat: String? = nil, unknownFeatures: [String] = [], newerNotes: [UUID] = []) {
        self.vaultFormat = vaultFormat; self.unknownFeatures = unknownFeatures; self.newerNotes = newerNotes
    }

    /// True when the vault may be written.
    public var isEmpty: Bool { vaultFormat == nil && unknownFeatures.isEmpty && newerNotes.isEmpty }

    /// Human-readable reasons, one per marker.
    public var descriptions: [String] {
        var out: [String] = []
        if let vaultFormat { out.append("the vault uses format \(vaultFormat), newer than this version's \(SempereFormat.identifier)") }
        if !unknownFeatures.isEmpty { out.append("the vault uses format extensions this version does not know: \(unknownFeatures.joined(separator: ", "))") }
        if !newerNotes.isEmpty {
            let n = newerNotes.count
            out.append("\(n) note\(n == 1 ? " holds" : "s hold") revisions written by a newer version")
        }
        return out
    }
}

/// The newer content a `Vault` (and every copy of it) has seen while
/// reading: once a note's newer revision has been read, every write through
/// that vault value is refused (format.md §7.3). Shared by reference so
/// copies of a `Vault` see it; thread-safe.
final class ReadOnlyLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: Set<UUID> = []
    /// Bound on the notes remembered: past it, the latch stays set but
    /// lists no more ids.
    static let maxNotes = 100_000

    func record(_ note: UUID) {
        lock.lock(); defer { lock.unlock() }
        if notes.count < Self.maxNotes { notes.insert(note) }
    }

    var newerNotes: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return notes.sorted { $0.uuidString < $1.uuidString }
    }
}

/// A thread-safe count of work done (`Vault.revisionDecrypts`).
final class WorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add(_ n: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        count += n
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// A thread-safe byte count and its peak (`Vault.plainHeld`).
final class ByteGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var top = 0

    func add(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        current += n
        top = max(top, current)
    }

    func remove(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        current -= n
    }

    /// The current count and the peak since the last `resetPeak`.
    var value: (current: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (current, top)
    }

    func resetPeak() {
        lock.lock(); defer { lock.unlock() }
        top = current
    }
}

// MARK: - Lenient decoding of newer revisions

/// Per-decode state: whether the revision being decoded is newer (so its
/// ops and snapshot elements decode leniently, format.md §7.4), and what was
/// skipped. One per `InkJSON.decoder()`; decoding is single-threaded.
final class NewerDecoding: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "sempere.newerDecoding")
    var lenient = false
    var content = NewerContent()

    static func of(_ decoder: Decoder) -> NewerDecoding? {
        guard let key else { return nil }
        return decoder.userInfo[key] as? NewerDecoding
    }
}

/// An array element that never fails to decode: in a newer revision, an
/// element that does not decode is skipped and counted (format.md §7.4).
struct LenientElement<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: Decoder) throws {
        do { value = try T(from: decoder) } catch {
            value = nil
            NewerDecoding.of(decoder)?.content.skippedElements += 1
        }
    }
}

/// One op of a newer delta: the op, or nil (skipped and counted by name).
struct LenientOp: Decodable {
    var op: Op?

    static let knownOps: Set<String> = [
        "addStroke", "removeStroke", "addPage", "removePage", "setPageOrder", "setPageRecognition",
        "setPagePaper", "setMeta", "addTag", "removeTag", "deleteNote", "restoreNote", "addItem",
        "removeItem", "setItem", "addRecording", "removeRecording", "setRecording",
    ]

    init(from decoder: Decoder) throws {
        do { op = try Op(from: decoder); return } catch { op = nil }
        var name = "?"
        if let c = try? decoder.container(keyedBy: Op.CodingKeys.self),
           let o = (try? c.decodeIfPresent(String.self, forKey: .op)) ?? nil {
            name = o
            if o == "setMeta" || o == "setRecording" || o == "setItem",
               let f = (try? c.decodeIfPresent(String.self, forKey: .field)) ?? nil {
                name = "\(o).\(f)"
            }
        }
        if let ctx = NewerDecoding.of(decoder) { NewerContent.count(name, in: &ctx.content.skippedOps) }
    }
}

extension KeyedDecodingContainer {
    /// `[T]` under `key` (absent: `[]`); in a newer revision, elements that do
    /// not decode are skipped and counted instead of failing the whole array.
    func decodeElements<T: Decodable>(_ type: T.Type, forKey key: Key, decoder: Decoder) throws -> [T]? {
        if NewerDecoding.of(decoder)?.lenient == true {
            return try decodeIfPresent([LenientElement<T>].self, forKey: key)?.compactMap(\.value)
        }
        return try decodeIfPresent([T].self, forKey: key)
    }
}

/// The version markers of a revision (format.md §7.1), read on their own so
/// a newer revision that does not decode is reported as newer, not corrupt.
struct RevisionMarkers: Decodable {
    var format: String?
    var features: [String]?

    enum CodingKeys: String, CodingKey { case format, features }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        features = try c.decodeIfPresent([String].self, forKey: .features)
    }

    /// True when these markers name a later major or an unknown extension.
    /// Throws for a malformed marker (format.md §7.2).
    func isNewer() throws -> Bool {
        if let format {
            guard SempereFormat.major(of: format) != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.format],
                                                        debugDescription: "bad format \(format.prefix(64))"))
            }
        }
        if let format, SempereFormat.isNewer(format) { return true }
        return !(features ?? []).allSatisfy(EpochManifest.knownFeatures.contains)
    }

    /// Peeks `json`'s markers: true for a newer revision, false otherwise or
    /// when the markers cannot be read.
    static func peekNewer(_ json: Data) -> Bool {
        guard let m = try? JSONDecoder().decode(RevisionMarkers.self, from: json) else { return false }
        return (try? m.isNewer()) == true
    }
}
