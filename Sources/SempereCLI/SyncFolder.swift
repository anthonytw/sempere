import ArgumentParser
import Foundation
import Sempere
import SempereSync

struct SyncFolderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folder",
        abstract: "Sync a vault with a copy in a folder (iCloud Drive, another provider, a drive or a share).",
        discussion: """
            The same two-way sync as `sync webdav`, with a folder as the other side (docs/io.md "Folder targets"):
            revisions and blobs are copied to the side that lacks them and never overwritten, vault.json is compared with the last sync (a change on both sides keeps both copies, exit 3),
            settings.age is merged per key with the vault unlocked, deletions follow only compaction and blob
            collection, and every file taken from the folder is checked before it is placed (format.md §9.1; one that
            fails is quarantined, exit 1). PATH may be missing or empty: the first run copies the vault into it. The
            vault folder may be missing or empty: the first run copies the folder's vault into it. The two must not
            overlap.

            In a provider's folder (iCloud Drive or another File Provider on a Mac) every read and write is
            coordinated with the provider, a file the provider has evicted (a .<name>.icloud stand-in or a dataless
            file) is asked for and waited for (at most --wait seconds in all), and a folder the provider has listed
            before its files is left alone for two minutes: such files exist, so nothing is uploaded over them or
            deleted for them. What has not arrived is listed as "arriving" on stderr (JSON "arriving") and the exit
            code is 1: run again. The provider's conflict versions of vault.json, the journal and settings.age are
            merged (or kept as conflict copies) and removed, so no version picker appears.

            The folder is not trusted: symbolic links in it are never followed, names that are not vault files are
            ignored and listed (-v), and reads are bounded. A plain folder's conditional writes take an advisory lock
            (.sempere-lock in PATH), so the CLI and the app on one machine take turns.

            --push-only makes it a one-way mirror (as for WebDAV: nothing is ever read back into the vault), for
            example into a folder a web server serves to the web viewer (--web-viewer).

            Exit codes: 0 ok, 1 errors, quarantined files or files still arriving (listed), 3 conflicts to resolve,
            6 a rejected vault.json.
            """
    )

    @Argument(help: ArgumentHelp("The folder holding (or to hold) the vault's copy.", valueName: "path"))
    var path: String

    @Option(name: .long, help: ArgumentHelp("Name for this device in conflict file names.", valueName: "name"))
    var device: String?

    @Option(name: .long, help: ArgumentHelp("Longest the run waits, in all, for files the provider is downloading (default 30).",
                                            valueName: "seconds"))
    var wait: Int?

    @Option(name: .customLong("max-blob-mib"),
            help: ArgumentHelp("Largest attachment blob file to transfer, in MiB (default 1088: 1 GiB of content plus padding).",
                               valueName: "n"))
    var maxBlobMiB: Int?

    @Option(name: .customLong("max-notes"),
            help: ArgumentHelp("Most note folders the folder may list in one run (default 100000).", valueName: "n"))
    var maxNotes: Int?

    @Option(name: .customLong("max-entries"),
            help: ArgumentHelp("Most entries listed in one run, all folders together (default 1000000).", valueName: "n"))
    var maxEntries: Int?

    @Option(name: .customLong("max-download-mib"),
            help: ArgumentHelp("Most MiB copied from the folder in one run (default 65536).", valueName: "n"))
    var maxDownloadMiB: Int?

    @Option(name: .customLong("max-minutes"),
            help: ArgumentHelp("Longest a run may take, in minutes (default 720).", valueName: "n"))
    var maxMinutes: Int?

    @Option(name: .long, help: ArgumentHelp("Listings, copies in and copies out at once, 1 to 16 (default 6).", valueName: "n"))
    var jobs: Int?

    @Flag(name: .customLong("retry-quarantined"),
          help: "Copy in and check again the files an earlier run quarantined, even if they did not change.")
    var retryQuarantined = false

    @Flag(name: .customLong("dry-run"), help: "Only list what would be copied or deleted.")
    var dryRun = false

    @Flag(name: .customLong("push-only"),
          help: "One-way mirror: only write and delete in the folder; never copy anything into the vault.")
    var pushOnly = false

    @Flag(name: .customLong("delete-extraneous"),
          help: "With --push-only: remove from the folder the files the vault does not have and compaction does not explain.")
    var deleteExtraneous = false

    @Flag(name: .customLong("keep-server-changes"),
          help: "With --push-only: keep a vault.json in the folder changed since this device's last sync (exit 3).")
    var keepServerChanges = false

    @Flag(name: .customLong("web-viewer"),
          help: "Create the folder's sempere-index.json and sempere-summaries.sealed for the web viewer (needs the vault unlocked).")
    var webViewer = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        if deleteExtraneous && !pushOnly { throw CLIError.usage("--delete-extraneous needs --push-only") }
        if keepServerChanges && !pushOnly { throw CLIError.usage("--keep-server-changes needs --push-only") }
        guard !path.isEmpty else { throw CLIError.usage("give the folder to sync with") }
        let target = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue {
            throw CLIError.usage("\(target.path) is not a folder")
        }
        let dir = try access.vaultURL()
        if dir.overlaps(target) {
            throw CLIError.usage("the folder \(target.path) and the vault \(dir.path) overlap; sync with a folder outside the vault")
        }

        var options = SyncOptions(dryRun: dryRun)
        options.deviceID = SyncCLI.deviceID()
        options.recordSynced = true
        options.pushOnly = pushOnly
        options.keepServerChanges = keepServerChanges
        options.deleteExtraneous = deleteExtraneous
        options.publishForWebViewer = webViewer
        options.summaryCacheDirectory = SummaryCache.cliDirectory(environment: Env.vars)
        options.retryQuarantined = retryQuarantined
        try SyncCLI.applyLimits(&options, maxBlobMiB: maxBlobMiB, maxNotes: maxNotes, maxEntries: maxEntries,
                                maxDownloadMiB: maxDownloadMiB, maxMinutes: maxMinutes)
        try SyncCLI.applyJobs(jobs, &options)
        if let wait {
            guard (0...86_400).contains(wait) else { throw CLIError.usage("--wait must be 0 to 86400") }
            options.arrivalWait = TimeInterval(wait)
        } else {
            options.arrivalWait = 30
        }
        let meter = ProgressLine.forStderr(json: output.json, quiet: output.quiet)
        if let meter { options.progress = { @Sendable p in meter.show(p.line) } }

        let hasManifest = FileManager.default.fileExists(atPath: dir.appendingPathComponent(Vault.manifestName).path)
        if pushOnly && !hasManifest { throw CLIError.usage("--push-only needs an existing vault (no vault.json in \(dir.path))") }
        if !pushOnly { OpenedVaults.shared.record(dir) }   // a first pull creates the vault here
        let vault = hasManifest ? try access.openVault(.ifPossible) : nil
        if let id = vault?.writerDevice { options.deviceID = id }   // the vault device's id names its summaries file
        // A mirror never writes in the vault: not even the local index or summaries refresh at exit.
        if pushOnly { OpenedVaults.shared.forget(dir) }
        if webViewer && vault?.canRead != true {
            throw CLIError.usage("--web-viewer needs the vault unlocked (--identity or a stored key's passphrase)")
        }
        // A first pull checks what it copies in under the vault.json it takes (format.md §9.1).
        // A first pull, or a joining machine taking its approval (KH4), checks the vault.json it pulls with its key.
        if let vault, !vault.canRead {
            options.firstPullIdentities = try access.readingIdentities(vaultId: vault.vaultId)
        } else if vault == nil {
            options.firstPullIdentities = try access.explicitIdentities()
        }
        options.deviceLabel = device ?? ProcessInfo.processInfo.hostName

        let remote = FolderRemote(root: target)
        if output.verbose, !output.json {
            output.info("folder: \(remote.root.path) (\(remote.provider.managesFiles ? "held by \(remote.provider.name)" : "a plain folder"))")
        }
        let sync = SyncEngine(
            directory: dir, vault: vault, remote: remote,
            stateURL: SyncEngine.defaultStateURL(remote: remote.root, vault: dir, environment: Env.vars),
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
}
