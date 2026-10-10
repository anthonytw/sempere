import ArgumentParser
import Foundation
import Sempere
import SempereRender

/// `sempere recognize-math`: handwritten math → LaTeX → a math item, as the
/// app's "Convert to Math" (docs/attachments.md §14 G1 part 2): the same
/// lasso rule (`InkLasso`), image (`MathInkImage`), recogniser
/// (`CoreMLMathRecognizer`, macOS) and conversion (`NoteOps.convertInk`, one delta).
struct RecognizeMathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recognize-math",
        abstract: "Read handwritten math on a page as LaTeX, and optionally turn it into an equation.",
        discussion: """
            Pick the ink with --strokes (stroke ids, or unique id prefixes of 4+ characters), --rect x,y,w,h \
            or --lasso "x,y x,y x,y ..." (page points; a stroke is taken when at least half of it is inside), \
            or --all-ink (every stroke on the page except markers' highlights). The ink is drawn as the model \
            wants it (black lines of one width, scaled into its input image) and read on this machine by a \
            converted model (--model FOLDER, with manifest.json; every file is checked against its SHA-256 \
            first). Core ML runs models on macOS only: elsewhere, give the reading yourself with --latex (or \
            --latex-file) to convert ink with a source made elsewhere.

            Without --place nothing is written: the readings are printed, best first. --place replace removes \
            the strokes and adds the equation where they were, in one delta; --place beside keeps the ink and \
            adds the equation to its right (or below it). The equation is as tall as the ink. The CLI has no \
            typesetter: the item has no rendering until the app typesets it (see `attach math`). \
            --save-image writes the image the model reads (a PNG), also without a model (a default size).
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("The page (1-based, default 1).", valueName: "n"))
    var page: Int?

    @Option(name: .long, parsing: .upToNextOption, help: ArgumentHelp("Stroke ids or unique prefixes (4+ characters), space- or comma-separated.", valueName: "id"))
    var strokes: [String] = []

    @Option(name: .long, help: ArgumentHelp("Take the ink inside this rectangle (page points).", valueName: "x,y,w,h"))
    var rect: RectArgument?

    @Option(name: .long, help: ArgumentHelp("Take the ink inside this loop of page points.", valueName: "\"x,y x,y x,y ...\""))
    var lasso: String?

    @Flag(name: .customLong("all-ink"), help: "Take every stroke on the page.")
    var allInk = false

    @Option(name: .long, help: ArgumentHelp("A converted model folder (manifest.json and its files).", valueName: "folder"))
    var model: String?

    @OptionGroup var source: LatexInput

    @Option(name: .long, help: ArgumentHelp("Turn the ink into an equation: replace (the ink goes) or beside.", valueName: "how"))
    var place: MathPlacementChoice?

    @Option(name: .long, help: ArgumentHelp("Which reading to place (1-based, default 1).", valueName: "n"))
    var candidate: Int = 1

    @Flag(name: .long, help: "Text (inline) style instead of display style.")
    var inline = false

    @Option(name: .long, help: ArgumentHelp("Font size in points (default 20).", valueName: "pt"))
    var size: Double = 20

    @Option(name: .long, help: ArgumentHelp("Colour as #RRGGBB or #RRGGBBAA (default black).", valueName: "hex"))
    var color: ColorArgument?

    @Option(name: .customLong("save-image"), help: ArgumentHelp("Write the image the model reads to this PNG file.", valueName: "file"))
    var saveImage: String?

    @Flag(name: .customLong("dry-run"), help: "With --place: say what would be written; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        let selections = [!strokes.isEmpty, rect != nil, lasso != nil, allInk].filter { $0 }.count
        guard selections == 1 else { throw ValidationError("pick the ink with one of --strokes, --rect, --lasso or --all-ink") }
        if let page, page < 1 { throw ValidationError("--page counts from 1") }
        try source.validate(required: false)
        if source.given && model != nil { throw ValidationError("give --model to read the ink, or --latex, not both") }
        if !source.given && model == nil && saveImage == nil {
            throw ValidationError("give --model FOLDER to read the ink (macOS), or --latex SOURCE")
        }
        if place == nil && dryRun { throw ValidationError("--dry-run goes with --place") }
        guard candidate >= 1 else { throw ValidationError("--candidate counts from 1") }
        guard size.isFinite, size > 0, size <= TextContent.Limits.size else {
            throw ValidationError("--size must be greater than 0 and at most \(Int(TextContent.Limits.size))")
        }
        if let lasso, Self.parseLasso(lasso) == nil {
            throw ValidationError("--lasso takes at least three points as \"x,y x,y x,y\"")
        }
    }

    /// `"x,y x,y …"` as lasso points; nil when fewer than three parse.
    static func parseLasso(_ text: String) -> [InkLasso.Point]? {
        var points: [InkLasso.Point] = []
        for piece in text.split(whereSeparator: { $0 == " " || $0 == ";" }) {
            guard let p = PointArgument(argument: String(piece)) else { return nil }
            points.append(.init(x: p.x, y: p.y))
            guard points.count <= 100_000 else { return nil }
        }
        return points.count >= 3 ? points : nil
    }

    /// The image size used by --save-image without a model.
    static let previewSpec = MathImageSpec(width: 512, height: 128, padding: 8, strokeWidth: 3)

    /// The ids `strokes` names on `page`: full ids or unique prefixes.
    static func resolveStrokes(_ names: [String], on page: Page) throws -> [UUID] {
        let all = page.strokes.map(\.id)
        return try names.flatMap { $0.split(separator: ",") }.map { raw in
            try resolveIDPrefix(raw.trimmingCharacters(in: .whitespaces), kind: "stroke", among: all,
                                place: "on this page", id: { $0 })
        }
    }

    struct Output: Encodable {
        var note: String
        var page: Int
        var pageId: UUID
        var strokes: [String]
        var engine: String?
        var seconds: Double?
        var candidates: [MathCandidate]
        var placement: MathPlacement?
        var dryRun: Bool
        var file: String?
        var item: Item?
        var removed: [String]?
        var image: String?
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let state = try liveState(vault, id)
        let target = try targetPage(state, page)
        let ids: [UUID]
        if allInk {
            ids = target.page.strokes.filter { $0.ink.tool != .marker && !$0.points.isEmpty }.map(\.id)
        } else if let rect {
            let r = rect.rect
            let loop: [InkLasso.Point] = [.init(x: r.x, y: r.y), .init(x: r.x + r.w, y: r.y),
                                          .init(x: r.x + r.w, y: r.y + r.h), .init(x: r.x, y: r.y + r.h)]
            ids = InkLasso.select(target.page.strokes, lasso: loop)
        } else if let lasso, let points = Self.parseLasso(lasso) {
            ids = InkLasso.select(target.page.strokes, lasso: points)
        } else {
            ids = try Self.resolveStrokes(strokes, on: target.page)
        }
        guard !ids.isEmpty else { throw CLIError.failure("no strokes were picked on page \(target.number)") }
        let chosen = Set(ids)
        let ink = target.page.strokes.filter { chosen.contains($0.id) }

        var out = Output(note: id.uuidString.lowercased(), page: target.number, pageId: target.page.id,
                         strokes: ids.map { $0.uuidString.lowercased() }, candidates: [], placement: place?.placement,
                         dryRun: dryRun)
        // Core ML may write diagnostics to standard output: keep it for our own output (--json).
        let recognizer = try model.map { path in try Self.stdoutToStderr { try Self.loadModel(path) } }
        if let saveImage {
            let spec = recognizer?.imageSpec ?? Self.previewSpec
            guard let image = try MathInkImage.render(strokes: ink, spec: spec) else {
                throw CLIError.failure("the picked strokes have no ink to draw")
            }
            try image.png().write(to: URL(fileURLWithPath: saveImage))
            out.image = saveImage
        }
        if let given = try source.read() {
            out.candidates = [MathCandidate(latex: given)]
        } else if let recognizer {
            guard let result = try Self.stdoutToStderr({ try recognizer.recognize(strokes: ink) }) else {
                throw CLIError.failure("the picked strokes have no ink to read")
            }
            out.engine = result.engine
            out.seconds = result.seconds
            out.candidates = result.candidates
        }
        if let place {
            guard out.candidates.indices.contains(candidate - 1) else {
                throw CLIError.failure(out.candidates.isEmpty ? "nothing was read" : "there are \(out.candidates.count) reading(s)")
            }
            let latex = out.candidates[candidate - 1].latex
            let content = try translating { try NoteOps.math(latex, display: !inline, size: size, color: color?.color ?? .black) }
            var conversion = try translating {
                try NoteOps.convertInk(ids, toMath: content, on: target.page, pageSize: state.meta.pageSize, placement: place.placement)
            }
            if !dryRun {
                let pageID = target.page.id
                let revision = try editNote(vault, id) { now in
                    try requireLive(now)
                    let current = try pageWithID(pageID, in: now)
                    conversion = try translating {
                        try NoteOps.convertInk(ids, toMath: content, on: current.page, pageSize: now.meta.pageSize,
                                               placement: place.placement)
                    }
                    return conversion.ops
                }
                out.file = revision?.name.filename
            }
            out.item = conversion.item
            out.removed = conversion.removed.map { $0.uuidString.lowercased() }
        }
        try report(out)
    }

    /// Runs `body` with file descriptor 1 pointing at standard error, so
    /// whatever a framework prints there never mixes with our output.
    static func stdoutToStderr<T>(_ body: () throws -> T) rethrows -> T {
        fflush(nil)
        let saved = dup(1)
        guard saved >= 0, dup2(2, 1) >= 0 else {
            if saved >= 0 { close(saved) }
            return try body()
        }
        defer {
            fflush(nil)
            dup2(saved, 1)
            close(saved)
        }
        return try body()
    }

    #if canImport(CoreML)
    static func loadModel(_ path: String) throws -> any MathRecognizing {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let manifest = try MathModelStore.manifest(in: folder)
            try MathModelStore.verify(manifest, in: folder)
            return try CoreMLMathRecognizer(folder: folder, manifest: manifest)
        } catch let e as MathModelManifest.Failure {
            throw CLIError.failure("\(path): \(e)")
        }
    }
    #else
    static func loadModel(_ path: String) throws -> any MathRecognizing {
        throw CLIError.failure(
            "reading handwritten math needs Core ML, so it runs only in the macOS build of sempere (or in the app); "
                + "give the reading with --latex instead. Nothing was changed")
    }
    #endif

    func report(_ out: Output) throws {
        if output.json { try output.emitJSON(out); return }
        if place == nil || output.verbose {
            for (i, c) in out.candidates.enumerated() {
                let score = c.score.map { String(format: "  (%.3f)", $0) } ?? ""
                print("\(i + 1). \(c.latex)\(score)")
            }
        }
        if let item = out.item, !dryRun { print(item.id.uuidString.lowercased()) }
        let what = place.map { $0 == .replace ? "replaced \(out.strokes.count) stroke(s) with an equation" : "added an equation beside \(out.strokes.count) stroke(s)" }
        if let what {
            output.info("\(dryRun ? "Dry run: would have " : "")\(what) on page \(out.page)\(out.file.map { " (\(out.note)/\($0))" } ?? "")")
        } else {
            output.info("Read \(out.strokes.count) stroke(s) on page \(out.page)\(out.seconds.map { String(format: " in %.2f s", $0) } ?? ""); nothing was written.")
        }
    }
}

enum MathPlacementChoice: String, ExpressibleByArgument, CaseIterable {
    case replace, beside
    var placement: MathPlacement { self == .replace ? .replace : .beside }
}
