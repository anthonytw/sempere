import Foundation

// MARK: - Registers of items and recordings (docs/format.md §8.2.2, §8.3.1)
//
// Every field of an item or recording is either a register (merged
// last-writer-wins per field, changed by `setItem` / `setRecording`) or
// immutable (set once by the add). Fields a reader does not know are
// registers (§7). The merge (`NoteReducer`) and the restore diff
// (`NoteHistory`) read and write registers through these helpers only.

extension Item {
    /// The item's registers as the changes that would set them, keyed by field
    /// name: `frame`, `rotation` and `z` for every kind, `text` or `crop` for
    /// the kinds that have them, and every unknown field. An unknown field
    /// named like an immutable field of some kind (`blob` on a text item) is
    /// not a register: `setItem` can never name it (§8.2.2).
    public var registers: [String: ItemChange] {
        var r: [String: ItemChange] = ["frame": .frame(frame), "rotation": .rotation(rotation), "z": .z(z)]
        let mine = Self.kindFields(kind)
        if mine.contains("text"), let text { r["text"] = .text(text) }
        if mine.contains("crop") { r["crop"] = .crop(crop) }
        if mine.contains("poster") { r["poster"] = .poster(poster) }
        if mine.contains("math"), let math { r["math"] = .math(math) }
        for (k, v) in extra where !Self.immutableFields.contains(k) { r[k] = .other(field: k, value: v) }
        return r
    }

    /// Sets one register. A typed change for a field this item's kind does
    /// not have (`crop` on a text item) is an unknown field there and is kept
    /// in `extra` (§8.2.1); an unknown-field change naming one of the kind's
    /// own fields is decoded as that field, and dropped if it does not decode
    /// or names an immutable field.
    public mutating func apply(_ change: ItemChange) {
        let mine = Self.kindFields(kind)
        switch change {
        case .frame(let v): frame = v
        case .rotation(let v): rotation = v
        case .z(let v): z = v
        case .text(let v):
            if mine.contains("text") { text = v } else { extra["text"] = (try? JSONValue(encoding: v)) ?? .null }
        case .crop(let v):
            if mine.contains("crop") { crop = v } else { extra["crop"] = v.flatMap { try? JSONValue(encoding: $0) } ?? .null }
        case .poster(let v):
            if mine.contains("poster") { poster = v } else { extra["poster"] = v.flatMap { try? JSONValue(encoding: $0) } ?? .null }
        case .math(let v):
            if mine.contains("math") { math = v } else { extra["math"] = (try? JSONValue(encoding: v)) ?? .null }
        case .other(let field, let value):
            if mine.contains(field) || Self.commonFields.contains(field) {
                guard let typed = try? ItemChange(field: field, value: value) else { return }
                if case .other = typed { return }
                apply(typed)
            } else {
                extra[field] = value
            }
        }
    }

    /// True when the immutable fields (§8.2.2) other than `id` and `parent`
    /// are equal: what a copy re-created by a restore keeps (§5.7).
    public func hasSameImmutableFields(as other: Item) -> Bool {
        guard kind == other.kind, layer == other.layer, rec == other.rec, blob == other.blob,
              pixelSize == other.pixelSize, orientation == other.orientation, pageIndex == other.pageIndex,
              pageSize == other.pageSize, duration == other.duration, videoRotation == other.videoRotation,
              codec == other.codec, recording == other.recording else { return false }
        let fixed = Self.immutableFields
        return extra.filter { fixed.contains($0.key) } == other.extra.filter { fixed.contains($0.key) }
    }
}

extension Recording {
    /// The recording's registers (format.md §8.3.1) as the changes that would
    /// set them: `title`, `transcript` and every unknown field.
    public var registers: [String: RecordingChange] {
        var r: [String: RecordingChange] = ["title": .title(title), "transcript": .transcript(transcript)]
        for (k, v) in extra { r[k] = .other(field: k, value: v) }
        return r
    }

    /// Sets one register. An unknown-field change naming `title` or
    /// `transcript` is decoded as that field (dropped if it does not decode).
    public mutating func apply(_ change: RecordingChange) {
        switch change {
        case .title(let v): title = v
        case .transcript(let v): transcript = v
        case .other(let field, let value):
            if Self.knownFields.contains(field) {
                guard let typed = try? RecordingChange(field: field, value: value) else { return }
                if case .other = typed { return }
                apply(typed)
            } else {
                extra[field] = value
            }
        }
    }

    /// True when the immutable fields other than `id` and `parent` are equal.
    public func hasSameImmutableFields(as other: Recording) -> Bool {
        blob == other.blob && started == other.started && duration == other.duration && codec == other.codec
            && sampleRate == other.sampleRate && channels == other.channels && bitRate == other.bitRate
    }
}

extension NoteState {
    /// The recording a `rec` link names (format.md §8.3.3): the recording
    /// with that id, else one restored from it (its `parent` names it, §5.7),
    /// else nil (the link is ignored).
    public func recording(for link: RecordingLink) -> Recording? {
        recordings.first { $0.id == link.id }
            ?? recordings.filter { $0.parent == link.id }.min(by: Recording.sortsBefore)
    }
}

/// A change of one register of an item or recording, as the restore diff
/// compares and writes it.
protocol RegisterChange {
    init(field: String, value: JSONValue) throws
    var field: String { get }
    /// The `value` an op carries for this change; nil if it cannot be encoded.
    var wireForm: JSONValue? { get }
    /// True for a field this reader does not know.
    var isUnknownField: Bool { get }
}

extension ItemChange: RegisterChange {
    var wireForm: JSONValue? {
        switch self {
        case .frame(let v): return try? JSONValue(encoding: v)
        case .rotation(let v): return v.map { .number(InkJSON.round3($0)) } ?? .null
        case .z(let v): return .string(v)
        case .text(let v): return try? JSONValue(encoding: v)
        case .crop(let v): return v.map { try? JSONValue(encoding: $0) } ?? .null
        case .poster(let v): return v.map { try? JSONValue(encoding: $0) } ?? .null
        case .math(let v): return try? JSONValue(encoding: v)
        case .other(_, let v): return v
        }
    }

    var isUnknownField: Bool { if case .other = self { return true } else { return false } }
}

extension RecordingChange: RegisterChange {
    var wireForm: JSONValue? {
        switch self {
        case .title(let v): return v.map(JSONValue.string) ?? .null
        case .transcript(let v): return v.map { try? JSONValue(encoding: $0) } ?? .null
        case .other(_, let v): return v
        }
    }

    var isUnknownField: Bool { if case .other = self { return true } else { return false } }
}

extension NoteState {
    /// The blobs this state references: every live item's `blob`, a video's
    /// `poster` and a math item's `render`, and every
    /// recording's `blob` and `transcript`, one per content hash (the first
    /// in that order), sorted by `sha256`.
    public var blobReferences: [BlobRef] {
        var seen: [String: BlobRef] = [:]
        let refs = pages.flatMap { $0.items.flatMap(\.blobReferences) }
            + recordings.flatMap { [$0.blob] + ($0.transcript.map { [$0] } ?? []) }
        for r in refs where seen[r.sha256] == nil { seen[r.sha256] = r }
        return seen.values.sorted { $0.sha256 < $1.sha256 }
    }
}
