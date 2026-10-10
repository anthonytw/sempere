import ArgumentParser
import Foundation
import Sempere
import SempereRender

struct SearchHit: Encodable {
    var noteId: String
    var title: String
    var notebook: String?
    /// 1-based; absent for a transcript hit.
    var page: Int?
    var pageId: String?
    var snippet: String
    var matches: Int
    /// `handwriting` (page recognition), `text` (a text box), `pdf` (a PDF page's text,
    /// format.md §8.2.6) or `transcript` (a recording's).
    var source: String
    /// The recogniser's or extractor's name (`handwriting`, `pdf` and `transcript` hits; absent for a text box).
    var engine: String?
    /// The recognised words containing the term (`handwriting` hits only; empty otherwise).
    var words: [Word]
    /// With `--show-boxes`: every matching word on the page (`handwriting` hits), numbered as the app steps through them.
    var locations: [Location]?
    /// The text box or PDF page item (`text` and `pdf` hits).
    var itemId: String?
    /// Its frame `[x, y, w, h]`.
    var box: [Double]?
    /// The recording and the segment's time in seconds (`transcript` hits).
    var recordingId: String?
    var recordingTitle: String?
    var start: Double?
    var end: Double?
    /// The page of the PDF, 1-based (`pdf` hits).
    var pdfPage: Int?

    struct Word: Encodable { var text: String; var box: [Double] }
    struct Location: Encodable {
        /// 1-based position among all matches in the note (pages in order), as in "3 of 12".
        var n: Int
        /// How many matches the note has.
        var of: Int
        var text: String
        /// `[x, y, w, h]` in page points.
        var box: [Double]
        /// The text box the match is in (a `text` hit's); absent for recognised handwriting.
        var itemId: String?
    }

    /// Where the hit is, for the table: `p3`, `p3 text` or `rec 12:03`.
    var place: String {
        if let page {
            switch source {
            case "text": return "p\(page) text"
            case "math": return "p\(page) math"
            case "pdf": return "p\(page) pdf" + (pdfPage.map { " p\($0)" } ?? "")
            default: return "p\(page)"
            }
        }
        // A transcript's times are only checked to be ordered and ≥ 0 (format.md §8.3.2):
        // anything past a million hours is shown as unknown, never converted (Int(1e300) traps).
        let time = start.flatMap { $0.isFinite && $0 >= 0 && $0 < 3.6e9 ? Int($0) : nil }
            .map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "?:??"
        return "rec \(time)" + (recordingTitle.map { " \($0)" } ?? "")
    }
}

struct SearchCommand: ParsableCommand {
    /// Where the words fall inside text boxes, laid out by the CLI's shaper (`--show-boxes`).
    static let textBoxes: TextBoxMatcher = { words, item in
        TextMatchBoxes.boxes(of: words, in: item, shaper: cliTextShaper)
    }

    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the recognised handwriting, typed text, equations, PDF page text and (with --transcripts) transcripts of all notes.",
        discussion: """
            Case-insensitive substring search over each page's recognised text (from the Notability
            import or on-device recognition), over the text of every text box, the LaTeX source of every
            equation (format.md §8.2.8; hits say "p3 math") and over the stored text of
            every PDF page (format.md §8.2.6; hits say "p3 pdf p7": note page 3, PDF page 7). With --transcripts it
            also searches the transcript of each recording (this decrypts each transcript blob, so it is
            slower). Prints note title, where (p3, p3 text, rec 12:03) and a snippet; --json adds ids,
            the source of each hit, the item and the boxes of the matching words. --show-boxes lists every matching
            word with its box and its number among the note's matches (across pages: the app's "3 of 12");
            with --json it adds `locations` to each handwriting hit. Deleted notes are skipped.
            """
    )

    @Argument(help: ArgumentHelp("Text to look for.", valueName: "term"))
    var term: String

    @Flag(name: .customLong("show-boxes"), help: "Report where each match is: its word, box and number in the note.")
    var showBoxes = false

    @Flag(name: .long, help: "Also search the transcripts of recordings (decrypts each transcript).")
    var transcripts = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("the search term is empty") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        var hits: [SearchHit] = []
        var unreadable = 0
        var transcriptProblems = 0
        let ids = try vault.noteIDs()
        for (id, result) in zip(ids, vault.states(of: ids, detail: .withoutStrokePoints)) {
            let state: NoteState
            let title: String
            switch result {
            case .success(let s): state = s
            case .failure(let error):
                unreadable += 1
                printStderr("warning: cannot read note \(id.uuidString.lowercased()): \(CLIError.from(error).message)")
                continue
            }
            guard !state.deleted else { continue }
            title = state.meta.title
            let noteId = id.uuidString.lowercased()
            let located = showBoxes ? SearchMatches.matches(needle, in: state.pages, textBoxes: Self.textBoxes) : []
            for (index, page) in state.pages.enumerated() {
                let pageId = page.id.uuidString.lowercased()
                if let rec = page.recognition {
                    let found = RecognitionSearch.ranges(of: needle, in: rec.text)
                    if let first = found.first {
                        let words = rec.words.filter { w in
                            tokens.contains { w.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                        }
                        let locations: [SearchHit.Location]? = showBoxes
                            ? located.enumerated().filter { $0.element.pageId == page.id && $0.element.item == nil }.map {
                                .init(n: $0.offset + 1, of: located.count, text: $0.element.text,
                                      box: [$0.element.box.x, $0.element.box.y, $0.element.box.w, $0.element.box.h])
                            } : nil
                        hits.append(SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: index + 1,
                                              pageId: pageId, snippet: RecognitionSearch.snippet(rec.text, around: first),
                                              matches: found.count, source: "handwriting", engine: rec.engine,
                                              words: words.map { .init(text: $0.text, box: [$0.box.x, $0.box.y, $0.box.w, $0.box.h]) },
                                              locations: locations))
                    }
                }
                for item in page.items where item.kind == .pdfPage {
                    guard let pageText = item.pageText else { continue }
                    let found = RecognitionSearch.ranges(of: needle, in: pageText.text)
                    guard let first = found.first else { continue }
                    var hit = SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: index + 1,
                                        pageId: pageId, snippet: RecognitionSearch.snippet(pageText.text, around: first),
                                        matches: found.count, source: "pdf", engine: pageText.engine, words: [],
                                        itemId: item.id.uuidString.lowercased(),
                                        box: [item.frame.x, item.frame.y, item.frame.w, item.frame.h])
                    hit.pdfPage = item.pageIndex.map { $0 + 1 }
                    hits.append(hit)
                }
                for item in page.items where item.kind == .math {
                    guard let latex = item.math?.latex else { continue }
                    let found = RecognitionSearch.ranges(of: needle, in: latex)
                    guard let first = found.first else { continue }
                    hits.append(SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: index + 1,
                                          pageId: pageId, snippet: RecognitionSearch.snippet(latex, around: first),
                                          matches: found.count, source: "math", engine: nil, words: [],
                                          itemId: item.id.uuidString.lowercased(),
                                          box: [item.frame.x, item.frame.y, item.frame.w, item.frame.h]))
                }
                for item in page.items where item.kind == .text {
                    guard let text = item.text.map(MarkdownText.searchText) else { continue }
                    let found = RecognitionSearch.ranges(of: needle, in: text)
                    guard let first = found.first else { continue }
                    var hit = SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: index + 1,
                                        pageId: pageId, snippet: RecognitionSearch.snippet(text, around: first),
                                        matches: found.count, source: "text", engine: nil, words: [],
                                        itemId: item.id.uuidString.lowercased(),
                                        box: [item.frame.x, item.frame.y, item.frame.w, item.frame.h])
                    if showBoxes {
                        // The words inside the box (laid out like an export), numbered among all the note's matches.
                        hit.locations = located.enumerated().filter { $0.element.item == item.id }.map {
                            .init(n: $0.offset + 1, of: located.count, text: $0.element.text,
                                  box: [$0.element.box.x, $0.element.box.y, $0.element.box.w, $0.element.box.h],
                                  itemId: item.id.uuidString.lowercased())
                        }
                    }
                    hits.append(hit)
                }
            }
            if transcripts {
                for recording in state.recordings {
                    guard let ref = recording.transcript else { continue }
                    let transcript: Transcript
                    do {
                        transcript = try Transcript.decode(try vault.readBlob(note: id, ref, maxBytes: Transcript.maxSize))
                        guard transcript.recording == recording.id else {
                            throw CLIError.failure("it names another recording")
                        }
                    } catch {
                        transcriptProblems += 1
                        printStderr("warning: cannot read the transcript of recording \(recording.id.uuidString.lowercased()) in note \(noteId): \(CLIError.from(error).message)")
                        continue
                    }
                    for t in TranscriptSearch.hits(of: needle, in: transcript, recording: recording.id,
                                                   title: recording.title) {
                        hits.append(SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: nil, pageId: nil,
                                              snippet: t.snippet, matches: t.matches,
                                              source: "transcript", engine: t.engine, words: [],
                                              recordingId: recording.id.uuidString.lowercased(), recordingTitle: recording.title,
                                              start: t.start, end: t.end))
                    }
                }
            }
        }
        hits.sort {
            ($0.title.lowercased(), $0.noteId, $0.page ?? Int.max, $0.start ?? 0, $0.source)
                < ($1.title.lowercased(), $1.noteId, $1.page ?? Int.max, $1.start ?? 0, $1.source)
        }
        if output.json {
            try output.emitJSON(hits)
        } else if hits.isEmpty {
            output.info("No matches.")
        } else {
            var rows = output.quiet ? [] : [["TITLE", "WHERE", "TEXT"]]
            for h in hits { rows.append([h.title.isEmpty ? "(untitled)" : h.title, h.place, h.snippet]) }
            print(Format.table(rows))
            if showBoxes {
                for h in hits {
                    for l in h.locations ?? [] {
                        let box = l.box.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                        print("  \(h.noteId.prefix(8)) p.\(h.page ?? 0)  \(l.n) of \(l.of)  \(l.text)  [\(box)]")
                    }
                }
            }
        }
        if unreadable > 0 { throw CLIError.failure("\(unreadable) note(s) could not be read") }
        if transcriptProblems > 0 { throw CLIError.failure("\(transcriptProblems) transcript(s) could not be read") }
    }
}

struct NotesSearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find notes as the app's search box does: titles, tags, notebooks and recognised text, best first.",
        discussion: """
            The query is words; a note matches when every word is found somewhere in it (title,
            notebook, tags or a page's recognised handwriting and typed text), ignoring case and accents,
            substrings included. A word starting with # matches tags only. Notes are ranked as in the app
            (title and tag matches first, then the page with most of the words) and printed with the page
            and a snippet of the best match. --notebook and --tag search within one notebook (and below)
            or tag; --deleted searches Recently Deleted instead. For every occurrence of a phrase on
            every page, use `sempere search`.
            """
    )

    @Argument(help: ArgumentHelp("Words to look for.", valueName: "query"))
    var query: String

    @Option(name: .long, help: ArgumentHelp("Only notes in this notebook or below it.", valueName: "path"))
    var notebook: String?

    @Option(name: .long, help: ArgumentHelp("Only notes with this tag.", valueName: "tag"))
    var tag: String?

    @Flag(name: .long, help: "Search deleted notes (Recently Deleted) instead.")
    var deleted = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func validate() throws {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("the query is empty") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let notes = try vault.summaries(of: nil, cache: cache.cache(for: vault)).filter { n in
            n.deleted == deleted
                && (notebook.map { NotebookPath.name(n.notebook, isWithin: $0) } ?? true)
                && (tag.map { t in n.tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(t) } } ?? true)
        }
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hits = NoteSearch.search(query, in: notes)
        let fieldNames: [NoteSearchHit.Field: String] = [.title: "title", .tag: "tag", .notebook: "notebook", .text: "text"]
        if output.json {
            struct Page: Encodable { var number: Int; var id: String }
            struct Hit: Encodable {
                var note: String; var title: String; var notebook: String?; var tags: [String]; var fields: [String]
                var page: Page?; var snippet: String?; var matchedPages: Int; var score: Int
            }
            try output.emitJSON(hits.map { h in
                let s = byID[h.note]
                return Hit(note: h.note.uuidString.lowercased(), title: s?.title ?? "", notebook: s?.notebook,
                           tags: s?.tags ?? [], fields: h.fields.compactMap { fieldNames[$0] },
                           page: h.page.map { Page(number: $0.number, id: $0.pageId.uuidString.lowercased()) },
                           snippet: h.snippet?.text, matchedPages: h.matchedPages, score: h.score)
            })
            return
        }
        if hits.isEmpty { output.info("No notes found."); return }
        var rows = output.quiet ? [] : [["ID", "TITLE", "MATCH", "PAGE", "TEXT"]]
        for h in hits {
            let title = byID[h.note].map { $0.title.isEmpty ? "(untitled)" : $0.title } ?? ""
            rows.append([h.note.uuidString.lowercased(), title, h.fields.compactMap { fieldNames[$0] }.joined(separator: ","),
                         h.page.map { String($0.number) } ?? "-", h.snippet?.text ?? ""])
        }
        print(Format.table(rows))
    }
}
