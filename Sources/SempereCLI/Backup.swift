import Age
import ArgumentParser
import Foundation
import Sempere

struct BackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Back up a vault's encrypted files to a folder or a tar archive, and check backups.",
        subcommands: [BackupRun.self, BackupVerify.self, BackupStatusCommand.self],
        defaultSubcommand: BackupRun.self
    )
}

struct BackupRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Copy new and changed vault files to a backup folder (incremental), or write a tar.",
        discussion: """
            sempere backup V --to DIR copies the files DIR lacks, each written atomically and read back
            to compare its SHA-256. Revision files are write-once, so later runs copy only what is new.
            Files whose content changed (vault.json, the rewrap journal, keys/, revisions after a
            recipient change) are replaced and the previous copy is kept under DIR/versions/<time>/.
            Nothing is ever deleted from DIR, except with --prune: revision files the vault no longer
            has that a snapshot held in both the vault and DIR covers (what compaction deletes); --prune
            needs the key. DIR is itself a vault: sempere --vault DIR works on it. An interrupted run
            is finished by running it again.

            sempere backup V --into FOLDER does the same in FOLDER/<vault name>.sempere-backup, as the
            app's Back Up does: any device's Open Vault... takes it as a one-time copy, and it is never
            a sync target (anything holding backup.json is a backup, whatever its name). FOLDER itself
            when it is this vault's *.sempere-backup already (or an empty folder so named);
            "<name> 2.sempere-backup", ... when the name holds something else; an existing backup of
            this vault there is continued. A backup of this vault an earlier version named
            "<name> Backup" or "<name>.sempere" in FOLDER is first renamed to <name>.sempere-backup
            when that name is free (no file inside is touched). Inside a vault or a backup nothing is
            written, except into this vault's own *.sempere-backup inside this vault's older backup.

            sempere backup V --archive FILE.tar writes one tar of the encrypted files (no plaintext),
            checked member by member before it takes its name. `tar xf FILE.tar` gives the vault back.

            Exit codes: 0 ok, 1 some files failed (listed), 2 usage, 4 --prune without a key.
            """
    )

    @Argument(help: ArgumentHelp("The vault directory (default: --vault or $SEMPERE_VAULT).", valueName: "vault"))
    var vaultPath: String?

    @Option(name: .long, help: ArgumentHelp("The backup folder (created if needed).", valueName: "dir"))
    var to: String?

    @Option(name: .long, help: ArgumentHelp("Back up into <vault name>.sempere-backup inside this folder (as the app does).",
                                            valueName: "folder"))
    var into: String?

    @Option(name: .long, help: ArgumentHelp("Write a single tar archive instead. Refuses to overwrite.",
                                            valueName: "file.tar"))
    var archive: String?

    @Flag(name: .long, help: "Delete backed-up revisions that compaction removed from the vault (needs the key).")
    var prune = false

    @Flag(name: .long, help: "Re-hash files already in the backup instead of trusting their size.")
    var checksum = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard [to, into, archive].compactMap({ $0 }).count == 1 else {
            throw ValidationError("give exactly one of --to DIR, --into FOLDER and --archive FILE")
        }
        if archive != nil && (prune || checksum) {
            throw ValidationError("--prune and --checksum apply to --to and --into only")
        }
        if let vaultPath, let v = access.vault, v != vaultPath {
            throw ValidationError("the vault is given twice (\(vaultPath) and --vault \(v))")
        }
    }

    func run() throws {
        var opts = access
        if let vaultPath { opts.vault = vaultPath }
        let vault = try opts.openVault(prune ? .required : .ifPossible)
        try vault.requireCompleteCopy()   // a backup of a partial copy would silently lack what it has not fetched
        if let archive {
            let report = try Backup.writeArchive(source: vault, to: URL(fileURLWithPath: archive))
            if output.json { try output.emitJSON(report) } else {
                output.info("Wrote \(report.archive): \(report.files) files, \(report.bytes) bytes, sha256 \(report.sha256)")
            }
            return
        }
        let dest: URL
        if let into {
            let folder = URL(fileURLWithPath: into), name = VaultStore.displayName(of: vault.url.standardizedFileURL)
            if let renamed = BackupDestination.renameLegacy(in: folder, vaultId: vault.vaultId, vaultName: name) {
                output.info("Renamed \(renamed.from) to \(renamed.to) (this vault's earlier backup)")
            }
            dest = try BackupDestination.folder(in: folder, vaultId: vault.vaultId, vaultName: name)
        } else {
            dest = URL(fileURLWithPath: to ?? "")
        }
        clearBundleBits([vault.url, dest])
        defer { clearBundleBits([vault.url, dest]) }
        let report = try Backup.run(source: vault, to: dest,
                                    options: BackupOptions(prune: prune, checksum: checksum))
        if output.json {
            try output.emitJSON(report)
        } else {
            if !output.quiet {
                for p in report.copied { print("copied    \(p)") }
                for p in report.replaced { print("replaced  \(p)") }
                for p in report.pruned { print("pruned    \(p)") }
                if output.verbose {
                    for p in report.versioned { print("kept      \(p)") }
                    for p in report.kept { print("not in vault, kept  \(p)") }
                }
            }
            for e in report.errors { printStderr("error: \(e.path): \(e.message)") }
            output.info("\(report.copied.count) copied, \(report.replaced.count) replaced, \(report.unchanged) unchanged, "
                        + "\(report.pruned.count) pruned, \(report.kept.count) kept after compaction, "
                        + "\(report.errors.count) errors")
            if into != nil { output.info("Backup folder: \(dest.path)") }
        }
        if !report.errors.isEmpty { throw ExitCode(ExitStatus.failure) }
    }
}

struct BackupVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check a backup folder: hashes without a key, every revision with one.",
        discussion: """
            Without a key: every file recorded in DIR/backup.json is present with its SHA-256 and size,
            and vault.json is well formed. With --identity (or a scripted passphrase for the key file
            stored in the backup): also decrypts, tag-checks and decodes every revision, as
            `sempere vault verify` does. Exit 0 healthy, 3 problems found, 4 the key does not open it.
            """
    )

    @Argument(help: ArgumentHelp("The backup folder.", valueName: "dir"))
    var dir: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let url = URL(fileURLWithPath: dir)
        let hasManifest = FileManager.default.fileExists(atPath: url.appendingPathComponent(Vault.manifestName).path)
        // A damaged vault.json (a classic key included) is refused before any key is read.
        if hasManifest { _ = try Vault.open(at: url) }
        let identities = hasManifest ? try access.readingIdentities(vaultId: try Vault.open(at: url).vaultId)
            : try access.explicitIdentities()
        // Fail early, with exit 4, when the key does not open this vault.
        if !identities.isEmpty, hasManifest { _ = try Vault.open(at: url, identities: identities) }
        let report = Backup.verify(at: url, identities: identities)
        let problems = report.files.filter { $0.status != .ok && $0.status != .unindexed }
        let vaultProblems = (report.vault?.files ?? []).filter { $0.status.isProblem }

        if output.json {
            struct File: Encodable { var path: String; var status: String; var detail: String? }
            struct Out: Encodable {
                var healthy: Bool
                var decrypted: Bool
                var backupProblems: [String]
                var vaultProblem: String?
                var manifestProblems: [String]
                var counts: [String: Int]
                var files: [File]
            }
            var counts: [String: Int] = [:]
            for f in report.files { counts["index." + f.status.rawValue, default: 0] += 1 }
            for f in report.vault?.files ?? [] { counts["vault." + f.status.rawValue, default: 0] += 1 }
            let files = report.files.map { File(path: $0.path, status: $0.status.rawValue, detail: $0.detail) }
                + vaultProblems.map { File(path: $0.path, status: $0.status.rawValue, detail: $0.detail) }
            try output.emitJSON(Out(healthy: report.isHealthy, decrypted: report.decrypted,
                                    backupProblems: report.backupProblems, vaultProblem: report.vaultProblem,
                                    manifestProblems: report.vault?.manifestProblems ?? [], counts: counts, files: files))
        } else {
            for p in report.backupProblems { print("backup.json: \(p)") }
            if let p = report.vaultProblem { print("vault: \(p)") }
            for p in report.vault?.manifestProblems ?? [] { print("\(Vault.manifestName): \(p)") }
            for f in problems { print("\(f.status.rawValue)  \(f.path)" + (f.detail.map { "  (\($0))" } ?? "")) }
            for f in vaultProblems { print("\(f.status.rawValue)  \(f.path)" + (f.detail.map { "  (\($0))" } ?? "")) }
            if output.verbose {
                for f in report.files where f.status == .unindexed { print("unindexed  \(f.path)") }
            }
            let checked = report.files.filter { $0.status == .ok }.count
            output.info("\(checked) file(s) match backup.json, \(problems.count) problem(s); "
                        + (report.decrypted
                           ? "\((report.vault?.files ?? []).filter { $0.status == .ok }.count) revision(s) decrypted and verified, \(vaultProblems.count) problem(s)"
                           : "revisions not decrypted (no key)"))
            output.info(report.isHealthy ? "Backup is healthy." : "Backup has problems.")
        }
        if !report.isHealthy { throw ExitCode(ExitStatus.unhealthy) }
    }
}

struct BackupStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show when a backup folder was last brought up to date and how much it holds.",
        discussion: """
            Reads DIR/backup.json only (no key, no other file): the vault id, the first run, the last
            run, the last complete run (no file errors), and the notes, files and bytes it records
            (previous copies under versions/ apart). It does not check the files: `sempere backup
            verify DIR` does.

            --max-age DAYS is the app's "Remind Me" for scripts: the backup is overdue when no run
            completed in the last DAYS days (counted from the folder's first run when none ever did).
            Exit 0, 1 when DIR is not a backup folder or its backup.json cannot be read, 3 overdue.
            """
    )

    @Argument(help: ArgumentHelp("The backup folder.", valueName: "dir"))
    var dir: String

    @Option(name: .customLong("max-age"),
            help: ArgumentHelp("Exit 3 when no backup completed in the last DAYS days (1...3650).", valueName: "days"))
    var maxAge: Int?

    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let maxAge, !(1...BackupSchedule.maxDays).contains(maxAge) {
            throw ValidationError("--max-age must be between 1 and \(BackupSchedule.maxDays) days")
        }
    }

    func run() throws {
        let status = try Backup.status(at: URL(fileURLWithPath: dir))
        let now = Date()
        let overdue = maxAge.map { status.isOverdue(maxAgeDays: $0, now: now) }
        if output.json {
            struct Out: Encodable {
                var status: BackupStatus
                var maxAgeDays: Int?
                var due: Date?
                var overdue: Bool?
                func encode(to encoder: any Encoder) throws {
                    try status.encode(to: encoder)
                    enum K: String, CodingKey { case maxAgeDays, due, overdue }
                    var c = encoder.container(keyedBy: K.self)
                    try c.encodeIfPresent(maxAgeDays, forKey: .maxAgeDays)
                    try c.encodeIfPresent(due, forKey: .due)
                    try c.encodeIfPresent(overdue, forKey: .overdue)
                }
            }
            try output.emitJSON(Out(status: status, maxAgeDays: maxAge, due: maxAge.map { status.dueDate(maxAgeDays: $0) },
                                    overdue: overdue))
        } else {
            print("vault     \(status.vaultId)")
            print("created   \(Format.local(status.created))")
            print("updated   \(Format.local(status.updated))")
            print("completed \(status.completed.map(Format.local) ?? "never")")
            print("notes     \(status.notes)")
            print("files     \(status.files) (\(status.bytes) bytes)")
            print("versions  \(status.versionFiles) (\(status.versionBytes) bytes)")
            if let maxAge, let overdue {
                print("due       \(Format.local(status.dueDate(maxAgeDays: maxAge)))"
                      + (overdue ? "  OVERDUE (no complete backup in \(maxAge) days)" : ""))
            }
        }
        if overdue == true { throw ExitCode(ExitStatus.unhealthy) }
    }
}

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a vault from a backup folder into a new vault folder, then verify it.",
        discussion: """
            Copies vault.json, keys/ and notes/ from DIR (an `sempere backup` folder, or any vault folder
            such as an extracted tar) to NEWPATH, which must end in .sempere and be new or empty. Every
            file is checked against DIR/backup.json; a damaged file is not restored and is reported.
            vault.json is written last, so an interrupted restore never looks like a vault; run the
            same command again to finish it. The restored vault is then verified: fully with a key
            (--identity), structure only without. Exit 0 ok, 1 files could not be restored, 3 the
            restored vault is not healthy, 4 the key does not open it.

            --dry-run writes nothing: it checks NEWPATH as a real restore would (refusing it the same
            way) and prints what DIR holds: notes, revisions, attachments, bytes and the newest
            revision's time (from file names, no key needed).
            """
    )

    @Argument(help: ArgumentHelp("The backup folder.", valueName: "dir"))
    var dir: String

    @Option(name: .long, help: ArgumentHelp("The new vault folder (*.sempere).", valueName: "newpath"))
    var to: String

    @Flag(name: .long, help: "Show what would be restored and check NEWPATH; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard to.hasSuffix(".sempere") else { throw CLIError.usage("--to must end in .sempere: \(to)") }
        let source = URL(fileURLWithPath: dir)
        // A backup whose vault.json does not open is refused before anything is copied.
        _ = try Vault.open(at: source)
        // Never into (or around) the vault named by --vault / $SEMPERE_VAULT.
        let protecting = (access.vault ?? Env.vars["SEMPERE_VAULT"]).map { [URL(fileURLWithPath: $0)] } ?? []
        if dryRun {
            try Backup.checkRestoreTarget(URL(fileURLWithPath: to), from: source, protecting: protecting)
            let preview = try Backup.preview(of: source)
            if output.json {
                try output.emitJSON(preview)
            } else {
                print("vault        \(preview.vaultId)" + (preview.isBackup ? "" : " (a vault folder, not a backup)"))
                if let d = preview.backupUpdated { print("backed up    \(Format.local(d))") }
                print("notes        \(preview.notes)")
                print("revisions    \(preview.revisions)")
                print("attachments  \(preview.attachments)")
                print("key files    \(preview.keyFiles)")
                print("bytes        \(preview.bytes)")
                print("newest       \(preview.newestRevision.map(Format.local) ?? "none")")
                output.info("Nothing written; \(to) can take the restore.")
            }
            return
        }
        let identities = try access.readingIdentities(vaultId: try Vault.open(at: source).vaultId)
        if !identities.isEmpty { _ = try Vault.open(at: source, identities: identities) }   // exit 4 early
        let report = try Backup.restore(from: source, to: URL(fileURLWithPath: to), identities: identities,
                                        protecting: protecting)
        let verify = report.verify
        let bad = (verify?.files ?? []).filter { ![.ok, .unknownFile, .notChecked].contains($0.status) }
        if output.json {
            struct Out: Encodable {
                var vault: String; var restored: Int; var alreadyPresent: Int
                var errors: [BackupReport.FileError]; var healthy: Bool; var decrypted: Bool; var problems: [String]
            }
            try output.emitJSON(Out(vault: to, restored: report.restored.count, alreadyPresent: report.alreadyPresent,
                                    errors: report.errors, healthy: verify?.isHealthy ?? false,
                                    decrypted: !identities.isEmpty,
                                    problems: (verify?.manifestProblems ?? []) + bad.map { "\($0.status.rawValue) \($0.path)" }))
        } else {
            if output.verbose { for p in report.restored { print("restored  \(p)") } }
            for e in report.errors { printStderr("error: \(e.path): \(e.message)") }
            for f in bad { print("\(f.status.rawValue)  \(f.path)" + (f.detail.map { "  (\($0))" } ?? "")) }
            output.info("\(report.restored.count) file(s) restored, \(report.alreadyPresent) already there, "
                        + "\(report.errors.count) error(s); "
                        + (verify == nil ? "\(Vault.manifestName) missing, not verified"
                           : identities.isEmpty ? "structure verified (no key: revisions not decrypted)"
                           : "every revision decrypted and verified")
                        + (verify?.isHealthy == false ? ": PROBLEMS" : ""))
        }
        if !report.errors.isEmpty { throw ExitCode(ExitStatus.failure) }
        if verify?.isHealthy != true { throw ExitCode(ExitStatus.unhealthy) }
    }
}
