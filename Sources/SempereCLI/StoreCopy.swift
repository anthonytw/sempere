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
            (the kit's identity file, or the vault's passphrase copy, read with --passphrase-env). The new vault \
            takes vault init's options. \(VaultInitOptions.discussion)

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
    }

    func run() throws {
        let store = location.open()
        let sourceURL = try resolveSource(store)
        var access = AccessOptions()
        access.identity = identity
        access.recoveryKey = sourceRecoveryKey
        access.root = root
        access.passphraseEnv = spec.passphraseEnv
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
            return try finish(report, entry: nil)
        }

        let prepared = try spec.prepare()
        let keys = prepared.keys
        let ledger: (any WriteLedgerStore)? = cliLedger(vaultId: keys.vaultId, device: keys.device.identity)
        var file = try DeviceClockFile(url: DeviceState.defaultURL())
        let device = file.device
        do {
            let (entry, report) = try store.create(name: name) { url -> CopyReport in
                _ = try spec.create(at: url, prepared: prepared)
                let destination = try Vault.open(at: url, identities: [keys.device.nativeIdentity],
                                                 signing: keys.device.signing, trust: trustStore())
                // The clock is kept even when the copy stops half way: it stamped files it wrote.
                return try file.withClock(save: true) { clock in
                    try VaultCopier.copy(from: sourceVault, into: destination, device: device, clock: &clock,
                                         options: copyOptions(ledger: ledger), progress: progress)
                }
            }
            try finish(report, entry: entry)
        } catch let e as ExitCode {
            throw e
        } catch {
            // The keys of a vault that does not exist (`spec.create` wrote them before the copy began).
            try? FileManager.default.removeItem(at: CLIDeviceKeyFiles.directory(vaultId: keys.vaultId))
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

    private func finish(_ report: CopyReport, entry: VaultStore.Entry?) throws {
        if output.json {
            try output.emitJSON(report)
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
                if output.quiet { print(entry.url.path) } else { output.info("Path: \(entry.url.path)") }
                output.info("Recovery key: " + (spec.recoveryOut ?? "(the one you gave)") + ". The copy has its own keys.")
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
