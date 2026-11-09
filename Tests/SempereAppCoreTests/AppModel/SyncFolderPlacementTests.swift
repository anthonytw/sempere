import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Owner's test of TestFlight build 10 (iPad): New Vault's Sync With and Sync Targets' Add Folder… listed
    /// "junk/Wompa.sempere", but the runs wrote the vault's files straight into "junk". The subfolder was lost when the
    /// target was added: `standardizedFileURL` drops `/private` from `/private/var/…` only for a path that exists, so the
    /// picked folder and the copy's folder inside it (not made yet) compared as unrelated (`AppModel.subfolder(of:in:)`).
    /// These run the real `FolderTargetRun` through the model's sessions.
    @MainActor
    struct SyncFolderPlacementTests {
        /// A device with its own store, device state and sync state (`FolderTargetTests.Device` in `SempereAppCoreTests`).
        struct Device {
            let model: AppModel
            let library: VaultLibrary
            @MainActor var store: VaultStore { library.vaultStore }
            @MainActor var vaultID: UUID { model.vault?.vaultId ?? UUID() }
            @MainActor var folder: URL { model.vaultURL ?? URL(fileURLWithPath: "/") }
        }

        static func device() -> Device {
            let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
            model.vaultStore = library.vaultStore
            model.webdavTick = .milliseconds(20)
            model.folderWriteDelay = 0.05
            model.folderArrivalWait = 0.5
            return Device(model: model, library: library)
        }

        /// The revision and blob files under `folder`'s `notes/`.
        static func noteFiles(_ folder: URL) -> Set<String> {
            let notes = folder.appendingPathComponent("notes")
            guard let e = FileManager.default.enumerator(atPath: notes.path) else { return [] }
            return Set(e.compactMap { $0 as? String }.filter {
                !($0 as NSString).lastPathComponent.hasPrefix(".") && $0.hasSuffix(".age")
            })
        }

        /// A store vault, unlocked, on a device of its own; and an empty folder the user picks, holding one file of theirs.
        static func setUp() async throws -> (Device, picked: URL) {
            let (vault, keyURL) = try AppModelTests.fixtureVault()
            let key = try String(contentsOf: keyURL, encoding: .utf8)
            let device = Self.device()
            try await device.model.copyIn(picked: vault, library: device.library)
            try await device.model.unlock(identityText: key)
            let picked = TestTemp.root.appendingPathComponent("junk-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: picked.appendingPathComponent("keep.txt"))
            return (device, picked)
        }

        static func listing(_ dir: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
        }

        /// The paths an iPhone or iPad hands over: the picked folder (which exists) standardizes to `/var/…`, the copy's
        /// folder inside it (not made yet) keeps `/private/var/…`. Both still compare as folder and subfolder.
        @Test func theSubfolderSurvivesPrivateVarPaths() {
            let picked = URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/junk", isDirectory: true)
            let copy = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/junk/Wompa.sempere",
                           isDirectory: true)
            #expect(AppModel.subfolder(of: copy, in: picked) == "Wompa.sempere")
            #expect(AppModel.subfolder(of: copy.deletingLastPathComponent(), in: picked) == nil)
            #expect(AppModel.samePlace(copy.deletingLastPathComponent(), picked))
            #expect(AppModel.subfolder(of: URL(fileURLWithPath: "/private/tmp/a/b"), in: URL(fileURLWithPath: "/tmp/a")) == "b")
            #expect(AppModel.subfolder(of: URL(fileURLWithPath: "/elsewhere/b"), in: picked) == nil)
            #expect(AppModel.subfolder(of: URL(fileURLWithPath: "/var/mobile/junkyard/x"), in: URL(fileURLWithPath: "/var/mobile/junk"))
                    == nil, "a sibling with a longer name is not inside")
        }

        /// A picked `.sempere` folder is the target itself; one holding other files and no vault is refused, an empty one
        /// is taken.
        @Test func aPickedSempereFolderIsTheTargetItself() async throws {
            let (device, picked) = try await Self.setUp()
            defer { device.model.close() }
            let name = device.folder.lastPathComponent
            let copy = picked.appendingPathComponent(name)
            let added = try device.model.addPickedFolderTarget(picked, to: device.vaultID)
            await device.model.syncAllTargetsNow()
            try await device.model.removeSyncTarget(added.id, of: device.vaultID)
            let itself = try device.model.addPickedFolderTarget(copy, to: device.vaultID)
            #expect(itself.subfolder == nil && itself.path == copy.standardizedFileURL.path)
            let stray = picked.deletingLastPathComponent().appendingPathComponent("Stray-\(UUID().uuidString).sempere")
            try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
            #expect(try AppModel.folderTargetLocation(picked: stray, vaultFolderName: name, vaultId: device.vaultID)
                    == stray)
            try Data("x".utf8).write(to: stray.appendingPathComponent("note.txt"))
            #expect(throws: SyncTargetProblem.notAVault(stray.lastPathComponent)) {
                try AppModel.folderTargetLocation(picked: stray, vaultFolderName: name, vaultId: device.vaultID)
            }
        }

        /// Join This Device needs a sync target: a store vault without one (a backup opened as a copy) does not offer it.
        @Test func joinNeedsASyncTarget() async throws {
            let (device, picked) = try await Self.setUp()
            defer { device.model.close() }
            #expect(device.model.openVaultTargets.isEmpty)
            #expect(!device.model.canJoinOpenVault)
            try device.model.addPickedFolderTarget(picked, to: device.vaultID)
            #expect(device.model.canJoinOpenVault)
        }
    }
}
