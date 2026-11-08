import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// The two rules a target's run starts from (`AppModelCore.syncRunKeys`, the folder and WebDAV run closures of
    /// `AppModel+SyncTargets` and `AppModel+WebDAV`): two-way only for the open vault while it is unlocked and not
    /// stale (`syncVaultStale`, review of #70, F1), and a joining device's key while the open vault is locked.
    @MainActor
    struct SyncRunRuleTests {
        /// The fixture vault in a store of its own, with a folder target, open (locked) in a model.
        static func openStoreVault() async throws -> (model: AppModel, target: UUID, folder: URL, key: URL, note: UUID) {
            let (source, key) = try await ModelFixture.vault()
            let root = try TestTemp.directory("rule")
            let (store, entry, folder) = try await Self.store(root: root, source: source)
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), webdavLocations: WebDAVLocationStore(store: store))
            model.vaultStore = store
            model.folderArrivalWait = 0
            // As the folder picker hands it over: the picked folder is the scope, the vault's copy goes inside it.
            let target = try model.addFolderTarget(folder, scope: folder.deletingLastPathComponent(), to: entry.vaultId)
            try await model.openVault(at: entry.url)
            return (model, target.id, folder, key, ModelFixture.lecture)
        }

        @concurrent static func store(root: URL, source: URL) async throws -> (VaultStore, VaultStore.Entry, URL) {
            let store = VaultStore(root: root.appendingPathComponent("Vaults", isDirectory: true))
            let entry = try store.importVault(from: source)
            let folder = root.appendingPathComponent("Sync", isDirectory: true).appendingPathComponent("sample.sempere")
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (store, entry, folder)
        }

        @concurrent static func revisions(of note: UUID, in folder: URL) async throws -> Set<String> {
            Set(try VaultEnumeration.listNotes(vault: folder, only: [note]).first?.names ?? [])
        }

        @Test func onlyTheOpenUnlockedVaultAsTheDiskSaysRunsTwoWay() async throws {
            let (model, target, _, key, _) = try await Self.openStoreVault()
            #expect(model.syncSessions.contains { $0.locationID == target })
            #expect(model.syncRunKeys(for: target).vault == nil, "locked: upload-only")
            #expect(model.syncRunKeys(for: target).join == nil, "locked, not joining: no join key")

            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            #expect(model.syncRunKeys(for: target).vault?.vaultId == model.vault?.vaultId, "open and unlocked: two-way")
            #expect(model.syncRunKeys(for: UUID()).vault == nil, "another vault's target: upload-only")

            model.syncVaultStale = true
            #expect(model.syncRunKeys(for: target).vault == nil, "a reopen pending: upload-only")
            model.syncVaultStale = false
            #expect(model.syncRunKeys(for: target).vault != nil)

            model.close()
            #expect(model.syncRunKeys(for: target).vault == nil, "closed: upload-only")
        }

        @Test func aJoiningDevicesKeyGoesToTheLockedOpenVaultsRuns() async throws {
            let (model, target, _, _, _) = try await Self.openStoreVault()
            let joiner = try NativeIdentity.generate(.postQuantum)
            model.joinIdentity = joiner
            let keys = model.syncRunKeys(for: target)
            #expect(keys.vault == nil)
            #expect(keys.join?.recipient.string == joiner.recipient.string)
            #expect(model.syncRunKeys(for: UUID()).join == nil, "only the open vault's targets")
        }

        /// What another device wrote into the target is placed only by a two-way run: while `syncVaultStale` holds, a
        /// run uploads and places nothing; once it is cleared, the next run brings the revision in.
        @Test func aStaleOpenVaultsRunsPlaceNothing() async throws {
            let (model, target, folder, key, note) = try await Self.openStoreVault()
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            let session = try #require(model.syncSessions.first { $0.locationID == target })
            let first = await session.syncNow()   // the first two-way run makes the target's copy
            #expect(first?.errors.isEmpty == true, "\(String(describing: session.failure))")
            try await TS.writeAsAnotherDevice([.setMeta(.title("Renamed elsewhere"))], to: note, vault: folder, key: key)
            let local = try #require(model.vault).url
            let written = try await Self.revisions(of: note, in: folder)
                .subtracting(try await Self.revisions(of: note, in: local))
            #expect(written.count == 1)

            model.syncVaultStale = true
            _ = await session.syncNow()
            #expect(try await Self.revisions(of: note, in: local).isDisjoint(with: written), "upload-only while stale")

            model.syncVaultStale = false
            _ = await session.syncNow()
            #expect(try await Self.revisions(of: note, in: local).isSuperset(of: written), "two-way again")
        }
    }
}
