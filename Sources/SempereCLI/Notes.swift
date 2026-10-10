import ArgumentParser
import Foundation
import Sempere

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "List, find, create and edit notes, switch page layout, show their history and restore earlier revisions.",
        subcommands: [NotesList.self, NotesShow.self, NotesNew.self, NotesRename.self, NotesTag.self, NotesMove.self,
                      NotesPaper.self, NotesLanguage.self, NotesMarkers.self, NotesFavorite.self, NotesLayout.self, NotesSearch.self, NotesDelete.self, NotesUndelete.self, NotesHistory.self,
                      NotesRestore.self, NotesCheckpoint.self, NotesDedupe.self]
    )
}

struct NoteJSON: Encodable {
    var id: String
    var title: String
    var tags: [String]
    var notebook: String?
    var deleted: Bool
    var pages: Int
    var strokes: Int
    var recognizedPages: Int
    var items: Int
    var recordings: Int
    var modified: Date?
    var problem: String?
    /// The handwriting language (format.md §5.4), when set.
    var lang: String?
    var markersBehindText: Bool
    /// The note is a favorite (format.md §5.4).
    var favorite: Bool
    /// The last recognition run that read the note (format.md §5.4 `recognized`), when one did.
    var recognized: RecognitionRecord?
    /// True when the note cannot be changed by this version: the vault is
    /// read-only, or the note holds content a newer version wrote (format.md §7.3).
    var readOnly: Bool
    /// What a newer version wrote and what could not be shown (format.md §7.4).
    var newer: NewerContent?

    init(_ s: NoteSummary, vaultReadOnly: Bool = false) {
        readOnly = vaultReadOnly || s.newer != nil
        newer = s.newer
        id = s.id.uuidString.lowercased(); title = s.title; tags = s.tags; notebook = s.notebook
        deleted = s.deleted; pages = s.pages; strokes = s.strokes
        recognizedPages = s.recognizedPages; items = s.items; recordings = s.recordings
        modified = s.modified; problem = s.problem
        lang = s.lang; markersBehindText = s.markersBehindText; favorite = s.favorite; recognized = s.recognized
    }
}

struct NotesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notes: id, title, pages, strokes, modified.",
        discussion: """
            Deleted notes are hidden unless --deleted. Summaries are kept in an encrypted per-device cache \
            ($XDG_CACHE_HOME/sempere, default ~/.cache/sempere), so only notes with new revisions are read again.
            """
    )

    @Option(name: .long, help: ArgumentHelp("Only notes with this tag.", valueName: "tag"))
    var tag: String?

    @Option(name: .long, help: ArgumentHelp("Only notes in this notebook or below it.", valueName: "path"))
    var notebook: String?

    @Flag(name: .long, help: "Include deleted notes.")
    var deleted = false

    @Flag(name: .long, help: "Only favorite notes (see `notes favorite`).")
    var favorites = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let notes = try vault.summaries(of: nil, cache: cache.cache(for: vault)).filter { n in
            (deleted || !n.deleted) && (!favorites || n.favorite) && (tag.map { t in n.tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(t) } } ?? true) && (notebook.map { NotebookPath.name(n.notebook, isWithin: $0) } ?? true)
        }
        let readOnly = vault.isReadOnly
        if output.json { try output.emitJSON(notes.map { NoteJSON($0, vaultReadOnly: readOnly) }); return }
        if notes.isEmpty { output.info("No notes."); return }
        var rows = output.quiet ? [] : [["ID", "TITLE", "PAGES", "STROKES", "MODIFIED"]]
        for n in notes {
            let title = (n.title.isEmpty ? "(untitled)" : n.title) + (n.deleted ? " [deleted]" : "") + (n.favorite ? " [favorite]" : "")
                + (n.problem != nil ? " [!]" : "") + (n.newer != nil ? " [newer]" : "")
            rows.append([n.id.uuidString.lowercased(), title, String(n.pages), String(n.strokes), Format.local(n.modified)])
        }
        print(Format.table(rows))
    }
}

struct NotesShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a note's metadata, placed items, recordings and revision history.",
        discussion: """
            The note is picked by id, an id prefix of 4 or more characters, or exact title. Items (text boxes, \
            images, PDF pages) are listed by page in drawing order, recordings by start time.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let loaded = try vault.loadNote(id, detail: .withoutStrokePoints)
        let summary = vault.summary(of: id, loaded: loaded)
        let history = loaded.history
        // Best effort, like the summary: what the readable revisions hold.
        let state = try? NoteReducer.reconstruct(loaded.revisions)
        let placed = AttachmentListing.items(state)
        let recordings = AttachmentListing.recordings(state)
        if output.json {
            struct Rev: Encodable { var name: String; var kind: String; var wall: Date?; var app: String?; var error: String? }
            struct Out: Encodable {
                var note: NoteJSON; var items: [AttachmentListing.PlacedItem]; var recordings: [Recording]
                var readOnly: Bool; var readOnlyReasons: [String]; var revisions: [Rev]
            }
            let reasons = vault.readOnlyReasons
            try output.emitJSON(Out(note: NoteJSON(summary, vaultReadOnly: !reasons.isEmpty), items: placed,
                                    recordings: recordings, readOnly: !reasons.isEmpty,
                                    readOnlyReasons: reasons.descriptions, revisions: history.map {
                Rev(name: $0.name.filename, kind: $0.name.kind.rawValue, wall: $0.wall, app: $0.app,
                    error: $0.error.map { "\($0)" })
            }))
            return
        }
        print("Id:       \(summary.id.uuidString.lowercased())")
        print("Title:    \(summary.title.isEmpty ? "(untitled)" : summary.title)")
        print("Tags:     \(summary.tags.isEmpty ? "-" : summary.tags.joined(separator: ", "))")
        print("Notebook: \(summary.notebook ?? "-")")
        print("Deleted:  \(summary.deleted ? "yes" : "no")")
        print("Pages:    \(summary.pages)   Strokes: \(summary.strokes)")
        print("Text:     \(summary.recognizedPages) of \(summary.pages) page(s) with recognised text")
        print("Modified: \(Format.local(summary.modified))")
        if let p = summary.problem { print("Problem:  \(p)") }
        if let n = summary.newer { print("Newer:    \(n.summary); shown as far as this version understands it") }
        if vault.isReadOnly { print("Read-only: " + vault.readOnlyReasons.descriptions.joined(separator: "; ")) }
        if !placed.isEmpty {
            print("\nItems (\(placed.count)):")
            print(Format.table(placed.map(AttachmentListing.row)))
        }
        if !recordings.isEmpty {
            print("\nRecordings (\(recordings.count)):")
            print(Format.table(recordings.map(AttachmentListing.row)))
        }
        print("\nRevisions (\(history.count)):")
        print(Format.table(history.map { h in
            [h.name.kind.rawValue, Format.local(h.wall), h.name.filename,
             h.error.map { "UNREADABLE: \($0)" } ?? (output.verbose ? (h.app ?? "") : "")]
        }))
    }
}

/// Items and recordings of a note as `notes show` lists them.
enum AttachmentListing {
    /// One placed item with the page it is on: `--json` gives the item in its
    /// format JSON (format.md §8.2) without the snapshot-only `origin` and
    /// `clocks`.
    struct PlacedItem: Encodable {
        /// 1-based page number.
        var page: Int
        var pageId: UUID
        var item: Item

        enum CodingKeys: String, CodingKey { case page, pageId, item }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(page, forKey: .page)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
            try c.encode(item, forKey: .item)
        }
    }

    static func items(_ state: NoteState?) -> [PlacedItem] {
        guard let state else { return [] }
        return state.pages.enumerated().flatMap { i, p in
            p.items.map { item -> PlacedItem in
                var item = item
                item.origin = nil; item.clocks = nil
                return PlacedItem(page: i + 1, pageId: p.id, item: item)
            }
        }
    }

    static func recordings(_ state: NoteState?) -> [Recording] {
        (state?.recordings ?? []).map { r in
            var r = r
            r.origin = nil; r.clocks = nil
            return r
        }
    }

    static func number(_ v: Double) -> String {
        let r = InkJSON.round3(v)
        return r == r.rounded() && abs(r) < 1e15 ? String(Int(r)) : String(r)
    }

    static func blob(_ b: BlobRef) -> String { "\(b.type) \(b.size) B \(b.sha256.prefix(12))" }

    /// `p<N>  kind  layer  [x, y, w, h]  what  id`.
    static func row(_ p: PlacedItem) -> [String] {
        let i = p.item
        let f = i.frame
        var what: String
        switch i.kind {
        case .text:
            let t = (i.text.map(MarkdownText.searchText) ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            what = "\"" + (t.count > 40 ? t.prefix(39) + "…" : t) + "\""
        case .pdfPage: what = (i.blob.map(blob) ?? "") + " page \((i.pageIndex ?? 0) + 1)"
        case .video:
            what = (i.blob.map(blob) ?? "") + " \(number(i.duration ?? 0)) s"
                + (i.pixelSize.map { " \(number($0.w))×\(number($0.h))" } ?? "") + (i.poster == nil ? " (no poster)" : " +poster")
        case .math:
            let t = (i.math?.latex ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            what = "$" + (t.count > 40 ? t.prefix(39) + "…" : t) + "$" + (i.math?.render == nil ? " (not typeset)" : "")
        case .audio: what = "recording " + (i.recording.map { String($0.uuidString.lowercased().prefix(8)) } ?? "-")
        default: what = i.blob.map(blob) ?? (i.kind.isDefined ? "" : "(unknown kind)")
        }
        if let r = i.rotation, r != 0 { what += " rotated \(number(r))°" }
        return ["p\(p.page)", i.kind.rawValue, "layer \(i.layer)",
                "[\([f.x, f.y, f.w, f.h].map(number).joined(separator: ", "))]", what, i.id.uuidString.lowercased()]
    }

    /// `start  duration  "title"  blob  [transcript]  id`.
    static func row(_ r: Recording) -> [String] {
        [Format.local(r.started), r.duration.map { number($0) + " s" } ?? "-", "\"\(r.title ?? "")\"",
         blob(r.blob) + (r.transcript != nil ? " +transcript" : ""), r.id.uuidString.lowercased()]
    }
}

enum NoteLayout: String, ExpressibleByArgument, CaseIterable {
    case paged, pageless
}

struct NotesLayout: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "Switch a note between paged and pageless by writing one new delta.",
        discussion: """
            pageless joins the pages into one infinite page (sheet height = the page height);
            paged cuts an infinite page into pages of its sheet height (breakHeight, default
            width x 11/8.5). No ink is deleted and none moves relative to its sheet: strokes that
            change page are re-added under new ids with `parent` naming the old ones (format.md
            §5.4.3). Nothing is written when the note already has the layout (a pageless note with
            several pages, left by concurrent edits, is joined), or with --dry-run.
            The device id and clock come from $XDG_STATE_HOME/sempere/device.json.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: "paged or pageless.")
    var layout: NoteLayout

    @Flag(name: .customLong("dry-run"), help: "Only say what would change.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let layout = self.layout
        func switched(_ state: NoteState) -> LayoutEdit {
            layout == .paged
                ? NoteOps.makePaged(pages: state.pages, pageSize: state.meta.pageSize)
                : NoteOps.makePageless(pages: state.pages, pageSize: state.meta.pageSize)
        }
        // The switch is computed from the note as it is on disk when the delta is written.
        var before = 0
        var edit = LayoutEdit(ops: [], pages: [], pageSize: .letter)
        var file: String?
        if dryRun {
            let state = try vault.reconstruct(try vault.loadNote(id))
            try requireLive(state)
            before = state.pages.count
            edit = switched(state)
        } else {
            file = try editNote(vault, id) { current in
                try requireLive(current)
                before = current.pages.count
                edit = switched(current)
                return edit.ops
            }?.name.filename
        }
        let noteName = id.uuidString.lowercased()
        if output.json {
            struct Out: Encodable {
                var note: String; var layout: String; var dryRun: Bool; var changed: Bool
                var pagesBefore: Int; var pagesAfter: Int; var file: String?
            }
            try output.emitJSON(Out(note: noteName, layout: layout.rawValue, dryRun: dryRun, changed: !edit.ops.isEmpty,
                                    pagesBefore: before, pagesAfter: edit.pages.count, file: file))
            return
        }
        guard !edit.ops.isEmpty else {
            output.info("\(noteName) is already \(layout.rawValue); nothing to write.")
            return
        }
        let what = "\(before) page(s) -> \(edit.pages.count) page(s)"
        print("\(dryRun ? "would make" : "made") \(noteName) \(layout.rawValue): \(what)")
        if let file { output.info("Wrote \(noteName)/\(file)") }
    }
}
