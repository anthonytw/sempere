import ArgumentParser
import Foundation
import SempereImport
import SempereRender
import Sempere

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import notes from other apps.",
        subcommands: ImportRegistry.commands + [ImportPDFCommand.self]
    )
}

// MARK: - import pdf

struct ImportPDFCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Make a note from each PDF: one page per PDF page, the page as its background.",
        discussion: """
            The PDF is stored as one blob of the new note and each page becomes a note page with a pdfPage \
            item that fills it (docs/attachments.md §8): the note's page size is the first PDF page's \
            (effective size: crop box, rotation), paper is blank, later pages of another size are fitted and \
            centred. Everything is one delta. The title is --title (one file only) or the file name without \
            .pdf. Encrypted PDFs are refused, and so are more than 2000 pages; --pages imports a subset. \
            Each page's text is stored for search (--pdf-text: pdftotext when installed, else the built-in \
            reader; format.md §8.2.6). Writing on the pages is the app's job: ink is stored as usual on top. \
            Exit 1 if any file failed.
            """
    )

    @Argument(help: ArgumentHelp("PDF files.", valueName: "file"))
    var files: [String]

    @Option(name: .long, help: ArgumentHelp("Title of the note (a single file only; default: the file name).", valueName: "title"))
    var title: String?

    @Option(name: .long, help: ArgumentHelp("Put the note in this notebook (School/Math for levels).", valueName: "path"))
    var notebook: String?

    @Option(name: .customLong("tag"), help: ArgumentHelp("Add this tag. Repeatable.", valueName: "tag"))
    var tags: [String] = []

    @Option(name: .long, help: ArgumentHelp("Import only these PDF pages: 1-3,5,7- (default all).", valueName: "list"))
    var pages: PageSelection?

    @Flag(name: .customLong("dry-run"), help: "Check the files and say what would be imported; write nothing.")
    var dryRun = false

    @OptionGroup var pdfText: PDFTextOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func validate() throws {
        if files.isEmpty { throw ValidationError("give at least one PDF file") }
        if title != nil && files.count > 1 { throw ValidationError("--title names one note: give one file, or no --title") }
    }

    struct Result: Encodable {
        var source: String
        var status: String
        var reason: String?
        var id: String?
        var title: String?
        var pages: Int?
        var blob: BlobRef?
        var file: String?
        /// Pages stored with their text (`pageText`, format.md §8.2.6) and the extractor.
        var pagesWithText: Int?
        var textEngine: String?
    }

    func run() throws {
        let vault = try access.openVault(.required)
        if !dryRun { try vault.requireWritable() }   // format.md §7.3: exit 7, not a failure per file
        let extractor = try pdfText.extractor()
        let known = NoteOps.normalizedTags(tags).isEmpty
            ? [] : NoteOps.vaultTags(try vault.summaries(of: nil, cache: cache.cache(for: vault)))
        let spelled = tags.map { NoteOps.tagSpelling($0, among: known) }
        var results: [Result] = []
        for path in files {
            var r = Result(source: path, status: dryRun ? "would import" : "imported")
            do {
                let data: Data
                do { data = try BoundedRead.contents(of: URL(fileURLWithPath: path), maxBytes: 1 << 30) } catch VaultError.fileTooLarge {
                    throw CLIError.failure("\(path) is larger than the 1 GiB limit")
                }
                let summary = try PDFIngest.inspect(data)
                var selected = try pages.map { try summary.pages(numbered: try $0.resolve(total: summary.pages.count)) } ?? summary.pages
                guard !selected.isEmpty else { throw CLIError.failure("no PDF pages selected") }
                let texts = PDFIngest.withText(selected, pdf: data, extractor: extractor)
                if texts.failed { printStderr("warning: \(extractor?.engine ?? "the extractor") could not read the text of \(path)") }
                selected = texts.refs
                r.pagesWithText = texts.withText
                r.textEngine = extractor?.engine
                let name = (title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ref = BlobRef(content: data, type: "application/pdf")
                let note = UUID()
                let ops = try NoteOps.newPDFNote(title: name, blob: ref, selected, notebook: NotebookPath.canonical(notebook), tags: spelled)
                r.id = note.uuidString.lowercased(); r.title = name; r.pages = selected.count; r.blob = ref
                if !dryRun {
                    _ = try vault.writeBlob(note: note, data, type: "application/pdf")
                    r.file = try vault.apply(ops, to: note, deviceState: DeviceState.defaultURL(), app: appName).name.filename
                }
            } catch {
                var e = CLIError.from(error)
                if let pdf = error as? PDFIngestError { e = .failure("\(pdf)") }
                if let ops = error as? AttachmentOpsError { e = .failure("\(ops)") }
                r.status = "failed"; r.reason = e.message
                r.id = nil
            }
            results.append(r)
        }
        let failed = results.filter { $0.status == "failed" }.count
        if output.json {
            struct Out: Encodable { var dryRun: Bool; var imported: Int; var failed: Int; var notes: [Result] }
            try output.emitJSON(Out(dryRun: dryRun, imported: results.count - failed, failed: failed, notes: results))
        } else {
            for r in results {
                if let id = r.id, output.quiet { print(id); continue }
                if r.status == "failed" { printStderr("failed \(r.source): \(r.reason ?? "")"); continue }
                print(r.id ?? "")
                output.info("\(dryRun ? "Would import" : "Imported") \(r.source): \(r.pages ?? 0) page(s) as \"\(r.title ?? "")\"")
            }
        }
        if failed > 0 { throw CLIError.failure("\(failed) file(s) failed to import") }
    }
}
