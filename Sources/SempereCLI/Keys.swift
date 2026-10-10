import Age
import ArgumentParser
import Foundation
import Sempere

struct KeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Generate, show and export age identities, and print recovery kits.",
        subcommands: [KeysGenerate.self, KeysShow.self, KeysExport.self, KeysPaper.self]
    )
}

private struct PublicKeyOutput: Encodable {
    var publicKey: String
    var path: String?
}

struct KeysGenerate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Create a new age identity file (mode 0600) and print its public key.",
        discussion: """
            Without --out the identity is written to standard output and the public key to standard error.
            The key is post-quantum, MLKEM768-X25519 (AGE-SECRET-KEY-PQ-1..., recipient age1pq1...), as
            `age-keygen -pq` makes; vaults take no other kind. Reading its files with the stock CLI needs
            age 1.3 or later.
            """
    )

    @Option(name: .long, help: ArgumentHelp("Where to write the identity. Refuses to overwrite.", valueName: "file"))
    var out: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        let identity: NativeIdentity
        do { identity = try NativeIdentity.generate(.postQuantum) } catch {
            throw CLIError.failure("\(error)")
        }
        let text = IdentityFile.render(identity, created: Date())
        let key = identity.recipient.string
        guard let out else {
            print(text, terminator: "")
            printStderr("Public key: \(key)")
            return
        }
        try writeNewSecretFile(text, to: out)
        if output.json {
            try output.emitJSON(PublicKeyOutput(publicKey: key, path: out))
        } else if output.quiet {
            print(key)
        } else {
            print("Wrote \(out)\nPublic key: \(key)")
        }
    }
}

struct KeysShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the public key (age1... or age1pq1...) of an identity file."
    )

    @Argument(help: ArgumentHelp("The identity file.", valueName: "file"))
    var file: String

    @OptionGroup var output: OutputOptions

    func run() throws {
        let key = try readIdentityFile(file).recipient.string
        if output.json { try output.emitJSON(PublicKeyOutput(publicKey: key, path: file)) } else { print(key) }
    }
}

struct KeysExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Decrypt the vault's passphrase-wrapped key file to an identity file.",
        discussion: """
            Moves a key to another device: the passphrase unlocks keys/<recipient>.key.age and the
            plain identity is written to --out (mode 0600) or standard output. This is one of the
            two commands that print a secret key.
            """
    )

    @OptionGroup var access: AccessOptions

    @Option(name: .long, help: ArgumentHelp("Which key file to export (default: the only one).", valueName: "age1..."))
    var recipient: String?

    @Option(name: .long, help: ArgumentHelp("Where to write the identity. Refuses to overwrite.", valueName: "file"))
    var out: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        let locked = try Vault.open(at: try access.vaultURL())
        try locked.requireMigrated()
        var wanted: NativeRecipient?
        if let recipient {
            wanted = try parseRecipient(recipient)
        } else if try locked.identityFiles().count > 1 {
            throw CLIError.usage("the vault holds several key files; choose one with --recipient")
        }
        let identity = try access.identitiesFromKeyFiles(of: locked, recipient: wanted)[0]
        let text = IdentityFile.render(identity, created: Date())
        guard let out else {
            print(text, terminator: "")
            return
        }
        try writeNewSecretFile(text, to: out)
        if output.json {
            try output.emitJSON(PublicKeyOutput(publicKey: identity.recipient.string, path: out))
        } else {
            output.info("Wrote \(out)\nPublic key: \(identity.recipient.string)")
        }
    }
}
