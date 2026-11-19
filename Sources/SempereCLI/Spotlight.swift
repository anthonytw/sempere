import ArgumentParser
import Foundation
import Sempere

/// `sempere spotlight`: what the app's Spotlight switch would donate (docs/design/1.3-spotlight.md §5).
struct SpotlightCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spotlight",
        abstract: "Show what the app's opt-in Spotlight indexing would donate (the CLI never indexes).",
        discussion: """
            Indexing itself is app-only: Core Spotlight items belong to an app's bundle identity, which a command-line \
            binary does not have. `plan` runs the same planner the app does, so you can audit what turning the switch on \
            exposes outside the vault's encryption before enabling it.
            """,
        subcommands: [SpotlightPlanCommand.self]
    )
}

struct SpotlightPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "List what would be donated to Spotlight: one record per note, and the caps. Writes nothing.",
        discussion: """
            By default the title, notebook, tags and modified date of each note (the "Show This Vault's Notes in \
            Spotlight" switch). --text adds what "Include Note Text" adds: recognized handwriting, typed text, PDF \
            text and equations' source, the first 20,000 characters of each note (shown here as a length); with \
            --transcripts also recording transcripts (the app follows the Search Recording Transcripts setting). \
            Deleted notes are never included; thumbnails, insight summaries and embeddings never are.
            """
    )

    @Flag(name: .long, help: "Include note text (Include Note Text).")
    var text = false

    @Flag(name: .long, help: "With --text, include recording transcripts (decrypts each one).")
    var transcripts = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    func validate() throws {
        if transcripts && !text { throw ValidationError("--transcripts needs --text") }
    }

    struct Record: Encodable {
        var id: String
        var note: String
        var domain: String
        var title: String
        var description: String
        var keywords: [String]
        var modified: Date?
        /// Characters of text that would be donated (0: none).
        var textLength: Int
    }

    struct Caps: Encodable {
        var textCharacters = SpotlightPlanner.maxTextCharacters
        var descriptionTextCharacters = SpotlightPlanner.descriptionTextCharacters
        var notes = SpotlightPlanner.maxNotes
        var expiryDays = SpotlightPlanner.expiryDays
    }

    struct Report: Encodable {
        var vault: String
        var includeText: Bool
        var items: [Record]
        var omitted: Int
        var caps: Caps
    }

    func run() throws {
        let vault = try access.openVault(.required)
        OpenedVaults.shared.markUnchanged(vault.url)
        try vault.requireCompleteCopy()
        let notes = try vault.summaries(of: nil, cache: cache.cache(for: vault))
        var read: [UUID: [String]] = [:]
        var problems = 0
        if transcripts {
            for note in notes where !note.deleted {
                for recording in note.transcribed {
                    do {
                        let data = try vault.readBlob(note: note.id, recording.blob, maxBytes: Transcript.maxSize)
                        let transcript = try Transcript.decode(data)
                        guard transcript.recording == recording.recording else { throw CLIError.failure("it names another recording") }
                        read[note.id, default: []].append(transcript.spotlightText)
                    } catch {
                        problems += 1
                        printStderr("warning: cannot read a transcript in note \(note.id.uuidString.lowercased()): \(CLIError.from(error).message)")
                    }
                }
            }
        }
        let plan = SpotlightPlanner.plan(vaultId: vault.vaultId, notes: notes, options: SpotlightOptions(includeText: text),
                                         transcripts: read, shownTitles: NoteTitles.display(notes, in: vault))
        let records = plan.items.map {
            Record(id: $0.id, note: $0.noteId.uuidString.lowercased(), domain: $0.domain, title: $0.title,
                   description: $0.contentDescription, keywords: $0.keywords, modified: $0.modified,
                   textLength: $0.textContent?.count ?? 0)
        }
        if output.json {
            try output.emitJSON(Report(vault: vault.vaultId.uuidString.lowercased(), includeText: text, items: records,
                                       omitted: plan.omitted, caps: Caps()))
        } else if records.isEmpty {
            output.info("Nothing would be donated.")
        } else {
            var rows = output.quiet ? [] : [["ID", "TITLE", "DESCRIPTION", "KEYWORDS", "TEXT"]]
            for r in records {
                rows.append([r.id, r.title, r.description, r.keywords.joined(separator: ","), String(r.textLength)])
            }
            print(Format.table(rows))
            if plan.omitted > 0 { print("\(plan.omitted) older note(s) beyond the \(SpotlightPlanner.maxNotes)-note cap left out.") }
        }
        if problems > 0 { throw CLIError.failure("\(problems) transcript(s) could not be read") }
    }
}
