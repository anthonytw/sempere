import ArgumentParser
import Foundation
import Sempere

// `sempere recordings …`: a note's recordings and where they are placed on
// its pages (`audio` items, format.md §8.2.9): what the app's Recordings list
// and the item on the page do, one delta per change, through the same
// `NoteOps` builders.

struct RecordingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recordings",
        abstract: "List a note's recordings and where they are on its pages; place, rename or delete one.",
        discussion: """
            A recording belongs to the note; an audio item shows it on a page (format.md §8.2.9), where the app \
            plays it. A recording is named by its id, an id prefix of at least 4 characters or its exact title. \
            Add one with `attach recording` (with --place to put it on a page in the same delta).
            """,
        subcommands: [RecordingsList.self, RecordingsPlace.self, RecordingsRename.self, RecordingsDelete.self]
    )
}

/// Where an audio item goes: `--page`, and `--frame` or `--at`/`--width`.
struct AudioPlacementOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The page (1-based, default 1).", valueName: "n"))
    var page: Int?

    @Option(name: .long, help: ArgumentHelp("The frame as x,y,w,h in points (default 300 × 96, centred, a margin from the top).", valueName: "x,y,w,h"))
    var frame: RectArgument?

    @Option(name: .long, help: ArgumentHelp("Top-left corner as x,y.", valueName: "x,y"))
    var at: PointArgument?

    @Option(name: .long, help: ArgumentHelp("Width in points (the height stays 96).", valueName: "pt"))
    var width: Double?

    func validate() throws {
        if let page, page < 1 { throw ValidationError("--page counts from 1") }
        if frame != nil && (at != nil || width != nil) { throw ValidationError("give --frame, or --at and --width, not both") }
        if let width, !(width.isFinite && width > 0) { throw ValidationError("--width must be positive") }
        if let frame, !(frame.rect.w > 0 && frame.rect.h > 0) { throw ValidationError("--frame needs a positive width and height") }
    }

    var isGiven: Bool { page != nil || frame != nil || at != nil || width != nil }

    /// The `audio` item for `recording` on the chosen page of `state`.
    func place(_ recording: Recording, in state: NoteState, recordings: [Recording]) throws -> (number: Int, placement: ItemPlacement) {
        let (n, page) = try targetPage(state, self.page)
        let placed = try translating {
            try NoteOps.placeRecording(recording.id, recordings: recordings, on: page, pageSize: state.meta.pageSize,
                                       frame: frame?.rect, at: at.map { ($0.x, $0.y) }, width: width)
        }
        return (n, placed)
    }
}

struct RecordingsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a note's recordings: start, length, title, transcript and the pages that show each."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Row: Encodable {
        var recording: Recording
        /// The `audio` items that show it, with their 1-based pages.
        var items: [AttachmentListing.PlacedItem]
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let state = try vault.reconstruct(try vault.loadNote(id, detail: .withoutStrokePoints))
        let placed = AttachmentListing.items(state).filter { $0.item.kind == .audio }
        let rows = AttachmentListing.recordings(state).sorted(by: Recording.sortsBefore).map { r in
            Row(recording: r, items: placed.filter { state.recording(shownBy: $0.item)?.id == r.id })
        }
        let orphans = placed.filter { state.recording(shownBy: $0.item) == nil }
        if output.json {
            struct Out: Encodable { var recordings: [Row]; var missing: [AttachmentListing.PlacedItem] }
            try output.emitJSON(Out(recordings: rows, missing: orphans))
            return
        }
        if rows.isEmpty && orphans.isEmpty { output.info("No recordings."); return }
        var table = output.quiet ? [] : [["STARTED", "LENGTH", "TITLE", "TRANSCRIPT", "PAGES", "ID"]]
        for r in rows {
            let pages = r.items.map { "p\($0.page)" }.joined(separator: ",")
            table.append([Format.local(r.recording.started), r.recording.duration.map(Transcript.clock) ?? "-",
                          "\"\(r.recording.title ?? "")\"", r.recording.transcript == nil ? "-" : "yes",
                          pages.isEmpty ? "-" : pages, r.recording.id.uuidString.lowercased()])
        }
        print(Format.table(table))
        for o in orphans {
            output.info("p\(o.page): audio item \(o.item.id.uuidString.lowercased().prefix(8)) shows a recording that is missing")
        }
    }
}

struct RecordingsPlace: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "place",
        abstract: "Put a recording on a page as an audio item (one addItem delta).",
        discussion: """
            The card is 300 × 96 points (narrower on a narrow page), centred across the page a margin from its \
            top, above the page's other items; --at and --width, or --frame, place it. A recording may be placed \
            any number of times. Prints the new item's id.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The recording: id, id prefix (4+ characters) or exact title.", valueName: "recording"))
    var recording: String

    @OptionGroup var placement: AudioPlacementOptions

    @Flag(name: .customLong("dry-run"), help: "Say what would be added; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws { try placement.validate() }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let before = try liveState(vault, id)
        let target = try resolveRecording(recording, in: before)
        var (n, placed) = try placement.place(target, in: before, recordings: before.recordings)
        var out = AttachJSON(note: id.uuidString.lowercased(), dryRun: dryRun)
        if !dryRun {
            let pageID = placed.page
            let revision = try editNote(vault, id) { state in
                try requireLive(state)
                guard let current = state.recordings.first(where: { $0.id == target.id }) else {
                    throw CLIError.failure("the recording was removed while the command ran")
                }
                let (m, page) = try pageWithID(pageID, in: state)
                n = m
                placed = try translating {
                    try NoteOps.placeRecording(current.id, recordings: state.recordings, on: page, pageSize: state.meta.pageSize,
                                               frame: placed.item.frame, id: placed.item.id)
                }
                return placed.ops
            }
            out.file = revision?.name.filename
        }
        out.items = [AttachmentListing.PlacedItem(page: n, pageId: placed.page, item: placed.item)]
        try report(out, output: output, summary: "recording \(target.id.uuidString.lowercased().prefix(8)) on page \(n)")
    }
}

struct RecordingsRename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Set a recording's title (one setRecording delta); an empty title clears it."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The recording: id, id prefix (4+ characters) or exact title.", valueName: "recording"))
    var recording: String

    @Argument(help: ArgumentHelp("The new title.", valueName: "title"))
    var title: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let target = try resolveRecording(recording, in: try liveState(vault, id))
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            guard let current = state.recordings.first(where: { $0.id == target.id }) else {
                throw CLIError.failure("the recording was removed while the command ran")
            }
            guard (current.title ?? "") != t else { return [] }
            return [.setRecording(recordingId: current.id, change: .title(t.isEmpty ? nil : t))]
        }
        try reportEdit(vault, id, r, output: output, done: "Renamed the recording", unchanged: "The recording already has that title.")
    }
}

struct RecordingsDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove a recording and the audio items that show it (one delta).",
        discussion: """
            The audio and transcript blobs stay until `blobs gc`; history can restore the recording. To take a \
            recording off a page but keep it, delete its audio item with `items delete`.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("The recording: id, id prefix (4+ characters) or exact title.", valueName: "recording"))
    var recording: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let target = try resolveRecording(recording, in: try liveState(vault, id))
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            return NoteOps.removeRecording(target.id, in: state)
        }
        try reportEdit(vault, id, r, output: output, done: "Deleted the recording", unchanged: "No such recording any more.")
    }
}
