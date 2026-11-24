import ArgumentParser
import Foundation
import Sempere
import SempereSync
#if canImport(SempereCloudKit)
import SempereCloudKit
#endif

/// The CloudKit side of the store commands (docs/design/1.4-cloudkit.md §6.5). The adapter (`SempereCloudKit`) is linked
/// on macOS only, and works only in a build signed for the iCloud container: a Homebrew install carries the signed bundle
/// `sempere.app`; a source build (`swift build`) has no provisioning profile and says so here, before CloudKit is touched
/// (which would raise an exception in an unsigned process).
enum CloudKitCLI {
    /// Why CloudKit cannot be used here, in words for the person running the command; nil when it can.
    static var unavailable: String? {
        #if canImport(SempereCloudKit)
        if CloudKitDatabase.availability() != .available {
            return "iCloud (CloudKit) is not available in this build of sempere: it is not signed for the iCloud container "
                + "(a source build has no provisioning profile). Use the released sempere (the Homebrew install carries "
                + "the signed sempere.app), or sync this vault through a folder or WebDAV target."
        }
        return nil
        #else
        return "iCloud (CloudKit) is only available in sempere for macOS (the released, signed build); this build has no CloudKit."
        #endif
    }

    /// The signed-in account, for a new target: its hash, or a sentence saying what to do.
    static func accountHash() throws -> String? {
        if let unavailable { throw CLIError.failure(unavailable) }
        #if canImport(SempereCloudKit)
        let account = try CloudKitDatabase().account()
        switch account.status {
        case .available: return account.userHash
        case .noAccount: throw CLIError.failure("Sign in to iCloud in System Settings first, then add the target.")
        case .restricted, .managedAccountRestricted:
            throw CLIError.failure("iCloud is restricted on this Mac (Screen Time or device management).")
        case .temporarilyUnavailable, .couldNotDetermine:
            throw CLIError.failure("iCloud is not answering right now. Try again in a moment.")
        }
        #else
        return nil
        #endif
    }

    /// The remote of a CloudKit target: the vault's zone, the mirror in the target's state folder.
    static func remote(_ t: SyncTarget, vaultId: UUID, stateDirectory: URL) throws -> CloudRecordRemote {
        if let unavailable { throw CLIError.failure(unavailable) }
        #if canImport(SempereCloudKit)
        return CloudTargetRun.remote(store: CloudKitDatabase(), vaultId: vaultId, stateURL: stateDirectory.appendingPathComponent("sync-state.json"),
                                     expectedUser: t.cloudUser)
        #else
        throw CLIError.failure(unavailable ?? "iCloud (CloudKit) is not available")
        #endif
    }
}

// MARK: - `sempere cloudkit`: the vaults in the account's iCloud (docs/design/1.4-cloudkit.md §8, §9)

struct CloudKitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cloudkit",
        abstract: "Find, open and delete the vaults in your iCloud (CloudKit) account.",
        discussion: """
            What the app's Open Vault ▸ From iCloud, its suggestion on another device and Delete from iCloud do. macOS only, \
            in the released sempere (signed for the iCloud container; a source build says so and exits 1). A vault's target \
            is added and run with `sempere store target add --cloudkit` and `sempere store sync`.
            """,
        subcommands: [CloudKitList.self, CloudKitOpen.self, CloudKitDelete.self]
    )
}

struct CloudKitList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the vaults the signed-in Apple Account's iCloud holds.",
        discussion: """
            One request for the zones and one for each vault's vault.json label; nothing is downloaded. A vault that is in \
            this store already says so. --json: an array of {vaultId, zone, name, named, inStore, hasCloudKitTarget}. \
            Exit codes: 0, 1 when CloudKit cannot be used here or the account cannot be reached.
            """
    )

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    struct Row: Encodable {
        var vaultId: String
        var zone: String
        var name: String
        var named: Bool
        var inStore: Bool
        var hasCloudKitTarget: Bool
    }

    func run() throws {
        #if canImport(SempereCloudKit)
        _ = try CloudKitCLI.accountHash()
        let store = location.open()
        let rows = try CloudVaults.list(store: CloudKitDatabase()).map { v -> Row in
            let id = UUID(uuidString: v.vaultId)
            let here = id.flatMap { store.entry(id: $0) } != nil
            let target = id.map { store.targets.targets(of: $0).contains { $0.kind == .cloudkit } } ?? false
            return Row(vaultId: v.vaultId, zone: v.zone, name: v.name, named: v.named, inStore: here, hasCloudKitTarget: target)
        }
        if output.json { return try output.emitJSON(rows) }
        if rows.isEmpty { return output.info("No vaults in this iCloud account") }
        var table = [["ID", "NAME", "IN STORE"]]
        for r in rows { table.append([r.vaultId, r.name, r.inStore ? (r.hasCloudKitTarget ? "synced" : "yes") : "no"]) }
        print(Format.table(table))
        #else
        throw CLIError.failure(CloudKitCLI.unavailable ?? "iCloud (CloudKit) is not available")
        #endif
    }
}

struct CloudKitOpen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Copy a vault from your iCloud into the store and sync it with iCloud.",
        discussion: """
            VAULT is a vault id (or a unique id prefix) from `sempere cloudkit list`. The vault is downloaded whole into a \
            temporary folder, checked and copied into the store as a vault of its own (no key is needed), and gets an iCloud \
            target whose first sync finds nothing to do. A vault the store holds already just gets the target (if it has none). \
            Join this device afterwards (`sempere keys` / `sempere device`) to read it. Exit codes: 0, 1 on any failure \
            (nothing is left in the store).
            """
    )

    @Argument(help: ArgumentHelp("The vault's id or a unique id prefix.", valueName: "vault"))
    var vault: String

    @Option(name: .long, help: ArgumentHelp("The vault's name in the store (default: its label).", valueName: "name"))
    var name: String?

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        #if canImport(SempereCloudKit)
        let user = try CloudKitCLI.accountHash()
        let db = CloudKitDatabase()
        let listed = try CloudVaults.list(store: db).filter { $0.vaultId.hasPrefix(vault.lowercased()) }
        guard let found = listed.first else { throw CLIError.failure("no vault in this iCloud account matches “\(vault)”") }
        guard listed.count == 1 else { throw CLIError.usage("“\(vault)” matches \(listed.count) vaults; give more of the id") }
        let id = UUID(uuidString: found.vaultId) ?? UUID()
        let store = location.open()
        let entry: VaultStore.Entry
        if let existing = store.entry(id: id) {
            entry = existing
        } else {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-icloud-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let folder = work.appendingPathComponent("vault.sempere", isDirectory: true)
            let options = SyncOptions(deviceLabel: "cli")
            let report = try CloudVaults.download(vaultId: id, store: db, into: folder,
                                                  stateURL: work.appendingPathComponent("state/sync-state.json"), expectedUser: user, options: options)
            guard report.errors.isEmpty, report.stoppedEarly == nil else {
                throw CLIError.failure("the download did not finish: \(report.errors.first.map { "\($0.path): \($0.message)" } ?? "stopped early")")
            }
            entry = try store.importVault(from: folder, options: VaultStore.ImportOptions(name: name ?? (found.named ? found.name : nil)))
        }
        if !store.targets.targets(of: entry.vaultId).contains(where: { $0.kind == .cloudkit }) {
            try store.targets.add(.cloudkit(user: user, name: "iCloud"), to: entry.vaultId)
        }
        if output.json { return try output.emitJSON(entry) }
        output.info("Copied into the store as “\(entry.name)” (\(entry.vaultId.uuidString.lowercased())) and synced with iCloud")
        if output.quiet { print(entry.url.path) } else { output.info("Path: \(entry.url.path)") }
        #else
        throw CLIError.failure(CloudKitCLI.unavailable ?? "iCloud (CloudKit) is not available")
        #endif
    }
}

struct CloudKitDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a vault's data from your iCloud (its zone), and this store's iCloud target for it.",
        discussion: """
            Deletes the vault's zone and everything in it; every other device that syncs through iCloud stops (its target \
            reports that the data is gone). The copy in this store and its other targets are not touched. Refused unless the \
            vault has another sync target here or --force is given; --yes confirms (nothing is deleted without it). \
            Exit codes: 0, 1.
            """
    )

    @Argument(help: ArgumentHelp("The vault's id or a unique id prefix (in the store or in iCloud).", valueName: "vault"))
    var vault: String

    @Flag(name: .long, help: "Confirm: delete the iCloud data.")
    var yes = false

    @Flag(name: .long, help: "Delete even when iCloud holds the only copy besides this device's own (a backup keeps the vault safe).")
    var force = false

    @OptionGroup var location: StoreOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        #if canImport(SempereCloudKit)
        _ = try CloudKitCLI.accountHash()
        let db = CloudKitDatabase()
        let listed = try CloudVaults.list(store: db).filter { $0.vaultId.hasPrefix(vault.lowercased()) }
        guard let found = listed.first else { throw CLIError.failure("no vault in this iCloud account matches “\(vault)”") }
        guard listed.count == 1 else { throw CLIError.usage("“\(vault)” matches \(listed.count) vaults; give more of the id") }
        let id = UUID(uuidString: found.vaultId) ?? UUID()
        let store = location.open()
        if store.entry(id: id) != nil, !force,
           !store.targets.targets(of: id).contains(where: { $0.kind != .cloudkit }) {
            throw CLIError.failure("“\(found.name)” has no other sync target here: add a folder or WebDAV target or a backup first, or pass --force")
        }
        guard yes else { throw CLIError.usage("this deletes “\(found.name)” from iCloud for every device: pass --yes") }
        for t in store.targets.targets(of: id) where t.kind == .cloudkit { try store.targets.remove(t.id, of: id) }
        try db.deleteZone(found.zone)
        if output.json { return try output.emitJSON(["deleted": found.vaultId]) }
        output.info("Deleted “\(found.name)” from iCloud")
        #else
        throw CLIError.failure(CloudKitCLI.unavailable ?? "iCloud (CloudKit) is not available")
        #endif
    }
}
