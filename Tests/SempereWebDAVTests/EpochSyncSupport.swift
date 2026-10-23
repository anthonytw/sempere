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

    /// Reads the target for checks (never faulted); nil: the memory store.
    var inspector: (any SyncRemote)?

    func remote(for device: String) -> any SyncRemote {
        if !reachable { return UnreachableRemote(location: "memory:\(name)") }
        return reach?(device) ?? MemoryRemote(store: store)
    }

    /// A target over `t` (memory, the WebDAV mock, wsgidav): devices reach it through `t.remote`, or through
    /// `t.faulty` while `faults` returns a rate above 0.
    static func over(_ t: TransportUnderTest, name: String, seed: UInt64, faults: @escaping () -> Double) -> EpochTarget {
        let target = EpochTarget(name)
        target.inspector = t.inspector
        let counter = Locked(UInt64(0))
        target.reach = { _ in
            let p = faults()
            guard p > 0 else { return t.remote }
            counter.value &+= 1
            return t.faulty(seed &* 1_000_003 &+ counter.value, .all(p))
        }
        return target
    }

    /// The bytes of the target's file at `path` (slash-separated).
    func file(_ path: String) -> Data? {
        let comps = path.split(separator: "/").map(String.init)
        guard let inspector else { return store.file(comps) }
        return try? inspector.read(comps, maxBytes: 64 << 20).data
    }

    /// Every file path on the target.
    var paths: Set<String> {
        guard let inspector else { return Set(store.filePaths().map { $0.joined(separator: "/") }) }
        var out = Set<String>()
        func walk(_ p: [String]) {
            for e in (try? inspector.list(p)) ?? [] ?? [] where !e.name.hasPrefix(".") {
                if e.isCollection { walk(p + [e.name]) } else { out.insert((p + [e.name]).joined(separator: "/")) }
            }
        }
        walk([])
        return out
    }

    /// Writes `data` at `path` on the target, over whatever is there (another writer: storage credentials).
    func put(_ path: String, _ data: Data) {
        let comps = path.split(separator: "/").map(String.init)
        guard let inspector else { return store.putDirect(comps, data) }
        for i in 1..<comps.count { _ = try? inspector.makeCollection(Array(comps.prefix(i))) }
        _ = try? inspector.write(comps, .data(data), condition: .unconditional)
    }

    /// Removes the file at `path` from the target (withheld or lost).
    func remove(_ path: String) {
        let comps = path.split(separator: "/").map(String.init)
        guard let inspector else { return store.removeDirect(comps) }
        _ = try? inspector.delete(comps, ifETag: nil)
    }
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

    /// A two-way run with no key (a device that has not joined yet, or a locked vault).
    @discardableResult
    func syncLocked(_ target: EpochTarget, _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        var o = SyncOptions(deviceLabel: name)
        tune(&o)
        edit(&o)
        return try SyncEngine(directory: folder, vault: nil, remote: target.remote(for: name), stateURL: stateURL(target),
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

    convenience init(in dir: URL, names: [String], targets targetNames: [String] = ["T1"]) throws {
        try self.init(in: dir, names: names, made: targetNames.map { EpochTarget($0) })
    }

    init(in dir: URL, names: [String], made: [EpochTarget]) throws {
        devices = names.map { EpochSyncDevice($0, root: dir) }
        targets = made
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
