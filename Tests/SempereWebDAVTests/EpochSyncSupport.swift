import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// A sync target of an epoch test (key-hierarchy design §11.1, KH4): an in-memory store every device reaches
/// with its own `MemoryRemote` (faults optional), or a WebDAV mock.
final class EpochTarget: @unchecked Sendable {
    let name: String
    let store: MemoryStore
    /// How a device reaches it; nil: a plain `MemoryRemote`.
    var reach: ((String) -> any SyncRemote)?
    /// When false, every request fails (the target cannot be reached).
    var reachable = true

    init(_ name: String, store: MemoryStore = MemoryStore()) {
        self.name = name
        self.store = store
    }

    func remote(for device: String) -> any SyncRemote {
        if !reachable { return UnreachableRemote(location: "memory:\(name)") }
        return reach?(device) ?? MemoryRemote(store: store)
    }

    /// The bytes of the target's file at `path` (slash-separated).
    func file(_ path: String) -> Data? { store.file(path.split(separator: "/").map(String.init)) }

    /// Every file path on the target.
    var paths: Set<String> { Set(store.filePaths().map { $0.joined(separator: "/") }) }
}

/// A remote that cannot be reached: every request fails as a dropped connection would.
struct UnreachableRemote: SyncRemote {
    var location: String
    var capabilities: RemoteCapabilities { RemoteCapabilities() }
    var interrupt: (@Sendable () -> (any Error)?)?
    private func fail() -> Error { MemoryRemoteError.offline("\(location) is not reachable (test)") }
    func list(_ path: [String]) throws -> [RemoteEntry]? { throw fail() }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { throw fail() }
    func missingCollectionError(_ path: [String]) -> any Error { fail() }
    func stat(_ path: [String]) throws -> RemoteEntry? { throw fail() }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { throw fail() }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult { throw fail() }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool { throw fail() }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool { throw fail() }
    func makeCollection(_ path: [String]) throws -> CollectionResult { throw fail() }
    func createBase() throws { throw fail() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { throw fail() }
}

/// One device of an epoch sync test: its own working copy, device keys, trust record, write ledger,
/// set-aside store, device clock and per-target sync states, all under `root`.
final class EpochSyncDevice: @unchecked Sendable {
    let name: String
    let root: URL
    var identity: NativeIdentity
    let trust = MemoryEpochTrustStore()
    let ledger = MemoryWriteLedger()
    let setAside: SetAsideStore
    var tune: (inout SyncOptions) -> Void = { _ in }

    init(_ name: String, root: URL, identity: NativeIdentity = pqIdentity()) {
        self.name = name
        self.root = root.appendingPathComponent(name, isDirectory: true)
        self.identity = identity
        setAside = SetAsideStore(directory: self.root.appendingPathComponent("setaside"))
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    var folder: URL { root.appendingPathComponent("Vault.sempere", isDirectory: true) }
    var deviceState: URL { root.appendingPathComponent("device.json") }
    var keys: DeviceKeys { TestVaults.device(identity) }
    var fingerprint: Data { keys.fingerprint }
    var id: String { keys.id }
    var hasVault: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(Vault.manifestName).path) }

    func stateURL(_ target: EpochTarget) -> URL { root.appendingPathComponent("sync-\(target.name).json") }

    /// The working copy opened as this device.
    func open() throws -> Vault {
        try Vault.open(at: folder, identities: [identity], signing: TestVaults.signing(identity), trust: trust,
                       ledger: ledger, setAside: setAside)
    }

    /// A new note titled `title`, written as this device; its id.
    @discardableResult
    func write(_ title: String, id: UUID = UUID()) throws -> UUID {
        try open().apply(NoteOps.newNote(title: title, paper: .ruled, pageId: UUID()), to: id, deviceState: deviceState, app: "test/1")
        return id
    }

    func retitle(_ note: UUID, _ title: String) throws {
        try open().apply([.setMeta(.title(title))], to: note, deviceState: deviceState, app: "test/1")
    }

    /// A two-way run with `target`.
    @discardableResult
    func sync(_ target: EpochTarget, _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let v = hasVault ? try open() : nil
        var o = SyncOptions(deviceLabel: name)
        o.deviceID = v?.writerDevice
        if !hasVault { o.firstPullIdentities = [identity] }
        tune(&o)
        edit(&o)
        return try SyncEngine(directory: folder, vault: v, remote: target.remote(for: name), stateURL: stateURL(target),
                              options: o).run()
    }

    /// An upload-only run (the app's run of a vault nobody unlocked): no vault, push-only, server changes kept.
    @discardableResult
    func push(_ target: EpochTarget) throws -> SyncReport {
        var o = SyncOptions(deviceLabel: name)
        o.pushOnly = true
        o.keepServerChanges = true
        tune(&o)
        return try SyncEngine(directory: folder, vault: nil, remote: target.remote(for: name), stateURL: stateURL(target),
                              options: o).run()
    }

    /// Two-way runs until one changes nothing (at most `rounds`); the last report.
    @discardableResult
    func syncUntilQuiet(_ target: EpochTarget, rounds: Int = 6) throws -> SyncReport {
        var last = SyncReport()
        for _ in 0..<rounds {
            last = try sync(target)
            if last.isEmpty { return last }
        }
        return last
    }

    /// Each note's title as this device reads it (notes with no readable revision left out).
    func titles() throws -> [UUID: String] {
        let v = try open()
        var out: [UUID: String] = [:]
        for id in try v.noteIDs() {
            guard let loaded = try? v.loadNote(id), !loaded.revisions.isEmpty,
                  let s = try? v.reconstruct(loaded) else { continue }
            out[id] = s.meta.title
        }
        return out
    }
}

/// A vault shared by devices over sync targets: the first device is home and creates it; the others are
/// approved there, pull it from the first target and confirm their join (so each keeps a trust record).
final class EpochSyncWorld {
    let devices: [EpochSyncDevice]
    let targets: [EpochTarget]
    let recovery: MLKEM768X25519Identity
    let root: Data
    let vaultId: UUID

    init(in dir: URL, names: [String], targets targetNames: [String] = ["T1"]) throws {
        devices = names.map { EpochSyncDevice($0, root: dir) }
        targets = targetNames.map { EpochTarget($0) }
        recovery = try MLKEM768X25519Identity()
        let home = devices[0]
        var vault = try Vault.create(at: home.folder, device: home.keys, deviceName: home.name, recovery: recovery,
                                     recoveryPassphrase: "correct horse battery staple vault", workFactor: 10,
                                     trust: home.trust, ledger: home.ledger, setAside: home.setAside)
        for d in devices.dropFirst() {
            try vault.approveDevice(d.keys.joinRequest(vaultId: vault.vaultId, name: d.name, kind: "cli"))
        }
        root = vault.root
        vaultId = vault.vaultId
        try home.sync(targets[0])
        for d in devices.dropFirst() {
            try d.sync(targets[0])
            var v = try d.open()
            try v.confirmJoin(words: try XCTUnwrap(v.expectedReplyWords()))
        }
    }

    subscript(_ name: String) -> EpochSyncDevice {
        guard let d = devices.first(where: { $0.name == name }) else { preconditionFailure("no device \(name)") }
        return d
    }

    func target(_ name: String) -> EpochTarget {
        guard let t = targets.first(where: { $0.name == name }) else { preconditionFailure("no target \(name)") }
        return t
    }

    /// The vault as the recovery kit reads it from `device`'s working copy (an observer that holds every key).
    func observer(_ device: EpochSyncDevice) throws -> Vault {
        try Vault.open(at: device.folder, identities: [NativeIdentity.mlkem768x25519(recovery)], root: root)
    }
}
