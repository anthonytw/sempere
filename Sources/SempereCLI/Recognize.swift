import ArgumentParser
import Foundation
import Sempere
import SempereRender

/// Handwriting recognition from the command line: the app's pass
/// (`RecognitionPolicy`, `RecognitionImage`, `VisionText`), one delta of
/// `setPageRecognition` ops per note. Vision exists on Apple platforms only.
enum RecognitionRun {
    /// Whether this build can read handwriting.
    static var available: Bool {
        #if canImport(Vision)
        return true
        #else
        return false
        #endif
    }

    static let unavailable = CLIError.failure(
        "handwriting recognition needs Apple's Vision framework, so it runs only in the macOS build of sempere "
            + "(or in the app); nothing was changed")

    /// What one note's pass did.
    struct NoteResult: Encodable {
        var note: String
        var title: String
        /// Pages read (1-based), with recognised text or none.
        var read: [Int] = []
        /// Pages whose recognised text was cleared: they have no ink left.
        var cleared: [Int] = []
        /// The note's `meta.lang`, the language Vision was asked to read in (absent: automatic).
        var language: String?
        /// The delta written, a file name in the note's folder.
        var file: String?
        var error: String?
    }

    /// The recognition of one page's strokes, `basis` set to their digest:
    /// empty text when no stroke is readable (only markers), nil when the
    /// page has no strokes (its recognition is cleared).
    /// `language` is the note's `meta.lang` (format.md §5.4).
    static func recognize(_ strokes: [Stroke], language: String? = nil) throws -> Recognition? {
        guard !strokes.isEmpty else { return nil }
        #if canImport(Vision)
        var r = try VisionText.recognize(strokes: strokes, language: language)
            ?? Recognition(engine: VisionText.engine, text: "")
        r.basis = RecognitionBasis.digest(of: strokes.map(\.id))
        return r
        #else
        throw unavailable
        #endif
    }

    /// Reads the pages of note `id` that `mode` selects and writes what it
    /// read as one delta (nothing when no page needs it). With `dryRun` only
    /// the selection is made: nothing is read or written, and Vision is not needed.
    /// With `recordedAt` the delta also sets `meta.recognized` (format.md
    /// §5.4), which lists the note in "Recently Recognized" on every device.
    static func run(note id: UUID, vault: Vault, mode: RecognitionMode, dryRun: Bool,
                    recordedAt: Date? = nil) -> NoteResult {
        var result = NoteResult(note: id.uuidString.lowercased(), title: "")
        func record(_ state: NoteState, _ pages: [Page]) {
            result.title = state.meta.title
            for p in pages {
                guard let n = state.pages.firstIndex(where: { $0.id == p.id }).map({ $0 + 1 }) else { continue }
                if p.strokes.isEmpty { result.cleared.append(n) } else { result.read.append(n) }
            }
        }
        do {
            if dryRun {
                let state = try vault.reconstruct(try vault.loadNote(id, detail: .withoutStrokePoints))
                guard !state.deleted else { throw CLIError.failure("the note is deleted") }
                record(state, RecognitionPolicy.pagesToRead(state.pages, mode: mode))
                result.language = state.meta.lang
                return result
            }
            let r = try editNote(vault, id) { state in
                guard !state.deleted else { throw CLIError.failure("the note is deleted") }
                let pages = RecognitionPolicy.pagesToRead(state.pages, mode: mode)
                record(state, pages)
                result.language = state.meta.lang
                let ops: [Op] = try pages.map {
                    .setPageRecognition(pageId: $0.id, recognition: try recognize($0.strokes, language: state.meta.lang))
                }
                guard let at = recordedAt, !ops.isEmpty else { return ops }
                return ops + RecentlyRecognized.record(at: at, pages: state.pages.count, read: ops.count)
            }
            result.file = r?.name.filename
        } catch {
            result.error = CLIError.from(error).message
        }
        return result
    }
}

struct RecognizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recognize",
        abstract: "Read the handwriting of notes on this Mac (Vision) and store it for search and export.",
        discussion: """
            Each page is drawn black on white, cropped to its ink, and read with Apple's Vision on this
            machine; nothing leaves it. The text and word boxes are stored as the page's recognition
            (format.md §5.5), one delta per note, stamped with this machine's device id and clock.
            The same selection, image and mapping as the app's recognition.

            By default the pages read are those whose recognition is missing or out of date (ink
            changed since it was read). Recognition Notability made cannot be checked against the ink
            and is kept. --missing-only reads only pages with no recognition at all. --force reads
            every page with ink, replacing any recognition (Notability's included). A page whose ink
            is gone has its recognised text cleared. --dry-run lists the pages without reading them
            (this works on Linux too). macOS only: elsewhere the command exits 1 and changes nothing.

            Each note it writes recognition for is marked with the time of the run (format.md §5.4
            `recognized`), which lists it in the app's "Recently Recognized" on every device for 7
            days. --recent lists those notes (newest first; --days sets the window); it reads
            nothing, writes nothing and works on Linux too.
            """
    )

    @Argument(help: ArgumentHelp("Note ids or titles.", valueName: "id|title"))
    var notes: [String] = []

    @Flag(name: .long, help: "Every note that is not deleted.")
    var all = false

    @Flag(name: .customLong("missing-only"), help: "Only pages with no recognition at all.")
    var missingOnly = false

    @Flag(name: .long, help: "Every page with ink, replacing existing recognition (Notability's included).")
    var force = false

    @Flag(name: .customLong("dry-run"), help: "Only list the pages that would be read.")
    var dryRun = false

    @Flag(name: .long, help: "List the notes recognised recently (the app's Recently Recognized) instead.")
    var recent = false

    @Option(name: .long, help: ArgumentHelp("With --recent: the window in days (default 7).", valueName: "n"))
    var days: Int?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if recent {
            if all || !notes.isEmpty || missingOnly || force || dryRun {
                throw ValidationError("--recent takes no notes, --all, --missing-only, --force or --dry-run")
            }
            if let days, !(1...3650).contains(days) { throw ValidationError("--days must be 1 to 3650") }
            return
        }
        if days != nil { throw ValidationError("--days needs --recent") }
        if all == !notes.isEmpty { throw ValidationError("give note ids or titles, or --all") }
        if missingOnly && force { throw ValidationError("--missing-only and --force cannot be combined") }
    }

    var mode: RecognitionMode { force ? .all : missingOnly ? .missing : .stale }

    func run() throws {
        if recent { return try listRecent() }
        if !dryRun && !RecognitionRun.available { throw RecognitionRun.unavailable }
        let vault = try access.openVault(.required)
        if !dryRun { try vault.requireWritable() }   // format.md §7.3: exit 7, not a failure per note
        let ids: [UUID]
        if all {
            ids = try vault.summaries(of: nil).filter { !$0.deleted }.map(\.id)
        } else {
            var seen = Set<UUID>()
            ids = try notes.map { try vault.resolveNote($0) }.filter { seen.insert($0).inserted }
        }
        let now = Date()
        let results = ids.map { RecognitionRun.run(note: $0, vault: vault, mode: mode, dryRun: dryRun, recordedAt: now) }
        try report(results, output: output, dryRun: dryRun)
    }

    /// `--recent`: the notes whose `meta.recognized` is within the window, newest first.
    func listRecent() throws {
        let vault = try access.openVault(.required)
        let window = TimeInterval(days ?? 7) * 86_400
        let recent = RecentlyRecognized.notes(try vault.summaries(of: nil), now: Date(), window: window)
        if output.json {
            struct Entry: Encodable {
                var note: String; var title: String; var notebook: String?
                var at: Date; var pages: Int; var read: Int
            }
            struct Out: Encodable { var days: Int; var notes: [Entry] }
            try output.emitJSON(Out(days: days ?? 7, notes: recent.compactMap { s in
                s.recognized.map { Entry(note: s.id.uuidString.lowercased(), title: s.title, notebook: s.notebook,
                                         at: $0.at, pages: $0.pages, read: $0.read) }
            }))
            return
        }
        for s in recent {
            guard let r = s.recognized else { continue }
            let title = s.title.isEmpty ? "(untitled)" : s.title
            print("\(s.id.uuidString.lowercased())  \(RFC3339.string(from: r.at) ?? "-")  \(title): read \(r.read) of \(r.pages) page(s)")
        }
        output.info("\(recent.count) note(s) recognised in the last \(days ?? 7) day(s).")
    }
}

/// Prints recognition results (shared with `import notability --recognize`)
/// and throws when any note failed.
func report(_ results: [RecognitionRun.NoteResult], output: OutputOptions, dryRun: Bool) throws {
    if output.json {
        struct Out: Encodable { var dryRun: Bool; var notes: [RecognitionRun.NoteResult] }
        try output.emitJSON(Out(dryRun: dryRun, notes: results))
    } else {
        for r in results {
            let title = r.title.isEmpty ? "(untitled)" : r.title
            if let error = r.error {
                printStderr("failed \(r.note) \(title): \(error)")
            } else if r.read.isEmpty && r.cleared.isEmpty {
                if output.verbose { print("\(r.note) \(title): nothing to read") }
            } else {
                var parts: [String] = []
                if !r.read.isEmpty { parts.append("\(dryRun ? "would read" : "read") page(s) \(Format.pageList(r.read))") }
                if !r.cleared.isEmpty { parts.append("\(dryRun ? "would clear" : "cleared") page(s) \(Format.pageList(r.cleared))") }
                output.info("\(r.note) \(title): " + parts.joined(separator: "; "))
            }
        }
        let pages = results.reduce(0) { $0 + $1.read.count }
        output.info("\(dryRun ? "Dry run: " : "")\(pages) page(s) \(dryRun ? "would be read" : "read") in "
                    + "\(results.filter { !$0.read.isEmpty || !$0.cleared.isEmpty }.count) of \(results.count) note(s).")
    }
    let failed = results.filter { $0.error != nil }.count
    if failed > 0 { throw CLIError.failure("\(failed) note(s) could not be recognised") }
}

extension Format {
    /// `1-3, 5` for `[1, 2, 3, 5]` (sorted input).
    static func pageList(_ pages: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count, pages[j + 1] == pages[j] + 1 { j += 1 }
            parts.append(j > i ? "\(pages[i])-\(pages[j])" : "\(pages[i])")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }
}
