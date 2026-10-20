import ArgumentParser
import Foundation
import Sempere

/// `sempere store`: the vaults kept in a store folder (`VaultStore`), as the app keeps its own
/// (docs/design/device-first-sync.md §2; docs/cli.md "Vault store").
struct StoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store",
        abstract: "List, create, copy in and remove the vaults of a vault store.",
        discussion: """
            A store is a folder of complete vaults, one per vault id: <store>/<vault id>/<name>.sempere. The app \
            keeps every vault in its own store, inside its container; on a Mac that is ~/Library/Containers/\
            io.github.anthonytw.sempere/Data/Library/Application Support/Sempere/Vaults. A vault appears in a \
            store only complete: it is built or copied in a staging folder, checked, and moved into place at \
            once. Any other command works on a store vault through --vault "$(sempere store path NAME)".
            """,
        subcommands: [StoreList.self, StorePath.self, StoreCreate.self, StoreImport.self, StoreRemove.self]
    )
}

/// `--store`.
struct StoreOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp(
        "The store folder.",
        discussion: "Default: $SEMPERE_STORE, else $XDG_DATA_HOME/sempere/vaults (~/.local/share/sempere/vaults).",
        valueName: "dir"))
    var store: String?

    /// The store this invocation names.
    func open() -> VaultStore {
        if let store, !store.isEmpty { return VaultStore(root: URL(fileURLWithPath: store, isDirectory: true)) }
        if let env = Env.vars["SEMPERE_STORE"], !env.isEmpty {
            return VaultStore(root: URL(fileURLWithPath: env, isDirectory: true))
        }
        let data = Env.vars["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? NSHomeDirectory() + "/.local/share"
        return VaultStore(root: URL(fileURLWithPath: data, isDirectory: true)
            .appendingPathComponent("sempere/vaults", isDirectory: true))
    }
}

struct StoreList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the store's vaults (name, id, label, path).",
        discussion: "Reads only each vault.json (no key). --json: an array of {vaultId, name, path, label, problem}."
    )

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let entries = location.open().list()
        if output.json { return try output.emitJSON(entries) }
        guard !entries.isEmpty else { return output.info("No vaults in \(location.open().root.path)") }
        var rows = [["NAME", "ID", "LABEL", "PATH"]]
        for e in entries {
            rows.append([e.name, e.vaultId.uuidString.lowercased(), e.label ?? "", e.url.path])
        }
        print(Format.table(rows))
        for e in entries where e.problem != nil {
            printError("warning: \(e.name) (\(e.vaultId.uuidString.lowercased())): \(e.problem ?? "")")
        }
    }
}

struct StorePath: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the folder of a store vault, for --vault.",
        discussion: "VAULT is the vault id, a unique prefix of it (4 characters or more), or the vault's exact name."
    )

    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let entry = try location.open().resolve(vault)
        if output.json { return try output.emitJSON(entry) }
        print(entry.url.path)
    }
}

struct StoreCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new vault in the store.",
        discussion: "Takes vault init's options. " + VaultInitOptions.discussion
    )

    @Argument(help: ArgumentHelp("The vault's name (its folder is NAME.sempere).", valueName: "name"))
    var name: String

    @OptionGroup var spec: VaultInitOptions
    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        do { _ = try VaultStore.folderName(for: name) } catch { throw ValidationError("\(error)") }
    }

    func run() throws {
        let prepared = try spec.prepare()
        let (entry, created) = try location.open().create(name: name) { url -> (VaultInitOptions.Created, String?) in
            let created = try spec.create(at: url, prepared: prepared)
            // The key file's place inside the vault: the vault moves into the store afterwards.
            let relative = created.keyFile.map { String($0.dropFirst(url.path.count)) }
            return (created, relative)
        }
        try created.0.report(path: entry.url.path, output: output, keyFile: created.1.map { entry.url.path + $0 })
    }
}

struct StoreImport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Copy a vault folder into the store (the source is never written).",
        discussion: """
            The source must be a complete vault: a readable vault.json, no partial-copy markers (format.md §1.2), no \
            cloud placeholders (download it first), only folders and regular files (no symbolic links). Hidden files \
            are not copied. Every file is copied, read back and compared byte for byte with the source, and the source \
            is listed again, before the vault appears in the store; a failure leaves nothing there. A vault id the \
            store already holds is refused. No key is needed.
            """
    )

    @Argument(help: ArgumentHelp("The vault folder to copy in.", valueName: "source"))
    var source: String

    @Option(name: .long, help: ArgumentHelp("The vault's name in the store (default: the source folder's).",
                                            valueName: "name"))
    var name: String?

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let name {
            do { _ = try VaultStore.folderName(for: name) } catch { throw ValidationError("\(error)") }
        }
    }

    func run() throws {
        let verbose = output.verbose && !output.json && !output.quiet
        var options = VaultStore.ImportOptions(name: name)
        if verbose {
            options.progress = { (done: Int, total: Int) in
                if done == total || done % 100 == 0 { printStderr("copied \(done) of \(total) files") }
            }
        }
        let entry = try location.open().importVault(from: URL(fileURLWithPath: source, isDirectory: true), options: options)
        if output.json { return try output.emitJSON(entry) }
        output.info("Copied into the store as “\(entry.name)” (\(entry.vaultId.uuidString.lowercased()))")
        if output.quiet { print(entry.url.path) } else { output.info("Path: \(entry.url.path)") }
    }
}

struct StoreRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete a vault from the store, permanently.",
        discussion: """
            This deletes the store's copy of the vault: when it is the only copy, its notes are gone. Needs --yes. \
            Refused while the vault is open (in the app, or by another command).
            """
    )

    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @Flag(name: .long, help: "Confirm the deletion.")
    var yes = false

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let store = location.open()
        let entry = try store.resolve(vault)
        guard yes else {
            throw CLIError.usage("this deletes “\(entry.name)” (\(entry.vaultId.uuidString.lowercased())) from the store "
                + "permanently; pass --yes")
        }
        try store.remove(entry.vaultId)
        if output.json { return try output.emitJSON(entry) }
        output.info("Removed “\(entry.name)” (\(entry.vaultId.uuidString.lowercased()))")
    }
}
