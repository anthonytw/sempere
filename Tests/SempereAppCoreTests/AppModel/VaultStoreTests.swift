import Age
import Foundation
import Observation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// The in-app vault store through the model (docs/design/device-first-sync.md §2, §8.1; moved from the app's
    /// `VaultStoreAppTests`): New Vault creates into it, "Open Vault…" copies in and opens the copy, the welcome list
    /// opens and removes its vaults, and an open vault holds a lease.
    @MainActor
    struct VaultStoreTests {
        static func model() throws -> AppModel {
            AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        }

        /// Build 10 (iPad): swiping a vault row open to Delete kept resetting. A refresh that finds the same vaults
        /// must not publish `storedVaults` (an `@Observable` property notifies on every write, and the list redrew).
        @Test func refreshingTheStoreWithNothingNewPublishesNothing() async throws {
            let library = try BrowserTests.library()
            let model = try Self.model()
            defer { model.close() }
            _ = try await model.createVault(NewVaultRequest(name: "Fresh", keySource: .generate, passphrase: nil),
                                            library: library)
            #expect(library.storedVaults.count == 1)
            final class Flag: @unchecked Sendable { var set = false }
            let published = Flag()
            withObservationTracking({ _ = library.storedVaults }, onChange: { published.set = true })
            await library.refreshStoredVaults(log: NoPerfSink())
            #expect(!published.set, "the same vaults are not published again")
        }

        @Test func newVaultIsCreatedInTheStoreAndRemembersItsId() async throws {
            let library = try BrowserTests.library()
            let model = try Self.model()
            defer { model.close() }
            let created = try await model.createVault(NewVaultRequest(name: "Fresh", keySource: .generate, passphrase: nil),
                                                      library: library)
            let entry = try #require(library.vaultStore.list().first)
            #expect(library.vaultStore.list().count == 1)
            #expect(created.url == entry.url)
            #expect(entry.url.path.hasPrefix(library.vaultStore.root.path + "/" + entry.vaultId.uuidString.lowercased() + "/"))
            #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
            #expect(model.phase == .unlocked)
            #expect(model.vault?.isHome == true, "this device is the new vault's home, unlocked with its device key")
            #expect(model.vault?.devices.first?.key == created.device.key)
            let recent = try #require(library.recents.first)
            #expect(recent.storeID == entry.vaultId)
            #expect(library.storedVaults.map(\.vaultId) == [entry.vaultId])
            // Nothing is left in the staging folder.
            let staging = library.vaultStore.root.appendingPathComponent(".staging")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)

            // A relaunch (a new library on the same files) lists it and reopens it by id.
            model.close()
            let relaunched = VaultLibrary(storeURL: library.storeURL)
            #expect(relaunched.storedVaults.map(\.vaultId) == [entry.vaultId])
            let second = try Self.model()
            defer { second.close() }
            try await second.open(recent: try #require(relaunched.recents.first), library: relaunched)
            #expect(second.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
            #expect(second.phase == .locked)
            try await second.unlock(identityText: try #require(created.unlockKey))
            #expect(second.phase == .unlocked)
        }

        @Test func openVaultCopiesInAndOpensTheCopy() async throws {
            let (source, key) = try await ModelFixture.vault()
            let before = try Self.files(source)
            let library = try BrowserTests.library()
            let model = try Self.model()
            defer { model.close() }
            try await model.copyIn(picked: source, library: library)
            let entry = try #require(library.storedVaults.first)
            #expect(entry.name == "sample")
            #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
            #expect(model.phase == .locked)
            #expect(model.vaultCopy == nil)
            #expect(try Self.files(entry.url) == before)
            #expect(try Self.files(source) == before, "the picked folder is only read")
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            #expect(model.notes.contains { $0.id == ModelFixture.lecture })
            #expect(library.recents.first?.storeID == entry.vaultId)

            // The same vault again: not copied twice; its copy stays open as it was.
            try await model.copyIn(picked: source, library: library)
            #expect(model.phase == .unlocked)
            #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
            #expect(library.vaultStore.list().count == 1)
            // Another folder of the same vault (a pick of the folder holding it: VaultLocator), with no vault
            // open: the copy on this device opens.
            model.close()
            let (other, _) = try await ModelFixture.vault()
            try await model.copyIn(picked: other.deletingLastPathComponent(), library: library)
            #expect(model.vaultURL?.standardizedFileURL == entry.url.standardizedFileURL)
            #expect(model.phase == .locked)
            #expect(library.vaultStore.list().count == 1)
            #expect(library.recents.filter { $0.storeID == entry.vaultId }.count == 1)
        }

        @Test func anIncompleteVaultIsNotCopiedAndNothingChanges() async throws {
            let (source, _) = try await ModelFixture.vault()
            try FileManager.default.createDirectory(at: source.appendingPathComponent(".sempere-partial"),
                                                    withIntermediateDirectories: true)
            let library = try BrowserTests.library()
            let model = try Self.model()
            defer { model.close() }
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
            defer { model.close() }
            model.vaultStore = library.vaultStore
            let (source, _) = try await ModelFixture.vault()
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

        /// Removing a store vault from the device forgets its last place in the device's preferences too.
        @Test func removingAVaultForgetsItsLastPlace() async throws {
            let library = try BrowserTests.library()
            let model = try Self.model()
            defer { model.close() }
            model.vaultStore = library.vaultStore
            let other = try await library.create(NewVaultRequest(name: "Other", keySource: .generate, passphrase: nil))
            let entry = try #require(library.storedVaults.first { $0.url == other.url })
            LastPlace.save(RestorableSelection(sidebar: .allNotes, note: UUID(), vault: entry.vaultId, digest: { $0 }),
                           vault: entry.vaultId, in: model.deviceMemory)
            #expect(model.deviceMemory.string(forKey: LastPlace.key(entry.vaultId)) != nil)
            try await model.removeStoredVault(entry, library: library)
            #expect(model.deviceMemory.string(forKey: LastPlace.key(entry.vaultId)) == nil)
            #expect(library.storedVaults.isEmpty)
        }

        @Test func storeVaultsOpenFromTheListAndSortByUse() async throws {
            let library = try BrowserTests.library()
            _ = try await library.create(NewVaultRequest(name: "Beta", keySource: .generate, passphrase: nil))
            _ = try await library.create(NewVaultRequest(name: "Alpha", keySource: .generate, passphrase: nil))
            // The most recently created or opened first.
            #expect(library.storedVaultsByUse.map(\.name) == ["Alpha", "Beta"])
            let beta = try #require(library.storedVaults.first { $0.name == "Beta" })
            let model = try Self.model()
            defer { model.close() }
            try await model.openStored(beta, library: library)
            #expect(model.vaultURL?.standardizedFileURL == beta.url.standardizedFileURL)
            #expect(library.storedVaultsByUse.map(\.name) == ["Beta", "Alpha"])
            // Vaults never opened here (copied in by the CLI, say) come after, by name.
            let relaunched = VaultLibrary(storeURL: library.storeURL.deletingLastPathComponent().appendingPathComponent("other.json"),
                                          vaultStore: library.vaultStore)
            #expect(relaunched.storedVaultsByUse.map(\.name) == ["Alpha", "Beta"])
        }

        @Test func copyProgressReads() {
            var progress = VaultCopyProgress(name: "Notes", stage: .copying(done: 3, total: 12))
            #expect(progress.fraction == 0.25)
            progress.stage = .downloading(done: 0, total: 0)
            #expect(progress.fraction == nil)
        }

        /// Relative path → bytes of every regular file under `root` (hidden names skipped).
        static func files(_ root: URL) throws -> [String: Data] {
            let base = root.standardizedFileURL
            return try Dictionary(uniqueKeysWithValues: TS.regularFiles(under: base, skipHidden: true).map {
                ($0, try Data(contentsOf: base.appendingPathComponent($0)))
            })
        }

        /// Review of #28: a copy-in from a provider's folder (iCloud Drive) and a restore from one read the folder under
        /// a coordinated read of `services.files`, with the folder's URL (not the uncoordinated nil).
        @Test func aProviderCopyInAndARestoreAreCoordinatedThroughTheServices() async throws {
            let (source, _) = try await ModelFixture.vault()
            let files = RecordingFiles()
            var services = AppModelServices.headless()
            services.files = files
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: services)
            defer { model.close() }
            model.iCloudHooks = BackupTests.iCloudHooks()
            let library = try BrowserTests.library()
            try await model.copyIn(picked: source, library: library)
            #expect(files.read(source), "the copy-in: \(files.reads)")
            #expect(library.storedVaults.count == 1)

            let backup = source.deletingLastPathComponent().appendingPathComponent("Notes.sempere-backup", isDirectory: true)
            _ = try Backup.run(source: try Vault.open(at: source), to: backup)
            model.close()
            let found = try await model.previewRestore(from: backup)
            let before = files.reads.count
            // Into another device's store (this one already holds the vault).
            let outcome = try await model.restoreBackup(picked: backup, source: found.source, name: "Restored",
                                                        library: try BrowserTests.library())
            #expect(outcome.isComplete)
            #expect(files.reads.dropFirst(before).contains { $0.standardizedFileURL.path == found.source.standardizedFileURL.path },
                    "the restore: \(files.reads)")
            #expect(files.writes.isEmpty, "the picked folders are only read")
        }
    }
}
