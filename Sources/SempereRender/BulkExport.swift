import Foundation
import Sempere

// Bulk export (docs/io.md "Bulk export"): many notes, one at a time, into a
// folder tree or a zip archive. Shared by the app's "Export Notes…" and
// `sempere export --all` with --format pdf or png.

/// What a bulk export writes per note.
public enum BulkExportFormat: String, CaseIterable, Sendable, Codable, Identifiable {
    /// `<stem>.pdf`.
    case pdf
    /// `<stem>.pdf` with the recordings (and transcripts) and video clips embedded
    /// ("PDF + attachments", the CLI's `--attachments`).
    case pdfAttachments = "pdf-attachments"
    /// `<stem>/p001.png`, `p002.png`, ...
    case png
    /// `<stem>/`: the note's recordings (and transcripts), clips, images and
    /// PDFs as files, with `media.json` (`MediaExport`); notes without media
    /// write nothing.
    case media

    public var id: String { rawValue }

    /// The format's name for menus.
    public var title: String {
        switch self {
        case .pdf: return "PDF"
        case .pdfAttachments: return "PDF + attachments"
        case .png: return "PNG Pages"
        case .media: return "Media"
        }
    }

    /// A folder per note (PNG pages, media) rather than one file.
    public var isFolder: Bool { self == .png || self == .media }
}

/// Where a bulk export puts each note's files below the output folder.
public enum BulkExportLayout: String, CaseIterable, Sendable, Codable, Identifiable {
    /// A folder per notebook level, mirroring the notebook tree (notes
    /// without a notebook at the top).
    case notebooks
    /// Every note directly in the output folder.
    case flat

    public var id: String { rawValue }
}

/// Which notes a bulk export takes.
public enum BulkExportScope: Sendable, Equatable {
    /// These notes, in this order (a list selection).
    case notes([UUID])
    /// The notes in this notebook and its sub-notebooks.
    case notebook(String)
    /// Every note of the vault.
    case vault
}

/// How a bulk export renders.
public struct BulkExportOptions: Sendable, Equatable {
    public var format: BulkExportFormat
    public var layout: BulkExportLayout
    /// Draw the paper background and ruling.
    public var paper: Bool
    /// PNG resolution in dots per inch.
    public var dpi: Double
    /// Where pageless pages are cut.
    public var breaks: PageBreaks
    /// Keep image metadata (EXIF, GPS, ...) in the export.
    public var keepImageMetadata: Bool

    public init(format: BulkExportFormat, layout: BulkExportLayout = .notebooks, paper: Bool = true, dpi: Double = 144,
                breaks: PageBreaks = .gaps, keepImageMetadata: Bool = false) {
        self.format = format; self.layout = layout; self.paper = paper; self.dpi = dpi
        self.breaks = breaks; self.keepImageMetadata = keepImageMetadata
    }

    /// True when `dpi` is a usable resolution (only PNG uses it).
    public var isValid: Bool { format != .png || (dpi.isFinite && dpi > 0 && dpi <= ShareOptions.maxDPI) }

    /// Everything that changes the bytes written, as a string: a resumed run
    /// skips a file only when it was written with the same options.
    public var fingerprint: String {
        var parts = [format.rawValue, paper ? "paper" : "no-paper", breaks.rawValue,
                     keepImageMetadata ? "keep-metadata" : "strip-metadata"]
        if format == .png { parts.append("dpi=\(dpi)") }
        return parts.joined(separator: ",")
    }

    /// Render options for this export: `base` (rasterizer, shaper, image
    /// decoder of the caller) with the paper, breaks, metadata and embedding
    /// settings of these options.
    public func renderOptions(base: RenderOptions = RenderOptions()) -> RenderOptions {
        var r = base
        r.paper = paper
        r.breaks = breaks
        r.keepImageMetadata = keepImageMetadata
        r.embedRecordings = format == .pdfAttachments
        r.embedVideos = format == .pdfAttachments
        r.listAttachments = format == .pdfAttachments
        return r
    }
}

/// One note of a bulk export and where its files go.
public struct BulkExportJob: Sendable, Equatable, Identifiable {
    public var noteId: UUID
    public var title: String
    /// Sanitised folder names below the output folder (empty: at the top).
    public var folder: [String]
    /// The note's file name without extension (`<title>-<8 hex>`, longer on a collision).
    public var stem: String

    public var id: UUID { noteId }

    public init(noteId: UUID, title: String, folder: [String], stem: String) {
        self.noteId = noteId; self.title = title; self.folder = folder; self.stem = stem
    }

    /// The name the note takes in its folder: `<stem>.pdf`, or the folder `<stem>` of its PNG pages or media.
    public func leaf(_ format: BulkExportFormat) -> String {
        format.isFolder ? stem : stem + ".pdf"
    }

    /// `leaf` with its folders, `/`-separated, relative to the output folder.
    public func path(_ format: BulkExportFormat) -> String {
        (folder + [leaf(format)]).joined(separator: "/")
    }
}

/// Selection → job list.
public enum BulkExportPlan {
    /// The notes `scope` takes from `notes` (the vault's summaries), in
    /// export order: a `.notes` scope keeps its order (ids not among `notes`
    /// are dropped, repeats taken once); a notebook or the vault are sorted
    /// by folder, then title, then id. Deleted notes are left out unless
    /// named in a `.notes` scope or `includeDeleted`.
    public static func notes(in scope: BulkExportScope, from notes: [NoteSummary],
                             includeDeleted: Bool = false) -> [NoteSummary] {
        switch scope {
        case .notes(let ids):
            let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<UUID>()
            return ids.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                return byID[id]
            }
        case .notebook(let path):
            return sorted(notes.filter {
                (includeDeleted || !$0.deleted) && NotebookPath.name($0.notebook, isWithin: path)
            })
        case .vault:
            return sorted(notes.filter { includeDeleted || !$0.deleted })
        }
    }

    private static func sorted(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.sorted {
            let a = NotebookPath.components($0.notebook).map { $0.lowercased() }
            let b = NotebookPath.components($1.notebook).map { $0.lowercased() }
            if a != b { return a.lexicographicallyPrecedes(b) }
            let ta = $0.title.lowercased(), tb = $1.title.lowercased()
            if ta != tb { return ta < tb }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// `version(of:)` of the revisions a read found (readable or not).
    public static func version(of note: LoadedNote) -> String {
        version(of: note.revisions.map(\.name) + Array(note.failures.keys))
    }

    /// The jobs for `scope`: `notes(in:from:)` with a folder and a unique
    /// name each.
    ///
    /// Folders mirror the notebooks (`.notebooks`); for a notebook scope they
    /// start at the chosen notebook (exporting `School/Math` gives `Math/…`).
    /// Names are `ExportName.stem` (`<title>-<8 hex>`); two notes whose names
    /// would clash in one folder (equal ignoring case and Unicode
    /// normalisation, or equal to a sub-folder's name) get the full id
    /// instead, then `-2`, `-3`, ... Which note keeps the short name depends
    /// only on the ids, so a re-run names every note the same way.
    public static func jobs(for scope: BulkExportScope, from notes: [NoteSummary], format: BulkExportFormat,
                            layout: BulkExportLayout, includeDeleted: Bool = false) -> [BulkExportJob] {
        var chosen = self.notes(in: scope, from: notes, includeDeleted: includeDeleted)
        // Notes without any audio, video, image or PDF have nothing to write.
        if format == .media { chosen = chosen.filter(MediaExport.mayHaveMedia) }
        var folders: [String?: [String]] = [:]
        if layout == .notebooks {
            folders = TreeExporter.folders(for: chosen.map { NotebookPath.canonical($0.notebook) })
            if case .notebook(let path) = scope {
                // Start at the chosen notebook: drop its ancestors.
                let drop = max(0, NotebookPath.components(path).count - 1)
                folders = folders.mapValues { Array($0.dropFirst(min(drop, $0.count))) }
            }
        }
        var jobs = chosen.map { s in
            BulkExportJob(noteId: s.id, title: s.title, folder: folders[NotebookPath.canonical(s.notebook)] ?? [],
                          stem: ExportName.stem(title: s.title, noteId: s.id))
        }
        // Names already taken in each folder: the sub-folders.
        var taken: [String: Set<String>] = [:]
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        func dirKey(_ folder: [String]) -> String { key(folder.joined(separator: "/")) }
        for job in jobs {
            for k in 0..<job.folder.count {
                taken[dirKey(Array(job.folder.prefix(k))), default: []].insert(key(job.folder[k]))
            }
        }
        // Assign in id order so the outcome does not depend on the list order.
        for i in jobs.indices.sorted(by: { jobs[$0].noteId.uuidString < jobs[$1].noteId.uuidString }) {
            let dir = dirKey(jobs[i].folder)
            let id = jobs[i].noteId.uuidString.lowercased()
            let base = ExportName.component(jobs[i].title)
            var candidates = [jobs[i].stem, base + "-" + id]
            var stem = candidates.removeFirst()
            var n = 1
            while taken[dir, default: []].contains(key(BulkExportJob(noteId: jobs[i].noteId, title: "", folder: [],
                                                                     stem: stem).leaf(format))) {
                if !candidates.isEmpty { stem = candidates.removeFirst() } else { n += 1; stem = base + "-" + id + "-\(n)" }
            }
            jobs[i].stem = stem
            taken[dir, default: []].insert(key(jobs[i].leaf(format)))
        }
        return jobs
    }

    /// A short fingerprint of a note's revision file names (`Vault.revisionNames`):
    /// it changes whenever the note gains or loses a revision. Not a security
    /// hash; a resumed export uses it to tell an unchanged note (FNV-1a, 64 bits).
    public static func version(of revisions: [RevisionName]) -> String {
        version(ofFileNames: revisions.map(\.filename))
    }

    /// `version(of:)` from file names (the app's listing keeps names).
    public static func version(ofFileNames names: [String]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for name in names.sorted() {
            for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            h = (h ^ 0x0A) &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }
}

/// `.sempere-export-bulk.json` in the output folder: per file written, the
/// note, its version and the options, and the size. Untrusted when read back
/// (the folder may be shared): it can only make a run skip a file that
/// exists with the recorded size, never delete or write outside the folder.
struct BulkExportManifest: Codable {
    struct FileEntry: Codable, Equatable {
        var note: String
        var version: String
        var options: String
        var size: Int64
    }
    var version = 1
    var files: [String: FileEntry] = [:]

    static let fileName = ".sempere-export-bulk.json"
    static let maxBytes = 64 << 20
}

/// What became of one note.
public struct BulkNoteOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Rendered and written.
        case exported
        /// Left as an earlier run wrote it (same name, size, note version and options).
        case skipped
        /// Not exported; the batch went on.
        case failed(String)
    }
    public var job: BulkExportJob
    public var status: Status
    /// The note's files, relative to the output folder (or zip), `/`-separated.
    public var files: [String] = []
    /// Items drawn as placeholders.
    public var placeholders = 0
    /// Recordings and video clips embedded ("PDF + attachments").
    public var recordingsAttached = 0
    public var videosAttached = 0
    /// Recordings the PDF left out (plain PDF and PNG).
    public var recordingsOmitted = 0
    /// Render warnings (placeholders, omitted media), for the CLI's stderr.
    public var report = RenderReport()

    public static func == (a: Self, b: Self) -> Bool {
        a.job == b.job && a.status == b.status && a.files == b.files && a.placeholders == b.placeholders
            && a.recordingsAttached == b.recordingsAttached && a.videosAttached == b.videosAttached
            && a.recordingsOmitted == b.recordingsOmitted
    }
}

/// The end of a bulk export.
public struct BulkExportResult: Sendable, Equatable {
    /// The output folder, or the zip archive.
    public var output: URL
    /// One per job that was reached, in job order.
    public var notes: [BulkNoteOutcome]
    /// Jobs never reached because the run was cancelled.
    public var notReached: Int
    public var cancelled: Bool

    public var exported: [BulkNoteOutcome] { notes.filter { $0.status == .exported } }
    public var skipped: [BulkNoteOutcome] { notes.filter { $0.status == .skipped } }
    public var failures: [BulkNoteOutcome] { notes.filter { if case .failed = $0.status { return true } else { return false } } }

    /// "Physics (0d1c6a1e): reason" per failed note, for a final report.
    public var failureLines: [String] {
        failures.map { o in
            guard case .failed(let why) = o.status else { return "" }
            let title = o.job.title.isEmpty ? "Untitled" : o.job.title
            return "\(title) (\(o.job.noteId.uuidString.lowercased().prefix(8))): \(why)"
        }
    }

    /// "Physics (0d1c6a1e): warning" per warning of an exported note (a file
    /// left out, an image written with its metadata), for a final report.
    public var warningLines: [String] {
        exported.flatMap { o in
            let title = o.job.title.isEmpty ? "Untitled" : o.job.title
            return o.report.warnings.map { "\(title) (\(o.job.noteId.uuidString.lowercased().prefix(8))): \($0)" }
        }
    }
}

/// Why a bulk export stopped as a whole (one note's failure never does).
public enum BulkExportError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidResolution(Double)
    /// The output folder or archive cannot be written.
    case cannotWrite(path: String, reason: String)

    public var description: String {
        switch self {
        case .invalidResolution: return "The resolution must be greater than 0 and at most \(Int(ShareOptions.maxDPI)) dpi."
        case .cannotWrite(let path, let reason): return "cannot write \(path): \(reason)"
        }
    }
}

/// One bulk export run: the caller loops over the jobs, one note at a time,
/// so at most one note is in memory (the app downloads, reads and renders
/// each note in turn; the CLI reads it):
///
/// ```swift
/// let session = try BulkExportSession(destination: .folder(out), options: options, jobs: jobs)
/// for job in jobs {
///     try Task.checkCancellation()           // or stop the loop: session.finish(cancelled: true)
///     let version = BulkExportPlan.version(of: try vault.revisionNames(of: job.noteId))
///     if session.skip(job, version: version) { continue }
///     do { let (summary, state) = try load(job.noteId)
///          session.export(job, state: state, version: version, blobs: vault.blobSource(note: job.noteId))
///     } catch { session.fail(job, error) }
/// }
/// let result = try session.finish(cancelled: false)
/// ```
///
/// Folder output: each note's files are written in place (a PDF under a
/// temporary name, then renamed), and recorded in the folder's manifest, so
/// a later run into the same folder skips files it already wrote for the
/// same note version and options, if they are still there with the size it
/// recorded. Zip output: each note is written to `staging`, appended to the
/// archive and deleted; a zip is never resumed.
///
/// Not thread-safe: use it from one task at a time. The output is PLAINTEXT.
public final class BulkExportSession: @unchecked Sendable {
    public enum Destination: Sendable, Equatable {
        /// Files under this folder (created if missing).
        case folder(URL)
        /// One archive at `archive`; notes are rendered into `staging` first.
        case zip(archive: URL, staging: URL)
    }

    public let destination: Destination
    public let options: BulkExportOptions
    /// Render settings for every note (the caller's rasterizer and shaper); blobs are per note.
    public let renderOptions: RenderOptions
    private let total: Int
    private var outcomes: [BulkNoteOutcome] = []
    private var manifest = BulkExportManifest()
    private var zip: ZipWriter?
    private var unsaved = 0
    private var finished = false
    /// Notes between two saves of the folder's manifest (and at the end).
    static let manifestSaveInterval = 10

    /// - Parameters:
    ///   - jobs: the run's jobs (for `notReached`); the caller still loops over them.
    ///   - renderBase: the caller's rasterizer, shaper and image decoder.
    /// - Throws: `BulkExportError` when the destination cannot be created or the resolution is invalid.
    public init(destination: Destination, options: BulkExportOptions, jobs: [BulkExportJob],
                renderBase: RenderOptions = RenderOptions()) throws {
        guard options.isValid else { throw BulkExportError.invalidResolution(options.dpi) }
        self.destination = destination
        self.options = options
        self.renderOptions = options.renderOptions(base: renderBase)
        self.total = jobs.count
        let fm = FileManager.default
        switch destination {
        case .folder(let root):
            do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch {
                throw BulkExportError.cannotWrite(path: root.path, reason: error.localizedDescription)
            }
            if let data = try? BoundedRead.contents(of: root.appendingPathComponent(BulkExportManifest.fileName),
                                                    maxBytes: BulkExportManifest.maxBytes),
               let old = try? JSONDecoder().decode(BulkExportManifest.self, from: data), old.version == 1 {
                manifest = old
            }
        case .zip(let archive, let staging):
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                zip = try ZipWriter(url: archive)
            } catch let e as ZipWriterError {
                throw BulkExportError.cannotWrite(path: archive.path, reason: "\(e)")
            } catch {
                throw BulkExportError.cannotWrite(path: staging.path, reason: error.localizedDescription)
            }
        }
    }

    deinit {
        // A session dropped without `finish` (the app's task went away) leaves no half archive or staged plaintext.
        if !finished, case .zip(let archive, let staging) = destination {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: archive)
        }
    }

    /// Outcomes so far, in job order.
    public var progress: [BulkNoteOutcome] { outcomes }

    private var root: URL {
        switch destination {
        case .folder(let url): return url
        case .zip(_, let staging): return staging
        }
    }

    /// True (and recorded as skipped) when an earlier run into the same
    /// folder wrote every file of `job` for this `version` and these options,
    /// and each is still there with the size it recorded. Always false for a zip.
    public func skip(_ job: BulkExportJob, version: String) -> Bool {
        guard case .folder(let root) = destination else { return false }
        let id = job.noteId.uuidString.lowercased()
        let prefix = job.path(options.format)
        let mine = manifest.files.filter { rel, e in
            e.note == id && (options.format.isFolder ? rel.hasPrefix(prefix + "/") : rel == prefix)
        }
        guard !mine.isEmpty else { return false }
        let fm = FileManager.default
        for (rel, entry) in mine {
            guard entry.version == version, entry.options == options.fingerprint,
                  BulkExportManifest.isSafe(rel),
                  let attrs = try? fm.attributesOfItem(atPath: root.appendingPathComponent(rel).path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value == entry.size else { return false }
        }
        outcomes.append(BulkNoteOutcome(job: job, status: .skipped, files: mine.keys.sorted()))
        return true
    }

    /// Records that `job` could not be read (or downloaded); the run goes on.
    public func fail(_ job: BulkExportJob, _ error: Error, text: (Error) -> String = { "\($0)" }) {
        outcomes.append(BulkNoteOutcome(job: job, status: .failed(text(error))))
    }

    /// Renders `state` and writes its files. A note that cannot be rendered
    /// or written is recorded as failed, not thrown.
    ///
    /// - Throws: `CancellationError` (the files of this note are removed), or
    ///   `BulkExportError.cannotWrite` when the zip archive cannot be appended to.
    @discardableResult
    public func export(_ job: BulkExportJob, state: NoteState, version: String, blobs: (any BlobSource)?,
                       text: (Error) -> String = { "\($0)" }) throws -> BulkNoteOutcome {
        var render = renderOptions
        render.blobs = blobs
        var report = RenderReport()
        var written: [String] = []
        let fm = FileManager.default
        let root = self.root
        func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }
        func removeWritten() { for rel in written { try? fm.removeItem(at: url(rel)) } }
        /// Files an earlier, longer version of the note left in its folder (pages, media).
        func removeEarlier(_ folder: String) {
            guard case .folder = destination else { return }
            for (rel, e) in manifest.files where rel.hasPrefix(folder + "/") && BulkExportManifest.isSafe(rel)
                && e.note == job.noteId.uuidString.lowercased() {
                try? fm.removeItem(at: url(rel))
                manifest.files[rel] = nil
            }
        }
        var outcome = BulkNoteOutcome(job: job, status: .exported)
        do {
            try Task.checkCancellation()
            if options.format != .media {   // a note without media writes nothing, not even its folders
                try fm.createDirectory(at: url(job.folder.joined(separator: "/")), withIntermediateDirectories: true)
            }
            switch options.format {
            case .pdf, .pdfAttachments:
                let rel = job.path(options.format)
                // Streamed to a temporary name (clips are never held in memory), renamed when complete:
                // an interrupted run never leaves a short PDF under the final name.
                let partial = url(rel + ".partial")
                do {
                    try PDFWriter.write(note: state, options: render, report: &report, to: partial)
                } catch {
                    try? fm.removeItem(at: partial)
                    throw error
                }
                try Task.checkCancellation()
                _ = try? fm.removeItem(at: url(rel))
                try fm.moveItem(at: partial, to: url(rel))
                written = [rel]
            case .media:
                let folder = job.path(.media)
                removeEarlier(folder)
                let r = try MediaExport.write(state, noteId: job.noteId, blobs: blobs, to: url(folder),
                                              keepMetadata: options.keepImageMetadata, report: &report)
                written = r.files.map { folder + "/" + $0 }
            case .png:
                let pages = try PNGWriter.renderNamed(note: state, options: render, png: PNGOptions(dpi: options.dpi),
                                                      report: &report)
                let folder = job.path(.png)
                try fm.createDirectory(at: url(folder), withIntermediateDirectories: true)
                removeEarlier(folder)
                for (name, data) in pages {
                    try Task.checkCancellation()
                    let rel = folder + "/" + name + ".png"
                    try data.write(to: url(rel), options: .atomic)
                    written.append(rel)
                }
            }
        } catch is CancellationError {
            removeWritten()
            throw CancellationError()
        } catch {
            removeWritten()
            outcome.status = .failed(text(error))
            outcomes.append(outcome)
            return outcome
        }
        outcome.files = written
        outcome.placeholders = report.placeholders.count
        outcome.recordingsAttached = report.recordingsAttached
        outcome.videosAttached = report.videosAttached
        outcome.recordingsOmitted = options.format == .png ? state.recordings.count
            : options.format == .media ? 0 : report.recordingsOmitted
        outcome.report = report
        switch destination {
        case .folder:
            let id = job.noteId.uuidString.lowercased()
            for rel in written {
                let size = ((try? fm.attributesOfItem(atPath: url(rel).path))?[.size] as? NSNumber)?.int64Value ?? -1
                manifest.files[rel] = .init(note: id, version: version, options: options.fingerprint, size: size)
            }
            unsaved += 1
            if unsaved >= Self.manifestSaveInterval { saveManifest() }
        case .zip:
            guard let zip else { break }
            for rel in written {
                do { try zip.add(name: rel, contentsOf: url(rel)) } catch {
                    removeWritten()
                    throw BulkExportError.cannotWrite(path: zip.url.path, reason: "\(error)")
                }
            }
            removeWritten()
            // Folders the note's files were staged in.
            if let first = written.first {
                var dir = url(first).deletingLastPathComponent().standardizedFileURL
                let top = root.standardizedFileURL.path
                while dir.path.hasPrefix(top + "/"), (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                    try? fm.removeItem(at: dir)
                    dir.deleteLastPathComponent()
                }
            }
        }
        outcomes.append(outcome)
        return outcome
    }

    private func saveManifest() {
        guard case .folder(let root) = destination else { return }
        unsaved = 0
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(manifest).write(to: root.appendingPathComponent(BulkExportManifest.fileName), options: .atomic)
    }

    /// Ends the run. A folder keeps everything written (and its manifest, so
    /// a re-run resumes); a finished zip is complete, a cancelled one is deleted.
    ///
    /// - Throws: `BulkExportError.cannotWrite` when the archive cannot be completed.
    public func finish(cancelled: Bool) throws -> BulkExportResult {
        finished = true
        var output = root
        switch destination {
        case .folder:
            saveManifest()
        case .zip(let archive, let staging):
            output = archive
            try? FileManager.default.removeItem(at: staging)
            if cancelled {
                zip = nil
                try? FileManager.default.removeItem(at: archive)
            } else if let zip {
                do { try zip.finish() } catch {
                    try? FileManager.default.removeItem(at: archive)
                    throw BulkExportError.cannotWrite(path: archive.path, reason: "\(error)")
                }
            }
        }
        return BulkExportResult(output: output, notes: outcomes, notReached: max(0, total - outcomes.count),
                                cancelled: cancelled)
    }
}

extension BulkExportManifest {
    /// A relative path that stays inside the output folder.
    static func isSafe(_ rel: String) -> Bool {
        !rel.hasPrefix("/") && rel.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { ExportManifest.isSafeComponent(String($0)) }
    }
}
