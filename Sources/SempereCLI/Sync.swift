import ArgumentParser
import Foundation
import Sempere
import SempereSync
import SempereWebDAV

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Mirror a vault with a remote store.",
        subcommands: [SyncWebDAVCommand.self, SyncFolderCommand.self]
    )
}

struct SyncWebDAVCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webdav",
        abstract: "Sync a vault with a WebDAV folder (no server logic needed).",
        discussion: """
            Uploads revision files the server lacks and downloads the ones the vault lacks; files under
            notes/ are write-once and never overwritten on either side. Each note's attachment blobs
            (notes/<id>/att/) are synced the same way, streamed from and to disk; an interrupted blob
            download continues on the next run. A blob dropped on one side is deleted on the other
            only if no revision of its note references it there (format.md §8.1.6), else copied back. vault.json is compared with the last sync; when both sides changed, both copies
            are kept (vault.conflict-<device>-<time>.json) and the exit code is 3. A deletion
            follows only when compaction allows it, which needs the vault unlocked (--identity, or
            --passphrase-env). Only https is accepted, plus http to localhost. The password
            is never taken from the command line: --password-env names the variable (default
            SEMPERE_WEBDAV_PASSWORD). The vault folder may be new or empty for a first pull.

            With the vault unlocked, the server's sempere-summaries.sealed (format.md §12, the note list
            the web viewer reads first) is rewritten for what the server holds after the sync, when its
            entries changed. --web-viewer creates it, and sempere-index.json (the one-request listing), on a
            server that has none. Neither is ever copied between the two sides.

            A remote vault.json whose device list changed without a valid tag (format.md §2.1) is never
            copied over the local one: it is reported as rejected and the exit code is 6 (checking a changed
            list needs the key: pass --identity or --passphrase-env).

            --push-only makes it a one-way mirror for a server that is not trusted to write back:
            it uploads what the server lacks, overwrites the server's vault.json from the
            local copy, and deletes on the server what local compaction or
            blob collection removed; it never downloads and never writes or deletes anything in the
            vault, so nothing the server holds can change it. Files only the server has, which
            no compaction explains, are listed as extraneous, and removed with --delete-extraneous.
            With --keep-server-changes, a server vault.json that changed since this
            device's last sync (another writer, such as another device's key change) is kept and reported
            as a conflict (exit 3) instead of being replaced; revisions and blobs still upload. This is how
            the app pushes a WebDAV vault.

            Every downloaded revision and blob is checked before it is placed (format.md §9.1): with the
            vault unlocked it must decrypt, verify its tag or keyed name and name this note and file; locked
            (or a first pull without --identity), only its age structure is checked. A file that fails is
            never placed: it is kept in a quarantine folder next to the sync state, listed as quarantined
            (exit 1), and not fetched again while it and the local vault.json are unchanged
            (--retry-quarantined fetches it again).

            Note folders are listed, the files the vault lacks downloaded, and the files the server lacks
            uploaded, --jobs at a time (default 6, 1 to 16); each download is still checked on its own, and
            a note's blobs travel before its revisions (with --fetch, the note folders and small revisions,
            default 4). Deletions and vault.json go one at a time. On a terminal, progress is shown on stderr (listing, then
            files and MB downloaded of the total); with --json, the report's "progress" object is the summary.

            A run is bounded as a whole: --max-notes, --max-entries (listed remote entries),
            --max-download-mib and --max-minutes. Reaching one stops the run with an error (exit 1); what
            was done so far is kept, and the next run continues.

            Partial copies (format.md §1.2, docs/io.md "Partial copies") are pulled in steps. --metadata-only
            makes one in a new folder (or continues one): vault.json, settings.age and the
            server's sealed summaries, plus one empty folder per note marked as not downloaded yet; a few
            requests whatever the size of the vault, nothing uploaded or deleted. --fetch then fetches what a
            partial copy lacks: every note not downloaded yet (or only those named with --note, an id or id
            prefix), as the server holds it now, and their attachment blobs; with --no-blobs, revisions only
            (blobs keep a stand-in). --no-blobs alone does both steps. A fetch never uploads, never deletes and
            never changes vault.json or a note already complete, so it is safe while the vault is in use. An
            ordinary run (no flag) completes a partial copy too. While a copy is partial, nothing is written to
            a note not downloaded yet, whole-vault commands (export, backup, search, compaction, blobs gc,
            device key changes) refuse it, and a --push-only run keeps on the server everything the copy has
            not fetched (counted as kept, never extraneous; --delete-extraneous is refused). The JSON report
            then has a "partial" object: incompleteNotes, pendingBlobs, keptOnServer and completed.

            Exit codes: 0 ok, 1 errors or quarantined files (listed), 3 conflicts to resolve, 6 a rejected
            vault.json.
            """
    )

    @Argument(help: ArgumentHelp("The WebDAV collection holding the vault (https://host/path/).", valueName: "url"))
    var url: String

    @OptionGroup var login: WebDAVLoginOptions

    @Option(name: .long, help: ArgumentHelp("Name for this device in conflict file names.", valueName: "name"))
    var device: String?

    @Option(name: .customLong("max-blob-mib"),
            help: ArgumentHelp("Largest attachment blob file to transfer, in MiB (default 1088: 1 GiB of content plus padding).",
                               valueName: "n"))
    var maxBlobMiB: Int?

    @Option(name: .customLong("max-notes"),
            help: ArgumentHelp("Most note folders the server may list in one run (default 100000).", valueName: "n"))
    var maxNotes: Int?

    @Option(name: .customLong("max-entries"),
            help: ArgumentHelp("Most remote entries listed in one run, all folders together (default 1000000).", valueName: "n"))
    var maxEntries: Int?

    @Option(name: .customLong("max-download-mib"),
            help: ArgumentHelp("Most MiB downloaded in one run (default 65536).", valueName: "n"))
    var maxDownloadMiB: Int?

    @Option(name: .customLong("max-minutes"),
            help: ArgumentHelp("Longest a run may take, in minutes (default 720).", valueName: "n"))
    var maxMinutes: Int?

    @Option(name: .long, help: ArgumentHelp("Listings, downloads and uploads at once, 1 to 16 (default 6).", valueName: "n"))
    var jobs: Int?

    @Flag(name: .customLong("retry-quarantined"),
          help: "Download and check again the files an earlier run quarantined, even if they did not change.")
    var retryQuarantined = false

    @Flag(name: .customLong("dry-run"), help: "Only list what would be transferred or deleted.")
    var dryRun = false

    @Flag(name: .customLong("push-only"),
          help: "One-way mirror: only upload and delete on the server; never download or change the vault.")
    var pushOnly = false

    @Flag(name: .customLong("delete-extraneous"),
          help: "With --push-only: remove from the server the files the vault does not have and compaction does not explain.")
    var deleteExtraneous = false

    @Flag(name: .customLong("keep-server-changes"),
          help: "With --push-only: keep a server vault.json changed since this device's last sync (exit 3) instead of replacing it.")
    var keepServerChanges = false

    @Flag(name: .customLong("skip-unchanged"),
          help: "List on the server only the notes whose folder ETag changed since the last run (where the server is seen to keep them current; every note at least daily).")
    var skipUnchanged = false

    @Flag(name: .customLong("no-deep-listing"),
          help: "List each note folder with its own request, never all of them with one Depth: infinity PROPFIND (used only where the server is seen to answer it in full).")
    var noDeepListing = false

    @Flag(name: .customLong("metadata-only"),
          help: "Make or continue a partial copy: root files, sealed summaries and the note list, no revision or blob.")
    var metadataOnly = false

    @Flag(name: .customLong("fetch"),
          help: "Fetch what a partial copy lacks (every note not downloaded yet, or those named with --note, and their blobs).")
    var fetch = false

    @Flag(name: .customLong("no-blobs"),
          help: "A partial pull of every note's revisions and no attachment blob (with --fetch: revisions only).")
    var noBlobs = false

    @Option(name: .customLong("note"),
            help: ArgumentHelp("With --fetch: only this note (an id or id prefix); repeatable.", valueName: "id"))
    var fetchNotes: [String] = []

    @Flag(name: .customLong("web-viewer"),
          help: "Create the server's sempere-index.json and sempere-summaries.sealed for the web viewer (needs the vault unlocked).")
    var webViewer = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard let remote = URL(string: url) else { throw CLIError.usage("not a URL: \(url)") }
        if metadataOnly || fetch || noBlobs { return try runPartial(remote) }
        if !fetchNotes.isEmpty { throw CLIError.usage("--note needs --fetch") }
        var options = SyncOptions(dryRun: dryRun)
        options.deviceID = SyncCLI.deviceID()
        if deleteExtraneous && !pushOnly { throw CLIError.usage("--delete-extraneous needs --push-only") }
        if keepServerChanges && !pushOnly { throw CLIError.usage("--keep-server-changes needs --push-only") }
        options.pushOnly = pushOnly
        options.keepServerChanges = keepServerChanges
        options.deleteExtraneous = deleteExtraneous
        options.publishForWebViewer = webViewer
        options.skipUnchangedNotes = skipUnchanged
        options.deepListing = !noDeepListing
        options.summaryCacheDirectory = SummaryCache.cliDirectory(environment: Env.vars)
        options.retryQuarantined = retryQuarantined
        try applyLimits(&options)
        try SyncCLI.applyJobs(jobs, &options)
        let meter = ProgressLine.forStderr(json: output.json, quiet: output.quiet)
        if let meter { options.progress = { @Sendable p in meter.show(p.line) } }
        let client = try login.client(remote)

        let dir = try access.vaultURL()
        let hasManifest = FileManager.default.fileExists(atPath: dir.appendingPathComponent(Vault.manifestName).path)
        if pushOnly && !hasManifest { throw CLIError.usage("--push-only needs an existing vault (no vault.json in \(dir.path))") }
        if !pushOnly { OpenedVaults.shared.record(dir) }   // a first pull creates the vault here
        let vault = hasManifest ? try access.openVault(.ifPossible) : nil
        // A mirror never writes in the vault: not even the local index or summaries refresh at exit.
        if pushOnly { OpenedVaults.shared.forget(dir) }
        if webViewer && vault?.canRead != true {
            throw CLIError.usage("--web-viewer needs the vault unlocked (--identity or a stored key's passphrase)")
        }
        // A first pull checks what it downloads under the vault.json it pulls (format.md §9.1).
        if vault == nil { options.firstPullIdentities = try access.explicitIdentities() }
        options.deviceLabel = device ?? ProcessInfo.processInfo.hostName
        let sync = SyncEngine(
            directory: dir, vault: vault, client: client,
            stateURL: SyncEngine.defaultStateURL(remote: remote, vault: dir, environment: Env.vars),
            options: options)
        let report: SyncReport
        do { report = try sync.run() } catch { meter?.finish(); throw error }
        meter?.finish()

        if output.json {
            try output.emitJSON(report)
        } else {
            SyncCLI.printReport(report, output)
        }
        try SyncCLI.exit(for: report)
    }

    /// The size and run bounds given on the command line.
    private func applyLimits(_ options: inout SyncOptions) throws {
        try SyncCLI.applyLimits(&options, maxBlobMiB: maxBlobMiB, maxNotes: maxNotes, maxEntries: maxEntries,
                                maxDownloadMiB: maxDownloadMiB, maxMinutes: maxMinutes)
    }

    // MARK: - Partial pulls

    /// `--metadata-only`, `--fetch`, `--no-blobs` (format.md §1.2).
    private func runPartial(_ remote: URL) throws {
        if metadataOnly && fetch { throw CLIError.usage("--metadata-only and --fetch are separate steps; run one, then the other") }
        if metadataOnly && noBlobs { throw CLIError.usage("--metadata-only fetches no blob already; --no-blobs adds the revisions") }
        if !fetchNotes.isEmpty && !fetch { throw CLIError.usage("--note needs --fetch") }
        for (set, flag) in [(pushOnly, "--push-only"), (dryRun, "--dry-run"), (deleteExtraneous, "--delete-extraneous"),
                            (keepServerChanges, "--keep-server-changes"), (webViewer, "--web-viewer"),
                            (skipUnchanged, "--skip-unchanged"), (noDeepListing, "--no-deep-listing")] where set {
            throw CLIError.usage("\(flag) does not go with a partial pull (--metadata-only, --fetch, --no-blobs)")
        }
        var options = SyncOptions()
        try applyLimits(&options)
        if let jobs, !(1...TransferPool.maxWidth).contains(jobs) {
            throw CLIError.usage("--jobs must be 1 to \(TransferPool.maxWidth)")
        }
        let meter = ProgressLine.forStderr(json: output.json, quiet: output.quiet)
        if let meter { options.progress = { @Sendable p in meter.show(p.line) } }
        defer { meter?.finish() }
        options.retryQuarantined = retryQuarantined
        options.deviceLabel = device ?? ProcessInfo.processInfo.hostName
        let client = try login.client(remote)
        let dir = try access.vaultURL()
        let stateURL = SyncEngine.defaultStateURL(remote: remote, vault: dir, environment: Env.vars)
        let hasManifest = FileManager.default.fileExists(atPath: dir.appendingPathComponent(Vault.manifestName).path)
        OpenedVaults.shared.forget(dir)   // a partial copy's own index and summaries would leave notes out

        var reports: [SyncReport] = []
        if metadataOnly || (noBlobs && !fetch && !PartialCopyState.isUsable(dir)) {
            if hasManifest && !PartialCopy.isPartial(dir) {
                throw CLIError.usage("\(dir.path) holds a complete vault: a partial pull only makes or continues a partial copy "
                                     + "(run an ordinary sync instead)")
            }
            var o = options
            o.partial = .metadata
            o.firstPullIdentities = try access.explicitIdentities()
            reports.append(try SyncEngine(directory: dir, vault: nil, client: client, stateURL: stateURL, options: o).run())
        }
        if fetch || noBlobs, reports.allSatisfy({ $0.errors.isEmpty }) {
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(Vault.manifestName).path) else {
                throw CLIError.usage("no vault in \(dir.path): make a partial copy first (--metadata-only)")
            }
            let vault = try access.openVault(.ifPossible)
            OpenedVaults.shared.forget(dir)
            var notes: [UUID]?
            if !fetchNotes.isEmpty {
                let ids = try vault.noteIDs()
                notes = try fetchNotes.map { q in
                    guard let id = try NoteSummary.matchID(q, among: ids) else {
                        throw CLIError.usage("no note folder matches \(q) (give an id or an id prefix)")
                    }
                    return id
                }
            }
            var o = options
            o.partial = .fetch(FetchScope(notes: notes, blobs: noBlobs ? .none : .all,
                                                concurrency: jobs ?? FetchScope.defaultConcurrency))
            o.firstPullIdentities = vault.canRead ? [] : try access.explicitIdentities()
            reports.append(try SyncEngine(directory: dir, vault: vault.canRead ? vault : nil, client: client,
                                          stateURL: stateURL, options: o).run())
        }
        meter?.finish()   // the progress line ends before the report is printed
        let report = reports.dropFirst().reduce(reports.first ?? SyncReport()) { Self.merged($0, $1) }
        if output.json {
            try output.emitJSON(report)
        } else {
            SyncCLI.printReport(report, output)
            if let p = report.partial {
                output.info(p.completed || (p.incompleteNotes == 0 && p.pendingBlobs == 0)
                    ? "the copy is complete"
                    : "partial copy: \(p.incompleteNotes) notes and \(p.pendingBlobs) blobs not downloaded yet (--fetch)")
            }
        }
        try SyncCLI.exit(for: report)
    }

    /// Two runs' reports as one (the later one's partial status wins).
    static func merged(_ a: SyncReport, _ b: SyncReport) -> SyncReport {
        var r = a
        r.uploaded += b.uploaded; r.downloaded += b.downloaded; r.deleted += b.deleted; r.conflicts += b.conflicts
        r.errors += b.errors; r.skipped += b.skipped; r.ignored += b.ignored; r.extraneous += b.extraneous; r.arriving += b.arriving
        r.overwritten += b.overwritten; r.merged += b.merged; r.rejected += b.rejected; r.quarantined += b.quarantined
        r.stoppedEarly = b.stoppedEarly ?? a.stoppedEarly
        r.partial = b.partial ?? a.partial
        r.progress = b.progress ?? a.progress
        return r
    }
}

/// What the sync commands share: bounds from the command line, the report, the exit code.
enum SyncCLI {
    /// This machine's device id when it has one (`DeviceState.defaultURL`, made by the first write):
    /// its own `summaries/<device>.sealed` is then never taken from the remote (format.md §12.5).
    static func deviceID() -> DeviceID? {
        let url = DeviceState.defaultURL(environment: Env.vars)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? DeviceState.loadOrCreate(at: url).device
    }

    /// `--max-blob-mib`, `--max-notes`, `--max-entries`, `--max-download-mib`, `--max-minutes`.
    static func applyLimits(_ options: inout SyncOptions, maxBlobMiB: Int?, maxNotes: Int?, maxEntries: Int?,
                            maxDownloadMiB: Int?, maxMinutes: Int?) throws {
        if let maxBlobMiB {
            guard (1...(1 << 20)).contains(maxBlobMiB) else { throw CLIError.usage("--max-blob-mib must be 1 to 1048576") }
            options.maxBlobBytes = maxBlobMiB << 20
        }
        func bounded(_ value: Int?, _ flag: String, max: Int) throws -> Int? {
            guard let value else { return nil }
            guard (1...max).contains(value) else { throw CLIError.usage("--\(flag) must be 1 to \(max)") }
            return value
        }
        if let n = try bounded(maxNotes, "max-notes", max: 100_000_000) { options.limits.maxNotes = n }
        if let n = try bounded(maxEntries, "max-entries", max: 1_000_000_000) { options.limits.maxEntries = n }
        if let n = try bounded(maxDownloadMiB, "max-download-mib", max: 1 << 30) { options.limits.maxDownloadBytes = Int64(n) << 20 }
        if let n = try bounded(maxMinutes, "max-minutes", max: 525_600) { options.limits.maxDuration = TimeInterval(n) * 60 }
    }

    /// `--jobs`.
    static func applyJobs(_ jobs: Int?, _ options: inout SyncOptions) throws {
        guard let jobs else { return }
        guard (1...TransferPool.maxWidth).contains(jobs) else { throw CLIError.usage("--jobs must be 1 to \(TransferPool.maxWidth)") }
        options.concurrency = jobs
    }

    /// Exit 1 for errors, quarantined files or files still arriving; 6 for a rejected vault.json; 3 for conflicts.
    static func exit(for report: SyncReport) throws {
        if !report.errors.isEmpty || !report.quarantined.isEmpty || !report.arriving.isEmpty { throw ExitCode(ExitStatus.failure) }
        if !report.rejected.isEmpty { throw ExitCode(ExitStatus.untrustedList) }
        if !report.conflicts.isEmpty { throw ExitCode(ExitStatus.unhealthy) }
    }

    static func printReport(_ r: SyncReport, _ output: OutputOptions) {
        let verb = r.dryRun ? "would " : ""
        if !output.quiet {
            for p in r.uploaded { print("\(verb)upload    \(p)") }
            for p in r.downloaded { print("\(verb)download  \(p)") }
            for d in r.deleted { print("\(verb)delete    \(d.path) (\(d.side))") }
            for s in r.skipped where output.verbose { print("skipped    \(s.path): \(s.message)") }
            for p in r.overwritten { print("\(verb)overwrite \(p) (server copy replaced)") }
            for p in r.merged { print("\(verb)merge     \(p) (changed on both sides)") }
            for p in r.extraneous { print("extraneous \(p)") }
            for p in r.ignored where output.verbose { print("ignored    \(p)") }
        }
        for c in r.conflicts {
            printStderr("conflict: \(c.path): \(c.detail)" + (c.remoteCopy.map { "; server copy kept as \($0)" } ?? ""))
        }
        for e in r.errors { printStderr("error: \(e.path): \(e.message)") }
        for q in r.quarantined { printStderr("quarantined: \(q.path): \(q.message); not placed in the vault") }
        for e in r.rejected { printStderr("rejected: \(e.path): \(e.message); the local copy is kept") }
        for a in r.arriving { printStderr("arriving: \(a.path): \(a.message)") }
        output.info("\(r.dryRun ? "dry run: " : "")\(r.uploaded.count) uploaded, \(r.downloaded.count) downloaded, "
                    + "\(r.deleted.count) deleted, \(r.conflicts.count) conflicts, \(r.errors.count) errors"
                    + (r.extraneous.isEmpty ? "" : ", \(r.extraneous.count) extraneous")
                    + ((r.partial?.keptOnServer ?? 0) == 0 ? "" : ", \(r.partial?.keptOnServer ?? 0) kept (not fetched here yet)")
                    + (r.quarantined.isEmpty ? "" : ", \(r.quarantined.count) quarantined")
                    + (r.arriving.isEmpty ? "" : ", \(r.arriving.count) still arriving (run again)")
                    + (r.skipped.isEmpty ? "" : ", \(r.skipped.count) skipped (-v)"))
    }
}

/// `--user` and `--password-env`, shared by the WebDAV commands.
struct WebDAVLoginOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("User name for HTTP Basic auth.", valueName: "name"))
    var user: String?

    @Option(name: .customLong("password-env"),
            help: ArgumentHelp("Name of the environment variable holding the password.", valueName: "var"))
    var passwordEnv: String?

    /// The credentials: the password comes from the environment, never the command line.
    func credentials() throws -> WebDAVCredentials? {
        guard let user else {
            if passwordEnv != nil { throw CLIError.usage("--password-env needs --user") }
            return nil
        }
        let varName = passwordEnv ?? "SEMPERE_WEBDAV_PASSWORD"
        guard let password = Env.vars[varName] else {
            throw CLIError.usage("environment variable \(varName) is not set (it must hold the WebDAV password)")
        }
        return WebDAVCredentials(user: user, password: password)
    }

    /// A client for `url` (https, or http to localhost; no credentials in the URL).
    func client(_ url: URL) throws -> WebDAVClient {
        let credentials = try credentials()
        do { return try WebDAVClient(baseURL: url, credentials: credentials) } catch {
            throw CLIError.usage(CLIError.from(error).message)
        }
    }
}

/// A one-line progress display on stderr, redrawn in place (at most ten times a
/// second). Never with `--json` or `--quiet`; otherwise only on a terminal,
/// unless `SEMPERE_PROGRESS` is `always` (tests, logs) or `never`.
final class ProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var pending: String?
    private var shown = false

    static func forStderr(json: Bool, quiet: Bool) -> ProgressLine? {
        guard !json, !quiet else { return nil }
        switch Env.vars["SEMPERE_PROGRESS"] {
        case "always": return ProgressLine()
        case "never": return nil
        default: return isatty(STDERR_FILENO) == 1 ? ProgressLine() : nil
        }
    }

    func show(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        pending = line
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.1 else { return }
        last = now
        draw()
    }

    /// Draws the last line given and ends it with a newline.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        draw()
        if shown { FileHandle.standardError.write(Data("\n".utf8)) }
        shown = false
    }

    private func draw() {
        guard let line = pending else { return }
        pending = nil
        shown = true
        // Carriage return, the line, then erase what a longer earlier line left.
        FileHandle.standardError.write(Data(("\r" + line + "\u{1B}[K").utf8))
    }
}
