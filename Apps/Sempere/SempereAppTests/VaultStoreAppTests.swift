import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The in-app vault store in the app (docs/design/device-first-sync.md §2, §8.1): New Vault creates
/// into it, "Open Vault…" copies in and opens the copy, the welcome list opens and removes its vaults,
/// and an open vault holds a lease.
@MainActor
struct VaultStoreAppTests {
    static func model() throws -> AppModel {
        AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
    }

    @Test func newVaultIsCreatedInTheStoreAndRemembersItsId() async throws {
        let library = try BrowserTests.library()
        let model = try Self.model()
        let created = try await model.createVault(NewVaultRequest(name: "Fresh", keySource: .generate, passphrase: nil),
                                                  library: library)
        let entry = try #require(library.vaultStore.list().first)
        #expect(library.vaultStore.list().count == 1)
        #expect(created.url == entry.url)
        #expect(entry.url.path.hasPrefix(library.vaultStore.root.path + "/" + entry.vaultId.uuidString.lowercased() + "/"))
        #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
        #expect(model.phase == .unlocked)
        let recent = try #require(library.recents.first)
        #expect(recent.storeID == entry.vaultId)
        #expect(recent.bookmark.isEmpty)
        #expect(library.state(of: recent) == .available)
        #expect(library.storedVaults.map(\.vaultId) == [entry.vaultId])
        // Nothing is left in the staging folder.
        let staging = library.vaultStore.root.appendingPathComponent(".staging")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)

        // A relaunch (a new library on the same files) lists it and reopens it by id.
        model.close()
        let relaunched = VaultLibrary(storeURL: library.storeURL)
        #expect(relaunched.storedVaults.map(\.vaultId) == [entry.vaultId])
        let second = try Self.model()
        try await second.open(recent: try #require(relaunched.recents.first), library: relaunched)
        #expect(second.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
        #expect(second.phase == .locked)
        try await second.unlock(identityText: try #require(created.secretKey))
        #expect(second.phase == .unlocked)
    }

    @Test func openVaultCopiesInAndOpensTheCopy() async throws {
        let (source, key) = try AppModelTests.fixtureVault()
        let before = try Self.files(source)
        let library = try BrowserTests.library()
        let model = try Self.model()
        try await model.copyIn(picked: source, library: library)
        let entry = try #require(library.storedVaults.first)
        #expect(entry.name == "sample")
        #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
        #expect(model.phase == .locked)
        #expect(model.vaultCopy == nil)
        #expect(try Self.files(entry.url) == before)
        #expect(try Self.files(source) == before, "the picked folder is only read")
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.notes.contains { $0.id == AppModelTests.lecture })
        #expect(library.recents.first?.storeID == entry.vaultId)

        // The same vault again: not copied twice; its copy stays open as it was.
        try await model.copyIn(picked: source, library: library)
        #expect(model.phase == .unlocked)
        #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
        #expect(library.vaultStore.list().count == 1)
        // Another folder of the same vault (a pick of the folder holding it: VaultLocator), with no vault
        // open: the copy on this device opens.
        model.close()
        let (other, _) = try AppModelTests.fixtureVault()
        try await model.copyIn(picked: other.deletingLastPathComponent(), library: library)
        #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
        #expect(model.phase == .locked)
        #expect(library.vaultStore.list().count == 1)
        #expect(library.recents.filter { $0.storeID == entry.vaultId }.count == 1)
    }

    @Test func anIncompleteVaultIsNotCopiedAndNothingChanges() async throws {
        let (source, _) = try AppModelTests.fixtureVault()
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".sempere-partial"),
                                                withIntermediateDirectories: true)
        let library = try BrowserTests.library()
        let model = try Self.model()
        await #expect(throws: VaultStoreProblem.self) {
            try await model.copyIn(picked: source, library: library)
        }
        #expect(model.phase == .noVault)
        #expect(library.storedVaults.isEmpty)
        #expect(library.vaultStore.list().isEmpty)
        #expect(library.recents.isEmpty)
    }

    /// Two store vaults: opening one leases it (removal refused), the other is removed meanwhile, and
    /// closing ends the lease.
    @Test func anOpenVaultIsLeasedAndAnotherIsRemoved() async throws {
        let library = try BrowserTests.library()
        let model = try Self.model()
        model.vaultStore = library.vaultStore
        let (source, _) = try AppModelTests.fixtureVault()
        try await model.copyIn(picked: source, library: library)
        let open = try #require(library.storedVaults.first)
        let other = try await library.create(NewVaultRequest(name: "Other", keySource: .generate, passphrase: nil))
        #expect(library.storedVaults.count == 2)
        let otherEntry = try #require(library.storedVaults.first { $0.url == other.url })

        await #expect(throws: VaultStoreProblem(error: .inUse(open.vaultId))) {
            try await library.removeStored(open)
        }
        try await library.removeStored(otherEntry)
        #expect(library.storedVaults.map(\.vaultId) == [open.vaultId])
        #expect(!library.recents.contains { $0.storeID == otherEntry.vaultId })
        #expect(!FileManager.default.fileExists(atPath: other.url.path))
        #expect(model.vaultURL?.standardizedFileURL == open.url.standardizedFileURL)

        model.close()
        await model.closingEditor?.value
        try await library.removeStored(open)
        #expect(library.storedVaults.isEmpty)
        #expect(library.vaultStore.list().isEmpty)
    }

    @Test func storeVaultsOpenFromTheListAndSortByUse() async throws {
        let library = try BrowserTests.library()
        _ = try await library.create(NewVaultRequest(name: "Beta", keySource: .generate, passphrase: nil))
        _ = try await library.create(NewVaultRequest(name: "Alpha", keySource: .generate, passphrase: nil))
        // The most recently created or opened first.
        #expect(library.storedVaultsByUse.map(\.name) == ["Alpha", "Beta"])
        let beta = try #require(library.storedVaults.first { $0.name == "Beta" })
        let model = try Self.model()
        try await model.openStored(beta, library: library)
        #expect(model.vaultURL?.standardizedFileURL == beta.url.standardizedFileURL)
        #expect(library.storedVaultsByUse.map(\.name) == ["Beta", "Alpha"])
        // Vaults never opened here (copied in by the CLI, say) come after, by name.
        let relaunched = VaultLibrary(storeURL: library.storeURL.deletingLastPathComponent().appendingPathComponent("other.json"),
                                      vaultStore: library.vaultStore)
        #expect(relaunched.storedVaultsByUse.map(\.name) == ["Alpha", "Beta"])
    }

    /// A remembered key is bound to a store vault by its place in the store, not the container's path
    /// (which iOS changes), and unbinding it on removal leaves a later vault there unoffered.
    @Test func rememberedKeyLocationsOfStoreVaultsAreStable() throws {
        let root = try BrowserTests.tempDir()
        let storeA = root.appendingPathComponent("A/Vaults"), storeB = root.appendingPathComponent("B/Vaults")
        let id = UUID()
        let vaultA = storeA.appendingPathComponent("\(id.uuidString.lowercased())/Notes.sempere")
        let vaultB = storeB.appendingPathComponent("\(id.uuidString.lowercased())/Notes.sempere")
        let docs = root.appendingPathComponent("Documents")
        #expect(RememberedKeyLocations.location(of: vaultA, onDeviceFolder: docs, storeFolder: storeA)
                == RememberedKeyLocations.location(of: vaultB, onDeviceFolder: docs, storeFolder: storeB))
        #expect(RememberedKeyLocations.location(of: vaultA, onDeviceFolder: docs, storeFolder: storeA)
                != RememberedKeyLocations.location(of: vaultA, onDeviceFolder: docs))
        let locations = RememberedKeyLocations(onDeviceFolder: docs, storeFolder: storeA)
        locations.bind(id, to: vaultA)
        locations.bind(id, to: root.appendingPathComponent("elsewhere.sempere"))
        locations.unbind(id, from: vaultA)
        #expect(locations.locations(for: id).count == 1)
        #expect(!locations.locations(for: id).contains(locations.location(of: vaultA)))
    }

    @Test func copyProgressReads() {
        var progress = VaultCopyProgress(name: "Notes", stage: .copying(done: 3, total: 12))
        #expect(progress.fraction == 0.25)
        #expect(progress.text.contains("3 of 12"))
        progress.stage = .downloading(done: 0, total: 0)
        #expect(progress.fraction == nil)
        #expect(VaultStoreProblem(error: .alreadyInStore(vaultId: UUID(), name: "Notes")).description.contains("“Notes”"))
    }

    /// Relative path → bytes of every regular file under `root` (hidden names skipped).
    static func files(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let walker = FileManager.default.enumerator(atPath: base.path)
        while let rel = walker?.nextObject() as? String {
            let url = base.appendingPathComponent(rel)
            guard !url.lastPathComponent.hasPrefix("."),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out[rel] = try Data(contentsOf: url)
        }
        return out
    }
}
