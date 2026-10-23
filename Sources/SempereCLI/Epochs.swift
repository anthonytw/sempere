import Age
import ArgumentParser
import Foundation
import Sempere
import SempereSync

// New epochs from the CLI (docs/design/key-hierarchy.md §5.2, §5.4, §5.6, §5.8, §6.3, §6.5; phase KH3):
// `sempere devices remove|handoff` on the home device, `sempere recovery takeover|replace`, `sempere vault
// catch-up`, and the set-aside store (`sempere set-aside`).

/// What `--json` prints for an epoch change.
struct EpochChangeOutput: Encodable {
    var epoch: Int
    var epochId: String
    var reason: String
    var removed: [String]
    var home: String
    var sealed: Int

    init(_ r: EpochChangeReport) {
        epoch = r.epoch
        epochId = Hex.encode(r.epochId)
        reason = r.reason.rawValue
        removed = r.removed.map { String(Hex.encode($0).prefix(8)) }
        home = String(Hex.encode(r.home).prefix(8))
        sealed = r.sealed
    }
}

/// The advice every removal prints (design §5.5): a key change cannot take storage access away.
let storageAdvice = "A removed device can still reach your storage: change the password of a WebDAV target it "
    + "used, or sign it out of iCloud, if you no longer control it."

// MARK: - devices remove / handoff (home)

struct DevicesRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove devices (on the home device): a new vault key, immediately.",
        discussion: """
            Starts a new epoch (design §5.2): this machine first catches up its own files, then, under the \
            vault's write lock, writes the epoch record (the old key and the sealed set: every file it holds \
            that verifies) and vault.json with the new key wrapped to every remaining key. From then on every \
            write is under the new key; files a removed device writes later are set aside on every device, \
            never placed. The removed device is told it was removed when it opens the vault (exit 8 there). \
            Only the home device removes, and never itself (hand the home role over first).
            """
    )

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("The devices' ids (or 4+ leading hex digits).", valueName: "id"))
    var ids: [String] = []

    @OptionGroup var output: OutputOptions
    @Flag(name: .customLong("unsynced-epoch"), help: ArgumentHelp("Start the new epoch even though this store vault has sync "
          + "targets (they carry no epoch record before key hierarchy KH4: other devices cannot read what is written after it)."))
    var unsyncedEpoch = false

    func validate() throws {
        guard !ids.isEmpty else { throw ValidationError("name at least one device to remove") }
    }

    func run() throws {
        var vault = try access.openVault(.required)
        try refuseUnsyncedEpoch(vault.url, vaultId: vault.vaultId, allowed: unsyncedEpoch)
        let names = Dictionary(vault.devices.compactMap { d in d.id.map { ($0, DeviceName.display(d.name)) } },
                               uniquingKeysWith: { a, _ in a })
        let report = try vault.removeDevices(ids)
        if output.json { return try output.emitJSON(EpochChangeOutput(report)) }
        for fp in report.removed {
            let id = String(Hex.encode(fp).prefix(8))
            output.info("Removed \(names[id] ?? "the recovery key") (\(id)).")
        }
        output.info("Epoch \(report.epoch): a new vault key; \(report.sealed) files from before are sealed.")
        output.info(storageAdvice)
    }
}

struct DevicesHandoff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "handoff",
        abstract: "Make another listed device the home device (on the home device).",
        discussion: """
            A handoff is a new epoch with the same devices and a new vault key, signed by this (the old) home \
            and naming the new one (design §5.6). From then on only the new home approves, renames and \
            removes devices; this machine's signatures no longer count.
            """
    )

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("The new home's id (or 4+ leading hex digits).", valueName: "id"))
    var id: String

    @OptionGroup var output: OutputOptions
    @Flag(name: .customLong("unsynced-epoch"), help: ArgumentHelp("Start the new epoch even though this store vault has sync "
          + "targets (they carry no epoch record before key hierarchy KH4: other devices cannot read what is written after it)."))
    var unsyncedEpoch = false

    func run() throws {
        var vault = try access.openVault(.required)
        try refuseUnsyncedEpoch(vault.url, vaultId: vault.vaultId, allowed: unsyncedEpoch)
        let target = try vault.resolveDevice(id)
        let report = try vault.handOff(to: target.id ?? id)
        if output.json { return try output.emitJSON(EpochChangeOutput(report)) }
        output.info("Epoch \(report.epoch): \(DeviceName.display(target.name)) (\(target.id ?? "?")) manages devices now.")
    }
}

// MARK: - recovery takeover / replace

struct RecoveryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recovery",
        abstract: "Take over the vault with the recovery kit, or replace the kit (on the home device).",
        subcommands: [RecoveryTakeover.self, RecoveryReplace.self]
    )
}

struct RecoveryTakeover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "takeover",
        abstract: "Take over managing devices with the recovery kit: this machine becomes home, with the devices you pick.",
        discussion: """
            For a lost or stolen home device (design §5.6 rule 3, §6.3). Give the recovery key with \
            --recovery-key (the kit's identity file, or the vault's passphrase copy keys/recovery-*.key.age, \
            which carries the root). A machine that never joined the vault needs the root (--root, the kit's \
            16 groups, or the passphrase copy) and joins as the new home: a kit join is a takeover.

            The takeover is a new epoch under this machine's pinned epoch, signed by this machine and by the \
            recovery key, listing this machine, the recovery key and the devices you keep: --keep ID for each \
            (devices of the parent epoch's list, and devices an earlier epoch removed, for example by a stolen \
            home), or --keep-listed for every device of the parent epoch's list except those an epoch the takeover \
            drops removed. Without --yes it prints the choices, the epochs it drops and whom they removed, and \
            writes nothing; names come from this machine's trust record where it has them (a stolen home may have \
            renamed devices). It beats every epoch by the old home that is not its ancestor. Only the kit of the \
            epoch this machine pinned takes over: a retired kit, or one this machine has not pinned yet, is \
            refused.
            """
    )

    @OptionGroup var access: AccessOptions

    @Option(name: .long, help: ArgumentHelp("A device to keep (its id or 4+ leading hex digits); repeat.", valueName: "id"))
    var keep: [String] = []

    @Flag(name: .customLong("keep-listed"), help: ArgumentHelp("Keep every device of the parent epoch's list, except those an "
          + "epoch the takeover drops removed (name those with --keep)."))
    var keepListed = false

    @Option(name: .long, help: ArgumentHelp("This device's name, when it joins (at most 40 characters).", valueName: "text"))
    var name = "sempere CLI"

    @Option(name: .long, help: ArgumentHelp("This device's kind, when it joins: a lowercase word (cli, mac, ...).",
                                            valueName: "word"))
    var kind = "cli"

    @Flag(name: .long, help: "Take over (without it the choices are printed and nothing is written).")
    var yes = false

    @OptionGroup var output: OutputOptions
    @Flag(name: .customLong("unsynced-epoch"), help: ArgumentHelp("Start the new epoch even though this store vault has sync "
          + "targets (they carry no epoch record before key hierarchy KH4: other devices cannot read what is written after it)."))
    var unsyncedEpoch = false

    func validate() throws {
        guard access.recoveryKey != nil else { throw ValidationError("give the recovery key with --recovery-key FILE") }
        guard JoinRequest.isValidKind(kind) else { throw ValidationError("--kind must be a lowercase word of 1 to 32 letters") }
    }

    func run() throws {
        let url = try access.vaultURL()
        let locked = try Vault.open(at: url)
        try refuseUnsyncedEpoch(url, vaultId: locked.vaultId, allowed: unsyncedEpoch)
        guard let (identity, copyRoot) = try access.recoveryIdentity(), case .mlkem768x25519(let recovery) = identity else {
            throw CLIError.usage("the recovery key is not a post-quantum key (AGE-SECRET-KEY-PQ-1...)")
        }
        let root = try access.givenRoot() ?? copyRoot
        // This machine's device keys for the vault; a machine that has none joins with new ones.
        var device = try DeviceKeyStore.load(vaultId: locked.vaultId, passphraseEnv: access.passphraseEnv)
        var madeKeys = false
        if device == nil {
            do { device = try DeviceKeys.generate() } catch { throw CLIError.failure("\(error)") }
            madeKeys = true
        }
        guard let device else { throw CLIError.failure("no device keys") }
        let trust = trustStore()
        let plan = try Vault.takeoverPlan(at: url, device: device, recovery: recovery, trust: trust, root: root)
        var kept = Set<Data>()
        if keepListed { kept.formUnion(plan.candidates.filter(\.checkedByDefault).map(\.fingerprint)) }
        for q in keep {
            let matches = plan.candidates.filter { $0.id == q.lowercased() || (q.count >= 4 && $0.id.hasPrefix(q.lowercased())) }
            guard matches.count == 1, let m = matches.first else {
                throw CLIError.usage("--keep \(q): not one device of this takeover's choices (see them without --yes)")
            }
            kept.insert(m.fingerprint)
        }
        guard yes else {
            if output.json {
                struct Choice: Encodable {
                    var id: String; var name: String; var nameTrusted: Bool; var listed: Bool; var removedByDroppedEpoch: Bool
                    var checkedByDefault: Bool
                }
                struct Dropped: Encodable { var epoch: Int; var reason: String; var author: String; var removed: [String] }
                struct Out: Encodable { var parentEpoch: Int; var choices: [Choice]; var dropped: [Dropped]; var keep: [String] }
                try output.emitJSON(Out(
                    parentEpoch: plan.parentEpoch,
                    choices: plan.candidates.map {
                        Choice(id: $0.id, name: $0.name, nameTrusted: $0.nameTrusted, listed: $0.listed,
                               removedByDroppedEpoch: $0.removedByDroppedEpoch, checkedByDefault: $0.checkedByDefault)
                    },
                    dropped: plan.dropped.map { d in
                        Dropped(epoch: d.epoch, reason: d.reason, author: d.author, removed: d.removed.map { String(Hex.encode($0).prefix(8)) })
                    },
                    keep: plan.candidates.filter { kept.contains($0.fingerprint) }.map(\.id)))
            } else {
                print("A takeover under epoch \(plan.parentEpoch) makes this machine home.")
                for d in plan.dropped {
                    let gone = d.removed.map { String(Hex.encode($0).prefix(8)) }
                    print("It drops epoch \(d.epoch) (\(d.reason) by \(d.author))"
                        + (gone.isEmpty ? "." : ", which removed \(gone.joined(separator: ", ")): check why before keeping them."))
                }
                print("Devices to keep:")
                var rows: [[String]] = [["ID", "NAME", "", ""]]
                for c in plan.candidates {
                    let state = c.removedByDroppedEpoch ? "removed by a dropped epoch" : c.listed ? "on the parent's list" : "removed earlier"
                    rows.append([c.id, c.name + (c.nameTrusted ? "" : " (name from the current vault.json)"), state,
                                 kept.contains(c.fingerprint) ? "kept" : "dropped"])
                }
                print(Format.table(rows))
            }
            throw CLIError.usage("nothing written: pass --yes to take over (with --keep ID... or --keep-listed)")
        }
        if madeKeys {
            _ = try DeviceKeyStore.save(device, vaultId: locked.vaultId, passphrase: nil)
        }
        let result: (vault: Vault, report: EpochChangeReport)
        do {
            result = try Vault.takeover(
                at: url, device: device, recovery: recovery, keep: kept, name: name, kind: kind, trust: trust, root: root,
                ledger: cliLedger(vaultId: locked.vaultId, device: device.identity),
                setAside: SetAsideStore(directory: SetAsideStore.cliDirectory(environment: Env.vars)))
        } catch {
            if madeKeys { try? FileManager.default.removeItem(at: DeviceKeyStore.directory(vaultId: locked.vaultId)) }
            throw error
        }
        if output.json { return try output.emitJSON(EpochChangeOutput(result.report)) }
        output.info("Epoch \(result.report.epoch): this machine (\(device.id)) took over with the recovery kit and "
            + "manages devices now; \(result.report.removed.count) key(s) dropped.")
        output.info("Every other listed device will show the takeover. If a device was stolen, also replace the "
            + "recovery kit (sempere recovery replace).")
    }
}

struct RecoveryReplace: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replace",
        abstract: "Replace the recovery kit (on the home device): a new recovery key, after reviewing every device.",
        discussion: """
            Design §6.5. First the device review: every listed device but this one must be named, with \
            --keep ID or --remove ID (devices a takeover added since the current kit are marked). Without \
            --yes the review is printed and nothing is written; --yes is the confirmation that you are at the \
            device (the app asks for Face ID or the passcode instead).

            Then a new recovery key is written to --recovery-out (mode 0600; print it with `sempere keys \
            paper --vault PATH --identity FILE`, then delete the file), and a new epoch drops the old key and \
            the removed devices: from then on no device that saw it takes a takeover by the old kit. With \
            --old-recovery-key (the old kit, or the vault's passphrase copy) the epoch also carries the old \
            key's signature (evidence that its holder agreed). --recovery-passphrase writes the passphrase \
            copy for the new key and deletes the old one.
            """
    )

    @OptionGroup var access: AccessOptions

    @Option(name: .customLong("recovery-out"),
            help: ArgumentHelp("Where to write the new recovery key (mode 0600). Refuses to overwrite.", valueName: "file"))
    var recoveryOut: String

    @Option(name: .customLong("old-recovery-key"),
            help: ArgumentHelp("The current kit's identity file, or the vault's passphrase copy (optional evidence).",
                               valueName: "file"))
    var oldRecoveryKey: String?

    @Flag(name: .customLong("recovery-passphrase"), help: "Write the passphrase copy of the new recovery key into keys/.")
    var recoveryPassphrase = false

    @Option(name: .long, help: ArgumentHelp("A device to keep (id or 4+ hex digits); repeat.", valueName: "id"))
    var keep: [String] = []

    @Option(name: .long, help: ArgumentHelp("A device to remove (id or 4+ hex digits); repeat.", valueName: "id"))
    var remove: [String] = []

    @Flag(name: .long, help: "Replace the kit (without it the review is printed and nothing is written).")
    var yes = false

    @Option(name: .customLong("work-factor"), help: ArgumentHelp("scrypt work factor of the passphrase copy (20).",
                                                                  visibility: .private))
    var workFactor = RecoveryPassphraseCopy.workFactor

    @OptionGroup var output: OutputOptions
    @Flag(name: .customLong("unsynced-epoch"), help: ArgumentHelp("Start the new epoch even though this store vault has sync "
          + "targets (they carry no epoch record before key hierarchy KH4: other devices cannot read what is written after it)."))
    var unsyncedEpoch = false

    func run() throws {
        var vault = try access.openVault(.required)
        try refuseUnsyncedEpoch(vault.url, vaultId: vault.vaultId, allowed: unsyncedEpoch)
        guard vault.isHome else { throw CLIError.failure("only the home device replaces the recovery kit") }
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
        var old: MLKEM768X25519Identity?
        if let oldRecoveryKey {
            var a = access
            a.recoveryKey = oldRecoveryKey
            guard let (identity, _) = try a.recoveryIdentity(), case .mlkem768x25519(let pq) = identity else {
                throw CLIError.usage("--old-recovery-key is not a post-quantum key")
            }
            old = pq
        }
        var passphrase: String?
        if recoveryPassphrase {
            let pass = try obtainPassphrase(envName: access.passphraseEnv, prompt: "New recovery passphrase: ", confirm: true,
                                            asError: CLIError.failure)
            try requireStoredKeyPassphrase(pass)
            passphrase = pass
        }
        let newKit: MLKEM768X25519Identity
        do { newKit = try MLKEM768X25519Identity() } catch { throw CLIError.failure("\(error)") }
        try writeNewSecretFile(IdentityFile.render(.mlkem768x25519(newKit), created: Date()), to: recoveryOut)
        let report: EpochChangeReport
        do {
            report = try vault.replaceRecoveryKit(newKit, keep: Set(keep), remove: Set(remove), oldRecovery: old,
                                                  passphrase: passphrase, workFactor: workFactor)
        } catch {
            try? FileManager.default.removeItem(atPath: recoveryOut)
            throw error
        }
        if output.json { return try output.emitJSON(EpochChangeOutput(report)) }
        output.info("Epoch \(report.epoch): a new recovery kit. The old kit no longer opens or takes over this vault "
            + "on any device that sees this change.")
        output.info("New recovery key: \(recoveryOut). Print the kit (sempere keys paper --vault \(vault.url.path) "
            + "--identity \(recoveryOut) --out kit.pdf), keep it offline, then delete the file.")
        output.info("Root:     \(KitRecovery.rootGroups(vault.root).map(\.group).joined(separator: " "))")
    }
}

// MARK: - vault catch-up

struct VaultCatchUp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catch-up",
        abstract: "Re-encrypt this machine's own files that a device change did not seal, and set aside the rest.",
        discussion: """
            Design §5.4. The first write after this machine verifies a new epoch does this by itself; this \
            command runs it now and reports. For every file this machine wrote (its write ledger, in \
            $XDG_STATE_HOME/sempere/ledger) under an earlier key that the change did not seal, the same body \
            is re-encrypted under the current key (the old bytes set aside first). Other files under an earlier \
            key that no seal covers are copied into the set-aside store ($XDG_STATE_HOME/sempere/setaside) and \
            never read as notes.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let r = try vault.catchUp()
        _ = try? vault.pruneLedger()
        if let file = vault.ledger as? FileWriteLedger, file.logBytes > FileWriteLedger.warnLogBytes {
            printStderr("sempere: warning: this machine's write ledger is \(file.logBytes >> 20) MiB (\(file.folder.path)); "
                + "it should stay near the size of the vault's live files")
        }
        if output.json {
            struct Out: Encodable {
                var reencrypted: [String]; var pruned: Int; var sealedKept: Int; var dropped: [String]; var setAside: [String]
                var problems: [String: String]
            }
            try output.emitJSON(Out(reencrypted: r.reencrypted, pruned: r.pruned, sealedKept: r.sealedKept, dropped: r.dropped,
                                    setAside: r.setAside, problems: r.problems))
        } else {
            output.info("Re-encrypted \(r.reencrypted.count) file(s); \(r.setAside.count) set aside; "
                + "\(r.pruned) ledger entr\(r.pruned == 1 ? "y" : "ies") pruned.")
            for (path, why) in r.problems.sorted(by: { $0.key < $1.key }) { printStderr("sempere: \(path): \(why)") }
        }
        if !r.problems.isEmpty { throw CLIError.failure("\(r.problems.count) file(s) could not be caught up; try again") }
    }
}

// MARK: - set-aside

struct SetAsideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-aside",
        abstract: "Files from before a device change that this machine set aside: list, export, keep, clear.",
        discussion: """
            Design §5.8. A file under an earlier key that no device change sealed (written after a removal, by \
            a removed device or by one that has not caught up yet) is kept here, outside the vault, and never \
            read as a note. Nothing is deleted except by `clear`.
            """,
        subcommands: [SetAsideList.self, SetAsideExport.self, SetAsideKeep.self, SetAsideClear.self]
    )
}

/// The items `query` names: a SHA-256 or 8+ leading hex digits of one.
private func setAsideItems(_ vault: Vault, _ queries: [String]) throws -> [SetAsideStatus] {
    let all = vault.setAsideReport()
    return try queries.map { q in
        let m = all.filter { $0.item.sha256 == q.lowercased() || (q.count >= 8 && $0.item.sha256.hasPrefix(q.lowercased())) }
        guard m.count == 1, let one = m.first else { throw CLIError.failure("not one set-aside item: \(q)") }
        return one
    }
}

private func openForSetAside(_ access: AccessOptions) throws -> Vault {
    let vault = try access.openVault(.required)
    guard vault.setAsideStore != nil else { throw CLIError.cannotDecrypt("the set-aside store needs this machine's device key") }
    return vault
}

struct SetAsideList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the set-aside files.")

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let report = try openForSetAside(access).setAsideReport()
        if output.json {
            struct Row: Encodable {
                var path: String; var sha256: String; var reason: String; var epoch: Int?; var setAside: String; var superseded: Bool
            }
            return try output.emitJSON(report.map { Row(path: $0.item.path, sha256: $0.item.sha256, reason: $0.item.reason.rawValue,
                                                        epoch: $0.item.epoch, setAside: $0.item.setAside,
                                                        superseded: $0.superseded) })
        }
        var rows: [[String]] = [["SHA-256", "PATH", "REASON", ""]]
        for s in report {
            rows.append([String(s.item.sha256.prefix(12)), s.item.path, s.item.reason.rawValue, s.superseded ? "superseded" : ""])
        }
        print(Format.table(rows))
    }
}

struct SetAsideExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Copy set-aside files, as they are, under their vault paths in a folder.")

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("Items: SHA-256 (or 8+ leading hex digits).", valueName: "sha"))
    var items: [String] = []

    @Option(name: .long, help: ArgumentHelp("The folder to copy them into.", valueName: "dir"))
    var to: String

    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try openForSetAside(access)
        let picked = items.isEmpty ? vault.setAsideReport() : try setAsideItems(vault, items)
        let written = try picked.map { try vault.exportSetAside($0.item, to: URL(fileURLWithPath: to)).path }
        if output.json { return try output.emitJSON(written) }
        output.info("Exported \(written.count) file(s) to \(to)")
    }
}

struct SetAsideKeep: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep",
        abstract: "Put set-aside files back in the vault, re-encrypted under the current key.",
        discussion: "They may come from a removed device: keep only what you recognize. Needs --yes."
    )

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("Items: SHA-256 (or 8+ leading hex digits).", valueName: "sha"))
    var items: [String] = []

    @Flag(name: .long, help: "Confirm.")
    var yes = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard !items.isEmpty else { throw ValidationError("name the items to keep") }
    }

    func run() throws {
        let vault = try openForSetAside(access)
        let picked = try setAsideItems(vault, items)
        guard yes else {
            throw CLIError.usage("these files may come from a removed device; pass --yes to put them back in the vault")
        }
        for s in picked { try vault.keepSetAside(s.item) }
        if output.json { return try output.emitJSON(picked.map(\.item.path)) }
        output.info("Kept \(picked.count) file(s) in the vault.")
    }
}

struct SetAsideClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Delete set-aside files from this machine (superseded ones, or those named).")

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("Items: SHA-256 (or 8+ leading hex digits).", valueName: "sha"))
    var items: [String] = []

    @Flag(name: .long, help: "Every item whose body the vault holds accepted.")
    var superseded = false

    @Flag(name: .long, help: "Confirm.")
    var yes = false

    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try openForSetAside(access)
        guard let store = vault.setAsideStore else { return }
        var picked = items.isEmpty ? [] : try setAsideItems(vault, items)
        if superseded { picked += vault.setAsideReport().filter(\.superseded) }
        guard !picked.isEmpty else { throw CLIError.usage("name items, or pass --superseded") }
        guard yes else { throw CLIError.usage("this deletes \(picked.count) set-aside file(s) from this machine; pass --yes") }
        for s in picked { try store.remove(s.item) }
        if output.json { return try output.emitJSON(picked.map(\.item.path)) }
        output.info("Cleared \(picked.count) set-aside file(s).")
    }
}

/// Refuses a new epoch on a store vault that has sync targets (review S4): until key hierarchy KH4 syncs
/// `epochs/`, no other device can take the change, and what this machine writes after it is unreadable there.
/// `--unsynced-epoch` goes ahead anyway. A plain folder (synced by `sync folder|webdav` with state elsewhere) is
/// not detected: the command's help says so.
func refuseUnsyncedEpoch(_ url: URL, vaultId: UUID, allowed: Bool) throws {
    guard !allowed else { return }
    let idFolder = url.standardizedFileURL.deletingLastPathComponent()
    guard idFolder.lastPathComponent == vaultId.uuidString.lowercased() else { return }
    let registry = SyncTargetRegistry(root: idFolder.deletingLastPathComponent().appendingPathComponent(VaultStore.syncName))
    let targets: [SyncTarget]
    do { targets = try registry.load(vaultId) } catch {
        throw CLIError.failure("cannot read this store vault's sync targets (\(error)): pass --unsynced-epoch to go ahead")
    }
    guard targets.isEmpty else {
        throw CLIError.failure("this store vault syncs with \(targets.count) target(s), and device changes are not synced "
            + "before key hierarchy KH4: other devices could not read what is written after it. Pass --unsynced-epoch to go ahead")
    }
}
