import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp
import SempereAppCore

/// P9 of docs/design/device-first-sync.md in the app: Vault Details (storage, devices per target) and Repair's
/// adopt, export and delete, on two devices syncing through a folder. Add WebDAV Server… is the model's
/// (`WebDAVTests.aWebDAVServerIsAddedOnceAsATarget` in `SempereAppCoreTests`).
@MainActor
struct VaultDetailsAppTests {
    @Test func detailsShowTheCopyAndTheDevicesATargetHeld() async throws {
        let w = try await FolderTargetAppTests.world()
        let details = try await w.a.model.vaultDetails(w.a.vaultID)
        #expect(details.storage.notes > 0)
        let target = try #require(details.targets.first)
        #expect(details.targets.count == 1)
        #expect(target.syncedFiles > 0)
        #expect(!target.devices.isEmpty)
        #expect(target.quarantined.isEmpty)
        w.a.model.close(); w.b.model.close()
    }

    /// A good revision in the quarantine is adopted into the open vault and leaves it; a damaged one is
    /// refused and stays; Export copies it and Delete removes it.
    @Test func repairAdoptsExportsAndDeletes() async throws {
        let w = try await FolderTargetAppTests.world()
        let model = w.a.model, vault = w.a.vaultID
        let target = try #require(model.openVaultTargets.first).id
        let quarantine = w.a.store.quarantine(target, of: vault)
        let notes = w.a.folder.appendingPathComponent("notes")
        let fm = FileManager.default
        let note = try #require(try fm.contentsOfDirectory(atPath: notes.path).first { !$0.hasPrefix(".") })
        let name = try #require(try fm.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path).first { $0.hasSuffix(".age") })
        let local = notes.appendingPathComponent(note).appendingPathComponent(name)
        let held = quarantine.directory.appendingPathComponent("notes/\(note)/\(name)")
        try fm.createDirectory(at: held.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: local, to: held)

        try await model.adoptQuarantined("notes/\(note)/\(name)", target: target, of: vault)
        #expect(fm.fileExists(atPath: local.path))
        #expect(quarantine.list().isEmpty)

        let bad = "notes/\(UUID().uuidString.lowercased())/17596320000990000-cccccccc-1.delta.age"
        let badURL = quarantine.directory.appendingPathComponent(bad)
        try fm.createDirectory(at: badURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("age-encryption.org/v1\n-> X25519 junk\n---\n".utf8).write(to: badURL)
        await #expect(throws: QuarantineError.self) { try await model.adoptQuarantined(bad, target: target, of: vault) }
        #expect(quarantine.list().map(\.path) == [bad])

        let out = TestTemp.root.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        let copy = try await model.exportQuarantined(bad, target: target, of: vault, to: out)
        #expect(fm.fileExists(atPath: copy.path))
        try await model.deleteQuarantined(bad, target: target, of: vault)
        #expect(quarantine.list().isEmpty)
        w.a.model.close(); w.b.model.close()
    }
}
