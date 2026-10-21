import Age
import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp

/// Folder targets in the app (docs/design/device-first-sync.md §2, §3.3, §8.1; docs/io.md "Sync targets in
/// the app"): two devices, each with its own store, device state and sync state, sync through one folder
/// for real (`FolderTargetRun`, the engine). The failure paths: a target folder deleted or unreachable,
/// files a provider evicted while runs go, a provider's conflict copy, two targets bridged by one device,
/// a target added to a vault that has notes, and a voice note recorded while the vault is closed.
@MainActor
struct FolderTargetAppTests {
    struct Device {
        let model: AppModel
        let library: VaultLibrary
        @MainActor var store: VaultStore { library.vaultStore }
        @MainActor var vaultID: UUID { model.vault?.vaultId ?? UUID() }
        @MainActor var folder: URL { model.vaultURL ?? URL(fileURLWithPath: "/") }
    }

    struct World {
        let key: String
        let shared: URL
        let provider: EvictingFolderProvider
        var a: Device
        var b: Device
    }

    static func device(_ provider: EvictingFolderProvider?) -> Device {
        let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.vaultStore = library.vaultStore
        model.webdavTick = .milliseconds(20)
        model.folderWriteDelay = 0.05
        model.folderArrivalWait = 0.5
        if let provider { model.folderProvider = { _ in provider } }
        return Device(model: model, library: library)
    }

    /// A copies the fixture vault in and keeps a copy in a shared folder; B opens that folder with "Keep
    /// syncing with this folder". Both unlocked and in step.
    static func world() async throws -> World {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
        let provider = EvictingFolderProvider(root: shared, cloud: drive.appendingPathComponent(".cloud"))
        let a = device(provider)
        try await a.model.copyIn(picked: vault, library: a.library)
        try await a.model.unlock(identityText: key)
        try a.model.addFolderTarget(shared, scope: drive, to: a.vaultID)
        #expect(a.model.syncSessions.count == 1)
        #expect(a.model.openVaultTargets.first?.subfolder == "Shared.sempere")
        await a.model.syncAllTargetsNow()
        let folder = shared
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vault.json").path))

        let b = device(provider)
        try await b.model.copyIn(picked: folder, library: b.library, followUp: .keepSyncing)
        try await b.model.unlock(identityText: key)
        #expect(b.model.openVaultTargets.count == 1)
        let w = World(key: key, shared: folder, provider: provider, a: a, b: b)
        try await settle(w)
        return w
    }

    static func settle(_ w: World, rounds: Int = 6) async throws {
        for _ in 0..<rounds {
            let x = await w.a.model.syncSessions.first?.syncNow(), y = await w.b.model.syncSessions.first?.syncNow()
            if x?.isEmpty == true, y?.isEmpty == true { return }
        }
    }

    static func noteFiles(_ folder: URL) -> Set<String> {
        let notes = folder.appendingPathComponent("notes")
        guard let e = FileManager.default.enumerator(atPath: notes.path) else { return [] }
        return Set(e.compactMap { $0 as? String }.filter {
            !($0 as NSString).lastPathComponent.hasPrefix(".") && $0.hasSuffix(".age")
        })
    }

    // MARK: Two devices

    /// A note made on one device reaches the other's list through the folder, and a rename reaches the
    /// first one's open editor in place.
    @Test func notesTravelBetweenTwoDevicesThroughAFolder() async throws {
        let w = try await Self.world()
        #expect(Self.noteFiles(w.a.folder) == Self.noteFiles(w.b.folder))
        let note = try await w.a.model.createNote(title: "From A", paper: .ruled, notebook: nil)
        await w.a.model.syncAllTargetsNow()
        await w.b.model.syncAllTargetsNow()
        #expect(await TS.waitUntil { w.b.model.notes.contains { $0.id == note && $0.title == "From A" } })

        w.a.model.selectedNoteID = note
        try await w.a.model.openEditor(for: note)
        let editor = try #require(w.a.model.editor)
        try await w.b.model.renameNote(note, to: "Renamed on B")
        await w.b.model.syncAllTargetsNow()
        await w.a.model.syncAllTargetsNow()
        #expect(await TS.waitUntil { editor.meta.title == "Renamed on B" })
        #expect(w.a.model.editor === editor, "merged in place")
        try await Self.settle(w)
        #expect(Self.noteFiles(w.a.folder) == Self.noteFiles(w.b.folder))
        #expect(Self.noteFiles(w.shared) == Self.noteFiles(w.a.folder))
        w.a.model.close(); w.b.model.close()
    }

    // MARK: Failures

    /// The target folder deleted after it was synced: the run says so ("choose it again"), recreates
    /// nothing and deletes nothing here. Its parent gone too (a drive not connected): offline, not an error.
    @Test func aTargetFolderDeletedOrUnavailable() async throws {
        let w = try await Self.world()
        let before = Self.noteFiles(w.a.folder)
        try FileManager.default.removeItem(at: w.shared)
        let session = try #require(w.a.model.syncSessions.first)
        await session.syncNow()
        #expect(session.status.kind == .problem(.notFound))
        #expect(session.headline.contains("folder is gone"))
        #expect(!FileManager.default.fileExists(atPath: w.shared.path))
        #expect(Self.noteFiles(w.a.folder) == before)
        try FileManager.default.removeItem(at: w.shared.deletingLastPathComponent())
        await session.syncNow()
        #expect(session.status.kind == .offline)
        #expect(session.headline.contains("cannot be reached"))
        #expect(Self.noteFiles(w.a.folder) == before)
        w.a.model.close(); w.b.model.close()
    }

    /// Files the provider evicted are arriving, never missing: the run asks for them and says they are on
    /// their way, quarantines nothing and deletes nothing; a later run takes them.
    @Test func evictedFilesArriveLater() async throws {
        let w = try await Self.world()
        let note = try await w.a.model.createNote(title: "Evicted", paper: .ruled, notebook: nil)
        await w.a.model.syncAllTargetsNow()
        let names = Self.noteFiles(w.shared).filter { $0.hasPrefix(note.uuidString.lowercased()) }
        #expect(!names.isEmpty)
        w.provider.arrivalDelay = 100_000
        for name in names { try w.provider.evict("notes/\(name)", as: .dataless) }
        let session = try #require(w.b.model.syncSessions.first)
        let report = try #require(await session.syncNow())
        #expect(!report.arriving.isEmpty)
        #expect(report.quarantined.isEmpty && report.deleted.isEmpty)
        #expect(session.arriving > 0)
        #expect(!session.needsAttention)
        #expect(!w.b.model.notes.contains { $0.id == note })
        w.provider.arrivalDelay = 0
        await session.syncNow()
        #expect(await TS.waitUntil { w.b.model.notes.contains { $0.id == note } })
        w.a.model.close(); w.b.model.close()
    }

    /// A conflict copy the provider made of `vault.json` (the same bytes, as iCloud makes after an
    /// offline edit on two devices) is resolved: no version is left, no conflict reported.
    @Test func aProvidersConflictCopyIsResolved() async throws {
        let w = try await Self.world()
        let manifest = try Data(contentsOf: w.shared.appendingPathComponent("vault.json"))
        _ = try w.provider.addConflict("vault.json", manifest)
        let session = try #require(w.a.model.syncSessions.first)
        let report = try #require(await session.syncNow())
        #expect(report.conflicts.isEmpty)
        #expect(w.provider.versions(of: "vault.json").isEmpty)
        #expect(!session.needsAttention)
        w.a.model.close(); w.b.model.close()
    }

    // MARK: Several targets

    /// One device with two targets bridges them, and a target added to a vault with notes gets all of
    /// them (a union; nothing is deleted on either side).
    @Test func twoTargetsAreBridgedAndANewTargetGetsEveryNote() async throws {
        let w = try await Self.world()
        let second = TestTemp.root.appendingPathComponent("usb-\(UUID().uuidString)/Shared.sempere", isDirectory: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try w.a.model.addFolderTarget(second, scope: second.deletingLastPathComponent(), to: w.a.vaultID)
        #expect(w.a.model.syncSessions.count == 2)
        await w.a.model.syncAllTargetsNow()
        #expect(Self.noteFiles(second) == Self.noteFiles(w.a.folder))
        // The same folder again is refused.
        #expect(throws: SyncTargetProblem.duplicate) {
            try w.a.model.addFolderTarget(second, scope: second.deletingLastPathComponent(), to: w.a.vaultID)
        }
        // A third device on the second folder only; B on the first only. A bridges them.
        let c = Self.device(nil)
        try await c.model.copyIn(picked: second, library: c.library, followUp: .keepSyncing)
        try await c.model.unlock(identityText: w.key)
        let fromB = try await w.b.model.createNote(title: "From B", paper: .ruled, notebook: nil)
        await w.b.model.syncAllTargetsNow()
        await w.a.model.syncAllTargetsNow()
        await w.a.model.syncAllTargetsNow()
        await c.model.syncAllTargetsNow()
        #expect(await TS.waitUntil { c.model.notes.contains { $0.id == fromB } })
        // Removing a target leaves its folder alone.
        let target = try #require(w.a.model.openVaultTargets.last)
        try await w.a.model.removeSyncTarget(target.id, of: w.a.vaultID)
        #expect(w.a.model.syncSessions.count == 1)
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("vault.json").path))
        w.a.model.close(); w.b.model.close(); c.model.close()
    }

    // MARK: Quick capture

    /// A voice note recorded while its vault is closed goes into the vault's in-app inbox (found by id,
    /// whatever the profile's bookmark says), and the vault's target uploads it at once (upload-only).
    @Test func aCaptureWhileTheVaultIsClosedIsUploaded() async throws {
        let w = try await Self.world()
        let vault = try #require(w.b.model.vault)
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        try qc.store.save(StoredCaptureProfile(profile: profile, vaultName: "Shared", bookmark: Data(), transcribe: false))
        qc.backend = { FakeCapture() }
        qc.microphoneAllowed = { true }
        qc.transcriber = nil
        qc.root = TestTemp.root.appendingPathComponent("qc-\(UUID().uuidString)", isDirectory: true)
        qc.queueRoot = TestTemp.root.appendingPathComponent("qcq-\(UUID().uuidString)", isDirectory: true)
        qc.center = NotificationCenter()
        qc.showsActivity = false
        qc.vaultStore = w.b.store
        let coordinator = w.b.model.syncCoordinator
        coordinator.start()   // every vault syncs, as in the app
        w.b.model.close()

        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        let name = CaptureFile.name(outcome.id, .capture)
        let entry = try #require(w.b.store.entry(id: profile.vaultId))
        #expect(FileManager.default.fileExists(atPath: entry.url.appendingPathComponent("inbox/\(name)").path))
        let session = try #require(coordinator.sessions(of: profile.vaultId).first)
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: w.shared.appendingPathComponent("inbox/\(name)").path)
        }, "\(String(describing: session.lastReport)) \(session.failure ?? "") twoWay=\(session.twoWay)")
        // The open device takes it from the folder.
        await w.a.model.syncAllTargetsNow()
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: w.a.folder.appendingPathComponent("inbox/\(name)").path)
                || w.a.model.notes.contains { $0.title.hasPrefix("Voice note") }
        })
        w.a.model.close()
    }

    // MARK: Store

    /// WebDAV vaults of earlier builds become store vaults with a WebDAV target; their sync state and
    /// quarantine move with them (no re-upload, no re-check), the Keychain id is kept.
    @Test func legacyWebDAVCopiesBecomeStoreVaults() throws {
        let (vault, _) = try AppModelTests.fixtureVault()
        let root = TestTemp.root.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("WebDAV", isDirectory: true)
        let id = UUID()
        let dir = legacy.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: vault, to: dir.appendingPathComponent("Shared.sempere"))
        try Data("{\"version\":1}".utf8).write(to: dir.appendingPathComponent("sync-state.json"))
        let quarantine = dir.appendingPathComponent("sync-state.quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: quarantine.appendingPathComponent("x.age"))
        let vaultId = try Vault.open(at: vault).vaultId
        let list: [[String: Any]] = [["id": id.uuidString, "url": "https://dav.example.org/shared/", "vaultId": vaultId.uuidString,
                                      "name": "Shared", "folderName": "Shared.sempere", "downloaded": true]]
        let listURL = root.appendingPathComponent("webdav.json")
        try JSONSerialization.data(withJSONObject: list).write(to: listURL)
        let store = VaultStore(root: root.appendingPathComponent("Vaults", isDirectory: true))

        let converted = LegacyWebDAV.convert(list: listURL, root: legacy, store: store)
        #expect(converted == [id: vaultId])
        let entry = try #require(store.entry(id: vaultId))
        #expect(entry.name == "Shared")
        let target = try #require(store.targets.targets(of: vaultId).first)
        #expect(target.id == id && target.kind == .webdav && target.joined == true)
        let state = store.targets.stateDirectory(id, of: vaultId)
        #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("sync-state.json").path))
        #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("sync-state.quarantine/x.age").path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!FileManager.default.fileExists(atPath: listURL.path))
        // The WebDAV code sees it as a location whose copy is the store vault.
        let locations = WebDAVLocationStore(store: store)
        let location = try #require(locations.location(id))
        #expect(locations.copy(of: location).folder.standardizedFileURL == entry.url.standardizedFileURL)
        #expect(locations.copy(of: location).stateURL.standardizedFileURL
                == state.appendingPathComponent("sync-state.json").standardizedFileURL)
    }

    /// An earlier build's store moves into the App Group container once; a failed move keeps it in use.
    @Test func theStoreMovesIntoTheAppGroup() throws {
        let root = TestTemp.root.appendingPathComponent("group-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("AppSupport/Vaults", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("x"), withIntermediateDirectories: true)
        let group = root.appendingPathComponent("Group", isDirectory: true)
        let moved = VaultStoreRoot.prepare(appGroup: group, legacy: legacy)
        #expect(moved.path.hasSuffix("Group/Library/Application Support/Sempere/Vaults"))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("x").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(VaultStoreRoot.prepare(appGroup: nil, legacy: legacy) == legacy)
    }
}
