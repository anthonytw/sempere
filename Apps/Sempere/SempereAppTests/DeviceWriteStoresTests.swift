import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The app's write ledger and set-aside store (key-hierarchy design §5.4, §5.8; phase KH3): every note the app
/// writes is recorded in the ledger before it is placed, so a device change it has not seen is caught up.
@Suite(.serialized)
@MainActor
struct DeviceWriteStoresTests {
    @Test func appWritesAreRecordedInTheLedgerFirst() async throws {
        let trust = MemoryEpochTrustStore()
        let (url, keyText) = try ListAlertTests.trustedFixture(trust)
        let stores = DeviceWriteStores.inMemoryKey(root: try TestTemp.directory("ledger"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        model.writeStores = stores
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        let vault = try #require(model.vault)
        #expect(vault.ledger != nil)
        let id = try await model.createNote(title: "Recorded", paper: Paper(kind: .ruled), notebook: nil)
        let entries = try stores.ledger(for: vault.vaultId).entries()
        let prefix = "notes/\(id.uuidString.lowercased())/"
        let mine = entries.filter { $0.path.hasPrefix(prefix) }
        #expect(!mine.isEmpty, "\(entries.map(\.path))")
        for e in mine {
            let data = try Data(contentsOf: url.appendingPathComponent(e.path))
            #expect(FileDigest.sha256(data) == e.sha256)
            #expect(e.epoch == vault.manifest.epoch)
        }
    }

    @Test func aLedgerWhoseKeyIsMissingFailsClosed() async throws {
        let trust = MemoryEpochTrustStore()
        let (url, keyText) = try ListAlertTests.trustedFixture(trust)
        let root = try TestTemp.directory("ledger-nokey")
        struct NoKey: Error {}
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        model.writeStores = DeviceWriteStores(ledgerDirectory: root.appendingPathComponent("Ledger"),
                                              setAside: SetAsideStore(directory: root.appendingPathComponent("SetAside")),
                                              key: { throw NoKey() })
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        await #expect(throws: (any Error).self, "a write no ledger knows could not be caught up") {
            _ = try await model.createNote(title: "Unrecorded", paper: Paper(kind: .ruled), notebook: nil)
        }
    }

    /// A backup restored onto another device brings the ledgers back but not the this-device-only key (review
    /// R2): the old ledgers are moved aside (kept), a new key is made, and writes work, as for a new device.
    @Test func aRestoreOntoAnotherDeviceStartsAFreshLedger() async throws {
        let trust = MemoryEpochTrustStore()
        let (url, keyText) = try ListAlertTests.trustedFixture(trust)
        let root = try TestTemp.directory("ledger-restore")
        let ledgerDir = root.appendingPathComponent("Ledger", isDirectory: true)
        let vaultId = try Vault.open(at: url).vaultId
        // The restored ledger: records sealed with a key this device does not have.
        let lostKey = LedgerKeychain.randomKey()
        let old = FileWriteLedger(directory: ledgerDir, vaultId: vaultId, keyBytes: { lostKey })
        try old.append([LedgerEntry(path: "notes/x", sha256: String(repeating: "0", count: 64), epoch: 1, epochId: Data(count: 32))])
        let items = MemoryLedgerKeyItems()
        let fallback = root.appendingPathComponent("never-used-key")
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        model.writeStores = DeviceWriteStores(ledgerDirectory: ledgerDir, setAside: SetAsideStore(directory: root.appendingPathComponent("SetAside")),
                                              key: { try LedgerKeychain.key(items: items, ledgerDirectory: ledgerDir, unsignedFallback: fallback) })
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        _ = try await model.createNote(title: "After the restore", paper: Paper(kind: .ruled), notebook: nil)
        #expect(try items.read() != nil, "a new key")
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        let entries = try #require(model.writeStores).ledger(for: vaultId).entries()
        #expect(!entries.isEmpty && !entries.contains { $0.path == "notes/x" }, "a fresh ledger")
        let aside = try FileManager.default.contentsOfDirectory(atPath: ledgerDir.path).filter { $0.hasPrefix(".orphaned-") }
        #expect(aside.count == 1)
        let kept = ledgerDir.appendingPathComponent(aside[0]).appendingPathComponent(vaultId.uuidString.lowercased())
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("log").path), "kept, never deleted")
    }

    /// A key store that cannot be read (locked, an error) is not a missing key: nothing is moved or made, and the
    /// write fails closed (review R2).
    @Test func anUnreadableKeyStoreFailsClosedAndMovesNothing() throws {
        let root = try TestTemp.directory("ledger-locked")
        let ledgerDir = root.appendingPathComponent("Ledger", isDirectory: true)
        let vaultId = UUID()
        let key = LedgerKeychain.randomKey()
        try FileWriteLedger(directory: ledgerDir, vaultId: vaultId, keyBytes: { key })
            .append([LedgerEntry(path: "notes/x", sha256: String(repeating: "0", count: 64), epoch: 1, epochId: Data(count: 32))])
        let items = MemoryLedgerKeyItems(key: key)
        items.failRead = true
        #expect(throws: (any Error).self) {
            try LedgerKeychain.key(items: items, ledgerDirectory: ledgerDir, unsignedFallback: root.appendingPathComponent("k"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: ledgerDir.path)
        #expect(names.contains(vaultId.uuidString.lowercased()) && !names.contains { $0.hasPrefix(".orphaned-") })
        items.failRead = false
        #expect(try LedgerKeychain.key(items: items, ledgerDirectory: ledgerDir, unsignedFallback: root.appendingPathComponent("k")) == key)
        #expect(try FileWriteLedger(directory: ledgerDir, vaultId: vaultId, keyBytes: { key }).entries().count == 1, "the same ledger")
    }
}
