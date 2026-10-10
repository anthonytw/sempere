import Foundation

/// Ops for the edits a note browser makes (everything except ink).
public enum NoteOps {
    /// The ops that create a note: one empty page, all metadata fields, and
    /// one `addTag` per tag (format.md §5.4.1).
    ///
    /// Tags are trimmed and de-duplicated, an empty notebook is nil, and the
    /// paper is clamped to its valid ranges (format.md §5.4.2: writers keep
    /// every parameter in range).
    public static func newNote(title: String, paper: Paper = .ruled, pageSize: PageSize = .letter,
                               notebook: String? = nil, tags: [String] = [],
                               pageId: UUID = UUID()) -> [Op] {
        [.addPage(Page(id: pageId, order: PageOrder.between(nil, nil))),
         .setMeta(.title(title)),
         .setMeta(.notebook(normalizedNotebook(notebook))),
         .setMeta(.paper(paper.validated())),
         .setMeta(.pageSize(pageSize))]
            + normalizedTags(tags).map(Op.addTag)
    }

    /// The op that adds `tag` to a note in `state`, or nil when the tag is
    /// empty or the note already has it in any spelling (format.md §5.4.1).
    public static func addTag(_ tag: String, to state: NoteState) -> Op? {
        let tag = normalizedTag(tag)
        guard !tag.isEmpty, !state.meta.tags.contains(where: { tagKey($0) == tagKey(tag) }) else { return nil }
        return .addTag(tag)
    }

    /// The op that removes `tag` (any spelling) from a note in `state`: every
    /// live instance of its key is observed. Nil when the note does not have it.
    public static func removeTag(_ tag: String, from state: NoteState) -> Op? {
        let observed = state.tagSet?.instances(of: tag) ?? []
        guard !observed.isEmpty else { return nil }
        return .removeTag(normalizedTag(tag), observed: observed)
    }

    /// The ops that make a note in `state` carry exactly `tags` (normalised,
    /// first spelling per key wins): `removeTag` for keys it should lose or
    /// whose spelling differs, then `addTag` for keys it lacks, in `tags` order.
    public static func setTags(_ tags: [String], on state: NoteState) -> [Op] {
        let want = normalizedTags(tags)
        let have = state.meta.tags
        let wantSpelling = Dictionary(want.map { (tagKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        let haveSpelling = Dictionary(have.map { (tagKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        var ops: [Op] = []
        for tag in have where wantSpelling[tagKey(tag)] != tag {
            if let op = removeTag(tag, from: state) { ops.append(op) }
        }
        for tag in want where haveSpelling[tagKey(tag)] != tag { ops.append(.addTag(tag)) }
        return ops
    }

    /// The tag as stored: trimmed, inner runs of whitespace collapsed to one space.
    public static func normalizedTag(_ tag: String) -> String {
        tag.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The case-insensitive key tags are matched by: "Math" and "math" are one tag.
    public static func tagKey(_ tag: String) -> String {
        normalizedTag(tag).lowercased()
    }

    /// Normalises each tag (`normalizedTag`), drops empty ones and duplicates
    /// that differ only in case (the first spelling wins), keeps order.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map(normalizedTag).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The trimmed notebook name, nil when empty.
    public static func normalizedNotebook(_ name: String?) -> String? {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}

/// One note's ops in a multi-note edit (`NoteOps.renameNotebook`).
public struct NoteEdit: Hashable, Sendable {
    public var noteId: UUID
    public var ops: [Op]

    public init(noteId: UUID, ops: [Op]) { self.noteId = noteId; self.ops = ops }
}

extension NoteOps {
    /// The op that renames a note in `state` to `title` (trimmed), or none
    /// when the title is already that. Titles are labels, not keys: any
    /// title, including one another note has, is fine.
    public static func rename(to title: String, state: NoteState) -> [Op] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.meta.title == title ? [] : [.setMeta(.title(title))]
    }

    /// The op that sets the note's handwriting language (format.md §5.4
    /// `lang`; nil clears it), or none when it already has it.
    ///
    /// - Throws: `EditError.invalidLanguage` for a tag that is not BCP 47.
    public static func setLanguage(_ lang: String?, state: NoteState) throws -> [Op] {
        var tag: String?
        if let lang {
            guard let t = NoteMeta.validLanguage(lang.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw EditError.invalidLanguage(lang)
            }
            tag = t
        }
        return state.meta.lang == tag ? [] : [.setMeta(.lang(tag))]
    }

    /// The op that draws the note's marker strokes below (`true`) or above its
    /// content items (format.md §5.4 `markersBehindText`), or none when it already does.
    public static func setMarkersBehindText(_ on: Bool, state: NoteState) -> [Op] {
        state.meta.markersBehindText == on ? [] : [.setMeta(.markersBehindText(on))]
    }

    /// The op that marks the note a favorite (`true`) or not (format.md §5.4
    /// `favorite`), or none when it already is that way.
    public static func setFavorite(_ on: Bool, state: NoteState) -> [Op] {
        state.meta.favorite == on ? [] : [.setMeta(.favorite(on))]
    }

    /// The op that puts a note in `state` into the notebook path `notebook`
    /// (canonicalised, format.md §5.4; nil or blank: no notebook), or none
    /// when it is already there.
    public static func move(toNotebook notebook: String?, state: NoteState) -> [Op] {
        let target = NotebookPath.canonical(notebook)
        return state.meta.notebook == target ? [] : [.setMeta(.notebook(target))]
    }

    /// The op that moves a note in `state` to Recently Deleted, or none when
    /// it is there already.
    public static func delete(_ state: NoteState) -> [Op] { state.deleted ? [] : [.deleteNote] }

    /// The op that brings a deleted note in `state` back, or none when it is
    /// not deleted.
    public static func undelete(_ state: NoteState) -> [Op] { state.deleted ? [.restoreNote] : [] }

    /// The edits that rename or move the notebook `old` to `new`
    /// (format.md §5.4): every note in it or below it, deleted ones too, gets
    /// the `old` prefix of its notebook replaced by `new`
    /// (`NotebookPath.renamed`), one `setMeta(.notebook)` per note that
    /// changes. An empty `new` takes the notes directly in `old` out of any
    /// notebook and lifts its sub-notebooks to the top level. Empty when `old`
    /// names no notebook or the rename changes nothing. Sorted by note id.
    ///
    /// - Parameter notebooks: every note of the vault with its current
    ///   notebook; a note left out is left behind.
    public static func renameNotebook(_ old: String, to new: String?, notebooks: [UUID: String?]) -> [NoteEdit] {
        guard let old = NotebookPath.canonical(old) else { return [] }
        let target = NotebookPath.canonical(new)
        guard target != old else { return [] }
        return notebooks.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap { id, notebook in
            guard NotebookPath.name(notebook, isWithin: old) else { return nil }
            let renamed = NotebookPath.renamed(notebook, from: old, to: target)
            return renamed == notebook ? nil : NoteEdit(noteId: id, ops: [.setMeta(.notebook(renamed))])
        }
    }

    /// The spelling to store for a typed tag: the spelling of the same tag
    /// (`tagKey`) already in `existing` (the vault's tags), else the typed one
    /// normalised. Keeps "Math" from becoming "math" on one note.
    public static func tagSpelling(_ typed: String, among existing: [String]) -> String {
        let typed = normalizedTag(typed)
        return existing.first { tagKey($0) == tagKey(typed) }.map(normalizedTag) ?? typed
    }

    /// The vault's tags as the app lists them: each key once, in the first
    /// spelling met, from notes that are not deleted, sorted as Finder sorts names.
    public static func vaultTags(_ notes: [NoteSummary]) -> [String] {
        var byKey: [String: String] = [:]
        for tag in notes.filter({ !$0.deleted }).flatMap(\.tags) where byKey[tagKey(tag)] == nil {
            byKey[tagKey(tag)] = tag
        }
        return byKey.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension Vault {
    /// Writes one delta for an existing note whose ops `build` computes from
    /// the note as it is on disk now, as this device (see
    /// `apply(_:to:deviceState:app:wall:)`). Nothing is written, and nil is
    /// returned, when `build` returns no ops.
    ///
    /// - Throws: `VaultError.revision` when any revision of the note is
    ///   unreadable (ops computed from part of a note could undo what the
    ///   unreadable part holds), and what `apply` throws.
    @discardableResult
    public func apply(to noteId: UUID, deviceState: URL, app: String, wall: Date = Date(),
                      building build: (NoteState) throws -> [Op]) throws -> Revision? {
        try requireMigrated()
        guard canRead else { throw isLocked ? VaultError.locked : VaultError.noIdentities }
        let loaded = try loadNote(noteId)
        let ops = try build(try reconstruct(loaded))
        guard !ops.isEmpty else { return nil }
        return try writeDelta(ops, to: noteId, loaded: loaded, deviceState: deviceState, app: app, wall: wall)
    }

    /// Writes one delta of `ops` for a note as this device: the device id and
    /// clock come from the state file at `deviceState` (created on first use;
    /// saved before the revision is written, so the clock only ever moves
    /// forward). The clock first observes every readable revision of the
    /// note, so these ops win last-writer-wins races against what is already
    /// there. Creates the note when it has no revisions yet.
    ///
    /// - Throws: `VaultError.locked` / `.noIdentities` when the vault cannot
    ///   read, `.revision` for an unreadable snapshot, `VaultError.io` for the
    ///   state file.
    @discardableResult
    public func apply(_ ops: [Op], to noteId: UUID, deviceState: URL, app: String,
                      wall: Date = Date()) throws -> Revision {
        try requireMigrated()
        guard canRead else { throw isLocked ? VaultError.locked : VaultError.noIdentities }
        return try writeDelta(ops, to: noteId, loaded: try loadNote(noteId), deviceState: deviceState, app: app, wall: wall)
    }

    func writeDelta(_ ops: [Op], to noteId: UUID, loaded: LoadedNote, deviceState: URL, app: String,
                    wall: Date, checkpoint: Checkpoint? = nil) throws -> Revision {
        var state = try DeviceState.loadOrCreate(at: deviceState)
        var clock = state.clock
        for r in loaded.revisions { clock.observe(r.hlc, wall: wall) }
        let hlc = clock.tick(wall: wall)
        let seq = loaded.failures.isEmpty
            ? Vault.nextSeq(from: loaded.revisions, device: state.device)
            : try nextSeq(noteId: noteId, device: state.device)
        state.clock = clock
        try state.save(to: deviceState)
        let revision = Revision(noteId: noteId, device: state.device, seq: seq, hlc: hlc, wall: wall, app: app,
                                body: .delta(ops: ops), checkpoint: checkpoint)
        try write(revision)
        return revision
    }
}

/// Which pages a paper change applies to.
public enum PaperScope: Hashable, Sendable {
    /// Only this page: it gets its own paper.
    case page(UUID)
    /// The whole note: every page follows the note's paper.
    case allPages
}

extension NoteOps {
    /// The ops that set `paper` (clamped to its valid ranges, format.md
    /// §5.4.2) for `scope`. For `.allPages` that is the note's paper plus a
    /// `setPagePaper(nil)` for each page that has its own, so none keeps an
    /// older choice. Empty when nothing would change.
    public static func setPaper(_ paper: Paper, scope: PaperScope, note: NoteMeta, pages: [Page]) -> [Op] {
        let paper = paper.validated()
        switch scope {
        case .page(let id):
            guard let page = pages.first(where: { $0.id == id }), page.paper ?? note.paper != paper else { return [] }
            return [.setPagePaper(pageId: id, paper: paper)]
        case .allPages:
            var ops: [Op] = []
            if note.paper != paper { ops.append(.setMeta(.paper(paper))) }
            ops += pages.filter { $0.paper != nil }.map { .setPagePaper(pageId: $0.id, paper: nil) }
            return ops
        }
    }
}

/// Why a note edit cannot be made.
public enum EditError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Not a BCP 47 language tag (format.md §5.4 `lang`).
    case invalidLanguage(String)

    public var description: String {
        switch self {
        case .invalidLanguage(let s):
            return "\"\(s.prefix(80))\" is not a language tag (BCP 47, e.g. en-US, es, pt-BR)"
        }
    }
}
