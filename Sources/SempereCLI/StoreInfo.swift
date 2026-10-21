import ArgumentParser
import Foundation
import Sempere
import SempereSync

/// `sempere store info`: a store vault's storage and targets, each with its devices and quarantine
/// (docs/design/device-first-sync.md §8.3, §8.4), what the app's Vault Details and Settings ▸ Storage show.
struct StoreInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show a store vault's storage, sync targets, devices per target and quarantine.",
        discussion: """
            Read from this device only, never from a target: the vault folder's sizes (notes, attachments, other \
            files), and per target its last sync, the files both sides had then, the devices whose revisions or \
            summaries the target held then (a device missing from a target never syncs with it), the files \
            quarantined and the files staged for the next unlock. --measure-folders also measures each folder \
            target's copy (slow for a folder in a provider).

            --json: {vault, name, storage: {notes, attachments, other, total}, targets: [{target, syncedFiles, \
            devices: [{device, revisions, newest, publishesSummaries, isThisDevice}], quarantined: [{path, \
            vaultPath, size, quarantined, adoptable}], staged, stateBytes, folderBytes, folderNotDownloaded}]}.
            """
    )

    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @Flag(name: .customLong("measure-folders"), help: "Also measure each folder target's copy.")
    var measureFolders = false

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    struct Info: Encodable {
        var vault: String
        var name: String
        var storage: VaultStorage
        var targets: [TargetDetails]
    }

    func run() throws {
        let store = location.open()
        let entry = try store.resolve(vault)
        let info = Info(vault: entry.vaultId.uuidString.lowercased(), name: entry.name,
                        storage: TargetInspection.storage(of: entry.url),
                        targets: try store.targetDetails(entry, thisDevice: SyncCLI.deviceID(), measureFolders: measureFolders))
        if output.json { return try output.emitJSON(info) }
        let s = info.storage
        print("\(entry.name) (\(info.vault))")
        print("  on this device: \(Format.bytes(Int(s.total))) (notes \(Format.bytes(Int(s.notes))), "
              + "attachments \(Format.bytes(Int(s.attachments))), other \(Format.bytes(Int(s.other))))")
        if info.targets.isEmpty { print("  no sync targets: this device holds the only copy") }
        for d in info.targets {
            let t = d.target
            print("")
            print("  \(t.kind.rawValue) \(t.name): \(t.path ?? t.url ?? "")")
            print("    last sync: \(t.lastSuccess.map(Format.utc) ?? "never"); \(d.syncedFiles) files in step; "
                  + "sync state \(Format.bytes(Int(d.stateBytes)))" + (d.folderBytes.map { "; folder \(Format.bytes(Int($0)))" } ?? "")
                  + ((d.folderNotDownloaded ?? 0) > 0 ? " (\(d.folderNotDownloaded ?? 0) files not downloaded)" : ""))
            if d.staged > 0 { print("    staged for the next unlock: \(d.staged) files") }
            if !d.quarantined.isEmpty { print("    quarantined: \(d.quarantined.count) files (sempere store quarantine list)") }
            var rows = [["DEVICE", "REVISIONS", "NEWEST", "SUMMARIES"]]
            for dev in d.devices {
                rows.append([dev.device + (dev.isThisDevice ? " (this device)" : ""), "\(dev.revisions)",
                             dev.newest.map(Format.utc) ?? "-", dev.publishesSummaries ? "yes" : "no"])
            }
            if d.devices.isEmpty {
                print("    devices: none known yet (not synced)")
            } else {
                print(Format.table(rows).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
            }
        }
    }
}

/// `sempere store quarantine`: the files sync runs refused (format.md §9.1), per target.
struct StoreQuarantineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quarantine",
        abstract: "List, adopt, export or delete a store vault's quarantined files.",
        discussion: """
            A sync run never places a file that fails its checks: it keeps it in the target's quarantine \
            (<store>/.sync/<vault id>/<target id>/sync-state.quarantine/) and never removes it. A file leaves \
            only by adopt (checked again under the vault's current keys, and placed only if it passes: one that \
            arrived before a key change reached this device, say), export (a copy elsewhere; it stays) or \
            delete. Root files (vault.json, settings) cannot be adopted: they arrive only through a sync run.
            """,
        subcommands: [StoreQuarantineList.self, StoreQuarantineAdopt.self, StoreQuarantineExport.self,
                      StoreQuarantineDelete.self]
    )
}

/// The vault, an optional `--target`, and the files.
struct QuarantineSelection: ParsableArguments {
    @Argument(help: ArgumentHelp("The vault: id, id prefix or name.", valueName: "vault"))
    var vault: String

    @Option(name: .long, help: ArgumentHelp("Only this target (id, id prefix, name, path or URL).", valueName: "target"))
    var target: String?

    @OptionGroup var location: StoreOptions

    /// The store, the vault and the quarantines chosen.
    func open() throws -> (VaultStore, VaultStore.Entry, [(SyncTarget, TargetQuarantine)]) {
        let store = location.open()
        let entry = try store.resolve(vault)
        let targets = try target.map { [try store.targets.resolve($0, of: entry.vaultId)] } ?? store.targets.load(entry.vaultId)
        return (store, entry, targets.map { ($0, store.quarantine($0.id, of: entry.vaultId)) })
    }

    /// The quarantine holding `path` (with --target, only that one).
    func find(_ path: String, in quarantines: [(SyncTarget, TargetQuarantine)]) throws -> (SyncTarget, TargetQuarantine) {
        let holding = quarantines.filter { (try? $0.1.file(path)) != nil }
        guard let first = holding.first else { throw CLIError.usage("\(path) is not in the quarantine (sempere store quarantine list)") }
        guard holding.count == 1 else { throw CLIError.usage("\(path) is quarantined by several targets: pick one with --target") }
        return first
    }
}

struct QuarantineRow: Encodable {
    var target: String
    var file: QuarantinedFile
}

struct StoreQuarantineList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a store vault's quarantined files.",
        discussion: "--json: an array of {target, file: {path, vaultPath, size, quarantined, adoptable}}."
    )

    @OptionGroup var selection: QuarantineSelection
    @OptionGroup var output: OutputOptions

    func run() throws {
        let (_, entry, quarantines) = try selection.open()
        let rows = quarantines.flatMap { t, q in q.list().map { QuarantineRow(target: t.id.uuidString.lowercased(), file: $0) } }
        if output.json { return try output.emitJSON(rows) }
        guard !rows.isEmpty else { return output.info("\(entry.name) has no quarantined files") }
        var table = [["TARGET", "PATH", "SIZE", "QUARANTINED", "ADOPTABLE"]]
        for r in rows {
            table.append([String(r.target.prefix(8)), r.file.path, Format.bytes(Int(r.file.size)),
                          r.file.quarantined.map(Format.utc) ?? "-", r.file.adoptable ? "yes" : "no"])
        }
        print(Format.table(table))
    }
}

struct StoreQuarantineAdopt: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Check quarantined files again under the vault's keys and place the ones that pass.",
        discussion: """
            Needs the key. A file that passes is placed in the vault and leaves the quarantine; one the vault \
            already holds with the same bytes just leaves it. One that still fails, or a root file, stays \
            (exit 1, the reason printed). --json: an array of {path, adopted, error}.
            """
    )

    @OptionGroup var selection: QuarantineSelection

    @Argument(help: ArgumentHelp("Quarantined files, as `list` prints them.", valueName: "path"))
    var paths: [String]

    @Option(name: .long, help: ArgumentHelp("An age identity file (age-keygen style). Repeatable.",
                                            discussion: "Default: $SEMPERE_IDENTITY.", valueName: "file"))
    var identity: [String] = []

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Name of the environment variable holding the passphrase of the vault's key file.",
                               valueName: "var"))
    var passphraseEnv: String?

    @OptionGroup var output: OutputOptions

    struct Outcome: Encodable {
        var path: String
        var adopted: Bool
        var error: String?
    }

    func run() throws {
        let (store, entry, quarantines) = try selection.open()
        var access = AccessOptions()
        access.vault = entry.url.path
        access.identity = identity
        access.passphraseEnv = passphraseEnv
        // Every option of a hand-made OptionGroup is set: reading an unset one traps.
        access.recoveryKey = nil
        access.root = nil
        let vault = try access.openVault(.required)
        let lease = try store.lease(entry.vaultId)
        defer { lease.release() }
        var outcomes: [Outcome] = []
        for path in paths {
            do {
                let (_, q) = try selection.find(path, in: quarantines)
                try q.adopt(path, vaultFolder: entry.url, vault: vault, writeLock: store.writeLock(for: entry.vaultId))
                outcomes.append(Outcome(path: path, adopted: true))
            } catch {
                outcomes.append(Outcome(path: path, adopted: false, error: String(describing: error)))
            }
        }
        if output.json { try output.emitJSON(outcomes) } else {
            for o in outcomes {
                if let error = o.error { printError("\(o.path): not adopted: \(error)") } else { output.info("\(o.path): adopted") }
            }
        }
        if outcomes.contains(where: { !$0.adopted }) { throw ExitCode(1) }
    }
}

struct StoreQuarantineExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Copy quarantined files to a folder; they stay in the quarantine.",
        discussion: "Never over a file there: a taken name gets \" 2\", \" 3\"… --json: an array of {path, copy}."
    )

    @OptionGroup var selection: QuarantineSelection

    @Argument(help: ArgumentHelp("Quarantined files, as `list` prints them.", valueName: "path"))
    var paths: [String]

    @Option(name: .long, help: ArgumentHelp("The folder to copy them to.", valueName: "dir"))
    var to: String

    @OptionGroup var output: OutputOptions

    struct Outcome: Encodable {
        var path: String
        var copy: String
    }

    func run() throws {
        let (_, _, quarantines) = try selection.open()
        let folder = URL(fileURLWithPath: to, isDirectory: true)
        var outcomes: [Outcome] = []
        for path in paths {
            let (_, q) = try selection.find(path, in: quarantines)
            outcomes.append(Outcome(path: path, copy: try q.export(path, to: folder).path))
        }
        if output.json { return try output.emitJSON(outcomes) }
        for o in outcomes { output.info("\(o.path) → \(o.copy)") }
    }
}

struct StoreQuarantineDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete quarantined files.",
        discussion: "They are gone for good: export first to keep a copy. A sync run never deletes them."
    )

    @OptionGroup var selection: QuarantineSelection

    @Argument(help: ArgumentHelp("Quarantined files, as `list` prints them.", valueName: "path"))
    var paths: [String]

    @OptionGroup var output: OutputOptions

    func run() throws {
        let (_, _, quarantines) = try selection.open()
        for path in paths {
            let (_, q) = try selection.find(path, in: quarantines)
            try q.delete(path)
            output.info("\(path): deleted")
        }
    }
}
