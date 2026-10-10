import ArgumentParser
import Dispatch
import Foundation
import Sempere
import SempereSpeech

/// `sempere transcribe`: on-device transcription of a note's recordings
/// (docs/attachments.md §13), the app's engine (`SpeechTranscription`):
/// SpeechTranscriber on macOS 26, else SFSpeechRecognizer on device only.
/// The Speech framework exists on Apple platforms only.
struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe recordings on this Mac (Speech framework, on device) and store the transcripts.",
        discussion: """
            Each recording's audio is decrypted into a private temporary file (mode 0600, deleted afterwards), \
            transcribed on this machine, and stored as a transcript blob (format.md §8.3.2: segments with \
            per-word timings and confidence, the language and the engine), then set on the recording, one \
            delta per note. Nothing is sent to a server: a language without an on-device model is an error.

            The language is --language, else the note's language, else this machine's. The engine is \
            SpeechTranscriber (macOS 26 and later), falling back to SFSpeechRecognizer with on-device \
            recognition only (which needs an app's speech recognition permission, so from the command line \
            it is used only when that permission is already granted). --engine picks one.

            By default only recordings without a transcript are read; --force replaces existing transcripts. \
            --dry-run lists them without reading (this works on Linux too). --check prints which engines can \
            transcribe here and needs no vault. --download-model installs SpeechTranscriber's model for the \
            language through Apple's asset service (what the app's Settings button does; also no vault), and \
            a transcription downloads a missing model itself unless --no-download. macOS only: elsewhere the command exits 1 and changes nothing.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title (all notes with --all).", valueName: "id|title"))
    var note: String?

    @Argument(help: ArgumentHelp("Recordings of the note: id, id prefix (4+ characters) or exact title. Default: all.",
                                 valueName: "recording"))
    var recordings: [String] = []

    @Flag(name: .long, help: "Every note that is not deleted.")
    var all = false

    @Option(name: .long, help: ArgumentHelp("Language to transcribe in (BCP 47, e.g. es-ES).", valueName: "tag"))
    var language: String?

    @Option(name: .long, help: ArgumentHelp("auto, speechtranscriber or sfspeech.", valueName: "engine"))
    var engine: String = "auto"

    @Flag(name: .long, help: "Replace transcripts that exist.")
    var force = false

    @Flag(name: .customLong("dry-run"), help: "Only list the recordings that would be transcribed.")
    var dryRun = false

    @Flag(name: .long, help: "Print which engines can transcribe here (no vault needed).")
    var check = false

    @Flag(name: .customLong("no-download"), help: "Never download an on-device speech model.")
    var noDownload = false

    @Flag(name: .customLong("download-model"),
          help: "Download SpeechTranscriber's on-device model for --language (or this machine's), as the app's Settings button does; no vault needed.")
    var downloadModel = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if downloadModel && (check || dryRun || noDownload || all || note != nil) {
            throw ValidationError("--download-model stands alone (it takes only --language)")
        }
        if let language, TranscriptionLanguage.tag(language) == nil { throw ValidationError("--language is not a language tag: \(language)") }
        if downloadModel || check { return }
        if all == (note != nil) { throw ValidationError("give a note id or title, or --all") }
        if all && !recordings.isEmpty { throw ValidationError("recordings can be named only with one note") }
        if engineChoice == nil && engine != "auto" { throw ValidationError("--engine must be auto, speechtranscriber or sfspeech") }
        if let language, TranscriptionLanguage.tag(language) == nil { throw ValidationError("--language is not a language tag: \(language)") }
    }

    var engineChoice: TranscriptionEngine? { TranscriptionEngine(rawValue: engine) }

    var options: SpeechTranscription.Options {
        SpeechTranscription.Options(language: language, engine: engineChoice, allowModelDownload: !noDownload)
    }

    static let unavailable = CLIError.failure(
        "\(SpeechTranscriptionError.unavailable); nothing was changed")

    func run() throws {
        if downloadModel {
            if !SpeechTranscription.isSupported { throw Self.unavailable }
            let options = self.options
            try blockingThrowing { try await SpeechTranscription.downloadModel(options: options) }
            output.info("The on-device speech model is installed.")
            return
        }
        if check {
            let options = self.options
            let statuses = blocking { await SpeechTranscription.availability(options: options) } ?? []
            if output.json {
                struct Out: Encodable { var supported: Bool; var engines: [SpeechTranscription.EngineStatus] }
                try output.emitJSON(Out(supported: SpeechTranscription.isSupported, engines: statuses))
            } else {
                for s in statuses {
                    print("\(s.engine): \(s.available ? "available" : "unavailable")\(s.language.map { " (\($0))" } ?? "") – \(s.detail)")
                }
            }
            return
        }
        if !dryRun && !SpeechTranscription.isSupported { throw Self.unavailable }
        let vault = try access.openVault(.required)
        if !dryRun { try vault.requireWritable() }   // format.md §7.3: exit 7, not a failure per recording
        let ids: [UUID]
        if all {
            ids = try vault.summaries(of: nil).filter { !$0.deleted && $0.recordings > 0 }.map(\.id)
        } else {
            ids = [try vault.resolveNote(note ?? "")]
        }
        let results = ids.map { run(note: $0, vault: vault) }
        if output.json {
            struct Out: Encodable { var dryRun: Bool; var notes: [NoteResult] }
            try output.emitJSON(Out(dryRun: dryRun, notes: results))
        } else {
            for r in results {
                let title = r.title.isEmpty ? "(untitled)" : r.title
                if let error = r.error { printStderr("failed \(r.note) \(title): \(error)") }
                for rec in r.recordings {
                    let name = rec.id.prefix(8) + (rec.title.map { " \($0)" } ?? "")
                    if let error = rec.error {
                        printStderr("failed \(r.note.prefix(8)) recording \(name): \(error)")
                    } else if dryRun {
                        output.info("\(r.note.prefix(8)) \(title): would transcribe recording \(name)")
                    } else {
                        output.info("\(r.note.prefix(8)) \(title): recording \(name): \(rec.segments ?? 0) segment(s), "
                                    + "\(rec.words ?? 0) word(s), \(rec.language ?? "?"), \(rec.engine ?? "?")")
                    }
                }
            }
            let done = results.reduce(0) { $0 + $1.recordings.filter { $0.error == nil }.count }
            output.info("\(dryRun ? "Dry run: " : "")\(done) recording(s) \(dryRun ? "would be transcribed" : "transcribed").")
        }
        let failed = results.filter { $0.error != nil || $0.recordings.contains { $0.error != nil } }.count
        if failed > 0 { throw CLIError.failure("\(failed) note(s) had recordings that could not be transcribed") }
    }

    struct RecordingResult: Encodable {
        var id: String
        var title: String?
        var engine: String?
        var language: String?
        var segments: Int?
        var words: Int?
        var transcript: BlobRef?
        var error: String?
    }

    struct NoteResult: Encodable {
        var note: String
        var title: String
        var recordings: [RecordingResult] = []
        /// The delta written, a file name in the note's folder.
        var file: String?
        var error: String?
    }

    private func run(note id: UUID, vault: Vault) -> NoteResult {
        var result = NoteResult(note: id.uuidString.lowercased(), title: "")
        do {
            let state = try vault.reconstruct(try vault.loadNote(id, detail: .withoutStrokePoints))
            result.title = state.meta.title
            try requireLive(state)
            var targets: [Recording]
            if recordings.isEmpty {
                targets = state.recordings.sorted(by: Recording.sortsBefore)
                if !force { targets = targets.filter { $0.transcript == nil } }
            } else {
                var seen = Set<UUID>()
                targets = try recordings.map { try resolveRecording($0, in: state) }.filter { seen.insert($0.id).inserted }
            }
            if dryRun {
                result.recordings = targets.map { RecordingResult(id: $0.id.uuidString.lowercased(), title: $0.title) }
                return result
            }
            var written: [(UUID, BlobRef, Data)] = []
            let options = self.options
            let noteLanguage = TranscriptionLanguage.noteLanguage(of: state.meta)
            for r in targets {
                var out = RecordingResult(id: r.id.uuidString.lowercased(), title: r.title)
                do {
                    var o = options
                    o.noteLanguage = noteLanguage
                    let opts = o
                    let ext = r.blob.type.lowercased().hasPrefix("audio/mp4") ? "m4a" : nil
                    let transcript: Transcript = try vault.withBlobFile(note: id, r.blob, pathExtension: ext) { url in
                        try blockingThrowing { try await SpeechTranscription.transcribe(file: url, recording: r.id, options: opts) }
                    }
                    let content = try transcript.encoded()
                    let ref = try vault.writeBlob(note: id, content, type: BlobRef.transcriptType)
                    written.append((r.id, ref, content))
                    out.engine = transcript.engine
                    out.language = transcript.language
                    out.segments = transcript.segments.count
                    out.words = transcript.segments.reduce(0) { $0 + ($1.words?.count ?? 0) }
                    out.transcript = ref
                } catch {
                    out.error = (error as? SpeechTranscriptionError)?.description ?? CLIError.from(error).message
                }
                result.recordings.append(out)
            }
            guard !written.isEmpty else { return result }
            let revision = try editNote(vault, id) { state in
                try requireLive(state)
                var ops: [Op] = []
                for (rid, ref, content) in written where state.recordings.contains(where: { $0.id == rid }) {
                    ops += try NoteOps.setTranscript(ref, content: content, for: rid, in: state)
                }
                return ops
            }
            result.file = revision?.name.filename
        } catch {
            result.error = CLIError.from(error).message
        }
        return result
    }
}

/// Runs `body` to completion from synchronous code (the command's `run`).
final class AsyncBox<T>: @unchecked Sendable {
    var result: Result<T, Error> = .failure(CancellationError())
}

func blockingThrowing<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = AsyncBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result.get()
}

func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
    try? blockingThrowing { await body() }
}
