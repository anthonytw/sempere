import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Folder targets through the model (docs/design/device-first-sync.md §2, §3.3, §8.1; docs/io.md "Sync targets in
    /// the app"; moved from the app's `FolderTargetAppTests`): two devices, each with its own store, device state and
    /// sync state, sync through one folder for real (`FolderTargetRun`, the engine). The failure paths: a target folder
    /// deleted or unreachable, files a provider evicted while runs go, a provider's conflict copy, two targets bridged
    /// by one device, a target added to a vault that has notes, and a voice note recorded while the vault is closed. A
    /// moved target folder, which only the system's bookmarks follow, is `FolderTargetAppTests` in the app.
    @MainActor
    struct FolderTargetTests {
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
            /// Nil for a world of A alone (`world(withB: false)`), for the tests that never sync B.
            var b: Device!
        }

        /// A device of its own; its runs wait `arrivalWait` for files the provider is downloading (read when its
        /// sessions are made).
        static func device(_ provider: EvictingFolderProvider?, arrivalWait: TimeInterval = 0.5) -> Device {
            let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
            model.vaultStore = library.vaultStore
            model.webdavTick = .milliseconds(20)
            model.folderWriteDelay = 0.05
            model.folderArrivalWait = arrivalWait
            if let provider { model.folderProvider = { _ in provider } }
            return Device(model: model, library: library)
        }

        /// A copies the fixture vault in and keeps a copy in a shared folder; B opens that folder with "Keep
        /// syncing with this folder". Both unlocked and in step. Without B (`withB: false`) only A's half is made, for
        /// the tests about A's own target (Linux time, review of #28). The models are closed here if setting up throws.
        static func world(withB: Bool = true, arrivalWait: TimeInterval = 0.5) async throws -> World {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
            let provider = EvictingFolderProvider(root: shared, cloud: drive.appendingPathComponent(".cloud"))
            let a = device(provider, arrivalWait: arrivalWait)
            var b: Device?
            do {
                try await a.model.copyIn(picked: vault, library: a.library)
                try await a.model.unlock(identityText: key)
                try a.model.addFolderTarget(shared, scope: drive, to: a.vaultID)
                #expect(a.model.syncSessions.count == 1)
                #expect(a.model.openVaultTargets.first?.subfolder == "Shared.sempere")
                await a.model.syncAllTargetsNow()
                let folder = shared
                #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vault.json").path))
                if withB {
                    let made = device(provider, arrivalWait: arrivalWait)
                    b = made
                    try await made.model.copyIn(picked: folder, library: made.library, followUp: .keepSyncing)
                    try await made.model.unlock(identityText: key)
                    #expect(made.model.openVaultTargets.count == 1)
                }
                let w = World(key: key, shared: folder, provider: provider, a: a, b: b)
                if withB { try await settle(w) }
                return w
            } catch {
                a.model.close()
                b?.model.close()
                throw error
            }
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

        /// A quick capture on the fake recorder (`CaptureTestKit.swift`), in folders of its own.
        static func quickCapture() -> QuickCapture {
            let clock = CaptureClock(), sleeper = ManualSleeper()
            let audio = FakeAudio(clock: clock)
            let qc = QuickCapture(store: MemoryCaptureProfileStore(), audio: audio, audioFiles: FakeAudioFiles(),
                                  liveActivity: FakeLiveActivity(audio: audio), app: FakeApp(),
                                  root: CaptureFixture.temp("qc-root"), queueRoot: CaptureFixture.temp("qc-queue"))
            qc.now = { clock.now }
            qc.sleep = { await sleeper.sleep($0) }
            qc.showsActivity = false
            return qc
        }

        // MARK: Two devices

        /// A note made on one device reaches the other's list through the folder, and a rename reaches the
        /// first one's open editor in place.
        @Test func notesTravelBetweenTwoDevicesThroughAFolder() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            #expect(Self.noteFiles(w.a.folder) == Self.noteFiles(w.b.folder))
            let note = try await w.a.model.createNote(title: "From A", paper: .ruled, notebook: nil)
            await w.a.model.syncAllTargetsNow()
            await w.b.model.syncAllTargetsNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.contains { $0.id == note && $0.title == "From A" } })

            w.a.model.selectedNoteID = note
            try await w.a.model.openEditor(for: note)
            let editor = try #require(w.a.model.editor)
            try await w.b.model.renameNote(note, to: "Renamed on B")
            await w.b.model.syncAllTargetsNow()
            await w.a.model.syncAllTargetsNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { editor.meta.title == "Renamed on B" })
            #expect(w.a.model.editor === editor, "merged in place")
            try await Self.settle(w)
            #expect(Self.noteFiles(w.a.folder) == Self.noteFiles(w.b.folder))
            #expect(Self.noteFiles(w.shared) == Self.noteFiles(w.a.folder))
        }

        // MARK: Failures

        /// The target folder deleted after it was synced: the run says so ("choose it again"), recreates
        /// nothing and deletes nothing here. Its parent gone too (a drive not connected): offline, not an error.
        @Test func aTargetFolderDeletedOrUnavailable() async throws {
            let w = try await Self.world(withB: false)
            defer { w.a.model.close() }
            let before = Self.noteFiles(w.a.folder)
            try FileManager.default.removeItem(at: w.shared)
            let session = try #require(w.a.model.syncSessions.first)
            await session.syncNow()
            #expect(session.status.kind == .problem(.notFound))
            #expect(!FileManager.default.fileExists(atPath: w.shared.path))
            #expect(Self.noteFiles(w.a.folder) == before)
            // The folder the user picked gone too: its saved permission no longer opens anything, so the user
            // chooses the folder again (review of #72, G5), never "unavailable" for ever.
            try FileManager.default.removeItem(at: w.shared.deletingLastPathComponent())
            await session.syncNow()
            #expect(session.status.kind == .problem(.notFound))
            #expect(Self.noteFiles(w.a.folder) == before)
            // Choose Again: a new folder; the run starts over as a union and fills it.
            let elsewhere = TestTemp.root.appendingPathComponent("again-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let target = try #require(w.a.model.openVaultTargets.first)
            try w.a.model.rechooseFolderTarget(target.id, of: w.a.vaultID, picked: elsewhere)
            let refreshed = try #require(w.a.model.syncSessions.first)
            await refreshed.syncNow()
            #expect(!refreshed.needsAttention, "\(refreshed.status)")
            let copy = elsewhere.appendingPathComponent(w.a.folder.lastPathComponent)
            #expect(Self.noteFiles(copy) == before)
        }

        /// Files the provider evicted are arriving, never missing: the run asks for them and says they are on
        /// their way, quarantines nothing and deletes nothing; a later run takes them.
        @Test func evictedFilesArriveLater() async throws {
            let w = try await Self.world(arrivalWait: 0.1)   // the evicted files never arrive within a run: wait less for them
            defer { w.a.model.close(); w.b.model.close() }
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
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.contains { $0.id == note } })
        }

        /// Review of #115 (F1): the target folder iCloud Drive holds as a package (earlier builds), evicted whole on this
        /// device (Files ▸ "Remove Download": only `.Shared.sempere.icloud` is left). The run asks for it and says it is on
        /// its way, writes nothing and makes no folder (an empty one beside the package would be a split copy of the
        /// vault); once it is back, the next run syncs what was written meanwhile, into the one copy.
        @Test func aTargetEvictedWholeArrivesAndIsNeverSplit() async throws {
            let w = try await Self.world(arrivalWait: 0.1)   // the package never arrives within a run: wait less for it
            defer { w.a.model.close(); w.b.model.close() }
            w.provider.arrivalDelay = 100_000
            try w.provider.evictFolder("", as: .standIn)
            let note = try await w.a.model.createNote(title: "While evicted", paper: .ruled, notebook: nil)
            let session = try #require(w.a.model.syncSessions.first)
            let report = try #require(await session.syncNow())
            #expect(report.arriving.map(\.path) == ["/"], "\(report)")
            #expect(report.uploaded.isEmpty && report.errors.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: w.shared.path), "no folder made beside the package")
            #expect(session.arriving > 0)
            #expect(!session.needsAttention, "\(session.status)")
            #expect(w.provider.requested.contains(""), "the package was asked for")
            // Downloaded again: the next run syncs by itself, into the one copy.
            w.provider.arrivalDelay = 0
            let healed = try #require(await session.syncNow())
            #expect(healed.arriving.isEmpty, "\(healed)")
            #expect(!session.needsAttention, "\(session.status)")
            #expect(Self.noteFiles(w.shared).contains { $0.hasPrefix(note.uuidString.lowercased()) })
            #expect(w.provider.splitCopy(of: "") == nil)
        }

        /// Review of #119 (1): a re-encryption opens its targets through the runs' rule, so a target folder synced before
        /// and deleted is refused there and never made again by the claim.
        @Test func aReencryptionNeverMakesADeletedTargetAgain() async throws {
            let w = try await Self.world(withB: false)
            defer { w.a.model.close() }
            try FileManager.default.removeItem(at: w.shared)
            await #expect(throws: (any Error).self) { _ = try await w.a.model.openReencryptTargets(requireAll: true) }
            let open = try await w.a.model.openReencryptTargets(requireAll: false)
            #expect(open.targets.isEmpty)
            open.close()
            #expect(!FileManager.default.fileExists(atPath: w.shared.path))
        }

        /// A conflict copy the provider made of `vault.json` (the same bytes, as iCloud makes after an
        /// offline edit on two devices) is resolved: no version is left, no conflict reported.
        @Test func aProvidersConflictCopyIsResolved() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let manifest = try Data(contentsOf: w.shared.appendingPathComponent("vault.json"))
            _ = try w.provider.addConflict("vault.json", manifest)
            let session = try #require(w.a.model.syncSessions.first)
            let report = try #require(await session.syncNow())
            #expect(report.conflicts.isEmpty)
            #expect(w.provider.versions(of: "vault.json").isEmpty)
            #expect(!session.needsAttention)
        }

        // MARK: Several targets

        /// One device with two targets bridges them, and a target added to a vault with notes gets all of
        /// them (a union; nothing is deleted on either side).
        @Test func twoTargetsAreBridgedAndANewTargetGetsEveryNote() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
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
            defer { c.model.close() }
            try await c.model.copyIn(picked: second, library: c.library, followUp: .keepSyncing)
            try await c.model.unlock(identityText: w.key)
            let fromB = try await w.b.model.createNote(title: "From B", paper: .ruled, notebook: nil)
            await w.b.model.syncAllTargetsNow()
            await w.a.model.syncAllTargetsNow()
            await w.a.model.syncAllTargetsNow()
            await c.model.syncAllTargetsNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { c.model.notes.contains { $0.id == fromB } })
            // Removing a target leaves its folder alone.
            let target = try #require(w.a.model.openVaultTargets.last)
            try await w.a.model.removeSyncTarget(target.id, of: w.a.vaultID)
            #expect(w.a.model.syncSessions.count == 1)
            #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("vault.json").path))
        }

        // MARK: Quick capture

        /// A voice note recorded while its vault is closed goes into the vault's in-app inbox (found by id), and the vault's target uploads it at once (upload-only).
        @Test func aCaptureWhileTheVaultIsClosedIsUploaded() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let vault = try #require(w.b.model.vault)
            let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
            let qc = Self.quickCapture()
            try qc.store.save(StoredCaptureProfile(profile: profile, vaultName: "Shared", transcribe: false))
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
            #expect(await TS.waitUntil(timeout: .seconds(30)) {
                FileManager.default.fileExists(atPath: w.shared.appendingPathComponent("inbox/\(name)").path)
            }, "\(String(describing: session.lastReport)) \(session.failure ?? "") twoWay=\(session.twoWay)")
            // The open device takes it from the folder.
            await w.a.model.syncAllTargetsNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) {
                FileManager.default.fileExists(atPath: w.a.folder.appendingPathComponent("inbox/\(name)").path)
                    || w.a.model.notes.contains { $0.title.hasPrefix("Voice note") }
            })
        }

        /// P8b (design §4.1): while B's vault is closed, a background run stages what A wrote in B's target's
        /// state folder and never places it in B's copy; B's unlock checks and places it, and the note is listed.
        @Test func aClosedVaultStagesWhatArrivesAndTheUnlockPlacesIt() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let bID = w.b.vaultID, bFolder = w.b.folder
            let coordinator = w.b.model.syncCoordinator
            coordinator.start()   // every vault syncs, as in the app
            w.b.model.close()
            await w.b.model.closingEditor?.value

            let note = try await w.a.model.createNote(title: "While B was closed", paper: .ruled, notebook: nil)
            await w.a.model.syncAllTargetsNow()
            let before = Self.noteFiles(bFolder)
            let session = try #require(coordinator.sessions(of: bID).first)
            let target = try #require(w.b.store.targets.targets(of: bID).first)
            let staging = LockedStaging(targetState: w.b.store.targets.stateURL(target.id, of: bID))
            _ = await session.runInBackground(maxDuration: 30, cancel: SyncRunCancel())   // a background task stages
            #expect(Self.noteFiles(bFolder) == before, "nothing is placed in a vault nobody unlocked")
            #expect(staging.exists)
            #expect(session.staged > 0)
            #expect(session.status.kind == .waitingForUnlock)

            let entry = try #require(w.b.store.entry(id: bID))
            try await w.b.model.openStored(entry, library: w.b.library)
            try await w.b.model.unlock(identityText: w.key)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.contains { $0.id == note } })
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !staging.exists }, "placed, and the staging is gone")
            #expect(Self.noteFiles(w.b.folder).isSuperset(of: Self.noteFiles(w.a.folder)))
        }
    }
}
