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
}
