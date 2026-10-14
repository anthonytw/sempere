import Foundation
import Sempere

/// Which per-page images a Markdown export embeds besides the PDF.
public enum ExportImages: String, CaseIterable, Sendable {
    case none, png
}

/// The two folder-tree export formats.
public enum TreeFormat: String, CaseIterable, Sendable {
    case markdown, html
}

/// Why a tree export stopped (a note that fails to render is reported in
/// `TreeExporter.run`'s `errors`, not thrown).
public enum TreeExportError: Error, Equatable, CustomStringConvertible, Sendable {
    case cannotWrite(path: String, reason: String)

    public var description: String {
        switch self {
        case .cannotWrite(let path, let reason): return "cannot write \(path): \(reason)"
        }
    }
}

/// What a tree export (Markdown or HTML) wrote, per note.
public struct TreeResult: Sendable {
    public var noteId: String
    public var files: [String]
    public var changed: [String]
}

/// `.sempere-export-<format>.json` in the output root: which files an export
/// produced, so `--clean` removes only those and the folder indexes can list
/// notes from earlier runs.
struct ExportManifest: Codable {
    struct FileEntry: Codable {
        /// The note id, nil for an index file.
        var note: String?
        var notebook: String?
    }
    struct NoteEntry: Codable {
        var title: String
        /// File name without extension.
        var stem: String
        /// Sanitized folder components below the output root.
        var folder: [String]
        var notebook: String?
        var tags: [String]
        var pages: Int
        var modified: Date?
        /// Recognized text of the note (HTML index search only).
        var searchText: String?
        /// What the files below were made from (`TreeExporter.inputKey`); nil when the run
        /// could not tell, so the note is rendered again next time.
        var key: String?
        /// Every file written for the note (relative paths) and its size: a note whose key
        /// matches is skipped only while all of them are still there at that size.
        var outputs: [String: FileStamp]?
    }
    /// What a written file looked like: a same-size, same-time file is trusted, else its
    /// content hash (`hash`, nil for a file too large to hash: it then has to match in time) decides.
    struct FileStamp: Codable, Equatable {
        var size: Int64
        var mtime: Double
        var hash: String?
    }
    var version = 1
    var files: [String: FileEntry] = [:]
    var notes: [String: NoteEntry] = [:]

    /// A path component that stays inside its folder: not empty, not `.` or `..`,
    /// no separator or control character.
    static func isSafeComponent(_ c: String) -> Bool {
        !c.isEmpty && c != "." && c != ".." && !c.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.value < 0x20 }
    }

    /// The manifest is a file in a folder that may be shared, so it is not trusted: `--clean`
    /// deletes and the indexes write the paths it names. Entries that would leave the output
    /// folder (or are not what this exporter writes) are forgotten.
    mutating func dropUnsafeEntries() {
        files = files.filter { rel, _ in
            !rel.hasPrefix("/") && rel.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { Self.isSafeComponent(String($0)) }
        }
        notes = notes.filter { _, n in Self.isSafeComponent(n.stem) && n.folder.allSatisfy(Self.isSafeComponent) }
    }
}

/// One note of a tree export: its summary, a fingerprint of its revisions and how to read
/// it. `run` loads the state only when the note must be rendered, and drops it afterwards, so
/// memory is one note and a note that is up to date is never decoded.
public struct TreeNote: Sendable {
    public var summary: NoteSummary
    /// `BulkExportPlan.version(of:)` of the note's revision files; nil: always render.
    public var version: String?
    public var load: @Sendable () throws -> NoteState

    public init(summary: NoteSummary, version: String? = nil, load: @escaping @Sendable () throws -> NoteState) {
        self.summary = summary; self.version = version; self.load = load
    }
}

/// A 64-bit FNV-1a fingerprint over strings (not a security hash).
struct InputKey {
    private var h: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add(_ s: String) {
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        h = (h ^ 0x1F) &* 0x100_0000_01b3
    }
    mutating func add(_ data: Data) {
        for b in data { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    }
    mutating func add(_ v: some CustomStringConvertible) { add(v.description) }
    var hex: String { String(h, radix: 16) }
}

/// Writes notes as a folder tree: Markdown (`.md` + PDF [+ PNG pages] + a
/// `README.md` per folder) or HTML (one file per note + `index.html`).
/// Re-running rewrites only files whose content changed.
///
/// `run` is synchronous and blocking: call it off the main actor. It checks
/// `Task.checkCancellation()` before each note, so canceling the task that
/// runs it stops the export between notes (files already written stay).
public struct TreeExporter: Sendable {
    public var root: URL
    public var format: TreeFormat
    public var images: ExportImages
    /// Markdown only: write each note's PDF next to its `.md` and embed it
    /// (the CLI always does; the app's "Text (Markdown)" export makes it optional).
    public var pdf: Bool
    public var options: RenderOptions
    public var png: PNGOptions
    public var source: String
    public var clean: Bool
    public var notebookFilter: String?
    /// How a note's failure is worded in `run`'s `errors`.
    public var errorText: @Sendable (Error) -> String
    /// Each note's blobs (images); nil draws blob-backed items as placeholders.
    public var blobs: BlobSources?
    /// What the options cannot show about the environment that draws the notes (the program
    /// version, the fonts and PDF renderer available). It is part of every note's input key,
    /// so changing it renders every note again. nil: notes are never skipped as up to date.
    public var environment: String?
    /// Called once per rendered note with its placeholders and warnings.
    public var onReport: (@Sendable (UUID, RenderReport) -> Void)?

    public init(root: URL, format: TreeFormat, images: ExportImages = .none, pdf: Bool = true,
                options: RenderOptions = RenderOptions(),
                png: PNGOptions = PNGOptions(), source: String, clean: Bool = false, notebookFilter: String? = nil,
                errorText: @escaping @Sendable (Error) -> String = { "\($0)" }) {
        self.root = root; self.format = format; self.images = images; self.pdf = pdf; self.options = options; self.png = png
        self.source = source; self.clean = clean; self.notebookFilter = notebookFilter; self.errorText = errorText
    }

    private var manifestURL: URL { root.appendingPathComponent(".sempere-export-\(format.rawValue).json") }

    /// The largest export manifest read back (one entry per note and file).
    static let maxManifestBytes = 256 << 20

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        // The output folder may be synced or shared (format.md §9): its manifest
        // is read like format JSON (RFC 3339 dates), never Foundation's ISO 8601 parser.
        return (e, InkJSON.decoder())
    }

    /// True when both files exist and hold the same bytes (compared 1 MB at a time).
    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sa = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? NSNumber,
              let sb = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? NSNumber, sa == sb,
              let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        do {
            while true {
                // nil at the end of the file.
                let x = try ha.read(upToCount: 1 << 20) ?? Data(), y = try hb.read(upToCount: 1 << 20) ?? Data()
                guard x == y else { return false }
                if x.isEmpty { return true }
            }
        } catch {
            return false
        }
    }

    /// Folder components for each notebook: segments sanitized, and names
    /// that differ only by case share one spelling (the smallest), so a
    /// case-insensitive file system cannot merge two folders by accident.
    public static func folders(for notebooks: [String?]) -> [String?: [String]] {
        func sanitized(_ nb: String?) -> [String] {
            NotebookPath.components(nb).map { ExportName.folderComponent($0) }
        }
        var spelling: [String: String] = [:]
        for nb in Set(notebooks) {
            var key = ""
            for part in sanitized(nb) {
                key += "/" + part.lowercased()
                if let old = spelling[key] { spelling[key] = min(old, part) } else { spelling[key] = part }
            }
        }
        var out: [String?: [String]] = [:]
        for nb in Set(notebooks) {
            var key = "", parts: [String] = []
            for part in sanitized(nb) {
                key += "/" + part.lowercased()
                parts.append(spelling[key] ?? part)
            }
            out[nb] = parts
        }
        return out
    }

    private func inScope(_ notebook: String?) -> Bool {
        guard let f = notebookFilter else { return true }
        return NotebookPath.name(notebook, isWithin: f)
    }

    /// The key a note's files are valid for: everything the output depends on that is known
    /// before the note is read. nil when the run cannot tell (no `environment`, no version, or
    /// blobs that cannot describe themselves).
    func inputKey(_ note: TreeNote, prefix: String, vaultSource: String, blobs: (any BlobSource)?) -> String? {
        guard let environment, let version = note.version else { return nil }
        var token = "none"
        if let blobs {
            guard let t = blobs.contentToken else { return nil }
            token = t
        }
        let s = note.summary, o = options
        var k = InputKey()
        for part: String in ["tree-1", "render-\(RenderOutputVersion.current)", format.rawValue, images.rawValue, "\(pdf)", "\(png.scale)", "\(png.maxPixels)",
                             "\(o.paper)", "\(o.compress)", "\(o.tolerance)", "\(o.infiniteChunkHeight.map { "\($0)" } ?? "-")",
                             o.breaks.rawValue, "\(o.rasterScale)", "\(o.maxBackgroundPixels)", "\(o.keepImageMetadata)",
                             "\(o.maxImagePixels)", "\(o.embedRecordings)", "\(o.listAttachments)", "\(o.maxEmbeddedBytes)",
                             "\(o.shaper != nil)", "\(o.pdfRasterizer != nil)", "\(o.imageDecoder != nil)",
                             environment, version, token, prefix, vaultSource,
                             s.title, s.tags.joined(separator: "\u{1}"), s.notebook ?? "-", "\(s.favorite)",
                             s.created.map { "\($0.timeIntervalSince1970)" } ?? "-",
                             s.modified.map { "\($0.timeIntervalSince1970)" } ?? "-", "\(s.pages)"] {
            k.add(part)
        }
        return k.hex
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func hash(_ data: Data) -> String {
        var k = InputKey()
        k.add(data)
        return k.hex
    }

    /// The stamp of the file at `url`; `data` (what was just written) gives the hash.
    /// Largest output file whose content hash is kept (bigger ones are trusted on size and time only).
    static let stampHashLimit = 256 << 20

    static func stamp(_ url: URL, data: Data?) -> ExportManifest.FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.int64Value else { return nil }
        let t = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return .init(size: size, mtime: t, hash: data.map(hash))
    }

    /// True when the file still is what `stamp` says: same size and time, or the same content.
    static func matches(_ url: URL, _ stamp: ExportManifest.FileStamp) -> Bool {
        guard let now = Self.stamp(url, data: nil), now.size == stamp.size else { return false }
        if now.mtime == stamp.mtime { return true }
        guard let want = stamp.hash, let data = try? BoundedRead.contents(of: url, maxBytes: Int(stamp.size) + 1) else { return false }
        return hash(data) == want
    }

    /// The result for a note whose recorded files (relative paths and sizes, from an untrusted
    /// manifest) all belong to it and are still there at that size; nil otherwise.
    static func upToDate(_ outputs: [String: ExportManifest.FileStamp], note id: String, root: URL, files: [String: ExportManifest.FileEntry]) -> TreeResult? {
        guard !outputs.isEmpty else { return nil }
        var result = TreeResult(noteId: id, files: [], changed: [])
        for rel in outputs.keys.sorted() {
            guard files[rel]?.note == id, let stamp = outputs[rel], matches(root.appendingPathComponent(rel), stamp) else { return nil }
            result.files.append(root.appendingPathComponent(rel).path)
        }
        return result
    }

    /// Exports `notes` already in memory (see `run(_:[TreeNote]…)`, which reads one at a time).
    public func run(_ notes: [(NoteSummary, NoteState)], protected: Set<String>, vaultSource: String,
                    onNote: (Int, Int) -> Void = { _, _ in }, onFile: (String, Bool) -> Void = { _, _ in }) throws -> (results: [TreeResult], failures: Int, errors: [String]) {
        try run(notes.map { s, state in
            // The summary names what the state holds, so folders and names come out the same.
            var s = s
            s.title = state.meta.title; s.tags = state.meta.tags; s.notebook = state.meta.notebook
            s.favorite = state.meta.favorite; s.created = state.meta.created; s.pages = state.pages.count
            return TreeNote(summary: s, version: nil, load: { state })
        }, protected: protected, vaultSource: vaultSource, onNote: onNote, onFile: onFile)
    }

    /// Exports `notes`; `protected` are note ids that failed earlier in this run and must survive `--clean`.
    /// Each note is read with its `load` right before it is rendered and released after, and a note
    /// whose files are all still there from a run with the same input key (`TreeNote.version`,
    /// the options, the blobs and `environment`) is neither read nor rendered: its files count as
    /// this run's (so `--clean` keeps them) and are reported unchanged.
    /// `onNote(done, total)` is called before each note starts (with notes finished so far) and once at the end;
    /// `onFile(path, changed)` after each file.
    public func run(_ notes: [TreeNote], protected: Set<String>, vaultSource: String,
                    onNote: (Int, Int) -> Void = { _, _ in }, onFile: (String, Bool) -> Void = { _, _ in }) throws -> (results: [TreeResult], failures: Int, errors: [String]) {
        let fm = FileManager.default
        // Plaintext: folders and files this run creates are the owner's only (an existing folder keeps its mode).
        try FileIO.createPrivateDirectory(root)
        let (enc, dec) = Self.coder()
        var manifest = (try? dec.decode(ExportManifest.self,
                                        from: BoundedRead.contents(of: manifestURL, maxBytes: Self.maxManifestBytes)))
            ?? ExportManifest()
        manifest.dropUnsafeEntries()
        let folderMap = Self.folders(for: notes.map { NotebookPath.canonical($0.summary.notebook) })
        var runFiles = Set<String>()
        var results: [TreeResult] = [], errors: [String] = []
        var failures = 0
        var failedIDs = protected

        /// Writes `data` unless the file already holds exactly that.
        func put(_ rel: String, _ data: Data) throws -> Bool {
            let url = root.appendingPathComponent(rel)
            if let old = try? BoundedRead.contents(of: url, maxBytes: data.count), old == data { return false }
            try FileIO.createPrivateDirectory(url.deletingLastPathComponent())
            do { try FileIO.writePrivate(data, to: url) } catch {
                throw TreeExportError.cannotWrite(path: url.path, reason: error.localizedDescription)
            }
            return true
        }
        /// Writes the PDF `body` renders into a file, unless the file already holds exactly that: streamed to a
        /// temporary name next to it (embedded content is never held in memory), compared, then moved into place.
        func putPDF(_ rel: String, _ body: (URL) throws -> Void) throws -> Bool {
            let url = root.appendingPathComponent(rel)
            try FileIO.createPrivateDirectory(url.deletingLastPathComponent())
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: tmp) }
            do { try body(tmp) } catch let e as RenderError {
                guard case .cannotWrite = e else { throw e }
                throw TreeExportError.cannotWrite(path: url.path, reason: e.localizedDescription)
            }
            if Self.sameContents(url, tmp) { return false }
            do {
                if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
            } catch {
                throw TreeExportError.cannotWrite(path: url.path, reason: error.localizedDescription)
            }
            return true
        }

        for (n, note) in notes.enumerated() {
            try Task.checkCancellation()
            onNote(n, notes.count)
            let s = note.summary
            let id = s.id.uuidString.lowercased()
            let folder = folderMap[NotebookPath.canonical(s.notebook)] ?? []
            var stem = ExportName.stem(title: s.title, noteId: s.id)
            if format == .markdown {
                // `[`, `]`, `#` and `^` break Obsidian's [[wikilinks]].
                stem = String(stem.map { "[]#^".contains($0) ? "-" : $0 })
            }
            let prefix = (folder + [stem]).joined(separator: "/")
            let noteBlobs = blobs?(s.id)
            let key = inputKey(note, prefix: prefix, vaultSource: vaultSource, blobs: noteBlobs)
            if let key, let old = manifest.notes[id], old.key == key, let outputs = old.outputs,
               let result = Self.upToDate(outputs, note: id, root: root, files: manifest.files) {
                for rel in outputs.keys.sorted() {
                    runFiles.insert(rel)
                    onFile(root.appendingPathComponent(rel).path, false)
                }
                results.append(result)
                continue
            }
            var report = RenderReport()
            defer { if !report.placeholders.isEmpty || !report.warnings.isEmpty { onReport?(s.id, report) } }
            // Files are written as soon as they are made (one page image in memory, not the note's) and
            // recorded once the note is done; `changed` is whether the file's content changed.
            var outputs: [(rel: String, changed: Bool)] = []
            func output(_ rel: String, _ data: Data) throws { outputs.append((rel, try put(rel, data))) }
            do {
                let state = try note.load()
                let info = ExportNoteInfo(id: s.id, title: state.meta.title, tags: state.meta.tags,
                                          notebook: state.meta.notebook, favorite: state.meta.favorite,
                                          created: state.meta.created, modified: s.modified, pages: state.pages.count,
                                          source: vaultSource)
                var options = self.options
                if let b = noteBlobs { options.blobs = b }
                var searchText: String?
                // Clips are written next to the note and linked, never embedded in its PDF.
                options.embedVideos = false
                let clips = options.blobs == nil ? [] : ExportVideos.clips(of: state)
                let videoLinks = clips.map { (clip: $0, path: stem + "-assets/" + $0.fileName) }
                switch format {
                case .markdown:
                    if pdf {
                        let rel = prefix + ".pdf"
                        outputs.append((rel, try putPDF(rel) { try PDFWriter.write(note: state, options: options, report: &report, to: $0) }))
                    }
                    var pageImages: [[String]] = []
                    if images == .png {
                        let store = ImageStore(options: options, recordings: state.recordings)
                        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
                        for (i, page) in state.pages.enumerated() {
                            var pageReport = RenderReport()
                            var names: [String] = []
                            try PNGWriter.render(page: page, meta: state.meta, options: options, png: png,
                                                 pageNumber: i + 1, backgrounds: backgrounds, images: store,
                                                 report: &pageReport) { k, d in
                                let name = PNGWriter.imageName(page: i + 1, chunk: k) + ".png"
                                try output(prefix + "-assets/" + name, d)
                                names.append(stem + "-assets/" + name)
                            }
                            if !pdf {   // else the PDF reported the same items
                                report.placeholders += pageReport.placeholders
                                for w in pageReport.warnings { report.warn(w) }
                            }
                            pageImages.append(names)
                        }
                    }
                    let md = MarkdownExport.note(info: info, state: state, pdfName: pdf ? stem + ".pdf" : nil,
                                                    pageImages: pageImages, videos: videoLinks)
                    try output(prefix + ".md", Data(md.utf8))
                case .html:
                    let inline = try SVGWriter.exportInline(note: state, options: options, report: &report)
                    let back = String(repeating: "../", count: folder.count) + "index.html"
                    let html = HTMLExport.notePage(info: info, state: state, inline: inline, indexHref: back, videos: videoLinks)
                    try output(prefix + ".html", Data(html.utf8))
                    searchText = PageText.texts(of: state.pages).map(\.text).joined(separator: "\n")   // handwriting and typed text
                default:
                    break
                }
                var result = TreeResult(noteId: id, files: [], changed: [])
                var written: [String: ExportManifest.FileStamp] = [:]
                var complete = true   // a clip that could not be written is tried again next run
                let nb = NotebookPath.canonical(state.meta.notebook)
                if let source = options.blobs {
                    for clip in clips {
                        let rel = prefix + "-assets/" + clip.fileName
                        let url = root.appendingPathComponent(rel)
                        let changed: Bool
                        do {
                            changed = try ExportVideos.write(clip, from: source, to: url, keepMetadata: options.keepImageMetadata)
                        } catch {
                            report.warn("\(clip.label) could not be written: \(errorText(error))")
                            complete = false
                            continue
                        }
                        result.files.append(url.path)
                        if changed { result.changed.append(url.path) }
                        runFiles.insert(rel)
                        written[rel] = Self.stamp(url, data: nil)
                        manifest.files[rel] = .init(note: id, notebook: nb)
                        onFile(url.path, changed)
                    }
                }
                for (rel, changed) in outputs {
                    result.files.append(root.appendingPathComponent(rel).path)
                    if changed { result.changed.append(root.appendingPathComponent(rel).path) }
                    runFiles.insert(rel)
                    // Outputs are already on disk (written as made), so the content hash is read back.
                    let url = root.appendingPathComponent(rel)
                    written[rel] = Self.stamp(url, data: try? BoundedRead.contents(of: url, maxBytes: Self.stampHashLimit))
                    manifest.files[rel] = .init(note: id, notebook: nb)
                    onFile(root.appendingPathComponent(rel).path, changed)
                }
                manifest.notes[id] = .init(title: state.meta.title, stem: stem, folder: folder, notebook: nb,
                                           tags: state.meta.tags, pages: state.pages.count, modified: s.modified,
                                           searchText: searchText, key: complete ? key : nil, outputs: complete && key != nil ? written : nil)
                results.append(result)
            } catch let e as TreeExportError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Files written before the failure are tracked, and kept like the note's earlier ones.
                for (rel, _) in outputs where manifest.files[rel] == nil {
                    manifest.files[rel] = .init(note: id, notebook: NotebookPath.canonical(s.notebook))
                }
                failures += 1
                failedIDs.insert(id)
                errors.append("\(id): \(errorText(error))")
            }
        }
        onNote(notes.count, notes.count)

        // --clean: forget notes in scope that this run did not export.
        let exported = Set(results.map(\.noteId))
        if clean {
            for (id, n) in manifest.notes where !exported.contains(id) && !failedIDs.contains(id) && inScope(n.notebook) {
                manifest.notes[id] = nil
            }
        }

        // Indexes, from every note the manifest knows.
        let known = manifest.notes.values.sorted { ($0.title.lowercased(), $0.stem) < ($1.title.lowercased(), $1.stem) }
        switch format {
        case .markdown:
            var folders = Set<[String]>([[]])
            for n in known { for k in 1...max(1, n.folder.count) where n.folder.count >= k { folders.insert(Array(n.folder.prefix(k))) } }
            for f in folders.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
                let entries = known.filter { $0.folder == f }.map {
                    ExportIndexEntry(title: $0.title, href: $0.stem + ".md", notebook: $0.notebook, tags: $0.tags,
                                     pages: $0.pages, modified: $0.modified)
                }
                let subs = Set(folders.filter { $0.count == f.count + 1 && Array($0.prefix(f.count)) == f }.map { $0.last ?? "" })
                    .sorted().map { (name: $0, href: $0 + "/README.md") }
                let md = MarkdownExport.folderIndex(title: f.last ?? "Sempere export", subfolders: subs, notes: entries)
                let rel = (f + ["README.md"]).joined(separator: "/")
                let changed = try put(rel, Data(md.utf8))
                runFiles.insert(rel)
                manifest.files[rel] = .init(note: nil, notebook: nil)
                onFile(root.appendingPathComponent(rel).path, changed)
            }
        case .html:
            let entries = known.map {
                ExportIndexEntry(title: $0.title, href: ($0.folder + [$0.stem + ".html"]).joined(separator: "/"),
                                 notebook: $0.notebook, tags: $0.tags, pages: $0.pages, modified: $0.modified,
                                 searchText: $0.searchText ?? "")
            }
            let changed = try put("index.html", Data(HTMLExport.indexPage(entries: entries).utf8))
            runFiles.insert("index.html")
            manifest.files["index.html"] = .init(note: nil, notebook: nil)
            onFile(root.appendingPathComponent("index.html").path, changed)
        default:
            break
        }

        // --clean: delete files of ours that this run did not produce.
        if clean {
            let rootPath = root.standardizedFileURL.path
            for (rel, entry) in manifest.files where !runFiles.contains(rel) {
                if let n = entry.note, failedIDs.contains(n) { continue }
                if entry.note != nil && !inScope(entry.notebook) { continue }
                manifest.files[rel] = nil
                let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
                guard !rel.hasPrefix("/"), !parts.contains(".."), !parts.contains("") else { continue }
                var url = root.appendingPathComponent(rel).standardizedFileURL
                guard url.path.hasPrefix(rootPath + "/") else { continue }
                if (try? fm.removeItem(at: url)) != nil { onFile(url.path, true) }
                // Remove folders this left empty.
                url.deleteLastPathComponent()
                while url.path.hasPrefix(rootPath + "/"),
                      (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                    try? fm.removeItem(at: url)
                    url.deleteLastPathComponent()
                }
            }
        }

        try FileIO.writePrivate(try enc.encode(manifest), to: manifestURL)
        return (results, failures, errors)
    }
}
