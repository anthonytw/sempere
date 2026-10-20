import ArgumentParser
import Foundation
import Sempere
import SempereRender

/// `sempere notes dense`: a dense note for performance work (open time, scroll and zoom pacing,
/// memory): many pages or one long page, tens of thousands of strokes and pictures.
struct NotesDense: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dense",
        abstract: "Create a dense note: many pages, many strokes and images (for benchmarks).",
        discussion: """
            Writes a new note of --pages pages (or, with --pageless, one long page) holding --strokes \
            seeded synthetic strokes in all (SyntheticInk, as `pages scribble`), spread evenly over the \
            pages, and --images pictures (seeded noise PNGs of --image-size pixels, stored as blobs and \
            placed down the pages, one after another). The same --seed gives the same geometry and \
            pictures; ids are new every run. One delta makes the note and its pages, then one delta \
            per page holds its strokes and pictures, as a writer that saves a page at a time would. \
            Prints the note's id (--json: the note, the pages, strokes and images written).
            """
    )

    @Argument(help: ArgumentHelp("The title.", valueName: "title"))
    var title: String

    @Option(name: .long, help: ArgumentHelp("How many pages (1-500).", valueName: "n"))
    var pages = 40

    @Option(name: .long, help: ArgumentHelp("Strokes in all (0-500000).", valueName: "n"))
    var strokes = 20_000

    @Option(name: .long, help: ArgumentHelp("Control points per stroke (2-500).", valueName: "n"))
    var points = 16

    @Option(name: .long, help: ArgumentHelp("Pictures in all (0-500).", valueName: "n"))
    var images = 12

    @Option(name: .customLong("image-size"), help: ArgumentHelp("Width and height of each picture, in pixels (16-2048).",
                                                                 valueName: "px"))
    var imageSize = 480

    @Option(name: .long, help: ArgumentHelp("The seed of the geometry and pictures.", valueName: "n"))
    var seed: UInt64 = 1

    @Option(name: .long, help: ArgumentHelp("Put the note in this notebook.", valueName: "path"))
    var notebook: String?

    @Flag(name: .long, help: "One long (infinite) page instead of --pages pages.")
    var pageless = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if !(1...500).contains(pages) { throw ValidationError("--pages must be between 1 and 500") }
        if !(0...500_000).contains(strokes) { throw ValidationError("--strokes must be between 0 and 500000") }
        if !(2...500).contains(points) { throw ValidationError("--points must be between 2 and 500") }
        if !(0...500).contains(images) { throw ValidationError("--images must be between 0 and 500") }
        if !(16...2048).contains(imageSize) { throw ValidationError("--image-size must be between 16 and 2048") }
    }

    struct Result: Encodable {
        var note: NoteJSON
        var pages: Int
        var strokes: Int
        var images: Int
        var files: [String]
    }

    func run() throws {
        let vault = try access.openVault(.required)
        var spec = DenseNote(title: title)
        spec.pages = pages; spec.strokes = strokes; spec.points = points; spec.images = images
        spec.imageSize = imageSize; spec.seed = seed; spec.notebook = notebook; spec.pageless = pageless
        let written = try translating { try spec.write(to: vault, deviceState: DeviceState.defaultURL(), app: appName) }
        let id = written.note
        if output.json {
            try output.emitJSON(Result(note: NoteJSON(try vault.summary(of: id)), pages: written.pages.count,
                                       strokes: strokes, images: images, files: written.files))
        } else if output.quiet {
            print(id.uuidString.lowercased())
        } else {
            print(id.uuidString.lowercased())
            printStderr("Wrote \(strokes) stroke(s) and \(images) image(s) on \(written.pages.count) page(s) in \(written.files.count) revision(s)")
        }
    }
}
