import ArgumentParser
import Foundation
import Sempere
import SempereImport
import SempereRender

/// A type naming one importer, so that `RegisteredImportCommand` can be a distinct command type for
/// each (ArgumentParser needs a static command per name).
protocol ImporterTag {
    static var importer: any VaultImporter { get }
}

/// `sempere import <id> PATH...`: runs the importer `Tag.importer`. The importer's own flags come from
/// its option specs and are parsed here; the flags every import has (`--notebook`, `--dry-run`,
/// `--pdf-text`, `--recognize`, the vault and output options) are ArgumentParser's.
struct RegisteredImportCommand<Tag: ImporterTag>: ParsableCommand {
    static var configuration: CommandConfiguration {
        let importer = Tag.importer
        return CommandConfiguration(
            commandName: importer.id,
            abstract: importer.abstract,
            usage: "sempere import \(importer.id) [<options>] <path> ...",
            discussion: importer.discussion + "\n\n" + ImportOptionsHelp.text(for: importer)
        )
    }

    /// The paths and the importer's own flags (parsed by `ParsedImport`).
    @Argument(parsing: .allUnrecognized, help: ArgumentHelp("Paths, and the options listed under \"Import options\".", valueName: "path"))
    var rest: [String] = []

    @Option(name: .long, help: ArgumentHelp("File every note under this notebook.", valueName: "name"))
    var notebook: String?

    @Flag(name: .long, help: "Report what would happen without writing to the vault or the device state.")
    var dryRun = false

    @Option(name: .long, help: ArgumentHelp(
        "After importing, read the handwriting of pages the source app never indexed (macOS only).", valueName: "missing"))
    var recognize: RecognizeAfterImport?

    @OptionGroup var pdfText: PDFTextOptions

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    enum RecognizeAfterImport: String, ExpressibleByArgument, CaseIterable {
        case missing
    }

    func validate() throws {
        let importer = Tag.importer
        if recognize != nil && !importer.supportsRecognizeAfter {
            throw ValidationError("--recognize is not offered for \(importer.displayName) imports")
        }
        let parsed = try ParsedImport(rest, specs: importer.options)
        if parsed.paths.isEmpty { throw ValidationError("give at least one PATH") }
    }

    func run() throws {
        let importer = Tag.importer
        let parsed = try ParsedImport(rest, specs: importer.options)
        // Refused before anything is imported, not after.
        if recognize != nil && !dryRun && !RecognitionRun.available { throw RecognitionRun.unavailable }
        let extractor = importer.usesPDFText ? try pdfText.extractor() : nil
        let urls = parsed.paths.map { URL(fileURLWithPath: $0) }
        func request(_ vault: Vault, _ device: DeviceID) -> ImporterRequest {
            ImporterRequest(paths: urls, vault: vault, device: device, options: parsed.values, pdfText: extractor, notebook: notebook)
        }
        let result: ImporterResult
        var recognized: [RecognitionRun.NoteResult] = []
        /// Runs `--recognize` over the notes just written.
        func recognizeImported(_ result: ImporterResult, in vault: Vault) {
            guard recognize != nil else { return }
            recognized = result.writtenNotes.map { RecognitionRun.run(note: $0, vault: vault, mode: .missing, dryRun: dryRun) }
        }
        if dryRun {
            // Import into a throwaway copy of the vault with a throwaway device.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("sempere-dry-run-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let source = try access.vaultURL()
            try Vault.open(at: source).requireMigrated()   // refused before copying anything
            let copy = scratch.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: copy)
            } catch {
                throw CLIError.failure("cannot prepare dry run: \(error.localizedDescription)")
            }
            let vault = try access.openVault(at: copy, .required, trust: scratchTrustStore(for: source))
            var clock = HybridClock()
            let device = DeviceID.random()
            result = try importer.run(request(vault, device), clock: &clock)
            recognizeImported(result, in: vault)
        } else {
            let vault = try access.openVault(.required)
            try vault.requireWritable()   // format.md §7.3: exit 7, not a per-note failure
            let stateURL = DeviceState.defaultURL()
            var state = try DeviceState.loadOrCreate(at: stateURL)
            var clock = state.clock
            defer {
                // Keep the clock even when the import throws half way.
                state.clock = clock
                try? state.save(to: stateURL)
            }
            result = try importer.run(request(vault, state.device), clock: &clock)
            // Recognition writes through the device state file: save the import's clock first.
            state.clock = clock
            try state.save(to: stateURL)
            recognizeImported(result, in: vault)
            if let saved = try? DeviceState.loadOrCreate(at: stateURL) { state = saved; clock = saved.clock }
        }
        let recognition: ImporterRecognition? = recognize == nil ? nil : ImporterRecognition(
            results: recognized.map { AnyEncodable($0) },
            pagesRead: recognized.reduce(0) { $0 + $1.read.count },
            notesRead: recognized.filter { !$0.read.isEmpty }.count,
            failures: recognized.compactMap { r in r.error.map { (note: r.note, error: $0) } })
        let presentation = result.presentation(ImporterStyle(json: output.json, quiet: output.quiet, verbose: output.verbose,
                                                              dryRun: dryRun), recognition: recognition)
        if let json = presentation.json { try output.emitJSON(json) }
        for line in presentation.lines {
            if line.isError { printStderr(line.text) } else { print(line.text) }
        }
        if let failure = presentation.failure { throw CLIError.failure(failure) }
    }
}

/// The command line of an import after ArgumentParser took the flags every import has: the importer's
/// flags (by its option specs) and the paths.
struct ParsedImport {
    var paths: [String] = []
    var values = ImporterOptionValues()

    init(_ arguments: [String], specs: [ImporterOptionSpec]) throws {
        var i = 0
        var onlyPaths = false
        while i < arguments.count {
            let token = arguments[i]
            i += 1
            guard !onlyPaths, token.hasPrefix("--"), token.count > 2 else {
                if token == "--" { onlyPaths = true } else { paths.append(token) }
                continue
            }
            var name = String(token.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            guard let spec = specs.first(where: { $0.cliName == name }) else {
                throw ValidationError("Unknown option '--\(name)'")
            }
            switch spec.kind {
            case .flag(let defaultOn):
                if inline != nil { throw ValidationError("The flag '--\(name)' does not take a value") }
                values.values[spec.id] = .bool(!defaultOn)
            case .text(let valueName):
                values.values[spec.id] = .text(try Self.value(inline, arguments, &i, name: name, valueName: valueName))
            case .list(let valueName):
                let v = try Self.value(inline, arguments, &i, name: name, valueName: valueName)
                values.values[spec.id] = .list(values.list(spec.id) + [v])
            }
        }
    }

    private static func value(_ inline: String?, _ arguments: [String], _ i: inout Int, name: String, valueName: String) throws -> String {
        if let inline { return inline }
        guard i < arguments.count else { throw ValidationError("Missing value for '--\(name) <\(valueName)>'") }
        i += 1
        return arguments[i - 1]
    }
}

/// The importer's own flags as help text (ArgumentParser lists only the flags every import has).
enum ImportOptionsHelp {
    static func text(for importer: any VaultImporter) -> String {
        let rows: [(String, String)] = importer.options.compactMap { spec in
            guard let name = spec.cliName else { return nil }
            switch spec.kind {
            case .flag: return ("--\(name)", spec.help)
            case .text(let v), .list(let v): return ("--\(name) <\(v)>", spec.help)
            }
        }
        let width = rows.map(\.0.count).max() ?? 0
        let lines = rows.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
        return (["Import options:"] + lines).joined(separator: "\n")
    }
}
