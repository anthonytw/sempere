import ArgumentParser
import Foundation
import Sempere
import SempereWebDAV

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Mirror a vault with a remote store.",
        subcommands: [SyncWebDAVCommand.self]
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
            only if no revision of its note references it there (format.md §8.1.6), else copied back. vault.json and
            rewrap-journal.json are compared with the last sync; when both sides changed, both copies
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
            it uploads what the server lacks, overwrites the server's vault.json and
            rewrap-journal.json from the local copy, and deletes on the server what local compaction or
            blob collection removed; it never downloads and never writes or deletes anything in the
            vault, so nothing the server holds can change it. Files only the server has, which
            no compaction explains, are listed as extraneous, and removed with --delete-extraneous.
            With --keep-server-changes, a server vault.json or rewrap-journal.json that changed since this
            device's last sync (another writer, such as another device's key change) is kept and reported
            as a conflict (exit 3) instead of being replaced; revisions and blobs still upload. This is how
            the app pushes a WebDAV vault.

            Every downloaded revision and blob is checked before it is placed (format.md §9.1): with the
            vault unlocked it must decrypt, verify its tag or keyed name and name this note and file; locked
            (or a first pull without --identity), only its age structure is checked. A file that fails is
            never placed: it is kept in a quarantine folder next to the sync state, listed as quarantined
            (exit 1), and not fetched again while it and the local vault.json are unchanged
            (--retry-quarantined fetches it again).

            A run is bounded as a whole: --max-notes, --max-entries (listed remote entries),
            --max-download-mib and --max-minutes. Reaching one stops the run with an error (exit 1); what
            was done so far is kept, and the next run continues.

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
          help: "With --push-only: keep a server vault.json or rewrap-journal.json changed since this device's last sync (exit 3) instead of replacing it.")
    var keepServerChanges = false

    @Flag(name: .customLong("skip-unchanged"),
          help: "List on the server only the notes whose folder ETag changed since the last run (where the server is seen to keep them current; every note at least daily).")
    var skipUnchanged = false

    @Flag(name: .customLong("web-viewer"),
          help: "Create the server's sempere-index.json and sempere-summaries.sealed for the web viewer (needs the vault unlocked).")
    var webViewer = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard let remote = URL(string: url) else { throw CLIError.usage("not a URL: \(url)") }
        var options = WebDAVSyncOptions(dryRun: dryRun)
        if deleteExtraneous && !pushOnly { throw CLIError.usage("--delete-extraneous needs --push-only") }
        if keepServerChanges && !pushOnly { throw CLIError.usage("--keep-server-changes needs --push-only") }
        options.pushOnly = pushOnly
        options.keepServerChanges = keepServerChanges
        options.deleteExtraneous = deleteExtraneous
        options.publishForWebViewer = webViewer
        options.skipUnchangedNotes = skipUnchanged
        options.summaryCacheDirectory = SummaryCache.cliDirectory(environment: Env.vars)
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
        options.retryQuarantined = retryQuarantined
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
        let sync = WebDAVSync(
            directory: dir, vault: vault, client: client,
            stateURL: WebDAVSync.defaultStateURL(remote: remote, vault: dir, environment: Env.vars),
            options: options)
        let report = try sync.run()

        if output.json {
            try output.emitJSON(report)
        } else {
            printReport(report)
        }
        if !report.errors.isEmpty || !report.quarantined.isEmpty { throw ExitCode(ExitStatus.failure) }
        if !report.rejected.isEmpty { throw ExitCode(ExitStatus.untrustedRecipients) }
        if !report.conflicts.isEmpty { throw ExitCode(ExitStatus.unhealthy) }
    }

    private func printReport(_ r: SyncReport) {
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
        output.info("\(r.dryRun ? "dry run: " : "")\(r.uploaded.count) uploaded, \(r.downloaded.count) downloaded, "
                    + "\(r.deleted.count) deleted, \(r.conflicts.count) conflicts, \(r.errors.count) errors"
                    + (r.extraneous.isEmpty ? "" : ", \(r.extraneous.count) extraneous")
                    + (r.quarantined.isEmpty ? "" : ", \(r.quarantined.count) quarantined")
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
