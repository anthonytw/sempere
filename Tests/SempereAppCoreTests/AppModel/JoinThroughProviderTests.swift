import Foundation
import Sempere
import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// A join through a folder target that a provider holds, through the model (build 11, syncjoin-mac/ipad/iphone: "after
    /// entering the words it continued to say there was no device trying to join"; moved from the app's
    /// `JoinThroughProviderTests`, which keeps Add Device's sheet model, `AddDeviceApproval`, and the words): the new
    /// device's request reaches the sync folder only once a run and the provider's upload carried it, and home's copy only
    /// once its provider delivered it and a run took it. Simulated with `EvictingFolderProvider` (no iCloud in tests): a
    /// request the provider listed as a stand-in and delivers late.
    @MainActor
    struct JoinThroughProviderTests {
        /// Whether the simulated provider has uploaded what the runs wrote (the session reads it at each run).
        final class Uploads: @unchecked Sendable {
            private let lock = NSLock()
            private var _done = false
            var done: Bool {
                get { lock.withLock { _done } }
                set { lock.withLock { _done = newValue } }
            }
        }

        /// A new device as `FolderTargetTests.device` makes one, with a trust store: it confirms its join with the reply.
        static func joiningDevice(_ provider: EvictingFolderProvider) -> FolderTargetTests.Device {
            let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: MemoryEpochTrustStore())
            model.vaultStore = library.vaultStore
            model.webdavTick = .milliseconds(20)
            model.folderWriteDelay = 0.05
            model.folderArrivalWait = 0.5
            model.folderProvider = { _ in provider }
            model.deviceMemory = MemoryKeyValueStore()
            return FolderTargetTests.Device(model: model, library: library)
        }

        @Test func addDeviceWaitsForARequestTheProviderDeliversLate() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
            let provider = EvictingFolderProvider(root: shared, cloud: drive.appendingPathComponent(".cloud"))

            // Home (the Mac): the vault, unlocked with its device key, synced into the shared folder.
            let home = FolderTargetTests.device(provider)
            defer { home.model.close() }
            home.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            home.model.deviceMemory = MemoryKeyValueStore()
            try await home.model.copyIn(picked: vault, library: home.library)
            _ = try await home.model.unlock(identityText: key)
            try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
            await home.model.syncAllTargetsNow()

            // The iPad opens the shared folder, keeps syncing with it and asks to join.
            let pad = Self.joiningDevice(provider)
            defer { pad.model.close() }
            let uploads = Uploads()   // its provider has not uploaded what the runs wrote yet
            pad.model.providerUploadCheck = { _ in uploads.done ? .uploaded : .waiting }
            try await pad.model.copyIn(picked: shared, library: pad.library, followUp: .keepSyncing)
            #expect(pad.model.phase == .locked)
            let padKeys = RememberedKeys(store: MemoryDeviceKeyStore())
            guard case .waiting(let words, _) = try await pad.model.startJoin(store: padKeys.store) else {
                Issue.record("not waiting")
                return
            }
            await pad.model.syncAllTargetsNow()
            let joins = shared.appendingPathComponent("joins")
            let request = try #require(try FileManager.default.contentsOfDirectory(atPath: joins.path).first { $0.hasSuffix(".join.json") })
            // The join screen says the provider still has to upload it, not only "waiting for the approval".
            #expect(pad.model.joinDelivery == .waitingForUpload(iCloud: false))
            uploads.done = true
            await pad.model.syncAllTargetsNow()
            #expect(pad.model.joinDelivery == .sent)

            // On home's side the provider has listed the request (a stand-in) but delivers it only much later.
            try provider.evict("joins/\(request)", as: .standIn)
            provider.arrivalDelay = 1_000_000_000
            #expect(await home.model.pendingJoinRequests().isEmpty, "not in home's copy yet")
            // Approving syncs first, and says the request is on its way rather than that no device asked.
            await #expect(throws: DeviceJoinError.requestArriving) {
                _ = try await home.model.approveDevice(words: words, qr: nil)
            }
            var look = await home.model.lookForJoinRequests()
            #expect(look.requests.isEmpty)
            #expect(look.arriving)
            #expect(await home.model.hasJoinRequest(words: words, qr: nil) == false)

            // Delivered: the next look finds it (the sheet then approves the words typed before).
            provider.arrivalDelay = 0
            look = await home.model.lookForJoinRequests()
            #expect(look.requests.count == 1)
            #expect(!look.arriving)
            #expect(await home.model.hasJoinRequest(words: words, qr: nil))
            let reply = try await home.model.approveDevice(words: words, qr: nil)
            #expect(home.model.vault?.devices.count == 2)

            // The approval travels back; the iPad confirms with the reply and unlocks.
            await home.model.syncAllTargetsNow()
            await pad.model.syncAllTargetsNow()
            await pad.model.refreshLockedManifest()
            #expect({ if case .joining = $0 { true } else { false } }(await padKeys.unlockWithDeviceKey(pad.model)))
            #expect(padKeys.joinStage == .confirming, "\(String(describing: pad.model.syncSessions.first?.lastReport))")
            let device = try await padKeys.store.keys(for: try #require(pad.model.vault?.vaultId), reason: .unlock(vaultName: nil))
            try await pad.model.confirmJoin(words: reply.words, keys: device)
            #expect(pad.model.phase == .unlocked)
        }

        /// Words typed for a request nobody made, with nothing arriving: the old answer, in words that say requests can
        /// be late.
        @Test func wordsOfNoRequestAreRefusedAfterASync() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
            let home = FolderTargetTests.device(nil)
            defer { home.model.close() }
            home.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            try await home.model.copyIn(picked: vault, library: home.library)
            _ = try await home.model.unlock(identityText: key)
            try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
            await #expect(throws: DeviceJoinError.requestNotArrived) {
                _ = try await home.model.approveDevice(words: ["abandon", "ability", "able", "about", "above", "absent"], qr: nil)
            }
            #expect(home.model.syncSessions.first?.lastReport != nil, "it synced before saying so")
            let look = await home.model.lookForJoinRequests()
            #expect(look.requests.isEmpty && !look.arriving)
        }

        /// Home and an iPad that asked to join; on home's side the request is a stand-in the provider has not delivered.
        struct Asked {
            let home: FolderTargetTests.Device
            let pad: FolderTargetTests.Device
            let provider: EvictingFolderProvider
            let words: [String]
        }

        static func asked() async throws -> Asked {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
            let provider = EvictingFolderProvider(root: shared, cloud: drive.appendingPathComponent(".cloud"))
            let home = FolderTargetTests.device(provider)
            let pad = Self.joiningDevice(provider)
            do {
                home.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
                home.model.deviceMemory = MemoryKeyValueStore()
                try await home.model.copyIn(picked: vault, library: home.library)
                _ = try await home.model.unlock(identityText: key)
                try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
                await home.model.syncAllTargetsNow()
                try await pad.model.copyIn(picked: shared, library: pad.library, followUp: .keepSyncing)
                guard case .waiting(let words, _) = try await pad.model.startJoin(store: MemoryDeviceKeyStore()) else {
                    throw CancellationError()
                }
                await pad.model.syncAllTargetsNow()
                let joins = shared.appendingPathComponent("joins")
                let request = try #require(try FileManager.default.contentsOfDirectory(atPath: joins.path).first { $0.hasSuffix(".join.json") })
                try provider.evict("joins/\(request)", as: .standIn)
                provider.arrivalDelay = 1_000_000_000
                return Asked(home: home, pad: pad, provider: provider, words: words)
            } catch {
                home.model.close()   // the caller's `defer` never runs for models it did not get
                pad.model.close()
                throw error
            }
        }

        static func targetRequests(_ w: Asked) -> [String] {
            let joins = w.provider.root.appendingPathComponent("joins")
            return ((try? FileManager.default.contentsOfDirectory(atPath: joins.path)) ?? [])
                .filter { Vault.isJoinRequestName($0) || $0.hasSuffix(".join.json.icloud") }
        }

        /// The joining device withdraws its request when it cancels, and a new Ask to Join replaces its earlier request
        /// rather than leaving it for home.
        @Test func aJoiningDeviceWithdrawsItsRequest() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.provider.arrivalDelay = 0
            _ = await w.home.model.lookForJoinRequests()   // delivered: the request is a plain file on the target again
            let first = try #require(w.pad.model.joinRequestedFile(w.pad.vaultID))
            #expect(Self.targetRequests(w).contains { $0.contains(first.prefix(8)) })
            let store = MemoryDeviceKeyStore()
            // Asked again (the first join screen was closed without Cancel): the earlier request goes.
            _ = try await w.pad.model.startJoin(store: store)
            let second = try #require(w.pad.model.joinRequestedFile(w.pad.vaultID))
            #expect(second != first)
            await w.pad.model.syncAllTargetsNow()
            #expect(!Self.targetRequests(w).contains { $0.contains(first.prefix(8)) }, "\(Self.targetRequests(w)) \(String(describing: w.pad.model.syncSessions.first?.lastReport))")
            #expect(Self.targetRequests(w).contains(second))
            // Cancel withdraws it, on the target too.
            await w.pad.model.cancelJoin(store: store)
            await w.pad.model.syncAllTargetsNow()
            #expect(Self.targetRequests(w).isEmpty,
                    "\(Self.targetRequests(w)) \(String(describing: w.pad.model.syncSessions.first?.lastReport))")
        }

        @Test func theJoinScreenSaysWhereTheRequestIs() {
            let asked = Date(timeIntervalSince1970: 1_000)
            typealias T = JoinDelivery.Target
            func t(_ last: TimeInterval?, syncing: Bool = false, failure: String? = nil, joinsError: Bool = false,
                   pending: Int = 0, iCloud: Bool = true) -> T {
                T(lastAttempt: last.map { Date(timeIntervalSince1970: $0) }, syncing: syncing, failure: failure,
                  joinsError: joinsError, providerPending: pending, viaICloud: iCloud)
            }
            #expect(JoinDelivery.judge(requestedAt: asked, targets: []) == .sending)
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(nil)]) == .sending)
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(900)]) == .sending, "a run before the request")
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(1_100, syncing: true)]) == .sending)
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(1_100, joinsError: true)]) == .sending)
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(1_100, failure: "offline")]) == .problem("offline"))
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(1_100, pending: 2)]) == .waitingForUpload(iCloud: true))
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(1_100, pending: 1, iCloud: false)]) == .waitingForUpload(iCloud: false))
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(1_100)]) == .sent)
            #expect(JoinDelivery.judge(requestedAt: nil, targets: [t(5)]) == .sent)
            #expect(JoinDelivery.judge(requestedAt: asked, targets: [t(1_100, failure: "x"), t(1_200)]) == .sent, "one target holds it")
        }

        /// Two devices that never go online, joined through a plain folder (a USB drive carried between them): the
        /// joining device opens the drive's copy with "Keep syncing", its runs carry its request to the drive and take
        /// home's approval back, it confirms with the reply words, writes, and home sees the note (moved from the app's
        /// `OfflineModeTests`, where it ran in the offline mode too: nothing here may need the network).
        @Test func aDeviceJoinsThroughAFolderOnADrive() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let drive = try TestTemp.directory("usb")
            let shared = drive.appendingPathComponent("Notes.sempere", isDirectory: true)
            let homeKeys = try DeviceKeys.parse(try await ModelFixture.keyText(keyURL))
            let homeState = vault.deletingLastPathComponent().appendingPathComponent("home-folder-sync.json")
            func homeSync() throws {
                let v = try Vault.open(at: vault, identities: [homeKeys.nativeIdentity], signing: homeKeys.signing)
                _ = try FolderTargetRun.run(vaultFolder: vault, folder: shared, vault: v, stateURL: homeState, twoWay: true)
            }
            try homeSync()
            #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("vault.json").path))

            let root = try TestTemp.directory("joiner")
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: MemoryEpochTrustStore())
            model.vaultStore = library.vaultStore
            model.deviceMemory = MemoryKeyValueStore()
            model.folderWriteDelay = 0.05
            model.folderArrivalWait = 0.5
            try await model.copyIn(picked: shared, library: library, followUp: .keepSyncing)
            defer { model.close() }
            #expect(model.phase == .locked)
            #expect(model.syncSessions.count == 1)
            let keys = RememberedKeys(store: MemoryDeviceKeyStore())
            guard case .waiting(let words, _) = try await model.startJoin(store: keys.store) else { Issue.record("not waiting"); return }
            _ = await model.syncSessions.first?.syncNow()   // the request goes to the drive

            try homeSync()
            var home = try Vault.open(at: vault, identities: [homeKeys.nativeIdentity], signing: homeKeys.signing)
            let request = try #require(home.joinRequest(matching: words), "the request did not reach home through the drive")
            let reply = try home.approveDevice(request)
            try homeSync()

            _ = await model.syncSessions.first?.syncNow()
            await model.refreshLockedManifest()
            #expect({ if case .joining = $0 { true } else { false } }(await keys.unlockWithDeviceKey(model)))
            #expect(keys.joinStage == .confirming)
            let device = try await keys.store.keys(for: try #require(model.vault?.vaultId), reason: .unlock(vaultName: nil))
            try await model.confirmJoin(words: reply, keys: device)
            #expect(model.phase == .unlocked)
            let note = try await model.createNote(title: "Joined offline", paper: Paper(kind: .ruled), notebook: nil)
            _ = await model.syncSessions.first?.syncNow()
            try homeSync()
            #expect(try Vault.open(at: vault, identities: [homeKeys.nativeIdentity]).noteIDs().contains(note))
        }
    }
}
