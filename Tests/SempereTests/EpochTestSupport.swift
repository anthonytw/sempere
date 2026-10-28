import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// One device of an epoch scenario (key-hierarchy design §11.1; phase KH3): its keys and its device-local
/// state (trust record, write ledger, set-aside store, clock), all in process, sharing one vault folder.
final class EpochDevice {
    let name: String
    let identity: NativeIdentity
    let trust = MemoryEpochTrustStore()
    let ledger = MemoryWriteLedger()
    let setAside: SetAsideStore
    let state: URL

    init(_ name: String, root: URL) {
        self.name = name
        identity = pqIdentity()
        setAside = SetAsideStore(directory: root.appendingPathComponent("\(name)-setaside"))
        state = root.appendingPathComponent("\(name)-device.json")
    }

    var keys: DeviceKeys { TestVaults.device(identity) }
    var fingerprint: Data { keys.fingerprint }
    var id: String { keys.id }

    /// Opens the shared vault as this device.
    func open(_ url: URL, root: Data? = nil) throws -> Vault {
        try Vault.open(at: url, identities: [identity], signing: TestVaults.signing(identity), trust: trust, root: root,
                       ledger: ledger, setAside: setAside)
    }

    /// Writes a new note as this device; returns its id.
    @discardableResult
    func newNote(_ vault: Vault, _ title: String) throws -> UUID {
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: title, paper: .ruled, pageId: UUID()), to: id, deviceState: state, app: "test/1")
        return id
    }

    /// Retitles `note` as this device.
    func retitle(_ vault: Vault, _ note: UUID, _ title: String) throws {
        try vault.apply([.setMeta(.title(title))], to: note, deviceState: state, app: "test/1")
    }
}

/// A vault shared by in-process devices: the first is home and creates it, the others are approved and
/// confirm, so every device keeps a trust record.
final class EpochWorld {
    let url: URL
    let devices: [EpochDevice]
    let recovery: MLKEM768X25519Identity
    let root: Data

    init(in dir: URL, names: [String], passphrase: String? = nil) throws {
        url = dir.appendingPathComponent("Shared.sempere")
        devices = names.map { EpochDevice($0, root: dir) }
        recovery = try MLKEM768X25519Identity()
        let home = devices[0]
        var vault = try Vault.create(at: url, device: home.keys, deviceName: home.name, recovery: recovery,
                                     recoveryPassphrase: passphrase, workFactor: 10, trust: home.trust,
                                     ledger: home.ledger, setAside: home.setAside)
        for d in devices.dropFirst() {
            try vault.approveDevice(d.keys.joinRequest(vaultId: vault.vaultId, name: d.name, kind: "cli"))
        }
        root = vault.root
        for d in devices.dropFirst() {
            var v = try d.open(url)
            try v.confirmJoin(words: try XCTUnwrap(v.expectedReplyWords()))
        }
    }

    subscript(_ name: String) -> EpochDevice {
        guard let d = devices.first(where: { $0.name == name }) else { preconditionFailure("no device \(name)") }
        return d
    }

    func open(_ name: String) throws -> Vault { try self[name].open(url) }

    /// The bodies (title by note) every listed device reads.
    func titles(_ vault: Vault) throws -> [UUID: String] {
        var out: [UUID: String] = [:]
        for id in try vault.noteIDs() {
            let loaded = try vault.loadNote(id)
            guard !loaded.revisions.isEmpty else { continue }
            out[id] = try vault.reconstruct(loaded).meta.title
        }
        return out
    }
}
