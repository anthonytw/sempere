import Age
import ArgumentParser
import Foundation
import Sempere

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Create, inspect, verify and re-key a vault.",
        subcommands: [VaultInit.self, VaultInfo.self, VaultRecipients.self, VaultLink.self, VaultMarkersCommand.self, VaultRewrapResume.self,
                      VaultRewrapDiscard.self,
                      VaultVerify.self, VaultIndex.self, VaultSummaries.self]
    )
}

// MARK: - init

struct VaultInit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new vault directory (its name must end in .sempere).",
        discussion: """
            Every note is encrypted to all --recipient keys. With --store-key the matching identity is
            also written passphrase-wrapped to keys/ (the passphrase comes from the variable named by
            --passphrase-env, else $SEMPERE_PASSPHRASE, else the terminal).
            """
    )

    @Argument(help: ArgumentHelp("The new vault directory.", valueName: "path"))
    var path: String

    @Option(name: .long, help: ArgumentHelp("A recipient public key. Repeatable, at least one.", valueName: "age1..."))
    var recipient: [String] = []

    @Option(name: .long, help: ArgumentHelp("A label per recipient, in order. Repeatable.", valueName: "text"))
    var label: [String] = []

    @Option(name: .customLong("store-key"),
            help: ArgumentHelp("Also store this identity, passphrase-wrapped, in keys/.", valueName: "file"))
    var storeKey: String?

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Variable holding the passphrase for --store-key.", valueName: "var"))
    var passphraseEnv: String?

    @Option(name: .customLong("work-factor"),
            help: ArgumentHelp("scrypt work factor of the stored key, 15...18 (each step doubles the cost).",
                               valueName: "n"))
    var workFactor = 18

    @Flag(name: .customLong("allow-weak-passphrase"),
          help: "Store the key even under a passphrase too easy to guess offline (security.md).")
    var allowWeakPassphrase = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard IdentityFile.writerWorkFactors.contains(workFactor) else {
            throw ValidationError("--work-factor must be in \(IdentityFile.writerWorkFactors)")
        }
        guard !recipient.isEmpty else { throw ValidationError("give at least one --recipient age1...") }
        guard label.isEmpty || label.count == recipient.count else {
            throw ValidationError("give no --label, or one per --recipient (\(recipient.count))")
        }
        if passphraseEnv != nil && storeKey == nil { throw ValidationError("--passphrase-env needs --store-key") }
    }

    func run() throws {
        let recipients = try recipient.map(parseRecipient)
        try requirePostQuantum(recipients)
        var stored: (NativeIdentity, String)?
        if let storeKey {
            let id = try readIdentityFile(storeKey)
            guard recipients.contains(id.recipient) else {
                throw CLIError.usage("\(storeKey) is not one of the --recipient keys")
            }
            let pass = try obtainPassphrase(envName: passphraseEnv, prompt: "New key passphrase: ", confirm: true,
                                            asError: CLIError.failure)
            try requireStoredKeyPassphrase(pass, allowWeak: allowWeakPassphrase)
            stored = (id, pass)
        }
        let vault = try Vault.create(at: URL(fileURLWithPath: path), recipients: recipients, labels: label,
                                     trust: trustStore())
        var keyFile: String?
        if let (id, pass) = stored {
            keyFile = try vault.writeIdentityFile(id, passphrase: pass, workFactor: workFactor).path
        }
        if output.json {
            try output.emitJSON(InitOutput(path: path, vaultId: vault.vaultId.uuidString.lowercased(),
                                           recipients: recipients.map(\.string), keyFile: keyFile))
        } else {
            output.info("Created \(path)\nVault id: \(vault.vaultId.uuidString.lowercased())")
            if let keyFile { output.info("Stored passphrase-wrapped key: \(keyFile)") }
        }
    }

    private struct InitOutput: Encodable {
        var path: String
        var vaultId: String
        var recipients: [String]
        var keyFile: String?
    }
}

// MARK: - info

struct VaultInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show the manifest: id, created, recipients, note count, pending rewrap.",
        discussion: "Works without a key; with an identity (or a scripted passphrase) it also checks the rewrap journal."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.ifPossible, migration: true)
        let noteCount = try vault.noteIDs().count
        let keyFiles = try vault.identityFiles().map(\.string)
        let info = Info(
            path: vault.url.path, vaultId: vault.vaultId.uuidString.lowercased(), created: vault.manifest.created,
            recipients: vault.recipients.map {
                .init(key: $0.key, type: (try? NativeRecipient(string: $0.key))?.isPostQuantum == true
                    ? Info.Recipient.pqType : "x25519", label: $0.label, added: $0.added)
            },
            notes: noteCount, keyFiles: keyFiles, pendingRewrap: vault.pendingRewrap,
            journalProblem: vault.journalProblem, journalRefused: vault.journalRefused, unlocked: !vault.isLocked,
            format: vault.manifest.format, features: vault.manifest.features, readOnly: vault.isReadOnly,
            readOnlyReasons: vault.readOnlyReasons.descriptions,
            recipientsAuth: RecipientsStatusOutput(vault))
        if output.json { try output.emitJSON(info); return }
        print("Vault:          \(info.path)")
        print("Vault id:       \(info.vaultId)")
        print("Created:        \(Format.local(info.created))")
        print("Format:         \(info.format)" + (info.features.isEmpty ? "" : " (\(info.features.joined(separator: ", ")))"))
        if info.readOnly {
            print("Read-only:      YES: \(info.readOnlyReasons.joined(separator: "; ")); update Sempere to change it")
        }
        print("Notes:          \(info.notes)")
        print("Recipients:     \(info.recipients.count)")
        for r in info.recipients {
            print("  \(RecipientsProblem.abbreviate(r.key))  \(r.type)  \(VaultManifest.Recipient.displayLabel(r.label))  "
                + "added \(Format.local(r.added))")
        }
        let classic = info.recipients.filter { $0.type != Info.Recipient.pqType }.count
        if let old = vault.classicRecipients.first {
            print("Post-quantum:   NO: legacy vault (\(classic) classic X25519 recipient(s)); its notes stay locked "
                + "until it is migrated: sempere vault recipients replace \(old) NEW")
        } else {
            print("Post-quantum:   yes")
        }
        print("Device list:    \(info.recipientsAuth.text)")
        print("Stored keys:    \(keyFiles.isEmpty ? "none" : "\(keyFiles.count) passphrase-wrapped")")
        print("Pending rewrap: " + (!info.pendingRewrap ? "no"
            : info.journalRefused ? "REFUSED journal (check it, then run `sempere vault rewrap-discard`)"
            : "YES (run `sempere vault rewrap-resume`)"))
        if !info.unlocked {
            print("Journal:        not checked (locked; pass --identity to check)")
        } else if let p = info.journalProblem, info.pendingRewrap {
            print("Journal:        PROBLEM: \(p)")
        } else {
            print("Journal:        ok")
        }
    }

    private struct Info: Encodable {
        struct Recipient: Encodable {
            static let pqType = "mlkem768x25519"
            var key: String
            /// `x25519` or `mlkem768x25519`.
            var type: String
            var label: String
            var added: Date
        }
        var path: String
        var vaultId: String
        var created: Date
        var recipients: [Recipient]
        var notes: Int
        var keyFiles: [String]
        var pendingRewrap: Bool
        var journalProblem: String?
        /// True when the journal was read and refused (format.md §3.3.1): `vault rewrap-discard` deletes it.
        var journalRefused: Bool
        var unlocked: Bool
        /// `vault.json`'s `format` and `features` (format.md §2, §7.1).
        var format: String
        var features: [String]
        /// True when this version may read but not change the vault (format.md §7.3).
        var readOnly: Bool
        var readOnlyReasons: [String]
        var recipientsAuth: RecipientsStatusOutput
    }
}

/// `recipientsAuth` in `vault info --json` and `vault verify --json`: how
/// vault.json's recipients list checked (format.md §2.1).
struct RecipientsStatusOutput: Encodable {
    /// `verified`, `untagged`, `tampered` or `not-checked` (locked).
    var status: String
    /// For `verified`: `unchanged`, `firstUse` or `rotated`.
    var verification: String?
    /// For `tampered`: `tagMismatch`, `tagRemoved`, `secretUnconfirmed`, `recordUnreadable`, or, for the
    /// version markers (format.md §2.1), `markersMismatch`, `markersRemoved` or `markersRolledBack`.
    var reason: String?
    /// True when `recipientsTag` is present in vault.json.
    var tagged: Bool
    /// True when `markersTag` (format.md §2.1 "Version markers") is present in vault.json.
    var markersTagged: Bool
    /// For `tampered`: keys not in the last verified list.
    var unexpected: [String]?
    /// For `tampered`: keys of the last verified list no longer listed.
    var missing: [String]?
    /// For `tampered`: the list `recipients repair` would write (nil: unknown, pass --keep).
    var restore: [String]?

    init(_ vault: Vault) {
        let s = vault.recipientsStatus
        status = s.name
        tagged = vault.manifest.recipientsTag != nil
        markersTagged = vault.manifest.markersTag != nil
        if case .verified(let how) = s { verification = how.rawValue }
        if let p = s.problem {
            reason = p.reason.rawValue
            unexpected = p.unexpected
            missing = p.missing
            restore = p.restore
        }
    }

    var text: String {
        switch status {
        case "verified": return "verified" + (verification == "firstUse" ? " (first use on this machine)" : "")
        case "untagged": return "not authenticated yet (an older vault; unlocking with a key tags it)"
        case "not-checked": return tagged ? "authenticated; not checked (locked; pass --identity)" : "not checked (locked)"
        default:
            if let reason, reason.hasPrefix("markers") {
                return "TAMPERED (\(reason)): vault.json's format or features were changed without the vault's key; "
                    + "writing is refused until `sempere vault markers repair`"
            }
            let keys = (unexpected ?? []).map(RecipientsProblem.abbreviate).joined(separator: ", ")
            return "TAMPERED (\(reason ?? "?")): unexpected \(keys.isEmpty ? "none" : keys); writing is refused until "
                + "`sempere vault recipients repair`"
        }
    }
}

// MARK: - recipients

struct VaultRecipients: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recipients",
        abstract: "Add, remove or replace a recipient (rewraps every file).",
        subcommands: [RecipientsAdd.self, RecipientsRemove.self, RecipientsReplace.self, RecipientsRepair.self,
                      RecipientsConfirm.self]
    )
}

private struct RewrapOutput: Encodable {
    var complete: Bool
    var rewrapped: Int
    var alreadyCurrent: Int
    var failures: [String: String]
    /// `header` or `reencrypt` (attachment blobs); nil when nothing ran.
    var blobs: String? = nil
    /// Inbox files left untouched: they verify under no capture key (format.md §3.3.1, §11).
    var inboxSkipped: [String] = []
}

private func reportRewrap(_ report: Vault.RewrapReport, output: OutputOptions) throws {
    if output.json {
        try output.emitJSON(RewrapOutput(complete: report.isComplete, rewrapped: report.rewrapped.count,
                                         alreadyCurrent: report.alreadyCurrent.count,
                                         failures: report.failures.mapValues { "\($0)" },
                                         blobs: report.blobMethod?.rawValue, inboxSkipped: report.inboxSkipped))
    } else {
        output.info("Rewrapped \(report.rewrapped.count) file(s); \(report.alreadyCurrent.count) already current.")
        if output.verbose { for f in report.rewrapped { print("  rewrapped \(f)") } }
        for f in report.inboxSkipped { printError("\(f): left as it is (cannot be decrypted or verified here: forged, or sealed with a revoked capture key)") }
    }
    guard report.isComplete else {
        for (file, why) in report.failures.sorted(by: { $0.key < $1.key }) {
            printError("\(file): \(why)")
        }
        throw CLIError.unhealthy("incomplete: \(report.failures.count) file(s) not rewrapped; fix them, then run "
            + "`sempere vault rewrap-resume`")
    }
}

struct RecipientsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add a recipient and rewrap the vault to it.")

    @Argument(help: ArgumentHelp("The new recipient's public key, or a file holding it.", valueName: "age1..."))
    var recipient: String

    @Option(name: .long, help: ArgumentHelp("A label shown in `vault info`.", valueName: "text"))
    var label: String = ""

    @OptionGroup var store: StoreKeyOptions
    @OptionGroup var rewrap: RewrapOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let key = try parseRecipient(recipient)
        try requirePostQuantum([key])
        var vault = try access.openVault(.required, migration: true)
        let stored = try store.prepare(for: key)
        let report = try vault.addRecipient(key, label: label, policy: rewrap.policy)
        try store.write(stored, into: vault, output: output)
        try reportRewrap(report, output: output)
    }
}

struct RecipientsRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a recipient, rotate the vault secret and rewrap the vault.",
        discussion: """
            Removing a key does not un-leak what it already decrypted: copies of old files stay readable to it. \
            As in the app, the key this command unlocked with is not removed unless another key it unlocked \
            with stays listed (unlock with another key, or pass --force).
            """
    )

    @Argument(help: ArgumentHelp("The recipient to remove, or a file holding it.", valueName: "age1..."))
    var recipient: String

    @Flag(name: .long, help: "Remove it even if it is the key this command unlocked with.")
    var force = false

    @OptionGroup var rewrap: RewrapOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let key = try parseRecipient(recipient)
        var vault = try access.openVault(.required, migration: true)
        let held = vault.identityRecipients
        let listed = Set(vault.recipients.map(\.key))
        if !force, held.contains(key.string), held.intersection(listed).subtracting([key.string]).isEmpty {
            throw CLIError.usage("that is the key this vault was unlocked with: unlock with another key to remove it "
                + "(or pass --force)")
        }
        try reportRewrap(try vault.removeRecipient(key, policy: rewrap.policy), output: output)
    }
}

struct RecipientsReplace: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replace",
        abstract: "Replace one recipient by a post-quantum one in a single rewrap (migrates legacy X25519 vaults).",
        discussion: """
            The post-quantum migration: `sempere keys generate --out new.key`, then
            `sempere vault recipients replace age1old... new.key` with the old key unlocking (a recipient
            argument may be a file; only its public key is read). Rotates the
            vault secret and re-encrypts every note file once, so no file ever holds both stanza types.
            If it is interrupted, finish with `rewrap-resume --identity OLD --identity NEW`: files not yet
            rewrapped open only with the old key, so keep it until `vault info` shows no pending rewrap.
            Copies of the old files (backups, file-provider version history) stay X25519-only.
            """
    )

    @Argument(help: ArgumentHelp("The recipient to replace, or a file holding it.", valueName: "age1..."))
    var old: String

    @Argument(help: ArgumentHelp("The new recipient, or a file holding it.", valueName: "age1pq1..."))
    var new: String

    @Option(name: .long, help: ArgumentHelp("A label for the new recipient (default: the old one's).",
                                            valueName: "text"))
    var label: String?

    @OptionGroup var store: StoreKeyOptions
    @OptionGroup var rewrap: RewrapOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let oldKey = try parseRecipient(old), newKey = try parseRecipient(new)
        try requirePostQuantum([newKey])
        var vault = try access.openVault(.required, migration: true)
        let stored = try store.prepare(for: newKey)
        let report = try vault.replaceRecipient(oldKey, with: newKey, label: label, policy: rewrap.policy)
        try store.write(stored, into: vault, output: output)
        try reportRewrap(report, output: output)
    }
}

struct RecipientsRepair: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Undo a device list changed without the vault's key: rewrite the last verified list and rotate.",
        discussion: """
            For a vault whose vault.json recipients do not check (format.md §2.1; other write commands exit 6).
            Writes the last verified list (this machine's trust record, or the list the tag still verifies
            with the inserted keys deleted), keeping the current labels, as a recipient removal: the vault
            secret rotates and every file is rewrapped, so nothing stays encrypted to an unexpected key.
            --keep names the keys to keep instead (required when the last verified list is unknown).
            """
    )

    @Option(name: .long, help: ArgumentHelp("A recipient to keep (repeatable), or a file holding it.", valueName: "age1pq1..."))
    var keep: [String] = []

    @Flag(name: .customLong("dry-run"), help: "Only show what the repair would write.")
    var dryRun = false

    @OptionGroup var rewrap: RewrapOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let keys = try keep.map { try parseRecipient($0).string }
        var vault = try access.openVault(.required, migration: true)
        guard let problem = vault.recipientsStatus.problem else {
            throw CLIError.failure("the device list checks (\(vault.recipientsStatus.name)); nothing to repair")
        }
        if problem.reason == .secretUnconfirmed { _ = try vault.repairRecipients() }   // throws why not
        guard let target = keys.isEmpty ? problem.restore : keys else {
            throw CLIError.failure("this machine does not know the last verified list: name the keys to keep with --keep")
        }
        if dryRun || !output.json {
            output.info("Unexpected: \(problem.unexpected.isEmpty ? "none" : problem.unexpected.map(RecipientsProblem.abbreviate).joined(separator: ", "))")
            output.info("Keeping:    \(target.map(RecipientsProblem.abbreviate).joined(separator: ", "))")
        }
        if dryRun {
            if output.json {
                struct Out: Encodable { var reason: String; var unexpected: [String]; var keep: [String] }
                try output.emitJSON(Out(reason: problem.reason.rawValue, unexpected: problem.unexpected, keep: target))
            }
            return
        }
        try reportRewrap(try vault.repairRecipients(keeping: target, policy: rewrap.policy), output: output)
    }
}

struct RecipientsConfirm: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm",
        abstract: "Trust the current device list on this machine after checking it (missed key changes).",
        discussion: """
            For a vault whose secret changed in a way this machine cannot confirm (format.md §2.1: it missed
            two or more key changes, one of which added a device). Check every listed key first: confirming a
            list an attacker wrote lets them read what this machine writes. The tag must verify; nothing in
            the vault changes. Lists whose tag does not verify can only be repaired.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required, migration: true)
        try vault.confirmRecipients()
        if output.json {
            try output.emitJSON(RecipientsStatusOutput(vault))
        } else {
            output.info("Trusted \(vault.recipients.count) recipient(s) on this machine.")
        }
    }
}

// MARK: - link

struct VaultLink: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Show or upgrade the signed secret link and this machine's trust record (format.md §2.1).",
        subcommands: [LinkStatus.self, LinkUpgrade.self],
        defaultSubcommand: LinkStatus.self
    )
}

/// `sempere vault link [status] --json`.
struct LinkStatusOutput: Encodable {
    /// vault.json's `secretLink`: `none`, `signed`, `legacy` (HMAC) or `malformed`.
    var link: String
    /// True when `features` lists `signed-secret-link`.
    var featureListed: Bool
    /// This machine's trust record: `none`, `signed` (sempere-trust/2) or `legacy` (sempere-trust/1).
    var record: String
    /// True when `sempere vault link upgrade` would change something.
    var needsUpgrade: Bool
    var recipientsAuth: RecipientsStatusOutput

    init(_ vault: Vault) {
        let s = vault.secretLinkStatus
        link = s.link.rawValue
        featureListed = s.featureListed
        record = s.record.rawValue
        needsUpgrade = s.needsUpgrade
        recipientsAuth = RecipientsStatusOutput(vault)
    }

    func printText() {
        let linkText: String
        switch link {
        case "signed": linkText = "signed (Ed25519 + ML-DSA-65)"
        case "legacy": linkText = "LEGACY (HMAC): run `sempere vault link upgrade`"
        case "malformed": linkText = "MALFORMED (never verifies): run `sempere vault link upgrade`"
        default: linkText = "none (no rotation since signed links)"
        }
        let recordText: String
        switch record {
        case "signed": recordText = "signed (public keys only)"
        case "legacy": recordText = "LEGACY (HMAC key): run `sempere vault link upgrade`"
        case "unreadable": recordText = "UNREADABLE: check the list, then `sempere vault recipients confirm`"
        default: recordText = "none on this machine"
        }
        print("Secret link:    \(linkText)")
        print("Signed links:   \(featureListed ? "yes" : "not marked (older writers may still rotate with HMAC links)")")
        print("Trust record:   \(recordText)")
        print("Device list:    \(recipientsAuth.text)")
        print("Upgrade:        \(needsUpgrade ? "needed" : "nothing to do")")
    }
}

struct LinkStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the form of vault.json's secret link and of this machine's trust record.",
        discussion: "Works without a key (the device list is then not checked)."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.ifPossible, migration: true)
        let out = LinkStatusOutput(vault)
        if output.json { try output.emitJSON(out) } else { out.printText() }
    }
}

struct LinkUpgrade: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
        abstract: "Move this machine and the vault to signed secret links (once; needs the key).",
        discussion: """
            Replaces this machine's HMAC trust record by one holding only public keys, marks the vault
            `signed-secret-link` (older Sempere versions then stop writing to it), and removes a legacy HMAC
            `secretLink` (re-signed when an unfinished rewrap still holds the outgoing secret). A device list
            that does not check is refused (exit 6): confirm or repair it first.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required, migration: true)
        let report = try vault.upgradeSecretLink()
        if output.json {
            struct Out: Encodable { var upgrade: SecretLinkUpgrade; var status: LinkStatusOutput }
            try output.emitJSON(Out(upgrade: report, status: LinkStatusOutput(vault)))
            return
        }
        guard report.changed else { output.info("Already signed; nothing to do."); return }
        if report.recordUpgraded { output.info("Trust record on this machine: now public keys only.") }
        if report.featureAdded { output.info("Vault marked signed-secret-link.") }
        switch report.link {
        case .reSigned: output.info("Legacy secret link re-signed (Ed25519 + ML-DSA-65).")
        case .retired: output.info("Legacy secret link removed.")
        case .none: break
        }
    }
}

/// `--rewrap header|reencrypt`: how attachment blobs are rewrapped
/// (format.md §8.1.5). Without it the default policy applies: header-only
/// when a key is added, full re-encryption when one is removed or replaced
/// (or the key types change).
struct RewrapOptions: ParsableArguments {
    @Option(name: .long,
            help: ArgumentHelp("How attachment blobs are rewrapped: header (keep each file key, rewrite the header) "
                + "or reencrypt (new file key).",
                discussion: "Default: header when adding a key, reencrypt when removing or replacing one. "
                    + "`header` on a removal leaves old copies of the blobs (backups, version history) able to "
                    + "open the current files with the removed key.",
                valueName: "header|reencrypt"))
    var rewrap: RewrapMethod?

    var policy: RewrapPolicy {
        guard let rewrap else { return RewrapPolicy() }
        return RewrapPolicy(onAdd: rewrap, onRemoveOrTypeChange: rewrap)
    }
}

extension RewrapMethod: ExpressibleByArgument {}

/// Refuses a classic X25519 key as a new vault recipient before anything
/// else happens (no passphrase prompt, no vault opened): vaults take only
/// post-quantum keys (format.md §3.1).
func requirePostQuantum(_ recipients: [NativeRecipient]) throws {
    if let classic = recipients.first(where: { !$0.isPostQuantum }) {
        throw VaultError.classicRecipient(classic.string)
    }
}

/// `--store-key` for `recipients add` / `replace`: also store the new
/// recipient's identity, passphrase-wrapped, in `keys/`, so the vault keeps
/// opening with a passphrase after a migration (the old key file no longer
/// opens it).
struct StoreKeyOptions: ParsableArguments {
    @Option(name: .customLong("store-key"),
            help: ArgumentHelp("Also store this identity file (the new recipient's key), passphrase-wrapped, in keys/.",
                               valueName: "file"))
    var storeKey: String?

    @Option(name: .customLong("store-passphrase-env"),
            help: ArgumentHelp("Variable holding the passphrase for --store-key.",
                               discussion: "Without it $SEMPERE_PASSPHRASE is used, else the terminal is asked.",
                               valueName: "var"))
    var passphraseEnv: String?

    @Option(name: .customLong("work-factor"),
            help: ArgumentHelp("scrypt work factor of the stored key, 15...18.", valueName: "n"))
    var workFactor = 18

    @Flag(name: .customLong("allow-weak-passphrase"),
          help: "Store the key even under a passphrase too easy to guess offline (security.md).")
    var allowWeakPassphrase = false

    func validate() throws {
        guard IdentityFile.writerWorkFactors.contains(workFactor) else {
            throw ValidationError("--work-factor must be in \(IdentityFile.writerWorkFactors)")
        }
        if passphraseEnv != nil && storeKey == nil { throw ValidationError("--store-passphrase-env needs --store-key") }
    }

    /// Reads the identity (which must be `recipient`'s) and its passphrase,
    /// before the vault changes.
    func prepare(for recipient: NativeRecipient) throws -> (NativeIdentity, String)? {
        guard let storeKey else { return nil }
        let id = try readIdentityFile(storeKey)
        guard id.recipient == recipient else {
            throw CLIError.usage("\(storeKey) is not the key of the new recipient \(RecipientsProblem.abbreviate(recipient.string))")
        }
        let pass = try obtainPassphrase(envName: passphraseEnv, prompt: "New key passphrase: ", confirm: true,
                                        asError: CLIError.failure)
        try requireStoredKeyPassphrase(pass, allowWeak: allowWeakPassphrase)
        return (id, pass)
    }

    /// Writes the key file prepared by `prepare` (replacing one for the same key).
    func write(_ stored: (NativeIdentity, String)?, into vault: Vault, output: OutputOptions) throws {
        guard let (id, pass) = stored else { return }
        let file = try vault.writeIdentityFile(id, passphrase: pass, workFactor: workFactor, replace: true)
        output.info("Stored passphrase-wrapped key: \(file.path)")
    }
}

/// A key copy in `keys/` sits on the sync storage, where its passphrase can be
/// guessed offline (security review 2026-10, stage 4, S5): refused below
/// `PassphraseStrength.storedKeyMinimumBits` unless the user says otherwise.
func requireStoredKeyPassphrase(_ passphrase: String, allowWeak: Bool) throws {
    guard !allowWeak, let why = PassphraseStrength.storedKeyProblem(passphrase) else { return }
    throw CLIError.usage(why + " (or pass --allow-weak-passphrase)")
}

struct VaultRewrapResume: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rewrap-resume",
        abstract: "Finish an interrupted recipient change.")

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required, migration: true)
        guard vault.pendingRewrap else {
            if output.json {
                try output.emitJSON(RewrapOutput(complete: true, rewrapped: 0, alreadyCurrent: 0, failures: [:]))
            } else {
                output.info("No recipient change is pending.")
            }
            return
        }
        try reportRewrap(try vault.resumeRewrap(), output: output)
    }
}

struct VaultRewrapDiscard: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rewrap-discard",
        abstract: "Delete a rewrap journal this machine refuses (planted, or put back after its change finished).",
        discussion: """
            Only a journal that was read and refused (format.md §3.3.1) is deleted: one this machine accepts \
            belongs to an unfinished change (finish it with rewrap-resume), and one it cannot read now is kept. \
            Needs the key and a device list that checks (exit 6 otherwise).
            """)

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required, migration: true)
        let why = try vault.discardRefusedJournal()
        if output.json {
            try output.emitJSON(DiscardOutput(discarded: why != nil, reason: why))
        } else if let why {
            output.info("Discarded rewrap-journal.json: \(why)")
        } else {
            output.info("No rewrap journal to discard.")
        }
    }

    private struct DiscardOutput: Encodable {
        var discarded: Bool
        var reason: String?
    }
}

// MARK: - verify

struct VaultVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check every file: decrypt, tag, decode, recipient count.",
        discussion: """
            Exit 0 only if the vault is healthy, 6 when vault.json's device list does not check (format.md §2.1), \
            3 otherwise. With -q only problem files are listed.
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
            for p in report.manifestProblems { print("MANIFEST   vault.json: \(p)") }
            print("RECIPIENTS \(RecipientsStatusOutput(vault).text)")
            if let j = report.journalProblem { print("JOURNAL    rewrap-journal.json: \(j)") }
            if report.rewrapPending { print("PENDING    a recipient change is unfinished (`sempere vault rewrap-resume`)") }
            let shown = output.quiet ? report.files.filter { $0.status != .ok } : report.files
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
        if report.recipients.problem != nil { throw ExitCode(ExitStatus.untrustedRecipients) }
        if !report.isHealthy { throw ExitCode(ExitStatus.unhealthy) }
    }

    private struct Out: Encodable {
        struct File: Encodable { var path: String; var status: String; var detail: String? }
        var healthy: Bool
        var manifestProblems: [String]
        var rewrapPending: Bool
        var journalProblem: String?
        var counts: [String: Int]
        var files: [File]
        var readOnly: Bool
        var readOnlyReasons: [String]
        var recipientsAuth: RecipientsStatusOutput

        init(_ r: VerifyReport, _ vault: Vault) {
            readOnly = vault.isReadOnly
            readOnlyReasons = vault.readOnlyReasons.descriptions
            recipientsAuth = RecipientsStatusOutput(vault)
            healthy = r.isHealthy
            manifestProblems = r.manifestProblems
            rewrapPending = r.rewrapPending
            journalProblem = r.journalProblem
            counts = Dictionary(uniqueKeysWithValues: r.counts.map { ($0.key.rawValue, $0.value) })
            files = r.files.map { File(path: $0.path, status: $0.status.rawValue, detail: $0.detail) }
        }
    }
}
