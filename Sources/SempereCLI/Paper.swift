import Age
import ArgumentParser
import Foundation
import SempereRender
import Sempere

struct KeysPaper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paper",
        abstract: "Write a printable PDF recovery kit for a vault's recovery key (QR codes, checked text, instructions).",
        discussion: """
            The kit holds the recovery key (--identity, the file `sempere vault init --recovery-out` wrote) as
            a QR code and as text in numbered lines with a checksum each, the vault id and name and its root
            fingerprint (with --vault: 16 checked groups and a second QR code), and recovery with stock tools
            (the frozen script of format.md §15.13) and with sempere. THE PRINTED SHEET IS THE KEY: store it
            offline. No device keeps the recovery key, so the kit cannot be printed again later. The PDF is
            written with mode 0600 and never overwrites a file; delete it, and the key file, once printed.

            --passphrase prints a passphrase-wrapped copy of the key (age scrypt, armored) instead of the
            plain key, wrapped with a passphrase you choose. Only the secret key line is wrapped, so it fits
            a QR code. Such a sheet is useless without the passphrase. Kits are for post-quantum keys only.
            """
    )

    @Option(name: .long, help: ArgumentHelp("Where to write the PDF. Refuses to overwrite.", valueName: "file.pdf"))
    var out: String

    @Flag(name: .long, help: "Print a passphrase-wrapped copy of the key instead of the plain key.")
    var passphrase = false

    @Option(name: .customLong("work-factor"),
            help: ArgumentHelp("scrypt work factor for the passphrase-wrapped key (15...20).", valueName: "n"))
    var workFactor = 18

    @Option(name: .long, help: ArgumentHelp("Paper size: letter or a4.", valueName: "size"))
    var paper = "letter"

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    /// Kits are printed only for post-quantum keys (format.md §3.1).
    static let classicKey = CLIError.usage(
        "that is a classic X25519 key (AGE-SECRET-KEY-1...), which is not quantum-safe: create a new key "
            + "(sempere keys generate) and print a kit for that key")

    func validate() throws {
        guard ["letter", "a4"].contains(paper.lowercased()) else { throw ValidationError("--paper is letter or a4") }
        guard (15...RecoveryPassphraseCopy.workFactor).contains(workFactor) else {
            throw ValidationError("--work-factor must be between 15 and \(RecoveryPassphraseCopy.workFactor)")
        }
    }

    func run() throws {
        let explicit = try access.explicitIdentities()
        guard explicit.count == 1, let identity = explicit.first else {
            throw CLIError.usage("give the recovery key with one --identity FILE (no device keeps it)")
        }
        guard identity.isPostQuantum else { throw Self.classicKey }
        let hasVault = access.vault != nil || !(Env.vars["SEMPERE_VAULT"] ?? "").isEmpty
        let locked = hasVault ? try Vault.open(at: try access.vaultURL()) : nil
        let secret: RecoveryKit.Secret
        if passphrase {
            let pass = try obtainPassphrase(envName: access.passphraseEnv, prompt: "New passphrase for the kit: ",
                                            confirm: true, asError: CLIError.usage)
            // Only the secret key line is wrapped: the public key is 1959 characters and fits no QR code
            // (it is derived from the secret key, `age-keygen -y`).
            let text = "# Sempere recovery kit\n\(identity.string)\n"
            let wrapped = try AgeFile.encrypt(Data(text.utf8), to: [ScryptRecipient(passphrase: pass, workFactor: workFactor)])
            let armored = Armor.isArmored(wrapped) ? wrapped : Armor.encode(wrapped)
            // The sheet must open with this passphrase to this key, or it is worthless.
            let check = try AgeFile.decrypt(armored, with: [ScryptIdentity(passphrase: pass)])
            guard try IdentityFile.parse(String(decoding: check, as: UTF8.self)).recipient == identity.recipient else {
                throw CLIError.failure("the passphrase-wrapped key does not open to this key")
            }
            secret = .passphraseWrapped(String(decoding: armored, as: UTF8.self))
        } else {
            secret = .identity(identity.string)
        }

        var info: RecoveryKit.VaultInfo?
        if let locked {
            guard locked.manifest.recoveryEntry?.key == identity.recipient.string else {
                throw CLIError.cannotDecrypt("this key is not the vault's recovery key (\(ListProblem.abbreviate(identity.recipient.string)))")
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
