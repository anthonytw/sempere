import ArgumentParser
import Foundation
import Sempere
import SempereSync
import SempereWebDAV

// Device changes and sync targets from the CLI (docs/design/key-hierarchy.md §5.2 step 2, §5.5; phase KH4): the
// remover's best-effort pull from a store vault's targets before a removal, handoff, kit replacement or
// takeover, the last-synced times the removal warns with, and this machine's state for the vault
// (`sempere devices status`: listed, waiting for a device-change record, or unlisted, with its own changes no
// target holds).

/// What `--json` prints for one target of the remover's pull.
struct PullOutput: Encodable {
    var target: String
    var reached: Bool
    var downloaded: Int
    var error: String?
}

/// A device a change removes, with its last sync (design §5.5).
struct RemovedDeviceOutput: Encodable {
    var id: String
    var name: String
    /// RFC 3339, from its own `summaries/<id>.sealed`; nil when unknown.
    var lastSynced: String?
    /// True when it last synced more than a day ago, or it is not known.
    var stale: Bool
}

enum EpochTargets {
    /// A day: a removed device that synced longer ago is warned about.
    static let staleAfter: TimeInterval = 86_400

    /// The store a store vault at `url` lives in (`<store>/<vault id>/<name>.sempere`), when its registry has
    /// targets for it.
    static func store(of url: URL, vaultId: UUID) -> VaultStore? {
        let idFolder = url.standardizedFileURL.deletingLastPathComponent()
        let root = idFolder.deletingLastPathComponent()
        guard idFolder.lastPathComponent == vaultId.uuidString.lowercased() else { return nil }
        let store = VaultStore(root: root)
        return store.targets.targets(of: vaultId).isEmpty ? nil : store
    }

    /// The remover's best-effort pull (design §5.2 step 2): a pull-only pass, 10 seconds each, on every target
    /// of the store vault `vault`; reported on stderr. Nothing for a vault that is not a store vault with
    /// targets.
    static func pull(_ vault: Vault, passwordEnv: String?, output: OutputOptions) -> [PullOutput] {
        guard vault.canRead, let store = store(of: vault.url, vaultId: vault.vaultId) else { return [] }
        let targets = store.targets.targets(of: vault.vaultId)
        var outcomes: [PullOutput] = []
        var reachable: [EpochChangePull.Target] = []
        var names: [String: SyncTarget] = [:]
        for t in targets {
            names[t.id.uuidString.lowercased()] = t
            do {
                reachable.append(.init(name: t.id.uuidString.lowercased(), remote: try remote(t, passwordEnv: passwordEnv),
                                       quarantine: store.targets.quarantineDirectory(t.id, of: vault.vaultId)))
            } catch {
                outcomes.append(PullOutput(target: t.name, reached: false, downloaded: 0, error: CLIError.from(error).message))
            }
        }
        var base = SyncOptions()
        base.deviceID = vault.writerDevice
        base.deviceLabel = ProcessInfo.processInfo.hostName
        base.localWriteLock = store.writeLock(for: vault.vaultId)
        let scratch = store.targets.stateDirectory(UUID(), of: vault.vaultId).deletingLastPathComponent()
            .appendingPathComponent("pull", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for o in EpochChangePull.run(vault: vault, folder: vault.url, targets: reachable, scratch: scratch, options: base) {
            let t = names[o.target]
            outcomes.append(PullOutput(target: t?.name ?? o.target, reached: o.reached,
                                       downloaded: o.report?.downloaded.count ?? 0, error: o.error))
        }
        for o in outcomes where !output.json {
            if o.reached {
                output.info("Pulled from \(o.target): \(o.downloaded) file(s).")
            } else {
                let since = targets.first { $0.name == o.target }?.lastSuccess.map { " since \(RFC3339.string($0))" } ?? ""
                printStderr("sempere: \(o.target) was not reachable (\(o.error ?? "?")): changes there\(since) from other "
                    + "devices will be caught up by them")
            }
        }
        return outcomes
    }

    /// The remote of a store target (a folder, or WebDAV with the password from `passwordEnv`).
    static func remote(_ t: SyncTarget, passwordEnv: String?) throws -> any SyncRemote {
        switch t.kind {
        case .folder:
            guard let path = t.path else { throw CLIError.failure("target \(t.name) has no path") }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw CLIError.failure("\(path) cannot be reached now")
            }
            return FolderRemote(root: folder)
        case .webdav:
            guard let text = t.url, let url = URL(string: text) else { throw CLIError.failure("target \(t.name) has no URL") }
            let login = try WebDAVLoginOptions.parse((t.user.map { ["--user", $0] } ?? [])
                                                     + (passwordEnv.map { ["--password-env", $0] } ?? []))
            return WebDAVSyncRemote(try login.client(url))
        default:
            throw CLIError.failure("target kind \(t.kind) is not supported by this version")
        }
    }

    /// The devices `ids` with their last syncs, before a change removes them.
    static func removed(_ vault: Vault, ids: [String], now: Date = Date()) -> [RemovedDeviceOutput] {
        ids.compactMap { q in
            guard let d = try? vault.resolveDevice(q), let id = d.id else { return nil }
            let last = vault.lastSynced(device: id)
            return RemovedDeviceOutput(id: id, name: DeviceName.display(d.name), lastSynced: last.map { RFC3339.string($0) },
                                       stale: last.map { now.timeIntervalSince($0) > staleAfter } ?? true)
        }
    }

    /// The removal sheet's warning (design §5.5), one line per device.
    static func warn(_ removed: [RemovedDeviceOutput], output: OutputOptions, now: Date = Date()) {
        for r in removed where r.stale {
            let when = r.lastSynced.flatMap { RFC3339.parse($0) }.map { "last synced \(ago($0, now: now))" } ?? "has no recorded sync"
            output.info("\(r.name) (\(r.id)) \(when). Changes it made since then will not reach this vault. It will be told "
                + "it was removed, and can export them.")
        }
    }

    /// "12 days ago", "3 hours ago", "just now".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s >= 86_400 { let d = Int(s / 86_400); return "\(d) day\(d == 1 ? "" : "s") ago" }
        if s >= 3600 { let h = Int(s / 3600); return "\(h) hour\(h == 1 ? "" : "s") ago" }
        if s >= 60 { let m = Int(s / 60); return "\(m) minute\(m == 1 ? "" : "s") ago" }
        return "just now"
    }
}

/// `--no-pull` and `--password-env` for the commands that start a device change.
struct EpochPullOptions: ParsableArguments {
    @Flag(name: .customLong("no-pull"),
          help: "Do not pull from the store vault's sync targets first (design §5.2: a change seals what this machine holds).")
    var noPull = false

    @Option(name: .customLong("password-env"),
            help: ArgumentHelp("With a WebDAV target: the environment variable holding its password.", valueName: "var"))
    var passwordEnv: String?
}

// MARK: - devices status

struct DevicesStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "This machine's state in the vault: listed, waiting for a device change to be verified, or removed.",
        discussion: """
            Design §4.3, §5.5. A machine whose sync met a later device list it cannot verify yet (its record has \
            not arrived) keeps writing here but uploads nothing new until it can. A machine the newest list it \
            verified does not hold (removed, or dropped by a takeover) writes nothing (exit 8 on writes) and keeps \
            pulling; a takeover that lists it again undoes that. `unsynced` counts this machine's own files (its \
            write ledger) that no sync target of the store vault holds; --export DIR copies them, as they are, \
            under their vault paths (keep them, or import them into another vault).

            Sightings are the device lists this machine met and did not take (its trust store). An anchored one \
            (its parent is an epoch this machine verified) holds every sync back; a detached one (nothing verifies \
            it: anyone with write access to a target can plant one) holds back only syncs with the targets that \
            still show it, and is forgotten once none does. --forget-sightings forgets them all (a real change is \
            met again at the next sync).

            --json: state (listed, waiting, unlisted, record-pending), notice, heldSince, sightings (epoch, epochId, \
            anchored, sources, seen), unsynced, exported.
            """
    )

    @OptionGroup var access: AccessOptions

    @Option(name: .long, help: ArgumentHelp("Copy this machine's unsynced files into this folder.", valueName: "dir"))
    var export: String?

    @Flag(name: .customLong("forget-sightings"), help: "Forget every device list this machine met and did not take.")
    var forgetSightings = false

    @OptionGroup var output: OutputOptions

    struct SightingOut: Encodable {
        var epoch: Int
        var epochId: String
        var anchored: Bool
        var sources: [String]
        var seen: String
    }

    struct Out: Encodable {
        var state: String
        var notice: String?
        var heldSince: String?
        var sightings: [SightingOut]
        var forgotten: Int?
        var unsynced: [String]
        var exported: [String]?
    }

    func run() throws {
        let vault = try access.openVault(.required)
        var forgotten: Int?
        if forgetSightings {
            forgotten = vault.sightings().count
            try vault.forgetSightings()
        }
        let sightings = vault.sightings().map {
            SightingOut(epoch: $0.epoch, epochId: Hex.encode($0.epochId), anchored: vault.isAnchoredSighting($0),
                        sources: $0.sources, seen: RFC3339.string($0.seen))
        }
        let heldSince = vault.waitingNotice == nil ? nil
            : vault.sightings().filter { vault.isAnchoredSighting($0) }.map(\.seen).min()
        let state: String, notice: String?
        if let n = vault.unlistedNotice {
            (state, notice) = ("unlisted", n)
        } else if let n = vault.waitingNotice {
            (state, notice) = ("waiting", n)
        } else if vault.isRecordPending {
            (state, notice) = ("record-pending", "waiting for the device-change record \(vault.manifest.epochRecord); "
                + "files from before it are not read yet")
        } else {
            (state, notice) = ("listed", nil)
        }
        var states: [URL] = []
        if let store = EpochTargets.store(of: vault.url, vaultId: vault.vaultId) {
            states = store.targets.targets(of: vault.vaultId).map { store.targets.stateURL($0.id, of: vault.vaultId) }
        }
        let unsynced = try UnsyncedChanges.paths(vault: vault, stateURLs: states)
        var exported: [String]?
        if let export {
            let dir = URL(fileURLWithPath: export, isDirectory: true)
            exported = try unsynced.map { path in
                let target = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw CLIError.failure("\(target.path) exists: not overwritten")
                }
                try FileManager.default.copyItem(at: vault.url.appendingPathComponent(path), to: target)
                return target.path
            }
        }
        if output.json {
            return try output.emitJSON(Out(state: state, notice: notice, heldSince: heldSince.map { RFC3339.string($0) },
                                           sightings: sightings, forgotten: forgotten, unsynced: unsynced, exported: exported))
        }
        print("State: \(state)" + (notice.map { ": \($0)" } ?? ""))
        if let heldSince { print("Held back since \(RFC3339.string(heldSince)) (\(EpochTargets.ago(heldSince)))") }
        for s in sightings {
            print("Sighting: epoch \(s.epoch) \(s.epochId.prefix(16)) \(s.anchored ? "anchored" : "detached"), seen \(s.seen) at "
                + s.sources.joined(separator: ", "))
        }
        if let forgotten { output.info("Forgot \(forgotten) sighting(s).") }
        print("Own changes no target holds: \(unsynced.count)" + (states.isEmpty ? " (not a store vault with targets)" : ""))
        if let exported { output.info("Exported \(exported.count) file(s) to \(export ?? "")") }
    }
}
