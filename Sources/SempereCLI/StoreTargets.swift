import ArgumentParser
import Foundation
import Sempere
import SempereSync
import SempereWebDAV

/// `sempere store target`: the sync targets of a store vault (docs/design/device-first-sync.md §2, §8.1),
/// the same registry the app keeps (`<store>/.sync/<vault id>/targets.json`).
struct StoreTargetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "target",
        abstract: "List, add and remove the sync targets of a store vault.",
        discussion: """
            A target is an outside copy the vault syncs with both ways: a folder (iCloud Drive, another provider, a \
            drive, a share, any folder) or a WebDAV server folder. A vault may have any number; each keeps its own \
            sync state and quarantine in <store>/.sync/<vault id>/<target id>/. Adding a target to a vault that \
            already has notes makes the next sync a union: what either side lacks is copied, nothing is deleted. \
            Removing one never touches the folder or server. `sempere store sync` runs them.
            """,
        subcommands: [StoreTargetList.self, StoreTargetAdd.self, StoreTargetRemove.self]
    )
}

struct StoreTargetList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a store vault's sync targets.",
        discussion: "--json: an array of {id, kind, name, path, url, user, added, lastSuccess}."
    )

    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let store = location.open()
        let entry = try store.resolve(vault)
        let targets = try store.targets.load(entry.vaultId)
        if output.json { return try output.emitJSON(targets.map(StoreTargetOutput.init)) }
        guard !targets.isEmpty else { return output.info("\(entry.name) has no sync targets") }
        var rows = [["ID", "KIND", "NAME", "PLACE", "LAST SYNC"]]
        for t in targets {
            rows.append([t.id.uuidString.lowercased(), t.kind.rawValue, t.name, t.path ?? t.url ?? "",
                         t.lastSuccess.map(Format.utc) ?? "never"])
        }
        print(Format.table(rows))
    }
}

struct StoreTargetAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a folder or WebDAV sync target to a store vault.",
        discussion: """
            --folder PATH: the folder holding (or to hold) the vault's copy; it may be missing or empty (the first \
            sync copies the vault into it), or hold the same vault (the first sync is a union). It must not overlap \
            the store. --webdav URL [--user NAME]: a server folder (https, or http to localhost); the password is \
            never stored, `store sync` takes it from the environment. A target at the same place is refused (exit 1).
            """
    )

    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @Option(name: .long, help: ArgumentHelp("A folder target.", valueName: "path"))
    var folder: String?

    @Option(name: .long, help: ArgumentHelp("A WebDAV target: the server folder's URL.", valueName: "url"))
    var webdav: String?

    @Option(name: .long, help: ArgumentHelp("With --webdav: the user name for HTTP Basic auth.", valueName: "name"))
    var user: String?

    @Option(name: .long, help: ArgumentHelp("The target's display name (default: the folder's name or the host).",
                                            valueName: "name"))
    var name: String?

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if (folder == nil) == (webdav == nil) { throw ValidationError("give one of --folder PATH or --webdav URL") }
        if user != nil && webdav == nil { throw ValidationError("--user goes with --webdav") }
    }

    func run() throws {
        let store = location.open()
        let entry = try store.resolve(vault)
        var target: SyncTarget
        if let folder {
            let url = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
            try store.checkFolderTarget(url)
            target = .folder(url, name: name)
        } else {
            let text = webdav ?? ""
            guard let url = URL(string: text) else { throw CLIError.usage("\(text) is not a URL") }
            do { _ = try WebDAVClient(baseURL: url, credentials: nil) } catch {
                throw CLIError.usage(CLIError.from(error).message)
            }
            target = .webdav(text, user: user, name: name ?? url.host ?? text)
        }
        target = try store.targets.add(target, to: entry.vaultId)
        if output.json { return try output.emitJSON(StoreTargetOutput(target)) }
        output.info("Added \(target.kind) target \(target.id.uuidString.lowercased()) to \(entry.name)")
        if output.quiet { print(target.id.uuidString.lowercased()) }
    }
}

struct StoreTargetRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a sync target of a store vault (its folder or server is not touched).",
        discussion: "TARGET is the target's id, a unique id prefix, its name, path or URL. Its sync state on this device is deleted."
    )

    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @Argument(help: ArgumentHelp("The target: id, id prefix, name, path or URL.", valueName: "target"))
    var target: String

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let store = location.open()
        let entry = try store.resolve(vault)
        let found = try store.targets.resolve(target, of: entry.vaultId)
        try store.targets.remove(found.id, of: entry.vaultId)
        if output.json { return try output.emitJSON(StoreTargetOutput(found)) }
        output.info("Removed target \(found.id.uuidString.lowercased()) (\(found.name)) from \(entry.name)")
    }
}

/// `sempere store sync`.
struct StoreSync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync a store vault with its targets, one after the other.",
        discussion: """
            Runs the two-way sync of `sync folder` or `sync webdav` with each target of the vault (or only the \
            --target ones), each with its own sync state and quarantine (<store>/.sync/<vault id>/<target id>/). A \
            device with two targets bridges them: what one brings is taken to the other on the next run. With the \
            vault unlocked (--identity or the stored key's passphrase) received files are checked fully and \
            deletions explained by compaction follow; locked, only their structure is checked and nothing is \
            deleted. A folder target that was synced before and is gone is not recreated (exit 1: choose it again \
            or remove the target); one whose parent folder is missing (a drive not connected) is skipped (exit 1). \
            WebDAV passwords come from --password-env (default SEMPERE_WEBDAV_PASSWORD).

            --json: an array of {target, kind, name, report, error}. Exit codes as for `sync folder`, the worst \
            over the targets; 1 when a target could not run.
            """
    )

    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @Option(name: .long, help: ArgumentHelp("Only this target (id, id prefix, name, path or URL). Repeatable.",
                                            valueName: "target"))
    var target: [String] = []

    @Option(name: .long, help: ArgumentHelp("Longest a run waits, in all, for files a provider is downloading (default 30).",
                                            valueName: "seconds"))
    var wait: Int?

    @Option(name: .customLong("password-env"),
            help: ArgumentHelp("Name of the environment variable holding WebDAV targets' password.", valueName: "var"))
    var passwordEnv: String?

    @Option(name: .long, help: ArgumentHelp("An age identity file (age-keygen style). Repeatable.",
                                            discussion: "Default: $SEMPERE_IDENTITY.", valueName: "file"))
    var identity: [String] = []

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Name of the environment variable holding the passphrase of the vault's key file.",
                               valueName: "var"))
    var passphraseEnv: String?

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    struct Outcome: Encodable {
        var target: String
        var kind: String
        var name: String
        var report: SyncReport?
        var error: String?
    }

    func run() throws {
        let store = location.open()
        let entry = try store.resolve(vault)
        let all = try store.targets.load(entry.vaultId)
        let chosen = target.isEmpty ? all : try target.map { try store.targets.resolve($0, of: entry.vaultId) }
        guard !chosen.isEmpty else { throw CLIError.usage("\(entry.name) has no sync targets (sempere store target add)") }
        if let wait, !(0...86_400).contains(wait) { throw CLIError.usage("--wait must be 0 to 86400") }

        var access = AccessOptions()
        access.vault = entry.url.path
        access.identity = identity
        access.passphraseEnv = passphraseEnv
        // Every option of a hand-made OptionGroup is set: reading an unset one traps.
        access.recoveryKey = nil
        access.root = nil
        let vault = try access.openVault(.ifPossible)
        let lease = try store.lease(entry.vaultId)
        defer { lease.release() }

        var base = SyncOptions()
        base.deviceID = SyncCLI.deviceID()
        base.deviceLabel = ProcessInfo.processInfo.hostName
        base.summaryCacheDirectory = SummaryCache.cliDirectory(environment: Env.vars)
        base.arrivalWait = TimeInterval(wait ?? 30)
        base.localWriteLock = store.writeLock(for: entry.vaultId)

        var outcomes: [Outcome] = []
        for t in chosen {
            let stateURL = store.targets.stateURL(t.id, of: entry.vaultId)
            var options = base
            options.quarantineDirectory = store.targets.quarantineDirectory(t.id, of: entry.vaultId)
            var outcome = Outcome(target: t.id.uuidString.lowercased(), kind: t.kind.rawValue, name: t.name)
            do {
                let report: SyncReport
                switch t.kind {
                case .folder:
                    guard let path = t.path else { throw SyncTargetError.io("target \(t.name) has no path") }
                    report = try FolderTargetRun.run(vaultFolder: entry.url, folder: URL(fileURLWithPath: path, isDirectory: true),
                                                     vault: vault, stateURL: stateURL, twoWay: true, options: options)
                case .webdav:
                    guard let text = t.url, let url = URL(string: text) else { throw SyncTargetError.io("target \(t.name) has no URL") }
                    let login = try WebDAVLoginOptions.parse((t.user.map { ["--user", $0] } ?? [])
                                                             + (passwordEnv.map { ["--password-env", $0] } ?? []))
                    let client = try login.client(url)
                    try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    options.skipUnchangedNotes = true
                    report = try SyncEngine(directory: entry.url, vault: vault.canRead ? vault : nil, client: client,
                                            stateURL: stateURL, options: options).run()
                default:
                    throw SyncTargetError.io("target kind \(t.kind) is not supported by this version")
                }
                outcome.report = report
                if WebDAVSyncProblem.from(report: report).isEmpty {
                    try? store.targets.update(t.id, of: entry.vaultId) { $0.lastSuccess = Date() }
                }
            } catch {
                outcome.error = CLIError.from(error).message
            }
            outcomes.append(outcome)
        }

        if output.json {
            try output.emitJSON(outcomes)
        } else {
            for o in outcomes {
                if let error = o.error {
                    printError("\(o.name) (\(o.kind)): \(error)")
                } else if let report = o.report {
                    output.info("\(o.name) (\(o.kind)):")
                    SyncCLI.printReport(report, output)
                }
            }
        }
        if outcomes.contains(where: { $0.error != nil }) { throw ExitCode(ExitStatus.failure) }
        for report in outcomes.compactMap(\.report) where !report.errors.isEmpty || !report.quarantined.isEmpty || !report.arriving.isEmpty {
            try SyncCLI.exit(for: report)
        }
        for report in outcomes.compactMap(\.report) { try SyncCLI.exit(for: report) }
    }
}

/// A target as `--json` prints it (no bookmark bytes).
struct StoreTargetOutput: Encodable {
    var id: String
    var kind: String
    var name: String
    var path: String?
    var url: String?
    var user: String?
    var added: Date
    var lastSuccess: Date?

    init(_ t: SyncTarget) {
        id = t.id.uuidString.lowercased()
        kind = t.kind.rawValue
        name = t.name
        path = t.path
        url = t.url
        user = t.user
        added = t.added
        lastSuccess = t.lastSuccess
    }
}
