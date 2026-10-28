import Foundation
import Sempere
import SempereRender

// The interface between a host (the `sempere` CLI, the app) and an importer from another app
// (docs/import-notability.md "Structure"). A host lists the importers it was given, builds its
// options (CLI flags, app toggles) from their specs, runs one with a request, and shows the
// result. An importer module depends on this target and on nothing of the hosts; a host names
// an importer's module in exactly one place (its registry, behind `#if canImport(...)`).

/// One option an importer understands. The `id` is the key of `ImporterOptionValues`.
public struct ImporterOptionSpec: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// On or off. `cliName` is the flag that flips it from `defaultOn`.
        case flag(defaultOn: Bool)
        /// One text value (`--notebook name`).
        case text(valueName: String)
        /// A repeatable text value (`--tag tag`).
        case list(valueName: String)
    }

    public var id: String
    public var kind: Kind
    /// The long flag without dashes (`no-attachments`); nil: not offered on the command line.
    public var cliName: String?
    /// The CLI's help line for the flag.
    public var help: String
    /// The app offers this flag as a switch with this English title (the app looks the title up by
    /// `id` first, so it can be localized); nil: not offered in the app.
    public var appTitle: String?
    /// The app's footer under the switch, English.
    public var appDetail: String?

    public init(id: String, kind: Kind, cliName: String?, help: String, appTitle: String? = nil, appDetail: String? = nil) {
        self.id = id; self.kind = kind; self.cliName = cliName; self.help = help
        self.appTitle = appTitle; self.appDetail = appDetail
    }

    /// The value the option has when nothing sets it.
    public var defaultValue: ImporterOptionValues.Value {
        switch kind {
        case .flag(let on): return .bool(on)
        case .text: return .text(nil)
        case .list: return .list([])
        }
    }
}

/// The values of an importer's options, by spec id; an id that is not set has the spec's default.
public struct ImporterOptionValues: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case bool(Bool)
        case text(String?)
        case list([String])
    }

    public var values: [String: Value] = [:]

    public init(_ values: [String: Value] = [:]) { self.values = values }

    public func bool(_ id: String, default fallback: Bool) -> Bool {
        if case .bool(let b)? = values[id] { return b }
        return fallback
    }

    public func text(_ id: String) -> String? {
        if case .text(let s)? = values[id] { return s }
        return nil
    }

    public func list(_ id: String) -> [String] {
        if case .list(let l)? = values[id] { return l }
        return []
    }
}

/// How far an import has come, for the host's progress display (the CLI's line on stderr, the app's bar).
/// Reported by the importer from the thread it runs on; a host hops to its own.
public struct ImporterProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        /// Listing the picked files, folders and archives.
        case finding
        /// Reading every source before anything is written (copies of a note are resolved together).
        case reading
        /// Writing the notes into the vault, one delta each.
        case writing
    }

    public var phase: Phase
    /// Sources done in this phase.
    public var done: Int
    /// Sources in all (0 while finding).
    public var total: Int
    /// The file name of the source being worked on (never a folder path or note content).
    public var current: String?

    public init(phase: Phase, done: Int, total: Int, current: String? = nil) {
        self.phase = phase; self.done = done; self.total = total; self.current = current
    }

    /// The fraction of the whole import (reading counts as the first third), 0 while finding.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        let part = Double(min(max(done, 0), total)) / Double(total)
        switch phase {
        case .finding: return 0
        case .reading: return part / 3
        case .writing: return 1.0 / 3 + part * 2 / 3
        }
    }

    /// The CLI's line (English).
    public var line: String {
        let what: String
        switch phase {
        case .finding: return "Finding notes…"
        case .reading: what = "Reading"
        case .writing: what = "Importing"
        }
        return "\(what) \(done)/\(total) notes" + (current.map { ": \($0)" } ?? "")
    }
}

/// A request to stop an import, set by the host (the app's Cancel) and checked by the importer between
/// notes: what was written stays (each note is one delta), and the rest is reported as not imported.
public final class ImporterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// What a host asks an importer to do.
public struct ImporterRequest: Sendable {
    /// Files, folders or archives the user chose.
    public var paths: [URL]
    /// The open vault (already unlocked), written to with `device` and the clock passed to `run`.
    public var vault: Vault
    public var device: DeviceID
    public var options: ImporterOptionValues
    /// How the text of imported PDF pages is read (nil: not at all). The host decides: poppler in the CLI, PDFKit in the app.
    public var pdfText: (any PDFTextExtracting)?
    /// The notebook every note goes to (nil: the importer's own rule). The host canonicalizes it.
    public var notebook: String?
    /// Told how far the import is, after each source (any thread; nil: nobody asks).
    public var progress: (@Sendable (ImporterProgress) -> Void)?
    /// Checked between notes by an importer that `supportsCancel`; nil: the import runs to its end.
    public var cancellation: ImporterCancellation?

    public init(paths: [URL], vault: Vault, device: DeviceID, options: ImporterOptionValues = ImporterOptionValues(),
                pdfText: (any PDFTextExtracting)? = nil, notebook: String? = nil,
                progress: (@Sendable (ImporterProgress) -> Void)? = nil, cancellation: ImporterCancellation? = nil) {
        self.paths = paths; self.vault = vault; self.device = device; self.options = options
        self.pdfText = pdfText; self.notebook = notebook
        self.progress = progress; self.cancellation = cancellation
    }
}

/// A counted line of a report: what was imported, or what was left out.
public struct ImporterCount: Sendable, Hashable, Identifiable {
    /// Stable key (`pdfPages`); hosts localize by it when they know it.
    public var id: String
    /// English words for the CLI, and for a host that does not know the id.
    public var english: String
    public var count: Int

    public init(id: String, english: String, count: Int) { self.id = id; self.english = english; self.count = count }
}

/// What happened to one source note.
public struct ImporterNoteOutcome: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case imported
        case skipped(String)
        case failed(String)
    }

    /// Where it came from: a path, or `<zip>!<entry>`.
    public var source: String
    public var noteID: UUID?
    public var status: Status
    /// What the importer wants to tell about this note (placed by a guess, left out, …).
    public var warnings: [String]

    public init(source: String, noteID: UUID?, status: Status, warnings: [String] = []) {
        self.source = source; self.noteID = noteID; self.status = status; self.warnings = warnings
    }
}

/// An `Encodable` of any type, for results the host prints as JSON without knowing their shape.
public struct AnyEncodable: Encodable, @unchecked Sendable {
    private let value: any Encodable
    public init(_ value: any Encodable) { self.value = value }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// How the host will show the result (a CLI's flags).
public struct ImporterStyle: Sendable, Hashable {
    public var json: Bool
    public var quiet: Bool
    public var verbose: Bool
    /// Nothing was written: the vault was a scratch copy.
    public var dryRun: Bool

    public init(json: Bool = false, quiet: Bool = false, verbose: Bool = false, dryRun: Bool = false) {
        self.json = json; self.quiet = quiet; self.verbose = verbose; self.dryRun = dryRun
    }
}

/// The host's reading of the handwriting of the imported notes afterwards (`--recognize missing`),
/// for an importer to put into its report.
public struct ImporterRecognition: Sendable {
    /// One encodable result per note, as the host reports it.
    public var results: [AnyEncodable]
    public var pagesRead: Int
    public var notesRead: Int
    /// (note, why) of the notes that could not be read.
    public var failures: [(note: String, error: String)]

    public init(results: [AnyEncodable], pagesRead: Int, notesRead: Int, failures: [(note: String, error: String)]) {
        self.results = results; self.pagesRead = pagesRead; self.notesRead = notesRead; self.failures = failures
    }
}

/// The CLI's view of a result: JSON, or lines for the terminal, and whether the command fails.
public struct ImporterPresentation: Sendable {
    public struct Line: Sendable, Hashable {
        public var text: String
        /// Standard error (a warning) rather than standard output.
        public var isError: Bool
        public init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }
    }

    /// Printed as JSON when the style asked for it (then `lines` is empty).
    public var json: AnyEncodable?
    public var lines: [Line]
    /// The message of the failure exit, nil when the command succeeded.
    public var failure: String?

    public init(json: AnyEncodable? = nil, lines: [Line] = [], failure: String? = nil) {
        self.json = json; self.lines = lines; self.failure = failure
    }

    /// Left-aligned columns separated by two spaces; the last column is not padded.
    public static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        var widths = [Int](repeating: 0, count: first.count)
        for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
        return rows.map { r in
            r.enumerated().map { i, c in
                i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

/// What an import did, for every host.
public struct ImporterResult: Sendable {
    public var notes: [ImporterNoteOutcome]
    /// Totals of what was imported (PDF pages, images, …), zero counts left out.
    public var imported: [ImporterCount]
    /// Totals of what the importer left out of the notes it wrote, zero counts left out.
    public var leftOut: [ImporterCount]
    /// The CLI's output for this result; the recognition outcome is given when the host read the notes' handwriting.
    private let present: @Sendable (ImporterStyle, ImporterRecognition?) -> ImporterPresentation

    /// The import was stopped (`ImporterCancellation`): the notes not written are skipped, and say so.
    public var cancelled: Bool

    public init(notes: [ImporterNoteOutcome], imported: [ImporterCount], leftOut: [ImporterCount], cancelled: Bool = false,
                present: @escaping @Sendable (ImporterStyle, ImporterRecognition?) -> ImporterPresentation) {
        self.notes = notes; self.imported = imported; self.leftOut = leftOut; self.cancelled = cancelled; self.present = present
    }

    public func presentation(_ style: ImporterStyle, recognition: ImporterRecognition? = nil) -> ImporterPresentation {
        present(style, recognition)
    }

    /// The reason of a note an importer did not get to because the import was stopped (`ImporterCancellation`).
    public static let cancelledReason = "not imported: the import was canceled"

    /// Notes not imported because the import was stopped.
    public var cancelledCount: Int { notes.filter { $0.status == .skipped(Self.cancelledReason) }.count }
    public var importedCount: Int { notes.filter { $0.status == .imported }.count }
    /// Notes skipped for any reason, the cancelled ones included.
    public var skippedCount: Int { notes.filter { if case .skipped = $0.status { return true }; return false }.count }
    public var failedCount: Int { notes.filter { if case .failed = $0.status { return true }; return false }.count }
    /// Ids of the notes written.
    public var writtenNotes: [UUID] { notes.compactMap { $0.status == .imported ? $0.noteID : nil } }
}

/// An importer from another app's files.
public protocol VaultImporter: Sendable {
    /// The CLI subcommand (`import <id>`), lowercase.
    var id: String { get }
    /// The app's name as people write it (menus, titles).
    var displayName: String { get }
    /// The CLI help: one line, and the longer text.
    var abstract: String { get }
    var discussion: String { get }
    /// What a path argument may be, for the CLI help.
    var pathHelp: String { get }
    /// File name extensions of the files it reads; folders and zip archives are always offered.
    var fileExtensions: [String] { get }
    /// Its options, besides the ones every host handles itself (notebook, dry run, PDF text, recognition).
    var options: [ImporterOptionSpec] { get }
    /// The importer stores the text of PDF pages (`ImporterRequest.pdfText`).
    var usesPDFText: Bool { get }
    /// The importer's notes may lack recognized handwriting that the host can read afterwards.
    var supportsRecognizeAfter: Bool { get }
    /// The importer stops between notes when `ImporterRequest.cancellation` is set, leaving the vault consistent.
    var supportsCancel: Bool { get }

    /// Imports `request.paths` into the vault, one delta per note.
    func run(_ request: ImporterRequest, clock: inout HybridClock) throws -> ImporterResult
}

extension VaultImporter {
    public var supportsCancel: Bool { false }
}

/// The importers a host was built with.
public struct ImporterRegistry: Sendable {
    public private(set) var importers: [any VaultImporter]

    public init(_ importers: [any VaultImporter] = []) { self.importers = importers }

    public var isEmpty: Bool { importers.isEmpty }

    public func importer(id: String) -> (any VaultImporter)? { importers.first { $0.id == id } }
}
