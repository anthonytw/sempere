import Foundation

// MARK: - A note's revision log, for diagnosis (`sempere notes revisions`)
//
// Every revision file of one note as it reads here: what each delta's ops are, what each snapshot covers and holds for
// the `deleted` register, which files did not read and why (set aside under an earlier key, pending, unreadable), and
// which stamp won `deleted` in the merge (format.md §5.3, §5.4). It answers "why is this note (not) deleted here?" from
// the files alone: a later `restoreNote`, a snapshot whose recorded clock beats a `deleteNote`, or a `deleteNote` file
// that is missing or does not read on this device.

/// One revision of a note's log (`RevisionLog`).
public struct RevisionLogEntry: Hashable, Sendable, Encodable {
    /// The file name, `<hlc>-<device>-<seq>.<kind>.age`.
    public var revision: String
    /// `delta` or `snapshot`.
    public var kind: String
    public var hlc: String
    public var device: String
    public var seq: Int
    public var wall: Date
    public var app: String
    /// The editing session it was written in (format.md §5.8.2), if any.
    public var session: String?
    /// True for a checkpoint (format.md §5.8.1).
    public var checkpoint: Bool
    /// A positioned snapshot's revision (format.md §5.8.3).
    public var asOf: String?
    /// A delta's ops in order, `op` or `op field` (`setMeta title`), runs of the same op counted (`addStroke ×12`).
    public var ops: [String]?
    /// A snapshot's `included` (format.md §5.3).
    public var included: Included?
    /// A snapshot's `deleted` value and the stamp it records for it (`clocks.deleted`; absent: the snapshot's own).
    public var deleted: Bool?
    public var deletedClock: String?
}

/// A revision listed in the note's folder that did not read here.
public struct RevisionLogFailure: Hashable, Sendable, Encodable {
    public var revision: String
    /// `setAside`, `pending`, `newer` or `unreadable`.
    public var kind: String
    public var error: String
}

/// A note's revisions with ops and stamps, and where its `deleted` register comes from.
public struct RevisionLog: Hashable, Sendable, Encodable {
    public var note: String
    /// The merged `deleted` of the revisions that read.
    public var deleted: Bool
    /// The stamp that set it (`<hlc>-<device>`), the zero stamp when nobody did.
    public var deletedClock: String
    /// The revision holding the op that set it, nil when that revision is gone (compacted: a snapshot's recorded clock
    /// carries it) or nobody set it.
    public var deletedBy: String?
    /// Every revision that read, sorted by `(hlc, device, seq)`.
    public var revisions: [RevisionLogEntry]
    /// Every listed revision that did not read, sorted by name.
    public var failures: [RevisionLogFailure]

    /// The log of `loaded` (every revision of note `id`).
    public init(note id: UUID, loaded: LoadedNote) throws {
        note = id.uuidString.lowercased()
        let state = loaded.revisions.isEmpty ? nil : try NoteReducer.reconstruct(loaded.revisions)
        deleted = state?.deleted ?? false
        let clock = state?.clocks?[NoteState.ClockKey.deleted.rawValue].flatMap(Stamp.init) ?? .zero
        deletedClock = clock.description
        deletedBy = nil
        if clock != .zero {
            deletedBy = loaded.revisions.first { r in
                guard r.hlc == clock.hlc, r.device == clock.device else { return false }
                return r.ops.contains { if case .deleteNote = $0 { return true }; if case .restoreNote = $0 { return true }; return false }
            }?.name.filename
        }
        revisions = loaded.revisions.sorted { $0.name < $1.name }.map(Self.entry)
        failures = loaded.failures.sorted { $0.key.filename < $1.key.filename }.map { name, error in
            let kind: String
            switch error {
            case .setAside: kind = "setAside"
            case .pending: kind = "pending"
            case .newer: kind = "newer"
            default: kind = "unreadable"
            }
            return RevisionLogFailure(revision: name.filename, kind: kind, error: error.description)
        }
    }

    static func entry(_ r: Revision) -> RevisionLogEntry {
        var e = RevisionLogEntry(revision: r.name.filename, kind: r.kind.rawValue, hlc: r.hlc.description,
                                 device: r.device.rawValue, seq: r.seq, wall: r.wall, app: r.app, session: r.session,
                                 checkpoint: r.checkpoint != nil, asOf: r.asOf?.description)
        switch r.body {
        case .delta(let ops):
            var out: [(String, Int)] = []
            for op in ops {
                let label = Self.label(op)
                if let last = out.last, last.0 == label { out[out.count - 1].1 += 1 } else { out.append((label, 1)) }
            }
            e.ops = out.map { $0.1 == 1 ? $0.0 : "\($0.0) ×\($0.1)" }
        case .snapshot(let included, let state):
            e.included = included
            e.deleted = state.deleted
            e.deletedClock = state.clocks?[NoteState.ClockKey.deleted.rawValue]
        }
        return e
    }

    /// `op`, with the field for `setMeta`, `setItem` and `setRecording`.
    static func label(_ op: Op) -> String {
        guard let data = try? JSONEncoder().encode(op),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["op"] as? String else { return "?" }
        if let field = object["field"] as? String { return "\(name) \(field)" }
        return name
    }
}
