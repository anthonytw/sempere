import Age
import ArgumentParser
import Foundation
import SempereRender
import Sempere

struct KeysPaper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paper",
        abstract: "Write a printable PDF recovery kit for a key (QR code, checked text, instructions).",
        discussion: """
            The kit holds the age identity as a QR code and as text in numbered lines with a checksum
            each, the public key, the vault id and name (with --vault), and step-by-step recovery with
            stock tools (age, gunzip, jq) and with sempere. THE PRINTED SHEET IS THE KEY: store it
            offline. The PDF is written with mode 0600 and never overwrites a file; delete it once
            printed.

            --passphrase prints a passphrase-wrapped copy of the key (age scrypt, armored) instead of
            the plain key: wrapped with the passphrase of the vault's stored key file for this key (it
            is checked), else with one you choose. Only the secret key line is wrapped, so it fits a
            QR code. Such a sheet is useless without the passphrase. Kits are for post-quantum keys
            only: a classic key, or a legacy vault, is refused.

            Without --identity the key comes from the vault's stored key file (needs --vault and its
            passphrase).
            """
    )

    @Option(name: .long, help: ArgumentHelp("Where to write the PDF. Refuses to overwrite.", valueName: "file.pdf"))
    var out: String

    @Flag(name: .long, help: "Print a passphrase-wrapped copy of the key instead of the plain key.")
    var passphrase = false

    @Option(name: .customLong("work-factor"),
            help: ArgumentHelp("scrypt work factor for a new passphrase-wrapped key (15...18).", valueName: "n"))
    var workFactor = 18

    @Option(name: .long, help: ArgumentHelp("Paper size: letter or a4.", valueName: "size"))
    var paper = "letter"

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    /// Kits are printed only for post-quantum keys (format.md §3.1).
    static let classicKey = CLIError.usage(
        "that is a classic X25519 key (AGE-SECRET-KEY-1...), which is not quantum-safe: create a new key "
            + "(sempere keys generate), migrate the vault to it, and print a kit for that key")

    func validate() throws {
        guard ["letter", "a4"].contains(paper.lowercased()) else { throw ValidationError("--paper is letter or a4") }
        guard IdentityFile.writerWorkFactors.contains(workFactor) else {
            throw ValidationError("--work-factor must be between 15 and 18")
        }
    }

    func run() throws {
        let explicit = try access.explicitIdentities()
        guard explicit.count <= 1 else { throw CLIError.usage("give one --identity for a recovery kit") }
        let hasVault = access.vault != nil || !(Env.vars["SEMPERE_VAULT"] ?? "").isEmpty
        let locked = hasVault ? try Vault.open(at: try access.vaultURL()) : nil
        try locked?.requireMigrated()   // a legacy vault: migrate first (exit 5)
        if let classic = explicit.first, !classic.isPostQuantum { throw Self.classicKey }

        var identity = explicit.first
        let secret: RecoveryKit.Secret
        if passphrase {
            let stored = try locked?.identityFiles() ?? []
            // The element type is inferred: X25519 recipients today, any recipient
            // type the vault accepts (post-quantum) without a change here.
            let source = identity.flatMap { id in stored.first { $0 == id.recipient } }
                ?? (identity == nil ? stored.first : nil)
            if identity == nil, stored.count != 1 {
                throw CLIError.usage(stored.isEmpty
                    ? "no key: pass --identity FILE (or --vault V holding a stored key file)"
                    : "the vault holds several key files; choose one with --identity")
            }
            let pass = try obtainPassphrase(
                envName: access.passphraseEnv,
                prompt: source != nil ? "Passphrase of the vault's key file: " : "New passphrase for the kit: ",
                confirm: source == nil, asError: source == nil ? CLIError.usage : CLIError.cannotDecrypt)
            if let source, let locked {
                let opened = try locked.readIdentityFile(recipient: source, passphrase: pass)
                if identity == nil { identity = opened }
            } else if identity != nil {
                guard !pass.isEmpty else { throw CLIError.usage("the passphrase is empty") }
            } else {
                throw CLIError.usage("no key: pass --identity FILE")
            }
            guard let key = identity else { throw CLIError.usage("no key: pass --identity FILE") }
            // Only the secret key line is wrapped, never the vault's key file as
            // it is: that file also holds the public key, which for a
            // post-quantum key is 1959 characters and fits no QR code (the
            // public key is derived from the secret key, `age-keygen -y`).
            let text = "# Sempere recovery kit\n\(key.string)\n"
            let wrapped = try AgeFile.encrypt(Data(text.utf8), to: [ScryptRecipient(passphrase: pass,
                                                                                 workFactor: workFactor)])
            let armored = Armor.isArmored(wrapped) ? wrapped : Armor.encode(wrapped)
            // The sheet must open with this passphrase to this key, or it is worthless.
            let check = try AgeFile.decrypt(armored, with: [ScryptIdentity(passphrase: pass)])
            guard let identity, try IdentityFile.parse(String(decoding: check, as: UTF8.self)).recipient
                    == identity.recipient else {
                throw CLIError.failure("the passphrase-wrapped key does not open to this key")
            }
            secret = .passphraseWrapped(String(decoding: armored, as: UTF8.self))
        } else {
            if identity == nil, let locked { identity = try access.identityFromKeyFiles(of: locked) }
            guard let identity else {
                throw CLIError.cannotDecrypt("no key: pass --identity FILE (or --vault V holding a stored key file)")
            }
            secret = .identity(identity.string)
        }
        guard let identity else { throw CLIError.cannotDecrypt("no key") }
        guard identity.isPostQuantum else { throw Self.classicKey }

        var info: RecoveryKit.VaultInfo?
        if let locked {
            guard locked.recipients.contains(where: { $0.key == identity.recipient.string }) else {
                throw CLIError.cannotDecrypt("this key is not a recipient of the vault (\(RecipientsProblem.abbreviate(identity.recipient.string)))")
            }
            var name = locked.url.lastPathComponent
            if name.hasSuffix(".sempere") { name.removeLast(".sempere".count) }
            info = .init(vault: locked, name: name)
        }
        var kit = RecoveryKit(secret: secret, recipient: identity.recipient.string, vault: info, printed: Date())
        if paper.lowercased() == "a4" { kit.useA4() }
        let code = try kit.qrCode()
        try writeNewSecretFile(try kit.pdf(), to: out)

        let variant = passphrase ? "passphrase" : "plain"
        if output.json {
            struct Out: Encodable {
                var path: String; var variant: String; var publicKey: String; var vaultId: String?
                var qrVersion: Int; var qrErrorCorrection: String; var lines: Int
            }
            try output.emitJSON(Out(path: out, variant: variant, publicKey: identity.recipient.string,
                                    vaultId: info?.id, qrVersion: code.version,
                                    qrErrorCorrection: code.errorCorrection == .quartile ? "Q" : "M",
                                    lines: kit.lines.count))
        } else {
            output.info("Wrote \(out) (2 pages, \(variant) key; QR version \(code.version), "
                        + "\(kit.lines.count) checked lines)")
            if !passphrase && !output.quiet {
                printStderr("The PDF holds your secret key: print it, then delete the file (it is not encrypted).")
            }
        }
    }
}
