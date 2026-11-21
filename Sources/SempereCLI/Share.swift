import ArgumentParser
import Foundation
import Sempere
import SempereRender
import SempereShareViewer

/// `sempere share`: one note as a single encrypted web page (docs/design/1.3-share.md, docs/cli.md "share").
struct ShareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share",
        abstract: "Share one note as a single encrypted HTML file that opens in any browser.",
        discussion: """
            Writes FILE.html: the web viewer and the note (its pages as they look now, with images; never \
            its history, other notes, or any key of the vault), encrypted with a passphrase (age, scrypt \
            2^18, https://age-encryption.org). Send the file and the passphrase by different ways. The \
            recipient opens the file in a browser and types the passphrase; nothing is uploaded anywhere.

            The passphrase is never an argument (it would show in `ps`): --passphrase-file FILE (or - for \
            standard input), --share-passphrase-env VAR, or --generate-passphrase (seven random words, \
            printed once: in the JSON as `passphrase`, or on standard error). It must not be the vault's: \
            the variable the vault's passphrase comes from (--passphrase-env, $SEMPERE_PASSPHRASE) and a \
            passphrase equal to one the vault was opened with are refused (exit 2).

            Left out unless asked: tags (--tags), the notebook path (--notebook-path), the creation date \
            (--dates), recordings and their transcripts (--audio). Recognized text is included unless \
            --no-text. Images are re-encoded (at most 2048 px, JPEG) and lose their metadata; PDF pages \
            become pictures (Poppler's pdftoppm; without it they are left out); videos are never included. \
            The file name never carries the note's title: you choose it with --out, and a folder gets \
            "Shared note.html".

            The file is at most --max-size MB (default 20: most mail services take 20 to 25); a note that \
            cannot fit fails with where the bytes went, never a truncated file.

            `sempere share --verify FILE.html` checks that a file's script, style and Content-Security-Policy \
            are exactly this release's, and reports its scrypt work factor; it never decrypts anything. \
            The recipe without any Sempere code: sed -n '/-----BEGIN AGE ENCRYPTED FILE-----/,/-----END AGE \
            ENCRYPTED FILE-----/p' FILE.html | age -d > payload.bin (docs/web-viewer.md "Share files").
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String?

    @Option(name: .long, help: ArgumentHelp("The file to write (or a folder: the file is then \"Shared note.html\" in it).", valueName: "path"))
    var out: String?

    @Option(name: .customLong("passphrase-file"), help: ArgumentHelp("Read the passphrase from this file (- for standard input); one trailing newline is dropped.", valueName: "file"))
    var passphraseFile: String?

    @Option(name: .customLong("share-passphrase-env"), help: ArgumentHelp("Name of the environment variable holding the share's passphrase.", valueName: "var"))
    var passphraseEnv: String?

    @Flag(name: .customLong("generate-passphrase"), help: "Make a passphrase (seven random words) and print it once.")
    var generatePassphrase = false

    @Flag(name: .long, help: "Include the note's recordings and their transcripts.")
    var audio = false

    @Flag(name: .customLong("no-text"), help: "Leave out the recognized text.")
    var noText = false

    @Flag(name: .long, help: "Include the note's tags.")
    var tags = false

    @Flag(name: .customLong("notebook-path"), help: "Include the note's notebook path.")
    var notebookPath = false

    @Flag(name: .long, help: "Include the note's creation date.")
    var dates = false

    @Option(name: .customLong("max-size"), help: ArgumentHelp("The most the file may take, in MB (1 to 200).", valueName: "MB"))
    var maxSize: Int = 20

    @Option(name: .customLong("image-quality"), help: ArgumentHelp("How hard pictures are compressed.", valueName: "low|normal|high"))
    var imageQuality: WebShareOptions.ImageQuality = .normal

    @Option(name: .customLong("pdf-renderer"),
            help: "What draws PDF pages into pictures: auto (Poppler's pdftoppm when installed), poppler, none.")
    var pdfRenderer: PDFRendererChoice = .auto

    @Option(name: .customLong("pdf-timeout"), help: ArgumentHelp("Seconds Poppler may take per PDF page.", valueName: "seconds"))
    var pdfTimeout: Double = 30

    @Option(name: .long, help: ArgumentHelp("Check a share file against this release (script, style, Content-Security-Policy, work factor) instead of making one.", valueName: "file"))
    var verify: String?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Made: Encodable {
        struct Sections: Encodable { var ink: Int; var images: Int; var audio: Int; var template: Int }
        var file: String
        var bytes: Int
        var pages: Int
        var sections: Sections
        var scryptLog2N: Int
        var scriptSha256: String
        var skipped: [String]
        /// Only with --generate-passphrase.
        var passphrase: String?
    }

    struct Verified: Encodable {
        var file: String
        var ok: Bool
        var bytes: Int
        var matchesTemplate: Bool
        var policyMatches: Bool
        var scriptSha256: String
        var styleSha256: String
        var scryptLog2N: Int?
        var problems: [String]
    }

    func validate() throws {
        if verify != nil {
            if note != nil || out != nil { throw ValidationError("--verify takes only a file") }
            return
        }
        guard note != nil else { throw ValidationError("name the note to share (id or title), or use --verify FILE") }
        guard out != nil else { throw ValidationError("--out is required") }
        let sources = [passphraseFile != nil, passphraseEnv != nil, generatePassphrase].filter { $0 }.count
        guard sources == 1 else {
            throw ValidationError("give the passphrase with exactly one of --passphrase-file, --share-passphrase-env, --generate-passphrase")
        }
        guard (1...200).contains(maxSize) else { throw ValidationError("--max-size must be 1 to 200") }
        guard pdfTimeout > 0, pdfTimeout <= 3600 else { throw ValidationError("--pdf-timeout must be greater than 0 and at most 3600") }
    }

    private var template: ShareTemplate {
        get throws {
            guard let t = ShareTemplate(html: Data(ShareViewerTemplate.data)) else { throw CLIError.failure("this build's web viewer template is malformed") }
            return t
        }
    }

    func run() throws {
        if let verify { return try runVerify(verify) }
        guard let noteName = note, let outPath = out else { return }
        let (passphrase, generated) = try readPassphrase()
        if passphrase.isEmpty { throw CLIError.failure("the passphrase is empty") }
        if !generated { try refuseVaultPassphrase(passphrase, read: []) }
        let readBefore = PassphrasesRead.count
        let vault = try access.openVault(.required)
        if !generated { try refuseVaultPassphrase(passphrase, read: PassphrasesRead.since(readBefore)) }
        let id = try vault.resolveShownNote(noteName)
        let loaded = try vault.loadNote(id)
        let summary = vault.summary(of: id, loaded: loaded)
        if summary.deleted { printStderr("sempere: warning: \(id.uuidString.lowercased()) is deleted") }
        // The page shows the note's shown title, without the capture's date or time unless --dates.
        let state = try vault.reconstruct(loaded).showing(title: NoteTitles.share(summary, includeDates: dates, in: vault))

        var options = WebShareOptions()
        options.includeAudio = audio
        options.includeText = !noText
        options.includeTags = tags
        options.includeNotebookPath = notebookPath
        options.includeDates = dates
        options.maxFileBytes = maxSize << 20
        options.imageQuality = imageQuality
        let rasterizer: PopplerRasterizer?
        switch pdfRenderer {
        case .none: rasterizer = nil
        case .auto: rasterizer = PopplerRasterizer.locate().map { PopplerRasterizer(executable: $0, timeout: pdfTimeout) }
        case .poppler:
            guard let tool = PopplerRasterizer.locate() else {
                throw CLIError.failure("--pdf-renderer poppler: pdftoppm not found (install poppler-utils, or set SEMPERE_PDFTOPPM)")
            }
            rasterizer = PopplerRasterizer(executable: tool, timeout: pdfTimeout)
        }

        let result: WebShareResult
        do {
            result = try WebPageShare.make(state, blobs: vault.blobSource(note: id), options: options, passphrase: passphrase,
                                           template: try template, pdfRasterizer: rasterizer)
        } catch let e as WebShareError {
            throw CLIError.failure(e.description)
        }
        let target = try destination(outPath)
        try writeNewFileAtomically(target) { write in try write(result.file) }

        let made = Made(file: target.path, bytes: result.file.count, pages: result.pages,
                        sections: .init(ink: result.sections.ink, images: result.sections.images, audio: result.sections.audio,
                                        template: result.sections.template),
                        scryptLog2N: result.scryptLog2N, scriptSha256: result.scriptSha256, skipped: result.skipped,
                        passphrase: generated ? passphrase : nil)
        if output.json {
            try output.emitJSON(made)
        } else {
            output.info("Wrote \(target.path) (\(Format.bytes(made.bytes)): ink \(Format.bytes(made.sections.ink)), "
                + "images \(Format.bytes(made.sections.images)), audio \(Format.bytes(made.sections.audio)), "
                + "viewer \(Format.bytes(made.sections.template)))")
            if generated { printStderr("Passphrase: \(passphrase)") }
            output.info("Send the file and the passphrase by different ways. The recipient opens the file in a web browser.")
        }
        for s in result.skipped { printStderr("sempere: warning: \(s)") }
    }

    /// `--out`: a file, or a folder (then `Shared note.html` in it). The title never names the file.
    private func destination(_ path: String) throws -> URL {
        var isDir: ObjCBool = false
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return url.appendingPathComponent("Shared note.html")
        }
        return url
    }

    /// The recipient learns the share passphrase, so it must not be one that opens the vault: refused (exit 2) when
    /// `--share-passphrase-env` names the variable the vault is opened with, and when the passphrase equals a vault
    /// passphrase this process could read (`--passphrase-env`, `$SEMPERE_PASSPHRASE`) or did read (`read`).
    private func refuseVaultPassphrase(_ passphrase: String, read: Set<String>) throws {
        let vaultVariables = Set([access.passphraseEnv, "SEMPERE_PASSPHRASE"].compactMap { $0 })
        if let name = passphraseEnv, vaultVariables.contains(name) {
            throw CLIError.usage("--share-passphrase-env \(name) is the variable the vault's passphrase comes from: "
                + "use a passphrase of its own for the share")
        }
        let vaultPassphrases = read.union(vaultVariables.compactMap { Env.vars[$0] }.filter { !$0.isEmpty })
        if vaultPassphrases.contains(passphrase) {
            throw CLIError.usage("the share passphrase is the vault's passphrase: choose a different one (the recipient learns it)")
        }
    }

    private func readPassphrase() throws -> (String, Bool) {
        func trimmed(_ s: String) -> String {
            var t = s
            if t.hasSuffix("\n") { t.removeLast() }
            if t.hasSuffix("\r") { t.removeLast() }
            return t
        }
        if generatePassphrase { return (GeneratedPassphrase.make(), true) }
        if let name = passphraseEnv {
            guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else {
                throw CLIError.failure("the environment variable \(name) is not set or empty")
            }
            return (v, false)
        }
        guard let file = passphraseFile else { throw CLIError.usage("no passphrase source") }
        if file == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return (trimmed(String(decoding: data.prefix(4096), as: UTF8.self)), false)
        }
        do {
            let data = try BoundedRead.contents(of: URL(fileURLWithPath: file), maxBytes: 4096)
            return (trimmed(String(decoding: data, as: UTF8.self)), false)
        } catch {
            throw CLIError.failure("cannot read \(file): \(error.localizedDescription)")
        }
    }

    private func runVerify(_ path: String) throws {
        let data: Data
        do { data = try BoundedRead.contents(of: URL(fileURLWithPath: path), maxBytes: WebShareOptions.maxFileBytesLimit + (4 << 20)) } catch {
            throw CLIError.failure("cannot read \(path): \(error.localizedDescription)")
        }
        let v = try template.verify(file: data)
        let report = Verified(file: path, ok: v.ok, bytes: v.bytes, matchesTemplate: v.matchesTemplate, policyMatches: v.policyMatches,
                              scriptSha256: v.scriptSha256, styleSha256: v.styleSha256, scryptLog2N: v.scryptLog2N, problems: v.problems)
        if output.json {
            try output.emitJSON(report)
        } else if v.ok {
            output.info("\(path): matches this release's viewer (script sha256-\(v.scriptSha256), scrypt 2^\(v.scryptLog2N ?? 0)); nothing was decrypted")
        } else {
            for p in v.problems { printStderr("sempere: \(path): \(p)") }
        }
        if !v.ok { throw CLIError.failure("\(path) is not a share file made by this release") }
    }
}

extension WebShareOptions.ImageQuality: ExpressibleByArgument {}
