import ArgumentParser
import Foundation
import Sempere

// The edits the app's note browser and canvas make, one delta per note
// through `Vault.apply` with this machine's device id and clock
// ($XDG_STATE_HOME/sempere/device.json), the ops computed by the same
// `NoteOps` functions the app calls.

/// Writes one delta for `id` whose ops `build` computes from the note as it
/// is on disk; nil when there was nothing to change.
func editNote(_ vault: Vault, _ id: UUID, building build: (NoteState) throws -> [Op]) throws -> Revision? {
    try vault.apply(to: id, deviceState: DeviceState.defaultURL(), app: appName, building: build)
}

/// What a single-note edit prints with --json.
struct EditJSON: Encodable {
    /// The note as it is after the edit.
    var note: NoteJSON
    /// False when the note already was that way and nothing was written.
    var changed: Bool
    /// The delta written, a file name in the note's folder.
    var file: String?
}

/// Prints the outcome of a single-note edit: JSON, or one line.
func reportEdit(_ vault: Vault, _ id: UUID, _ revision: Revision?, output: OutputOptions,
                done: String, unchanged: String) throws {
    let name = id.uuidString.lowercased()
    if output.json {
        try output.emitJSON(EditJSON(note: NoteJSON(try vault.summary(of: id)), changed: revision != nil,
                                     file: revision?.name.filename))
    } else if let revision {
        output.info("\(done) (\(name)/\(revision.name.filename))")
    } else {
        output.info(unchanged)
    }
}

// MARK: - notes new

struct NotesNew: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a note with one empty page.",
        discussion: """
            Writes one delta that creates the note: one blank page, the title, the notebook (a
            /-separated path), the paper and page size, and one addTag per tag, in the spelling the
            vault already uses for it (as `notes tag --add`). Prints the new note's id. Titles need not
            be unique. Without a title the note is named after the date and time, as the app names a
            new note: --title-format (default: $SEMPERE_TITLE_FORMAT) takes a Unicode date pattern (e.g.
            "yyyy-MM-dd HH:mm", literal text in single quotes) or a strftime format ("%Y-%m-%d %H:%M");
            a format that cannot be used is refused (exit 2) with the reason, as the app's setting is.
            Without one the title is the locale's medium date and short time.
            """
    )

    @Argument(help: ArgumentHelp("The title (may be empty; omitted: the date and time).", valueName: "title"))
    var title: String?

    @Option(name: .customLong("title-format"),
            help: ArgumentHelp("Date pattern of the default title, when no title is given.", valueName: "pattern"))
    var titleFormat: String?

    @Option(name: .long, help: ArgumentHelp("Put the note in this notebook (School/Math for levels).",
                                            valueName: "path"))
    var notebook: String?

    @Option(name: .long, help: ArgumentHelp("Add this tag. Repeatable.", valueName: "tag"))
    var tag: [String] = []

    @Option(name: .long, help: ArgumentHelp("The paper kind (default ruled): \(PaperKind.argumentList).",
                                            valueName: "kind"))
    var paper: PaperKind = .ruled

    @Option(name: .customLong("page-size"), help: ArgumentHelp("letter or a4.", valueName: "size"))
    var pageSize: PageSizeArgument = .letter

    @OptionGroup var paperOptions: PaperOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    /// The format in effect: `--title-format`, else `$SEMPERE_TITLE_FORMAT`.
    var effectiveTitleFormat: String? {
        titleFormat ?? ProcessInfo.processInfo.environment["SEMPERE_TITLE_FORMAT"]
    }

    func validate() throws {
        try paperOptions.check()
        if title == nil, let format = effectiveTitleFormat, let problem = DefaultTitle.check(format) {
            throw ValidationError("\(titleFormat == nil ? "SEMPERE_TITLE_FORMAT" : "--title-format"): \(problem)")
        }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = UUID()
        let paper = try paperOptions.applied(to: Paper.template(self.paper))
        let known = NoteOps.normalizedTags(tag).isEmpty
            ? [] : NoteOps.vaultTags(try vault.summaries(of: nil, cache: cache.cache(for: vault)))
        let title = self.title ?? DefaultTitle.title(at: Date(), format: effectiveTitleFormat)
        let ops = NoteOps.newNote(title: title.trimmingCharacters(in: .whitespacesAndNewlines), paper: paper,
                                  pageSize: pageSize.size, notebook: NotebookPath.canonical(notebook),
                                  tags: tag.map { NoteOps.tagSpelling($0, among: known) })
        let revision = try vault.apply(ops, to: id, deviceState: DeviceState.defaultURL(), app: appName)
        if output.json {
            try output.emitJSON(EditJSON(note: NoteJSON(try vault.summary(of: id)), changed: true,
                                         file: revision.name.filename))
        } else if output.quiet {
            print(id.uuidString.lowercased())
        } else {
            print(id.uuidString.lowercased())
            printStderr("Created \(id.uuidString.lowercased())/\(revision.name.filename)")
        }
    }
}

enum PageSizeArgument: String, ExpressibleByArgument, CaseIterable {
    case letter, a4

    var size: PageSize { self == .letter ? .letter : .a4 }
}

// MARK: - notes rename / move / delete / undelete

struct NotesRename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a note (one setMeta title delta).",
        discussion: "The title is trimmed. Titles are labels, not keys: another note may have the same one."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The new title.", valueName: "new-title"))
    var title: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { NoteOps.rename(to: title, state: $0) }
        try reportEdit(vault, id, r, output: output, done: "Renamed", unchanged: "The note already has that title.")
    }
}

struct NotesLanguage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "language",
        abstract: "Set the language a note is handwritten in (recognition reads it in that language).",
        discussion: """
            One setMeta lang delta (format.md §5.4): a BCP 47 tag such as en-US, es-ES or pt (en_US is \
            read as en-US). `sempere recognize` and the app ask Vision for that language when it supports \
            it, else detect the language themselves. --none clears it. Without a tag or --none, prints \
            the note's language.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("A BCP 47 language tag.", valueName: "tag"))
    var tag: String?

    @Flag(name: .long, help: "Clear the language (recognisers use their default).")
    var none = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if none && tag != nil { throw ValidationError("give a tag or --none, not both") }
        if let tag, NoteMeta.validLanguage(tag.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            throw ValidationError(EditError.invalidLanguage(tag).description)
        }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        guard tag != nil || none else {
            let s = try vault.summary(of: id)
            if output.json {
                struct Out: Encodable { var note: String; var lang: String? }
                try output.emitJSON(Out(note: id.uuidString.lowercased(), lang: s.lang))
            } else {
                print(s.lang ?? "(none)")
            }
            return
        }
        let r = try editNote(vault, id) { try NoteOps.setLanguage(none ? nil : tag, state: $0) }
        try reportEdit(vault, id, r, output: output, done: none ? "Language cleared" : "Language set",
                       unchanged: "The note already has that language.")
    }
}

struct NotesMarkers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markers",
        abstract: "Draw a note's marker (highlighter) strokes behind or above its text boxes and images.",
        discussion: """
            One setMeta markersBehindText delta (format.md §5.4, §8.2.3). behind: markers are drawn \
            below the page's content items (text boxes, images) and below other ink, as Notability draws a \
            highlighter behind typed text; above: everything ink is above the items (the default). \
            Imported Notability notes are behind.
            """
    )

    enum Placement: String, ExpressibleByArgument, CaseIterable { case behind, above }

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("behind or above.", valueName: "placement"))
    var placement: Placement

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { NoteOps.setMarkersBehindText(placement == .behind, state: $0) }
        try reportEdit(vault, id, r, output: output, done: "Markers drawn \(placement.rawValue) the items",
                       unchanged: "The note's markers are already drawn that way.")
    }
}

struct NotesFavorite: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "favorite",
        abstract: "Mark a note as a favorite, or take the mark off (one setMeta favorite delta).",
        discussion: """
            The favorite flag (format.md §5.4) is what the app's Favorites list and the web viewer's \
            Favorites list show. `notes list --favorites` lists the marked notes. Nothing is written when \
            the note already is that way.
            """
    )

    @Argument(help: ArgumentHelp("Note id, id prefix or title.", valueName: "id|title"))
    var note: String

    @Flag(name: .long, help: "Take the favorite mark off instead.")
    var off = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { NoteOps.setFavorite(!off, state: $0) }
        try reportEdit(vault, id, r, output: output, done: off ? "Removed from favorites" : "Marked as a favorite",
                       unchanged: off ? "The note is not a favorite." : "The note already is a favorite.")
    }
}

struct NotesMove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Put a note into a notebook, or out of every notebook.",
        discussion: """
            The notebook is a /-separated display path (format.md §5.4), stored in canonical form:
            " A//B " is A/B. --none (or an empty name) takes the note out of any notebook.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The notebook path.", valueName: "notebook"))
    var notebook: String?

    @Flag(name: .long, help: "Take the note out of any notebook.")
    var none = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if none == (notebook != nil) { throw ValidationError("give a notebook or --none") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let target = none ? nil : NotebookPath.canonical(notebook)
        let r = try editNote(vault, id) { NoteOps.move(toNotebook: target, state: $0) }
        try reportEdit(vault, id, r, output: output, done: target.map { "Moved to \($0)" } ?? "Moved out of its notebook",
                       unchanged: "The note is already there.")
    }
}

struct NotesDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Move a note to Recently Deleted (one deleteNote delta).",
        discussion: "Nothing is removed from disk: `notes undelete` brings the note back."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id, building: NoteOps.delete)
        try reportEdit(vault, id, r, output: output, done: "Deleted", unchanged: "The note is already deleted.")
    }
}

struct NotesUndelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undelete",
        abstract: "Bring a deleted note back (one restoreNote delta).",
        discussion: "To roll a note back to an earlier revision, use `notes restore --to`."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id, building: NoteOps.undelete)
        try reportEdit(vault, id, r, output: output, done: "Restored", unchanged: "The note is not deleted.")
    }
}

// MARK: - notes tag

struct NotesTag: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "Add and remove a note's tags (one delta).",
        discussion: """
            Tags match case-insensitively and merge per tag (format.md §5.4.1): --add writes an addTag
            unless the note has the tag in any spelling, using the spelling the vault already has for
            it; --remove writes a removeTag observing every instance of the tag on disk. A tag cannot
            be both added and removed in one command.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("Add this tag. Repeatable.", valueName: "tag"))
    var add: [String] = []

    @Option(name: .long, help: ArgumentHelp("Remove this tag. Repeatable.", valueName: "tag"))
    var remove: [String] = []

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func validate() throws {
        let adds = NoteOps.normalizedTags(add), removes = NoteOps.normalizedTags(remove)
        if adds.isEmpty && removes.isEmpty { throw ValidationError("give --add or --remove with a non-empty tag") }
        let both = Set(adds.map(NoteOps.tagKey)).intersection(removes.map(NoteOps.tagKey))
        if let tag = both.first { throw ValidationError("'\(tag)' is both added and removed") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let adds = NoteOps.normalizedTags(add)
        let known = adds.isEmpty ? [] : NoteOps.vaultTags(try vault.summaries(of: nil, cache: cache.cache(for: vault)))
        let r = try editNote(vault, id) { state in
            NoteOps.normalizedTags(remove).compactMap { NoteOps.removeTag($0, from: state) }
                + adds.compactMap { NoteOps.addTag(NoteOps.tagSpelling($0, among: known), to: state) }
        }
        try reportEdit(vault, id, r, output: output, done: "Tags updated", unchanged: "The tags are already so.")
    }
}

// MARK: - notes paper

extension PaperKind: ExpressibleByArgument {
    /// Accepts the format name in any case, with or without dashes
    /// (`marginRuled`, `margin-ruled`).
    public init?(argument: String) {
        let key = argument.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        guard let kind = PaperKind.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
        self = kind
    }

    public static var allValueStrings: [String] { allCases.map(\.rawValue) }

    static var argumentList: String { allValueStrings.joined(separator: ", ") }
}

/// The parameters of a paper (format.md §5.4.2). Values outside the format's
/// limits are refused rather than clamped.
struct PaperOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("Line, dot or grid spacing, points (4-200).", valueName: "pt"))
    var spacing: Double?

    @Option(name: .customLong("line-width"), help: ArgumentHelp("Width of rules, points (0.1-4).", valueName: "pt"))
    var lineWidth: Double?

    @Option(name: .customLong("dot-radius"), help: ArgumentHelp("Dot radius, points (0.3-4).", valueName: "pt"))
    var dotRadius: Double?

    @Option(name: .customLong("margin-left"), help: ArgumentHelp("Left margin line, points from the edge (0-300; 0 none).",
                                                                  valueName: "pt"))
    var marginLeft: Double?

    @Option(name: .customLong("margin-top"), help: ArgumentHelp("Top margin line, points from the edge (0-300; 0 none).",
                                                                 valueName: "pt"))
    var marginTop: Double?

    @Option(name: .customLong("cue-width"), help: ArgumentHelp("Cornell cue column width, points (40-400).",
                                                                valueName: "pt"))
    var cueWidth: Double?

    @Option(name: .customLong("summary-height"), help: ArgumentHelp("Cornell summary band height, points (40-400).",
                                                                     valueName: "pt"))
    var summaryHeight: Double?

    @Option(name: .customLong("staff-spacing"), help: ArgumentHelp("Distance between staff lines, points (3-20).",
                                                                    valueName: "pt"))
    var staffSpacing: Double?

    @Option(name: .customLong("staff-gap"), help: ArgumentHelp("Gap between staves, points (8-150).", valueName: "pt"))
    var staffGap: Double?

    @Option(name: .long, help: ArgumentHelp("Background colour, #RRGGBB or #RRGGBBAA.", valueName: "hex"))
    var background: String?

    @Option(name: .customLong("line-color"), help: ArgumentHelp("Colour of rules and dots.", valueName: "hex"))
    var lineColor: String?

    @Option(name: .customLong("margin-color"), help: ArgumentHelp("Colour of the margin lines.", valueName: "hex"))
    var marginColor: String?

    /// True when any parameter was given.
    var any: Bool {
        [spacing, lineWidth, dotRadius, marginLeft, marginTop, cueWidth, summaryHeight, staffSpacing, staffGap]
            .contains { $0 != nil } || [background, lineColor, marginColor].contains { $0 != nil }
    }

    /// Range-checks every given value (exit 2 on a bad one).
    func check() throws {
        let limits: [(String, Double?, ClosedRange<Double>)] = [
            ("--spacing", spacing, Paper.Limits.spacing), ("--line-width", lineWidth, Paper.Limits.lineWidth),
            ("--dot-radius", dotRadius, Paper.Limits.dotRadius), ("--margin-left", marginLeft, Paper.Limits.margin),
            ("--margin-top", marginTop, Paper.Limits.margin), ("--cue-width", cueWidth, Paper.Limits.cueWidth),
            ("--summary-height", summaryHeight, Paper.Limits.summaryHeight),
            ("--staff-spacing", staffSpacing, Paper.Limits.staffSpacing), ("--staff-gap", staffGap, Paper.Limits.staffGap),
        ]
        for (name, value, range) in limits {
            guard let value else { continue }
            guard value.isFinite, range.contains(value) else {
                throw ValidationError("\(name) must be between \(range.lowerBound) and \(range.upperBound)")
            }
        }
        for (name, value) in [("--background", background), ("--line-color", lineColor), ("--margin-color", marginColor)] {
            if let value, Color(hex: value) == nil { throw ValidationError("\(name) is #RRGGBB or #RRGGBBAA") }
        }
    }

    /// `base` with every given parameter set.
    func applied(to base: Paper) throws -> Paper {
        try check()
        var p = base
        if let spacing { p.spacing = spacing }
        if let lineWidth { p.lineWidth = lineWidth }
        if let dotRadius { p.dotRadius = dotRadius }
        if let marginLeft { p.marginLeft = marginLeft }
        if let marginTop { p.marginTop = marginTop }
        if let cueWidth { p.cueWidth = cueWidth }
        if let summaryHeight { p.summaryHeight = summaryHeight }
        if let staffSpacing { p.staffSpacing = staffSpacing }
        if let staffGap { p.staffGap = staffGap }
        if let c = background.flatMap(Color.init(hex:)) { p.background = c }
        if let c = lineColor.flatMap(Color.init(hex:)) { p.lineColor = c }
        if let c = marginColor.flatMap(Color.init(hex:)) { p.marginColor = c }
        return p.validated()
    }
}

struct NotesPaper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paper",
        abstract: "Set the paper of a whole note or of one page (one delta).",
        discussion: """
            Without --page the note's paper is set and every page that had its own paper follows it
            again (setMeta paper plus setPagePaper null); with --page N only that page gets its own
            paper (setPagePaper). A KIND starts from that kind's defaults (as the app's paper picker);
            without one, the current paper of the note (or page) is changed by the options given.
            Kinds: \(PaperKind.argumentList) (format.md §5.4.2).
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The paper kind; omit to edit the current paper.", valueName: "kind"))
    var kind: PaperKind?

    @Option(name: .long, help: ArgumentHelp("Only this page (1 is the first).", valueName: "n"))
    var page: Int?

    @OptionGroup var paperOptions: PaperOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if kind == nil && !paperOptions.any { throw ValidationError("give a paper kind or a paper option") }
        if let page, page < 1 { throw ValidationError("--page counts from 1") }
        try paperOptions.check()
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        var chosen: Paper?
        let r = try editNote(vault, id) { state in
            let scope: PaperScope
            let current: Paper
            if let page {
                guard page <= state.pages.count else {
                    throw CLIError.usage("the note has \(state.pages.count) page(s); there is no page \(page)")
                }
                let p = state.pages[page - 1]
                scope = .page(p.id)
                current = p.paper ?? state.meta.paper
            } else {
                scope = .allPages
                current = state.meta.paper
            }
            guard !state.deleted else { throw CLIError.failure("the note is deleted: run `sempere notes undelete` first") }
            let paper = try paperOptions.applied(to: kind.map(Paper.template) ?? current)
            chosen = paper
            return NoteOps.setPaper(paper, scope: scope, note: state.meta, pages: state.pages)
        }
        let name = id.uuidString.lowercased()
        if output.json {
            struct Out: Encodable {
                var note: String; var changed: Bool; var file: String?; var page: Int?; var paper: Paper?
            }
            try output.emitJSON(Out(note: name, changed: r != nil, file: r?.name.filename, page: page, paper: chosen))
        } else if let r, let chosen {
            output.info("Set \(page.map { "page \($0)" } ?? "every page") to \(chosen.kind.title) (\(name)/\(r.name.filename))")
        } else {
            output.info("The paper is already so.")
        }
    }
}

// MARK: - notebooks

struct NotebooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notebooks",
        abstract: "List notebooks and rename or move them with every note inside.",
        subcommands: [NotebooksList.self, NotebooksRename.self, NotebooksMove.self]
    )
}

struct NotebooksList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the notebook tree with note counts.",
        discussion: """
            Notebooks are /-separated paths (format.md §5.4); parents are listed even when they hold
            no note directly. NOTES counts the notes directly in a notebook, TOTAL those in it or below
            it. Deleted notes are not counted unless --deleted.
            """
    )

    @Flag(name: .long, help: "Count deleted notes too.")
    var deleted = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let notes = try vault.summaries(of: nil, cache: cache.cache(for: vault)).filter { deleted || !$0.deleted }
        struct Row: Encodable { var path: String; var depth: Int; var notes: Int; var total: Int }
        let rows = NotebookNode.flatten(NotebookNode.tree(notes.map(\.notebook))).map { path in
            Row(path: path, depth: NotebookPath.components(path).count - 1,
                notes: notes.filter { NotebookPath.canonical($0.notebook) == path }.count,
                total: notes.filter { NotebookPath.name($0.notebook, isWithin: path) }.count)
        }
        if output.json { try output.emitJSON(rows); return }
        if rows.isEmpty { output.info("No notebooks."); return }
        var table = output.quiet ? [] : [["NOTEBOOK", "NOTES", "TOTAL"]]
        for r in rows { table.append([r.path, String(r.notes), String(r.total)]) }
        print(Format.table(table))
    }
}

struct NotebooksRename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename or move a notebook and everything below it.",
        discussion: """
            Every note in OLD or below it, deleted ones too, gets the OLD prefix of its notebook replaced
            by NEW: one setMeta notebook delta per note (as the app's sidebar rename). Paths compare by
            whole segments, so renaming A/B leaves A/Bc alone. An empty NEW ("") takes the notes directly
            in OLD out of any notebook and lifts its sub-notebooks to the top level. Refused, before
            anything is written, when any note cannot be read (its notebook is unknown).
            """
    )

    @Argument(help: ArgumentHelp("The notebook to rename.", valueName: "old"))
    var old: String

    @Argument(help: ArgumentHelp("The new path; \"\" for none.", valueName: "new"))
    var new: String

    @Flag(name: .customLong("dry-run"), help: "Only list the notes that would change.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if NotebookPath.canonical(old) == nil { throw ValidationError("the notebook name is empty") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        try Self.perform(vault, old: old, to: NotebookPath.canonical(new), dryRun: dryRun, output: output)
    }

    /// Replaces the prefix `old` of every note's notebook by `target` (nil: none), one delta per
    /// note; shared with `notebooks move`.
    static func perform(_ vault: Vault, old: String, to target: String?, dryRun: Bool, output: OutputOptions) throws {
        // Read every note now (no cache): a note left out would be left behind.
        let notes = try vault.summaries(of: nil)
        let unreadable = notes.filter { $0.problem != nil }
        guard unreadable.isEmpty else {
            throw CLIError.failure("\(unreadable.count) note(s) cannot be read, so their notebooks are unknown: "
                + unreadable.map { $0.id.uuidString.lowercased() }.joined(separator: ", "))
        }
        let planned = NoteOps.renameNotebook(old, to: target,
                                             notebooks: Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.notebook) }))
        struct Change: Encodable { var note: String; var title: String; var from: String?; var to: String?; var file: String? }
        var changes: [Change] = []
        for edit in planned {
            guard let s = notes.first(where: { $0.id == edit.noteId }) else { continue }
            var file: String?
            if !dryRun {
                let r = try editNote(vault, edit.noteId) { state in
                    NoteOps.renameNotebook(old, to: target, notebooks: [edit.noteId: state.meta.notebook]).first?.ops ?? []
                }
                guard let r else { continue }
                file = r.name.filename
            }
            changes.append(Change(note: edit.noteId.uuidString.lowercased(), title: s.title, from: s.notebook,
                                  to: NotebookPath.renamed(s.notebook, from: old, to: target), file: file))
        }
        if output.json {
            struct Out: Encodable { var from: String; var to: String?; var dryRun: Bool; var notes: [Change] }
            try output.emitJSON(Out(from: NotebookPath.canonical(old) ?? old, to: target, dryRun: dryRun, notes: changes))
            return
        }
        if changes.isEmpty { output.info("No note is in \(old)."); return }
        for c in changes {
            output.info("\(dryRun ? "would move" : "moved") \(c.note) \(c.title.isEmpty ? "(untitled)" : c.title): "
                        + "\(c.from ?? "-") -> \(c.to ?? "-")")
        }
    }
}

struct NotebooksMove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a notebook, with everything below it, into another notebook or to the top level.",
        discussion: """
            What dragging a notebook onto another one does in the app: NOTEBOOK keeps its last level and
            takes PARENT as its new parent, so `notebooks move School/Math Archive` makes School/Math
            Archive/Math, notes below it included (every note's notebook gets the prefix replaced, deleted
            ones too: one setMeta notebook delta per note, as `notebooks rename`). "" or --top-level moves
            it to the top level. Moving into itself or a notebook inside it is refused, and a
            notebook that already has that name at the destination is merged with it. Nothing is written
            when any note cannot be read (exit 1). --dry-run lists the notes that would move.
            """
    )

    @Argument(help: ArgumentHelp("The notebook to move.", valueName: "notebook"))
    var notebook: String

    @Argument(help: ArgumentHelp("The new parent notebook; \"\" for the top level.", valueName: "parent"))
    var parent: String?

    @Flag(name: .customLong("top-level"), help: "Move the notebook to the top level.")
    var topLevel = false

    @Flag(name: .customLong("dry-run"), help: "Only list the notes that would change.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if NotebookPath.canonical(notebook) == nil { throw ValidationError("the notebook name is empty") }
        if topLevel == (parent != nil) { throw ValidationError("give a parent notebook (\"\" for none) or --top-level") }
    }

    func run() throws {
        let from = NotebookPath.canonical(notebook) ?? notebook
        guard let target = NotebookPath.moved(from, into: topLevel ? nil : parent) else {
            throw CLIError.usage("cannot move \(from) into itself or into a notebook inside it")
        }
        let vault = try access.openVault(.required)
        try NotebooksRename.perform(vault, old: from, to: target, dryRun: dryRun, output: output)
    }
}

// MARK: - tags

struct TagsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tags",
        abstract: "List the vault's tags.",
        subcommands: [TagsList.self]
    )
}

struct TagsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tags with how many notes carry each.",
        discussion: """
            Tags match case-insensitively; each is shown once, in the first spelling found (as the app's
            sidebar). Deleted notes do not count.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let notes = try vault.summaries(of: nil, cache: cache.cache(for: vault)).filter { !$0.deleted }
        struct Row: Encodable { var tag: String; var notes: Int }
        let rows = NoteOps.vaultTags(notes).map { tag in
            Row(tag: tag, notes: notes.filter { $0.tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(tag) } }.count)
        }
        if output.json { try output.emitJSON(rows); return }
        if rows.isEmpty { output.info("No tags."); return }
        var table = output.quiet ? [] : [["TAG", "NOTES"]]
        for r in rows { table.append([r.tag, String(r.notes)]) }
        print(Format.table(table))
    }
}

// MARK: - pages

struct PagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pages",
        abstract: "List, add, move, delete and duplicate a note's pages.",
        subcommands: [PagesList.self, PagesAdd.self, PagesMove.self, PagesDelete.self, PagesDuplicate.self]
    )
}

struct PagesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a note's pages: number, id, strokes, paper, recognised text.",
        discussion: "PAPER is the page's own paper, or the note's (marked *) when the page follows it."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let state = try vault.reconstruct(try vault.loadNote(id, detail: .withoutStrokePoints))
        struct PageRow: Encodable {
            var page: Int; var id: String; var strokes: Int; var paper: Paper?; var recognized: Bool
        }
        let rows = state.pages.enumerated().map { i, p in
            PageRow(page: i + 1, id: p.id.uuidString.lowercased(), strokes: p.strokes.count, paper: p.paper,
                    recognized: !(p.recognition?.text.isEmpty ?? true))
        }
        if output.json {
            struct Out: Encodable { var note: String; var paper: Paper; var pageSize: PageSize; var pages: [PageRow] }
            try output.emitJSON(Out(note: id.uuidString.lowercased(), paper: state.meta.paper,
                                    pageSize: state.meta.pageSize, pages: rows))
            return
        }
        var table = output.quiet ? [] : [["PAGE", "ID", "STROKES", "PAPER", "TEXT"]]
        for r in rows {
            table.append([String(r.page), r.id, String(r.strokes),
                          r.paper.map(\.kind.title) ?? state.meta.paper.kind.title + " *", r.recognized ? "yes" : "-"])
        }
        print(Format.table(table))
    }
}

struct PagesAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add blank pages to a note (one delta).",
        discussion: """
            The pages go after the last page, or after page N with --after (0: before the first), and
            follow the note's paper, as the app's Add Page.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("How many pages (1-100).", valueName: "n"))
    var count = 1

    @Option(name: .long, help: ArgumentHelp("Insert after this page (1-based; 0: first).", valueName: "page"))
    var after: Int?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if !(1...100).contains(count) { throw ValidationError("--count must be between 1 and 100") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let after = after ?? state.pages.count
            guard (0...state.pages.count).contains(after) else {
                throw CLIError.failure("--after must be between 0 and \(state.pages.count)")
            }
            var pages = state.pages, ops: [Op] = []
            for k in 0..<count {
                let edit = NoteOps.addPage(at: after + k, in: pages)
                ops += edit.ops
                pages = edit.pages
            }
            return ops
        }
        try reportEdit(vault, id, r, output: output, done: "Added \(count) page(s)", unchanged: "No page added.")
    }
}

/// Throws for a deleted note: like the app, page edits need it restored first.
func requireLive(_ state: NoteState) throws {
    guard !state.deleted else { throw CLIError.failure("the note is deleted: run `sempere notes undelete` first") }
}

/// The page with 1-based number `number` in `state` (display order).
func pageNumbered(_ number: Int, of state: NoteState) throws -> Page {
    guard state.pages.indices.contains(number - 1) else {
        throw CLIError.failure("no page \(number): the note has \(state.pages.count) page(s)")
    }
    return state.pages[number - 1]
}

struct PagesMove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a page to another position (one setPageOrder delta).",
        discussion: """
            Page numbers are 1-based, as `pages list` prints them. The page ends up at position
            --to; other pages get new order keys only when none fits between its new neighbours
            (format.md §5.4.3).
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The page to move.", valueName: "page"))
    var number: Int

    @Option(name: .long, help: ArgumentHelp("Its new position (1-based).", valueName: "page"))
    var to: Int

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let moving = try pageNumbered(number, of: state)
            guard (1...state.pages.count).contains(to) else {
                throw CLIError.failure("--to must be between 1 and \(state.pages.count)")
            }
            return NoteOps.movePage(moving.id, to: to - 1, in: state.pages)?.ops ?? []
        }
        try reportEdit(vault, id, r, output: output, done: "Moved page \(number) to \(to)",
                       unchanged: "The page is already there.")
    }
}

struct PagesDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a page and its ink (one removePage delta).",
        discussion: """
            The last page of a note is never deleted. A removed page id never comes back (format.md
            §5.2); `notes restore --to` rolls the note back to before the delete.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The page to delete (1-based).", valueName: "page"))
    var number: Int

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let gone = try pageNumbered(number, of: state)
            guard state.pages.count > 1 else { throw CLIError.failure("a note keeps at least one page") }
            return NoteOps.deletePage(gone.id, in: state.pages)?.ops ?? []
        }
        try reportEdit(vault, id, r, output: output, done: "Deleted page \(number)", unchanged: "No page deleted.")
    }
}

struct PagesDuplicate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Copy a page, its ink, items, paper and recognised text, right after it (one delta).",
        discussion: "The copies get new ids (format.md §5.4.3), as the app's Duplicate Page."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The page to copy (1-based).", valueName: "page"))
    var number: Int

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            return NoteOps.duplicatePage(try pageNumbered(number, of: state).id, in: state.pages)?.ops ?? []
        }
        try reportEdit(vault, id, r, output: output, done: "Duplicated page \(number)", unchanged: "No page copied.")
    }
}
