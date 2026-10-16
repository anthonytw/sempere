import ArgumentParser
import Foundation
import Sempere

/// `sempere pages scribble`: synthetic handwriting on a page, for fixtures, stress tests and
/// benchmarks (a dense page, a note with many revisions, ink linked to a long recording).
struct PagesScribble: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scribble",
        abstract: "Write synthetic handwriting onto a page (for test fixtures and benchmarks).",
        discussion: """
            Adds --strokes seeded, word-like strokes (SyntheticInk: rows of small pen loops between the \
            margins, --row-height apart, starting at --top) to page --page as addStroke ops, \
            --per-revision of them to a delta (default: all in one), so --per-revision 1 leaves one \
            revision per stroke. The same --seed gives the same geometry; stroke ids are new every \
            run. --recording links the strokes to a recording of the note (format.md §5.6 `rec`), \
            spread evenly over its length, as if written while it played. With --json prints the \
            note, the files written and the number of strokes.
            """
    )

    @Argument(help: ArgumentHelp("Note id, id prefix or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("The page (1-based).", valueName: "n"))
    var page = 1

    @Option(name: .long, help: ArgumentHelp("How many strokes (1-200000).", valueName: "n"))
    var strokes = 1000

    @Option(name: .long, help: ArgumentHelp("Control points per stroke (2-500).", valueName: "n"))
    var points = 24

    @Option(name: .long, help: ArgumentHelp("Strokes per delta (default: all in one).", valueName: "n"))
    var perRevision: Int?

    @Option(name: .long, help: ArgumentHelp("The seed of the geometry.", valueName: "n"))
    var seed: UInt64 = 1

    @Option(name: .long, help: ArgumentHelp("The first row's baseline, in page points.", valueName: "y"))
    var top: Double = 48

    @Option(name: .long, help: ArgumentHelp("Distance between rows, in page points (4-200).", valueName: "pt"))
    var rowHeight: Double = 24

    @Option(name: .long, help: ArgumentHelp("Link the strokes to this recording of the note (id or id prefix).",
                                            valueName: "id"))
    var recording: String?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if !(1...200_000).contains(strokes) { throw ValidationError("--strokes must be between 1 and 200000") }
        if !(2...500).contains(points) { throw ValidationError("--points must be between 2 and 500") }
        if let perRevision, perRevision < 1 { throw ValidationError("--per-revision must be at least 1") }
        if !(top.isFinite && top >= 0 && top < 1_000_000) { throw ValidationError("--top must be between 0 and 1000000") }
        if !(rowHeight.isFinite && (4...200).contains(rowHeight)) { throw ValidationError("--row-height must be between 4 and 200") }
    }

    struct Result: Encodable {
        var note: NoteJSON
        var page: String
        var strokes: Int
        var files: [String]
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let state = try vault.reconstruct(noteId: id)
        try requireLive(state)
        let target = try pageNumbered(page, of: state)
        let link = try recording.map { prefix -> SyntheticInk.Recording in
            let matches = state.recordings.filter { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
            guard matches.count == 1, let r = matches.first else {
                throw CLIError.failure(matches.isEmpty ? "no recording \(prefix) in the note"
                                                       : "\(prefix) names more than one recording")
            }
            return SyntheticInk.Recording(id: r.id, duration: r.duration ?? 0)
        }
        let width = state.meta.pageSize.width
        var ink = SyntheticInk(seed: seed, options: .init(pointsPerStroke: points, pageWidth: width.isFinite && width > 100 ? width : 612,
                                                          rowHeight: rowHeight, top: top))
        let deltas = ink.deltas(strokes, page: target.id, perRevision: perRevision ?? strokes, recording: link)
        let files = try vault.applyInOrder(deltas, to: id, deviceState: DeviceState.defaultURL(), app: appName)
            .map(\.name.filename)
        let name = id.uuidString.lowercased()
        if output.json {
            try output.emitJSON(Result(note: NoteJSON(try vault.summary(of: id)), page: target.id.uuidString.lowercased(),
                                       strokes: strokes, files: files))
        } else {
            output.info("Wrote \(strokes) stroke(s) onto page \(page) in \(files.count) revision(s) (\(name))")
        }
    }
}
