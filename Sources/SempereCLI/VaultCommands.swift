import Age
import ArgumentParser
import Foundation
import Sempere

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Create, inspect and verify a vault.",
        subcommands: [VaultInit.self, VaultInfo.self, VaultLabelCommand.self, VaultVerify.self, VaultIndex.self,
                      VaultSummaries.self, VaultMergeCopy.self]
    )
}

// MARK: - init

struct VaultInit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new vault directory (its name must end in .sempere), with this machine as its home device.",
        discussion: """
            The vault is created with one epoch key, wrapped to this machine's new device key and to a new \
            recovery key (format.md §15). This machine is the vault's home: it approves and renames devices \
            (sempere devices). Its device key and signing keys are written to \
            $XDG_STATE_HOME/sempere/devices/<vault id>/device.key (mode 0600); with --passphrase they are \
            passphrase-wrapped there instead. They never leave this machine.

            The recovery key is the printed kit: it is written to --recovery-out (mode 0600; print it with \
            `sempere keys paper --vault PATH --identity FILE`, then delete the file) and no device keeps it. \
            With --recovery-key the given identity is the recovery key instead. --recovery-passphrase also \
            writes the passphrase copy of the recovery key into keys/ (scrypt work factor 20, a passphrase \
            of at least about 70 bits; the passphrase comes from the variable named by --passphrase-env, else \
            $SEMPERE_PASSPHRASE, else the terminal).
            """
    )

    @Argument(help: ArgumentHelp("The new vault directory.", valueName: "path"))
    var path: String

    @Option(name: .long, help: ArgumentHelp("This device's name (at most 40 characters).", valueName: "text"))
    var name = "sempere CLI"

    @Option(name: .long, help: ArgumentHelp("This device's kind: a lowercase word (cli, mac, ...).", valueName: "word"))
    var kind = "cli"

    @Option(name: .customLong("vault-label"),
            help: ArgumentHelp("The vault's display name (vault.json label, stored unencrypted: nothing private).",
                               valueName: "text"))
    var vaultLabel: String?

    @Option(name: .customLong("recovery-out"),
            help: ArgumentHelp("Where to write the new recovery key (mode 0600). Refuses to overwrite.", valueName: "file"))
    var recoveryOut: String?

    @Option(name: .customLong("recovery-key"),
            help: ArgumentHelp("Use this post-quantum identity file as the recovery key instead of a new one.",
                               valueName: "file"))
    var recoveryKey: String?

    @Flag(name: .customLong("recovery-passphrase"),
          help: "Also write the passphrase copy of the recovery key into keys/.")
    var recoveryPassphrase = false

    @Flag(name: .long, help: "Passphrase-wrap this machine's device key (asked at every use).")
    var passphrase = false

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Variable holding the passphrase(s).", valueName: "var"))
    var passphraseEnv: String?

    @Option(name: .customLong("work-factor"), help: ArgumentHelp("scrypt work factor of the passphrase copy (20).",
                                                                  visibility: .private))
    var workFactor = RecoveryPassphraseCopy.workFactor

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard JoinRequest.isValidKind(kind) else { throw ValidationError("--kind must be a lowercase word of 1 to 32 letters") }
        guard recoveryOut != nil || recoveryKey != nil else {
            throw ValidationError("give --recovery-out FILE (a new recovery key is written there) or --recovery-key FILE")
        }
        guard (1...RecoveryPassphraseCopy.workFactor).contains(workFactor) else {
            throw ValidationError("--work-factor must be in 1...\(RecoveryPassphraseCopy.workFactor)")
        }
    }

    func run() throws {
        let recovery: MLKEM768X25519Identity
        if let recoveryKey {
            guard case .mlkem768x25519(let pq) = try readIdentityFile(recoveryKey) else {
                throw CLIError.usage("\(recoveryKey) is not a post-quantum key (AGE-SECRET-KEY-PQ-1...)")
            }
            recovery = pq
        } else {
            do { recovery = try MLKEM768X25519Identity() } catch { throw CLIError.failure("\(error)") }
        }
        var copyPassphrase: String?
        if recoveryPassphrase {
            let pass = try obtainPassphrase(envName: passphraseEnv, prompt: "Recovery passphrase: ", confirm: true,
                                            asError: CLIError.failure)
            try requireStoredKeyPassphrase(pass)
            copyPassphrase = pass
        }
        let device: DeviceKeys
        do { device = try DeviceKeys.generate() } catch { throw CLIError.failure("\(error)") }
        let vaultId = UUID()
        let deviceKeyPassphrase = passphrase
            ? try obtainPassphrase(envName: passphraseEnv, prompt: "Device key passphrase: ", confirm: true,
                                   asError: CLIError.failure) : nil
        // The device key first: a vault this machine cannot open later is no use. A failed init removes
        // what it wrote (the device key of a vault that does not exist, the unused recovery key).
        var wroteRecovery = false
        let keyPath: String
        let vault: Vault
        do {
            keyPath = try DeviceKeyStore.save(device, vaultId: vaultId, passphrase: deviceKeyPassphrase)
            if let recoveryOut {
                try writeNewSecretFile(IdentityFile.render(.mlkem768x25519(recovery), created: Date()), to: recoveryOut)
                wroteRecovery = true
            }
            vault = try Vault.create(at: URL(fileURLWithPath: path), device: device, deviceName: name, kind: kind,
                                     recovery: recovery, recoveryPassphrase: copyPassphrase, workFactor: workFactor,
                                     vaultId: vaultId, trust: trustStore(), label: vaultLabel)
        } catch {
            try? FileManager.default.removeItem(at: DeviceKeyStore.directory(vaultId: vaultId))
            if wroteRecovery, let recoveryOut { try? FileManager.default.removeItem(atPath: recoveryOut) }
            throw error
        }
        let root = Hex.encode(vault.root)
        if output.json {
            try output.emitJSON(InitOutput(path: path, vaultId: vault.vaultId.uuidString.lowercased(), root: root,
                                           device: device.id, deviceKey: keyPath, recoveryKey: recoveryOut,
                                           passphraseCopy: vault.passphraseCopyNames().first.map { "keys/\($0)" }))
        } else {
            output.info("Created \(path)\nVault id: \(vault.vaultId.uuidString.lowercased())")
            output.info("Root:     \(KitRecovery.rootGroups(vault.root).map(\.group).joined(separator: " "))")
            output.info("This device (home): \(device.id), keys in \(keyPath)")
            if let recoveryOut {
                output.info("Recovery key: \(recoveryOut). Print the kit (sempere keys paper --vault \(path) --identity "
                    + "\(recoveryOut)), keep it offline, then delete the file: no device keeps it.")
            }
        }
    }

    private struct InitOutput: Encodable {
        var path: String
        var vaultId: String
        var root: String
        var device: String
        var deviceKey: String
        var recoveryKey: String?
        var passphraseCopy: String?
    }
}

// MARK: - label

/// `sempere vault label`: show, set or clear the vault's display name (format.md §2 `label`).
struct VaultLabelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label",
        abstract: "Show, set or clear the vault's display name (vault.json label).",
        discussion: """
            Without TEXT, prints the label (works without a key; no output when there is none). With TEXT, \
            stores it (one line, trimmed, at most 80 characters); --clear removes it. Setting needs a listed \
            device's key. The label is stored UNENCRYPTED in vault.json and covered by no signature: anyone \
            with access to the vault folder or the server can read it, and anyone who can write there can \
            change it, so put nothing private in it. It is for display only and never trusted.
            """
    )

    @Argument(help: ArgumentHelp("The new label.", valueName: "text"))
    var text: String?

    @Flag(name: .long, help: "Remove the label.")
    var clear = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if clear && text != nil { throw ValidationError("give TEXT or --clear, not both") }
        if let text, VaultLabelText.cleanVaultLabel(text) == nil { throw ValidationError("the label is empty; use --clear") }
    }

    func run() throws {
        var vault: Vault
        if text != nil || clear {
            vault = try access.openVault(.required)
            try vault.setLabel(clear ? nil : text)
        } else {
            vault = try access.openVault(.ifPossible)
        }
        if output.json {
            try output.emitJSON(LabelOutput(label: vault.label))
        } else if let label = vault.label {
            print(label)
        }
    }

    /// `{"label": …}`, null when there is none.
    private struct LabelOutput: Encodable {
        var label: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
        }

        enum CodingKeys: String, CodingKey { case label }
    }
}

// MARK: - info

struct VaultInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show the manifest: id, root, epoch, devices, note count.",
        discussion: "Works without a key; with one it also checks vault.json (design §4.3)."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        let m = vault.manifest
        let info = Info(
            path: vault.url.path, vaultId: vault.vaultId.uuidString.lowercased(), label: vault.label,
            created: m.created, root: Hex.encode(m.root), epoch: m.epoch, epochId: Hex.encode(m.epochId),
            home: String(Hex.encode(m.home).prefix(8)), devices: m.devices.map { DeviceOutput($0, in: m) },
            notes: try vault.noteIDs().count, passphraseCopy: !vault.passphraseCopyNames().isEmpty,
            joinRequests: vault.joinRequests().count, unlocked: !vault.isLocked, openedWith: Self.opener(vault),
            format: m.format, features: m.features, readOnly: vault.isReadOnly,
            readOnlyReasons: vault.readOnlyReasons.descriptions, list: ListStatusOutput(vault))
        if output.json { try output.emitJSON(info); return }
        print("Vault:          \(info.path)")
        print("Vault id:       \(info.vaultId)")
        if let label = info.label { print("Label:          \(label)") }
        print("Created:        \(info.created)")
        print("Root:           \(KitRecovery.rootGroups(m.root).map(\.group).joined(separator: " "))")
        print("Epoch:          \(info.epoch)")
        print("Format:         \(info.format)" + (info.features.isEmpty ? "" : " (\(info.features.joined(separator: ", ")))"))
        if info.readOnly {
            print("Read-only:      YES: \(info.readOnlyReasons.joined(separator: "; ")); update Sempere to change it")
        }
        print("Notes:          \(info.notes)")
        print("Devices:        \(info.devices.count) (home: \(info.home))")
        for d in info.devices {
            print("  \(d.id)  \(d.kind)  \(d.name)" + (d.home ? "  [manages devices]" : ""))
        }
        print("Recovery copy:  \(info.passphraseCopy ? "passphrase copy in keys/" : "none")")
        if info.joinRequests > 0 { print("Join requests:  \(info.joinRequests) (sempere devices list)") }
        print("Opened with:    \(info.openedWith)")
        print("Device list:    \(info.list.text)")
    }

    static func opener(_ vault: Vault) -> String {
        switch vault.openedWith {
        case .locked: return "nothing (locked)"
        case .recovery: return "the recovery key (read-only)"
        case .device(let fp): return "device \(Hex.encode(fp).prefix(8))"
        }
    }

    private struct Info: Encodable {
        var path: String
        var vaultId: String
        /// `vault.json`'s `label` (format.md §2), cleaned; absent when none.
        var label: String?
        var created: String
        var root: String
        var epoch: Int
        var epochId: String
        /// The home device's id (design §5.6).
        var home: String
        var devices: [DeviceOutput]
        var notes: Int
        var passphraseCopy: Bool
        var joinRequests: Int
        var unlocked: Bool
        var openedWith: String
        /// `vault.json`'s `format` and `features` (format.md §2, §7.1).
        var format: String
        var features: [String]
        /// True when this version may read but not change the vault (format.md §7.3).
        var readOnly: Bool
        var readOnlyReasons: [String]
        var list: ListStatusOutput
    }
}

/// One device in `vault info --json` and `devices list --json`.
struct DeviceOutput: Encodable {
    var id: String
    var name: String
    var kind: String
    var added: String
    var addedBy: String
    var home: Bool
    var fingerprint: String

    init(_ entry: EpochKeyEntry) {
        id = entry.id ?? ""
        name = DeviceName.display(entry.name)
        kind = entry.kind ?? ""
        added = entry.added
        addedBy = entry.addedBy ?? ""
        fingerprint = Hex.encode(entry.fingerprint)
        home = false
    }

    init(_ entry: EpochKeyEntry, in manifest: EpochManifest) {
        self.init(entry)
        home = entry.fingerprint == manifest.home
    }
}

/// `list` in `vault info --json` and `vault verify --json`: how vault.json checked (design §4.3).
struct ListStatusOutput: Encodable {
    /// `verified`, `refused` or `not-checked` (locked).
    var status: String
    /// For `verified`: `unchanged`, `firstUse`, `added` or `renamed`.
    var verification: String?
    /// For `refused`: `ListProblem.Reason`'s raw value.
    var reason: String?
    var detail: String?

    init(_ vault: Vault) {
        let s = vault.listStatus
        status = s.label
        if case .verified(let how) = s { verification = how.rawValue }
        if let p = s.problem { reason = p.reason.rawValue; detail = p.detail }
    }

    var text: String {
        switch status {
        case "verified": return "verified" + (verification == "firstUse" ? " (first use on this machine)" : "")
        case "not-checked": return "not checked (locked)"
        default: return "REFUSED (\(reason ?? "?")): \(detail ?? ""); nothing is written to the vault"
        }
    }
}

// MARK: - verify

struct VaultVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check every file: decrypt, tag, decode, one stanza to the vault identity.",
        discussion: """
            Exit 0 only if the vault is healthy, 6 when vault.json does not check on this machine (design \
            §4.3), 3 otherwise. With -q only problem files are listed. Works with the recovery key \
            (--recovery-key, read-only).
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let report = vault.verify()
        if output.json {
            try output.emitJSON(Out(report, vault))
        } else {
            for p in report.manifestProblems { print("MANIFEST   \(Vault.manifestName): \(p)") }
            print("DEVICES    \(ListStatusOutput(vault).text)")
            let shown = output.quiet ? report.files.filter { $0.status.isProblem } : report.files
            let rows = shown.map { [$0.status.rawValue, $0.path + ($0.detail.map { "  (\($0))" } ?? "")] }
            if !rows.isEmpty { print(Format.table(rows)) }
            let counts = VerifyReport.Status.allCases.compactMap { s in
                report.counts[s].map { "\(s.rawValue): \($0)" }
            }
            if vault.isReadOnly {
                print("READ-ONLY  " + vault.readOnlyReasons.descriptions.joined(separator: "; "))
            }
            print("\(report.files.count) file(s)" + (counts.isEmpty ? "" : " (" + counts.joined(separator: ", ") + ")")
                + (report.isHealthy ? ": healthy" : ": UNHEALTHY"))
        }
        if report.list.problem != nil { throw ExitCode(ExitStatus.untrustedList) }
        if !report.isHealthy { throw ExitCode(ExitStatus.unhealthy) }
    }

    private struct Out: Encodable {
        struct File: Encodable { var path: String; var status: String; var detail: String? }
        var healthy: Bool
        var manifestProblems: [String]
        var counts: [String: Int]
        var files: [File]
        var readOnly: Bool
        var readOnlyReasons: [String]
        var list: ListStatusOutput

        init(_ r: VerifyReport, _ vault: Vault) {
            readOnly = vault.isReadOnly
            readOnlyReasons = vault.readOnlyReasons.descriptions
            list = ListStatusOutput(vault)
            healthy = r.isHealthy
            manifestProblems = r.manifestProblems
            counts = Dictionary(uniqueKeysWithValues: r.counts.map { ($0.key.rawValue, $0.value) })
            files = r.files.map { File(path: $0.path, status: $0.status.rawValue, detail: $0.detail) }
        }
    }
}

// MARK: - merge-copy

struct VaultMergeCopy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge-copy",
        abstract: "Merge another copy of the vault into it (nothing is overwritten or deleted).",
        discussion: """
            FROM is another copy of the same vault (same vault id): the losing side of an iCloud Drive \
            conflict, a copy taken from another device, a folder restored from a backup. Every revision, \
            attachment blob, inbox file, epoch record, join request and passphrase copy the vault lacks is \
            checked as a received file (format.md §9.1) and copied in; settings.age is merged per key (needs \
            the key; locked, it is reported as pending). vault.json is taken from FROM only when it is a \
            later version of the vault's own by its home device (needs the key; design §5.1); otherwise a \
            difference is only reported. Nothing in the vault is deleted, so running it again does nothing. \
            Exit 1 when a file of FROM was refused (it is listed), 0 otherwise.
            """
    )

    @Argument(help: ArgumentHelp("The other copy (a vault folder).", valueName: "from"))
    var from: String

    @Flag(name: .long, help: "Only report what would be copied or merged.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        let report: CopyMergeReport
        do {
            report = try vault.mergeCopy(from: URL(fileURLWithPath: (from as NSString).expandingTildeInPath),
                                         dryRun: dryRun)
        } catch let e as CopyMergeError {
            throw CLIError.failure("\(from): \(e)")
        }
        if output.json {
            try output.emitJSON(report)
        } else {
            let verb = dryRun ? "would add" : "added"
            for path in report.added { print("\(verb) \(path)") }
            for (path, why) in report.refused.sorted(by: { $0.key < $1.key }) { print("refused \(path): \(why)") }
            for path in report.differing { print("differs \(path) (kept the vault's)") }
            if report.settingsMerged { print(dryRun ? "would merge settings.age" : "merged settings.age") }
            if let why = report.settingsPending { print("settings.age differs, not merged: \(why)") }
            if report.manifestUpdated { print(dryRun ? "would take vault.json (a later version)" : "took vault.json (a later version)") }
            if report.manifestDiffers { print("vault.json differs (kept the vault's)") }
            output.info(report.isEmpty ? "Nothing to merge." : "\(report.added.count) file(s) \(verb).")
        }
        if !report.refused.isEmpty { throw ExitCode(ExitStatus.failure) }
    }
}
