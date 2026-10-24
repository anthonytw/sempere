import Age
import ArgumentParser
import Foundation
import Sempere
import SempereSync
import SempereWebDAV

// `sempere vault reencrypt` (docs/design/key-hierarchy.md §7; phase KH6): on the home device, a new vault key and a
// new recovery key, then every file re-encrypted under the new key, carried to every sync target of the store vault,
// each target confirmed, and the finish. `--resume` continues one (after a crash, a lock, a lost network, or on a new
// home after a handoff); `--status` only reports.

/// What `--json` prints.
struct ReencryptOutput: Encodable {
    struct Target: Encodable {
        var name: String
        var reached: Bool
        var confirmed: Bool
        var files: Int
        var current: Int
        var replaced: Int
        var deleted: Int
        var waiting: [String: String]
        var error: String?
    }
    /// The re-encryption epoch, when one is on the chain.
    var epoch: Int?
    var pending: Bool
    var finished: Bool
    /// This device's working copy: files under a key from before the re-encryption still to do, of how many.
    var remaining: Int
    var total: Int
    var reencrypted: Int
    var left: [String: String]
    var problems: [String: String]
    var targets: [Target]
    /// A start: the new epoch and the new recovery key's file.
    var started: EpochChangeOutput?
    var recoveryOut: String?
}

struct VaultReencrypt: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reencrypt",
        abstract: "Re-encrypt every file under a new vault key and a new recovery key (on the home device).",
        discussion: """
            Design §7. For when the recovery kit is lost (no device was compromised) and nothing on the storage \
            should open with it any more. It is rare and slow: every file is encrypted again and goes over the \
            network to every sync target. Old backups, provider version history and this machine's set-aside files \
            still open with the old keys.

            Start (without --resume): first the device review, as for `recovery replace`: every listed device but \
            this one is named with --keep ID or --remove ID; without --yes the review is printed and nothing is \
            written. Then a pull from the store vault's targets (unless --no-pull), every target must be reachable \
            (--allow-unreachable NAME lets the start go on without one: it is claimed and confirmed when it is \
            back, and the finish waits for it), the re-encryption journal claims every target (a target holding \
            another re-encryption's journal refuses: nothing is written), the new recovery key is written to \
            --recovery-out (mode 0600; print it with `sempere keys paper`, then delete the file), and a new epoch \
            starts: every write is under the new key from then on, and the old kit no longer takes over on any \
            device that sees it.

            Then (and with --resume) one step: the pass re-encrypts this machine's files (each copy verified before \
            the old one goes; a file the acceptance rule does not take is set aside, never re-encrypted), a sync \
            with every target carries the new copies, each target is confirmed (its files under an earlier key \
            replaced by the current copy, or set aside here and deleted there; old blob names and the earlier \
            epoch records deleted), and once every target is, the finish: vault.json without the journal's \
            binding, the journal deleted, and a sync with every target again. Run --resume until it reports \
            "finished" (exit 1 while it is not). --status reports without changing anything.

            A vault with no sync targets (not a store vault) is re-encrypted in place and finished at once.
            """
    )

    @OptionGroup var access: AccessOptions

    @Flag(name: .long, help: "Continue a pending re-encryption (the pass, the targets, the finish).")
    var resume = false

    @Flag(name: .long, help: "Report where a re-encryption stands; change nothing.")
    var status = false

    @Option(name: .customLong("recovery-out"),
            help: ArgumentHelp("Where to write the new recovery key (mode 0600). Refuses to overwrite.", valueName: "file"))
    var recoveryOut: String?

    @Flag(name: .customLong("recovery-passphrase"), help: "Write the passphrase copy of the new recovery key into keys/.")
    var recoveryPassphrase = false

    @Option(name: .long, help: ArgumentHelp("A device to keep (id or 4+ hex digits); repeat.", valueName: "id"))
    var keep: [String] = []

    @Option(name: .long, help: ArgumentHelp("A device to remove (id or 4+ hex digits); repeat.", valueName: "id"))
    var remove: [String] = []

    @Option(name: .customLong("allow-unreachable"),
            help: ArgumentHelp("A sync target (name or id) the start may go on without; repeat.", valueName: "target"))
    var allowUnreachable: [String] = []

    @Flag(name: .long, help: "Start (without it the review is printed and nothing is written).")
    var yes = false

    @Option(name: .customLong("work-factor"), help: ArgumentHelp("scrypt work factor of the passphrase copy (20).",
                                                                  visibility: .private))
    var workFactor = RecoveryPassphraseCopy.workFactor

    @OptionGroup var pull: EpochPullOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if resume || status {
            guard recoveryOut == nil, keep.isEmpty, remove.isEmpty, !recoveryPassphrase else {
                throw CLIError.usage("--resume and --status take no review, --recovery-out or --recovery-passphrase")
            }
        }
    }

    func run() throws {
        var vault = try access.openVault(.required)
        let store = EpochTargets.store(of: vault.url, vaultId: vault.vaultId)
        let targets = store.map { $0.targets.targets(of: vault.vaultId) } ?? []
        if status { return try report(vault, targets: [], progress: nil, started: nil) }
        guard vault.isHome else {
            let who = vault.manifest.homeEntry.map { "\(DeviceName.display($0.name)) (\($0.id ?? "?"))" } ?? "another device"
            throw CLIError.failure("only the home device re-encrypts the vault: \(who) manages its devices")
        }
        var started: EpochChangeOutput?
        if !resume {
            guard !vault.isReencryptPending else {
                throw CLIError.usage("a re-encryption is pending: continue it with --resume")
            }
            guard let recoveryOut else { throw CLIError.usage("--recovery-out FILE is required to start") }
            if yes, !pull.noPull, store != nil {
                _ = EpochTargets.pull(vault, passwordEnv: pull.passwordEnv, output: output)
                vault = try access.openVault(.required)
            }
            let review = try vault.kitReview()
            let named = Set(try (keep + remove).map { try vault.resolveDevice($0).fingerprint })
            guard yes, review.allSatisfy({ named.contains($0.device.fingerprint) }) else {
                if output.json {
                    struct Row: Encodable { var id: String; var name: String; var takeoverSinceKit: Bool }
                    try output.emitJSON(review.map { Row(id: $0.device.id ?? "", name: DeviceName.display($0.device.name),
                                                         takeoverSinceKit: $0.takeoverSinceKit) })
                } else {
                    print("Confirm (--keep ID) or remove (--remove ID) every device:")
                    var rows: [[String]] = [["ID", "NAME", ""]]
                    for r in review {
                        rows.append([r.device.id ?? "?", DeviceName.display(r.device.name),
                                     r.takeoverSinceKit ? "TAKEOVER since the current kit: check it is yours" : ""])
                    }
                    print(Format.table(rows))
                }
                throw CLIError.usage("nothing written: name every device with --keep or --remove, and pass --yes")
            }
            // Every target reachable (design §7.1 step 2), but those the user lets go.
            let allowed = Set(try allowUnreachable.map { name in
                guard let t = targets.first(where: { $0.name == name || $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }) else {
                    throw CLIError.usage("no sync target \(name)")
                }
                return t.id
            })
            var reachable: [ReencryptCoordinator.Target] = []
            for t in targets {
                do {
                    let r = try EpochTargets.remote(t, passwordEnv: pull.passwordEnv)
                    _ = try r.list([])
                    reachable.append(.init(name: t.name, remote: r))
                } catch where allowed.contains(t.id) {
                    printStderr("sempere: \(t.name) is not reachable (\(CLIError.from(error).message)): it is claimed and "
                        + "confirmed when it is back; the finish waits for it")
                } catch {
                    throw CLIError.failure("\(t.name) is not reachable (\(CLIError.from(error).message)): every target must "
                        + "be (design §7.1), or pass --allow-unreachable \(t.name)")
                }
            }
            var passphrase: String?
            if recoveryPassphrase {
                let pass = try obtainPassphrase(envName: access.passphraseEnv, prompt: "New recovery passphrase: ", confirm: true,
                                                asError: CLIError.failure)
                try requireStoredKeyPassphrase(pass)
                passphrase = pass
            }
            let kit: MLKEM768X25519Identity
            do { kit = try MLKEM768X25519Identity() } catch { throw CLIError.failure("\(error)") }
            try writeNewSecretFile(IdentityFile.render(.mlkem768x25519(kit), created: Date()), to: recoveryOut)
            do {
                let prep = try vault.prepareReencryption(kit, keep: Set(keep), remove: Set(remove), passphrase: passphrase,
                                                         workFactor: workFactor)
                var seen = loadClaims(store, vault.vaultId)
                let claims = ReencryptCoordinator.claim(prep.journalFile, vault: vault, on: reachable, seen: &seen)
                saveClaims(store, vault.vaultId, seen)
                let refused = claims.filter { !$0.value.isClaimed }
                guard refused.isEmpty else {
                    ReencryptCoordinator.release(prep.journalFile, on: reachable)
                    _ = try? vault.abandonReencryptionStart()
                    let why = refused.sorted { $0.key < $1.key }.map { name, o -> String in
                        switch o {
                        case .refused(let s), .unreachable(let s): return "\(name): \(s)"
                        case .claimed: return name
                        }
                    }
                    throw CLIError.failure("nothing written: the re-encryption could not claim every target (\(why.joined(separator: "; ")))")
                }
                started = EpochChangeOutput(try vault.beginReencryption(prep))
            } catch {
                try? FileManager.default.removeItem(atPath: recoveryOut)
                throw error
            }
            if !output.json {
                output.info("Epoch \(started?.epoch ?? 0): re-encryption started. New recovery key: \(recoveryOut). Print the kit "
                    + "(sempere keys paper --vault \(vault.url.path) --identity \(recoveryOut) --out kit.pdf), keep it offline, "
                    + "then delete the file.")
            }
        } else if !vault.isReencryptPending {
            // A start that stopped before its epoch: its claims and its local journal go.
            if let journal = try vault.abandonReencryptionStart() {
                let remotes = targets.compactMap { t in (try? EpochTargets.remote(t, passwordEnv: pull.passwordEnv)).map {
                    ReencryptCoordinator.Target(name: t.name, remote: $0) } }
                let released = ReencryptCoordinator.release(journal, on: remotes)
                output.info("A re-encryption start that did not reach its epoch was abandoned (claims released on "
                    + "\(released.isEmpty ? "no target" : released.joined(separator: ", "))). Start again without --resume.")
            }
            vault.removeRecordsBelowReencryption()
            return try report(vault, targets: [], progress: nil, started: nil)
        }
        // One step: the pass, the targets, the finish.
        var remotes: [ReencryptCoordinator.Target] = []
        var unreachable: [String: String] = [:]
        var byName: [String: SyncTarget] = [:]
        for t in targets {
            byName[t.name] = t
            do { remotes.append(.init(name: t.name, remote: try EpochTargets.remote(t, passwordEnv: pull.passwordEnv))) } catch {
                unreachable[t.name] = CLIError.from(error).message
            }
        }
        // A journal claimed late (a target unreachable at the start): the runs put it there.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-reencrypt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var memo: [String: [String: String]] = [:]
        var progress: ReencryptCoordinator.Progress
        if unreachable.isEmpty {
            let opener = vault
            progress = try ReencryptCoordinator.advance(&vault, targets: remotes, sync: { t in
                // Each run opens the vault as it is on disk now (the pass and the finish change it).
                if let st = byName[t.name], let store { try syncTarget(store, st, vault: try opener.reopened()) }
            }, memo: &memo, scratch: scratch)
        } else {
            // The pass and the reachable targets only: no finish while a target cannot be confirmed.
            progress = .init()
            progress.pass = try vault.reencryptPass()
            for t in remotes { if let st = byName[t.name], let store { try? syncTarget(store, st, vault: vault) } }
            vault = try vault.reopened()
            for t in remotes {
                var m: [String: String] = [:]
                progress.targets.append(ReencryptCoordinator.confirm(vault: vault, target: t, memo: &m, scratch: scratch))
            }
        }
        try report(vault, targets: progress.targets.map { c in
            .init(name: c.target, reached: true, confirmed: c.confirmed, files: c.files, current: c.current,
                  replaced: c.replaced.count, deleted: c.deleted.count, waiting: c.waiting, error: nil)
        } + unreachable.sorted { $0.key < $1.key }.map { .init(name: $0.key, reached: false, confirmed: false, files: 0, current: 0,
                                                             replaced: 0, deleted: 0, waiting: [:], error: $0.value) },
                   progress: progress, started: started)
        if !progress.finished { throw ExitCode(ExitStatus.failure) }
    }

    /// Prints (or emits) where the re-encryption stands.
    func report(_ vault: Vault, targets: [ReencryptOutput.Target], progress: ReencryptCoordinator.Progress?,
                started: EpochChangeOutput?) throws {
        let s = try vault.reencryptStatus()
        let out = ReencryptOutput(epoch: s.epoch, pending: s.pending, finished: progress?.finished ?? (s.epoch != nil && !s.pending),
                                  remaining: s.remaining, total: s.total, reencrypted: progress?.pass?.reencrypted.count ?? 0,
                                  left: progress?.pass?.left ?? [:], problems: progress?.pass?.problems ?? [:], targets: targets,
                                  started: started, recoveryOut: started == nil ? nil : recoveryOut)
        if output.json { return try output.emitJSON(out) }
        guard let epoch = s.epoch else { return output.info("No re-encryption on this vault's chain.") }
        if out.finished && s.pending == false {
            output.info("Re-encryption of epoch \(epoch): finished. Nothing in the vault opens with the old kit or an earlier key.")
        } else {
            let done = s.total - s.remaining - s.unaccepted
            output.info("Re-encrypting (epoch \(epoch)): \(done) of \(s.total) files (this device)"
                + (s.journalHere ? "" : "; waiting for the journal from a target"))
        }
        for t in targets {
            let pct = t.files == 0 ? 100 : t.current * 100 / t.files
            if let e = t.error { printStderr("sempere: \(t.name): not reachable (\(e))"); continue }
            output.info("  \(t.name): \(t.confirmed ? "confirmed" : "\(pct) %")"
                + (t.replaced + t.deleted > 0 ? " (\(t.replaced) replaced, \(t.deleted) deleted)" : ""))
            for (p, why) in t.waiting.sorted(by: { $0.key < $1.key }).prefix(5) { printStderr("sempere:    \(p): \(why)") }
        }
        for (p, why) in out.left.sorted(by: { $0.key < $1.key }) { printStderr("sempere: \(p): set aside, \(why)") }
        for (p, why) in out.problems.sorted(by: { $0.key < $1.key }) { printStderr("sempere: \(p): \(why)") }
    }

    /// A two-way run with one store target (as `store sync` makes it).
    func syncTarget(_ store: VaultStore, _ t: SyncTarget, vault: Vault) throws {
        let lease = try store.lease(vault.vaultId)
        defer { lease.release() }
        var options = SyncOptions()
        options.deviceID = vault.writerDevice ?? SyncCLI.deviceID()
        options.deviceLabel = ProcessInfo.processInfo.hostName
        options.localWriteLock = store.writeLock(for: vault.vaultId)
        options.recordSynced = true
        options.epochTrust = trustStore()
        options.quarantineDirectory = store.targets.quarantineDirectory(t.id, of: vault.vaultId)
        let stateURL = store.targets.stateURL(t.id, of: vault.vaultId)
        let report: SyncReport
        switch t.kind {
        case .folder:
            guard let path = t.path else { throw SyncTargetError.io("target \(t.name) has no path") }
            report = try FolderTargetRun.run(vaultFolder: vault.url, folder: URL(fileURLWithPath: path, isDirectory: true),
                                             vault: vault, stateURL: stateURL, twoWay: true, options: options)
        case .webdav:
            guard let text = t.url, let url = URL(string: text) else { throw SyncTargetError.io("target \(t.name) has no URL") }
            let login = try WebDAVLoginOptions.parse((t.user.map { ["--user", $0] } ?? [])
                                                     + (pull.passwordEnv.map { ["--password-env", $0] } ?? []))
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            report = try SyncEngine(directory: vault.url, vault: vault, client: try login.client(url), stateURL: stateURL,
                                    options: options).run()
        default:
            throw SyncTargetError.io("target kind \(t.kind) is not supported by this version")
        }
        if !output.json {
            for e in report.errors.prefix(5) { printStderr("sempere: \(t.name): \(e.path): \(e.message)") }
        }
    }

    func loadClaims(_ store: VaultStore?, _ vaultId: UUID) -> ReencryptCoordinator.ClaimSightings {
        store.map { ReencryptCoordinator.loadClaimSightings(ReencryptCoordinator.claimSightingsURL(store: $0, vaultId: vaultId)) } ?? [:]
    }

    func saveClaims(_ store: VaultStore?, _ vaultId: UUID, _ seen: ReencryptCoordinator.ClaimSightings) {
        guard let store else { return }
        ReencryptCoordinator.saveClaimSightings(seen, to: ReencryptCoordinator.claimSightingsURL(store: store, vaultId: vaultId))
    }
}
