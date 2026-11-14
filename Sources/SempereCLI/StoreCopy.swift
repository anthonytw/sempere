import ArgumentParser
import Foundation
import Sempere

/// `sempere store copy`: Make a Copy… of a vault, including a read-only one, as a new vault of the user's own
/// (`VaultCopier`, docs/design/1.2-make-a-copy.md; docs/cli.md "Vault store").
struct StoreCopy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Make a copy of a vault (read-only ones too) as a new vault of your own in the store.",
        discussion: """
            The copy is a new vault: a new id, a new recovery key and this machine as its home, with the source's notes \
            in their current state, one checkpoint per note ("Copied from ..."). Note ids, pages, strokes, items, \
            recordings and attachments are kept; history, devices, sync targets, settings and the inbox are not. \
            Notes in Recently Deleted are left out unless --include-deleted. The source is only read: it may be \
            read-only (a newer format, an unconfirmed device list, this device removed, or opened with its recovery \
            key), with a warning about what a copy cannot keep. A partly downloaded source is refused. \
            SOURCE is a vault folder or a store vault (id, id prefix or name). It is read with this machine's key \
            for it, with --identity FILE (a device key or any age identity), or with --source-recovery-key FILE \
            (the kit's identity file, or the vault's passphrase copy, whose passphrase comes from \
            --source-passphrase-env, else $SEMPERE_PASSPHRASE, else the terminal; a passphrase-wrapped device key of \
            the source too). The new vault takes vault init's options, and its own passphrases come from \
            --passphrase-env: never the same variable as the source's. \(VaultInitOptions.discussion)

            The copy is built in the store's staging folder and appears at once when complete; a cancel or a failure \
            leaves nothing in the store. A note that cannot be read or copied is listed in the report and left out \
            (exit 1, the copy still exists); --strict stops at the first one instead and leaves no vault. \
            --dry-run reads everything, writes nothing and prints what a copy would write. --json prints the report.
            """
    )

    @Argument(help: ArgumentHelp("The vault to copy: a folder, or a store vault (id, id prefix or name).", valueName: "source"))
    var source: String

    @Argument(help: ArgumentHelp("The new vault's name (its folder is NAME.sempere).", valueName: "name"))
    var name: String

    @Option(name: .long, help: ArgumentHelp("A key file that reads the source: a device key, or any age identity.",
                                            valueName: "file"))
    var identity: [String] = []

    @Option(name: .customLong("source-recovery-key"),
            help: ArgumentHelp("Read the source with its recovery key (the kit's identity file, or its passphrase copy).",
                               valueName: "file"))
    var sourceRecoveryKey: String?

    @Option(name: .customLong("source-passphrase-env"),
            help: ArgumentHelp("Variable holding the source's passphrase (its passphrase copy, or a passphrase-wrapped device key).",
                               valueName: "var"))
    var sourcePassphraseEnv: String?

    @Option(name: .long, help: ArgumentHelp("The source's root fingerprint (64 hex digits, or the kit's 16 groups) to check a "
                                            + "--source-recovery-key read against.", valueName: "hex"))
    var root: String?

    @Flag(name: .customLong("include-deleted"), help: "Also copy the notes in Recently Deleted, in their deleted state.")
    var includeDeleted = false

    @Flag(name: .long, help: "Stop at the first note that cannot be copied and leave no vault.")
    var strict = false

    @Flag(name: .customLong("dry-run"), help: "Read everything, write nothing, print what a copy would write.")
    var dryRun = false

    @OptionGroup var spec: VaultInitOptions
    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        do { _ = try VaultStore.folderName(for: name) } catch { throw ValidationError("\(error)") }
        // One variable must never serve both vaults: the copy's own passphrases are new secrets.
        if sourcePassphraseEnv == nil, spec.passphraseEnv == nil, spec.passphrase || spec.recoveryPassphrase,
           Env.vars["SEMPERE_PASSPHRASE"] != nil {
            throw ValidationError("$SEMPERE_PASSPHRASE would serve both the source and the new vault: give "
                + "--source-passphrase-env and --passphrase-env (different variables)")
        }
        if let a = sourcePassphraseEnv, a == spec.passphraseEnv {
            throw ValidationError("--source-passphrase-env and --passphrase-env name the same variable")
        }
    }

    func run() throws {
        let store = location.open()
        let sourceURL = try resolveSource(store)
        var access = AccessOptions()
        access.identity = identity
        access.recoveryKey = sourceRecoveryKey
        access.root = root
        access.passphraseEnv = sourcePassphraseEnv
        let sourceVault = try access.openVault(at: sourceURL, .required)

        let verbose = output.verbose && !output.json && !output.quiet
        var progress: (@Sendable (CopyProgress) -> Void)?
        if verbose {
            progress = { (p: CopyProgress) in
                if p.done == p.total || p.done % 25 == 0 { printStderr("copied \(p.done) of \(p.total) notes") }
            }
        }

        if dryRun {
            var clock = HybridClock()
            let report = try VaultCopier.copy(from: sourceVault, into: nil, device: DeviceID.random(), clock: &clock,
                                              options: copyOptions(ledger: nil), progress: progress)
            return try finish(report, entry: nil, created: nil)
        }

        let prepared = try spec.prepare()
        let keys = prepared.keys
        let ledger = cliLedger(vaultId: keys.vaultId, device: keys.device.identity)
        var file = try DeviceClockFile(url: DeviceState.defaultURL())
        let device = file.device
        var created: VaultInitOptions.Created?
        do {
            let (entry, report) = try store.create(name: name) { url -> CopyReport in
                created = try spec.create(at: url, prepared: prepared)
                let destination = try Vault.open(at: url, identities: [keys.device.nativeIdentity],
                                                 signing: keys.device.signing, trust: trustStore())
                // The clock is kept even when the copy stops half way: it stamped files it wrote.
                return try file.withClock(save: true) { clock in
                    try VaultCopier.copy(from: sourceVault, into: destination, device: device, clock: &clock,
                                         options: copyOptions(ledger: ledger), progress: progress)
                }
            }
            try finish(report, entry: entry, created: created)
        } catch let e as ExitCode {
            throw e
        } catch {
            // What belongs to a vault that does not exist: its keys and ledger (`spec.create` and the copy wrote them
            // before it failed) and the unused recovery key.
            try? FileManager.default.removeItem(at: CLIDeviceKeyFiles.directory(vaultId: keys.vaultId))
            try? FileManager.default.removeItem(at: ledger.folder)
            if let out = spec.recoveryOut { try? FileManager.default.removeItem(atPath: out) }
            throw error
        }
    }

    private func copyOptions(ledger: (any WriteLedgerStore)?) -> VaultCopier.Options {
        VaultCopier.Options(includeDeleted: includeDeleted, strict: strict, app: appName,
                            sourceName: nil, ledger: ledger)
    }

    /// A folder that exists is the source; else a store vault.
    private func resolveSource(_ store: VaultStore) throws -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: source, isDirectory: true)
        }
        return try store.resolve(source).url
    }

    /// `--json`: the new vault as `store create` reports it (null in a dry run) and the copy's report.
    private struct Output: Encodable {
        var vault: VaultInitOptions.InitOutput?
        var report: CopyReport

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(vault, forKey: .vault)   // null, not absent, in a dry run
            try c.encode(report, forKey: .report)
        }

        enum Keys: String, CodingKey { case vault, report }
    }

    private func finish(_ report: CopyReport, entry: VaultStore.Entry?, created: VaultInitOptions.Created?) throws {
        if output.json {
            try output.emitJSON(Output(vault: entry.flatMap { e in created?.initOutput(path: e.url.path) }, report: report))
        } else {
            for w in report.warnings { printStderr("warning: \(w)") }
            for n in report.newer {
                let ops = n.skippedOps.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                printStderr("warning: note \(n.note) might be missing something a newer version wrote"
                    + (ops.isEmpty ? "" : " (skipped: \(ops))"))
            }
            for f in report.failed { printStderr("not copied: note \(f.note): \(f.reason)") }
            let counts = "\(report.notes) notes, \(report.pages) pages, \(report.strokes) strokes, \(report.items) items, "
                + "\(report.recordings) recordings, \(report.blobs) attachments (\(report.blobBytes) bytes)"
            if let entry {
                output.info("Copied \(counts) into the store as “\(entry.name)” (\(entry.vaultId.uuidString.lowercased()))")
                if output.quiet { print(entry.url.path) }
                // The new vault's keys, as `store create` shows them (a generated passphrase is shown once, even with -q).
                try created?.report(path: entry.url.path, output: output)
            } else {
                output.info("Dry run: a copy would write \(counts)")
            }
            if report.deletedSkipped > 0 {
                output.info("\(report.deletedSkipped) deleted notes left out (--include-deleted copies them)")
            }
        }
        if !report.isComplete { throw ExitCode(ExitStatus.failure) }
    }
}
