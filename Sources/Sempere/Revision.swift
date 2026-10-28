import Foundation

/// Errors from the note log (revisions, reconstruction, snapshots).
public enum NoteLogError: Error, Hashable, Sendable {
    /// Reconstruction or a snapshot needs at least one revision.
    case noRevisions
    /// Revisions from two different notes were mixed.
    case mixedNotes(UUID, UUID)
    /// Two revisions claim the same `(device, seq)` with different content.
    case conflictingRevisions(device: DeviceID, seq: Int)
    /// A delta was required but something else was given.
    case notADelta(RevisionName)
}

// MARK: - File names

/// `<hlc>-<device>-<seq>.<delta|snapshot>.age` (format.md §5).
public struct RevisionName: Hashable, Comparable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable {
        case delta, snapshot
    }

    /// Clock reading when the revision was written.
    public var hlc: HLC
    /// Writing device.
    public var device: DeviceID
    /// Per (note, device) counter, starting at 1.
    public var seq: Int
    /// Delta or snapshot.
    public var kind: Kind

    public init(hlc: HLC, device: DeviceID, seq: Int, kind: Kind) {
        self.hlc = hlc; self.device = device; self.seq = seq; self.kind = kind
    }

    /// The largest `seq` a reader accepts (2^53 − 1, the largest integer every
    /// JSON implementation represents exactly). Larger values in a file name,
    /// a revision or a snapshot's `included` are rejected, so `seq + 1` never
    /// overflows.
    public static let maxSeq = 9_007_199_254_740_991

    /// Parses a file base name. Rejects non-canonical `seq` (leading zeros, 0)
    /// and `seq` above `maxSeq`.
    public init?(_ filename: String) {
        let dot = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard dot.count == 3, dot[2] == "age", let kind = Kind(rawValue: String(dot[1])) else { return nil }
        let dash = dot[0].split(separator: "-", omittingEmptySubsequences: false)
        guard dash.count == 3,
              let hlc = HLC(String(dash[0])),
              let device = DeviceID(String(dash[1])) else { return nil }
        let s = dash[2]
        guard !s.isEmpty, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }), s.first != "0",
              let seq = Int(s), seq <= Self.maxSeq else { return nil }
        self.init(hlc: hlc, device: device, seq: seq, kind: kind)
    }

    /// The file base name.
    public var filename: String { "\(hlc)-\(device)-\(seq).\(kind.rawValue).age" }
    public var description: String { filename }

    /// The LWW stamp of ops in this revision.
    public var stamp: Stamp { Stamp(hlc: hlc, device: device) }

    /// Total order `(hlc, device, seq)`; `kind` only breaks ties between
    /// malformed duplicates.
    public static func < (l: RevisionName, r: RevisionName) -> Bool {
        (l.hlc, l.device, l.seq, l.kind.rawValue) < (r.hlc, r.device, r.seq, r.kind.rawValue)
    }
}

// MARK: - origin

/// Which op added a page or stroke: `"<hlc>-<device>-<seq>-<op>"`, the adding
/// revision's ordering key plus the op's index in it (format.md §5.5–§5.6).
/// Strokes on a page render in origin order.
public struct Origin: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// `hlc` of the adding revision.
    public var hlc: HLC
    /// Device of the adding revision.
    public var device: DeviceID
    /// `seq` of the adding revision; at least 1 in any parsed origin.
    public var seq: Int
    /// Index of the adding op within the revision's `ops`, from 0.
    public var op: Int

    public init(hlc: HLC, device: DeviceID, seq: Int, op: Int) {
        self.hlc = hlc; self.device = device; self.seq = seq; self.op = op
    }

    public init(_ name: RevisionName, op: Int) {
        self.init(hlc: name.hlc, device: name.device, seq: name.seq, op: op)
    }

    /// Parses `"<hlc>-<device>-<seq>-<op>"`; rejects `seq` 0 and leading zeros.
    public init?(_ string: String) {
        let p = string.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 4, let h = HLC(String(p[0])), let d = DeviceID(String(p[1])),
              let seq = Origin.decimal(p[2]), seq >= 1, let op = Origin.decimal(p[3]) else { return nil }
        self.init(hlc: h, device: d, seq: seq, op: op)
    }

    /// The `(hlc, device)` of the revision this origin names.
    var stamp: Stamp { Stamp(hlc: hlc, device: device) }

    private static func decimal(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }), s == "0" || s.first != "0" else { return nil }
        return Int(s)
    }

    public var description: String { "\(hlc)-\(device)-\(seq)-\(op)" }

    public static func < (l: Origin, r: Origin) -> Bool {
        (l.hlc, l.device, l.seq, l.op) < (r.hlc, r.device, r.seq, r.op)
    }
}

// MARK: - included

/// The set of revisions a snapshot reflects (format.md §5.3): per device,
/// every `seq ≤ upTo` plus the listed `extra`.
public struct Included: Hashable, Sendable {
    /// Coverage for one device.
    public struct Entry: Hashable, Sendable, Codable {
        /// Every `seq` from 1 through `upTo` is covered (inclusive; may be 0).
        public internal(set) var upTo: Int
        /// Sorted, all greater than `upTo + 1`. Read-only outside the module:
        /// `covers` relies on the order (binary search).
        public internal(set) var extra: [Int]

        public init(upTo: Int = 0, extra: [Int] = []) {
            self.upTo = upTo
            self.extra = extra
            normalize()
        }

        /// True for a covered `seq`; never for `seq < 1`. O(log extra.count):
        /// merging calls this per item and snapshot, and a hostile snapshot
        /// may list millions of extras.
        public func covers(_ seq: Int) -> Bool {
            guard seq >= 1 else { return false }
            if seq <= upTo { return true }
            let i = insertionIndex(seq)
            return i < extra.count && extra[i] == seq
        }

        /// The first index of `extra` whose value is not below `seq`.
        func insertionIndex(_ seq: Int) -> Int {
            var lo = 0, hi = extra.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if extra[mid] < seq { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        /// Adds one `seq` without re-sorting `extra`.
        mutating func insert(_ seq: Int) {
            guard seq >= 1, !covers(seq) else { return }
            guard seq == upTo + 1 else {   // seq > upTo here, so upTo < Int.max
                extra.insert(seq, at: insertionIndex(seq))
                return
            }
            upTo = seq
            var absorbed = 0
            while absorbed < extra.count, upTo < Int.max, extra[absorbed] == upTo + 1 {
                upTo += 1
                absorbed += 1
            }
            extra.removeFirst(absorbed)
        }

        mutating func normalize() {
            upTo = max(upTo, 0)
            var set = Set(extra.filter { $0 > upTo })
            // `upTo` may be `Int.max` (built in code, or decoded before the
            // range check below): never compute `upTo + 1` past it.
            while upTo < Int.max, set.remove(upTo + 1) != nil { upTo += 1 }
            extra = set.sorted()
        }

        enum CodingKeys: String, CodingKey { case upTo, extra }

        /// Rejects any `seq` above `RevisionName.maxSeq`, so `upTo + 1` (the
        /// next seq a device may use) always fits in an `Int`.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let upTo = try c.decode(Int.self, forKey: .upTo)
            let extra = try c.decode([Int].self, forKey: .extra)
            guard upTo <= RevisionName.maxSeq, extra.allSatisfy({ $0 <= RevisionName.maxSeq }) else {
                throw DecodingError.dataCorruptedError(forKey: .upTo, in: c,
                                                       debugDescription: "seq above \(RevisionName.maxSeq)")
            }
            self.init(upTo: upTo, extra: extra)
        }
    }

    /// Per-device coverage; devices without an entry cover nothing.
    public private(set) var entries: [DeviceID: Entry]

    public init(_ entries: [DeviceID: Entry] = [:]) {
        self.entries = entries.mapValues { var e = $0; e.normalize(); return e }
    }

    /// True when the revision `(device, seq)` is reflected.
    public func covers(device: DeviceID, seq: Int) -> Bool {
        entries[device]?.covers(seq) ?? false
    }

    /// Adds one revision, folding contiguous extras into `upTo`.
    public mutating func insert(device: DeviceID, seq: Int) {
        guard seq >= 1 else { return }
        entries[device, default: Entry()].insert(seq)
    }

    /// True when every revision `other` covers is also covered here.
    public func isSuperset(of other: Included) -> Bool {
        for (device, theirs) in other.entries {
            let mine = entries[device] ?? Entry()
            if theirs.upTo > mine.upTo {
                // The gap must be filled by `extra`; too few extras cannot.
                guard theirs.upTo - mine.upTo <= mine.extra.count else { return false }
                let extras = Set(mine.extra)
                guard ((mine.upTo + 1)...theirs.upTo).allSatisfy(extras.contains) else { return false }
            }
            guard theirs.extra.allSatisfy(mine.covers) else { return false }
        }
        return true
    }

    /// Everything covered by either.
    public func union(_ other: Included) -> Included {
        var out = self
        for (device, e) in other.entries {
            var mine = out.entries[device] ?? Entry()
            mine.upTo = max(mine.upTo, e.upTo)
            mine.extra += e.extra
            mine.normalize()
            out.entries[device] = mine
        }
        return out
    }
}

extension Included: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Entry].self)
        var entries: [DeviceID: Entry] = [:]
        for (k, v) in raw {
            guard let d = DeviceID(k) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad device id \(k)"))
            }
            entries[d] = v
        }
        self.init(entries)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }))
    }
}

// MARK: - Version history fields (format.md §5.8)

/// A revision's place in the order `(hlc, device, seq)`, without its kind:
/// what a positioned snapshot's `asOf` names (format.md §5.8.3).
public struct RevisionKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var hlc: HLC
    public var device: DeviceID
    public var seq: Int

    public init(hlc: HLC, device: DeviceID, seq: Int) {
        self.hlc = hlc; self.device = device; self.seq = seq
    }

    /// The key of a revision file name.
    public init(_ name: RevisionName) { self.init(hlc: name.hlc, device: name.device, seq: name.seq) }

    /// Parses `"<hlc>-<device>-<seq>"`; `seq` canonical, 1 … `RevisionName.maxSeq`.
    public init?(_ string: String) {
        let p = string.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, let h = HLC(String(p[0])), let d = DeviceID(String(p[1])) else { return nil }
        let s = p[2]
        guard !s.isEmpty, s.count <= 16, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }), s.first != "0",
              let seq = Int(s), seq <= RevisionName.maxSeq else { return nil }
        self.init(hlc: h, device: d, seq: seq)
    }

    public var description: String { "\(hlc)-\(device)-\(seq)" }

    public static func < (l: RevisionKey, r: RevisionKey) -> Bool {
        (l.hlc, l.device, l.seq) < (r.hlc, r.device, r.seq)
    }
}

/// The marker of a version the user saved (format.md §5.8.1).
public struct Checkpoint: Hashable, Sendable {
    /// Longest name writers store, in characters.
    public static let maxNameLength = 200

    /// The user's label; nil for an unnamed version.
    public var name: String?

    /// `name` trimmed and cut to `maxNameLength` characters; blank is nil.
    public init(name: String? = nil) {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = t.isEmpty ? nil : String(t.prefix(Self.maxNameLength))
    }

    /// As read: a `name` that is not a string is ignored; the text is kept as written.
    init(read name: String?) { self.name = (name?.isEmpty ?? true) ? nil : name }
}

/// Editing-session ids (format.md §5.8.2).
public enum EditingSession {
    /// A fresh id: a lowercase UUID.
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// True for 1 to 64 characters from `[0-9a-z-]`.
    public static func isValid(_ id: String) -> Bool {
        let u = id.utf8
        return !u.isEmpty && u.count <= 64 && u.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }
    }
}

/// Decodes a `checkpoint` value leniently: any object is a checkpoint.
private struct CheckpointWire: Codable {
    var name: String?

    enum CodingKeys: String, CodingKey { case name }

    init(name: String?) { self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
    }
}

// MARK: - Revision envelope

/// One file under `notes/<noteId>/` (format.md §5.1–§5.3), decrypted and
/// unframed. Pure value; reading and writing files is elsewhere.
public struct Revision: Hashable, Sendable {
    /// The type-specific part of a revision.
    public enum Body: Hashable, Sendable {
        /// Ops applied in order (format.md §5.2).
        case delta(ops: [Op])
        /// Full state plus the revisions it reflects (format.md §5.3).
        case snapshot(included: Included, state: NoteState)
    }

    /// Note directory name; lowercase on the wire.
    public var noteId: UUID
    /// Writing device.
    public var device: DeviceID
    /// Per (note, device) counter, starting at 1, gap-free.
    public var seq: Int
    /// Clock reading when written; the LWW timestamp of the revision's ops.
    public var hlc: HLC
    /// Informational (history UI).
    public var wall: Date
    /// Informational, e.g. `sempere-ios/0.1`.
    public var app: String
    /// Delta ops or snapshot content.
    public var body: Body
    /// The editing session that wrote this delta (format.md §5.8.2); nil
    /// for snapshots and for deltas written outside one.
    public var session: String?
    /// Set when this delta is a version the user saved (format.md §5.8.1).
    public var checkpoint: Checkpoint?
    /// For a positioned snapshot, the revision whose state it holds
    /// (format.md §5.8.3). Whether it is valid is decided against the other
    /// revisions (`NoteHistory.positions`).
    public var asOf: RevisionKey?
    /// Set when the revision was written by a newer version (its `format` or
    /// `features`, format.md §7.1) and so was decoded leniently: what was
    /// skipped (§7.4). Such a revision must never be written back.
    public var newer: NewerContent?

    public init(noteId: UUID, device: DeviceID, seq: Int, hlc: HLC, wall: Date, app: String, body: Body,
                session: String? = nil, checkpoint: Checkpoint? = nil, asOf: RevisionKey? = nil) {
        self.noteId = noteId; self.device = device; self.seq = seq; self.hlc = hlc
        self.wall = wall; self.app = app; self.body = body
        self.session = session; self.checkpoint = checkpoint; self.asOf = asOf
    }

    public var kind: RevisionName.Kind {
        if case .delta = body { return .delta }
        return .snapshot
    }

    /// The file name this revision is stored under.
    public var name: RevisionName { RevisionName(hlc: hlc, device: device, seq: seq, kind: kind) }

    /// LWW stamp for this revision's ops.
    public var stamp: Stamp { Stamp(hlc: hlc, device: device) }
}

extension Revision: Codable {
    enum CodingKeys: String, CodingKey {
        case type, noteId, device, seq, hlc, wall, app, ops, included, state, session, checkpoint, asOf
        case format, features
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        noteId = try c.decode(LowercaseUUID.self, forKey: .noteId).uuid
        device = try c.decode(DeviceID.self, forKey: .device)
        seq = try c.decode(Int.self, forKey: .seq)
        guard seq >= 1, seq <= RevisionName.maxSeq else {
            throw DecodingError.dataCorruptedError(forKey: .seq, in: c,
                                                   debugDescription: "seq must be 1...\(RevisionName.maxSeq)")
        }
        hlc = try c.decode(HLC.self, forKey: .hlc)
        wall = try c.decode(Date.self, forKey: .wall)
        app = try c.decode(String.self, forKey: .app)
        // Version markers (format.md §7.1): a newer revision decodes leniently (§7.4).
        let markers = try RevisionMarkers(from: decoder)
        let context = NewerDecoding.of(decoder)
        let isNewer: Bool
        do { isNewer = try markers.isNewer() } catch {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "\(error)")
        }
        if isNewer {
            var found = NewerContent()
            found.revisions = 1
            if let f = markers.format, SempereFormat.isNewer(f) { NewerContent.count(f, in: &found.formats) }
            for f in markers.features ?? [] where !EpochManifest.knownFeatures.contains(f) {
                NewerContent.count(f, in: &found.features)
            }
            context?.lenient = true
            context?.content = found
            newer = found
        }
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "delta":
            if isNewer {
                body = .delta(ops: try c.decode([LenientOp].self, forKey: .ops).compactMap(\.op))
            } else {
                body = .delta(ops: try c.decode([Op].self, forKey: .ops))
            }
            // Optional history fields: a malformed value is ignored, never fatal (§5.1).
            if let s = (try? c.decodeIfPresent(String.self, forKey: .session)) ?? nil, EditingSession.isValid(s) {
                session = s
            }
            if let w = (try? c.decodeIfPresent(CheckpointWire.self, forKey: .checkpoint)) ?? nil {
                checkpoint = Checkpoint(read: w.name)
            }
        case "snapshot":
            body = .snapshot(included: try c.decode(Included.self, forKey: .included),
                             state: try c.decode(NoteState.self, forKey: .state))
            if let a = (try? c.decodeIfPresent(String.self, forKey: .asOf)) ?? nil { asOf = RevisionKey(a) }
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown revision type \(type)")
        }
        if isNewer { newer = context?.content ?? newer }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .type)
        try c.encode(LowercaseUUID(noteId), forKey: .noteId)
        try c.encode(device, forKey: .device)
        try c.encode(seq, forKey: .seq)
        try c.encode(hlc, forKey: .hlc)
        try c.encode(wall, forKey: .wall)
        try c.encode(app, forKey: .app)
        switch body {
        case .delta(let ops):
            try c.encode(ops, forKey: .ops)
            try c.encodeIfPresent(session, forKey: .session)
            try c.encodeIfPresent(checkpoint.map { CheckpointWire(name: $0.name) }, forKey: .checkpoint)
        case .snapshot(let included, let state):
            try c.encode(included, forKey: .included)
            try c.encode(state, forKey: .state)
            try c.encodeIfPresent(asOf?.description, forKey: .asOf)
        }
    }
}
