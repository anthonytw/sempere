import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

extension AppModelSuites {
    /// A removal reaching a device over sync (design §5.5): its runs report it unlisted, the banner says so, and the
    /// model refuses writes. A device that cannot verify the change yet is held back, and says so after a day (moved
    /// from the app's `UnlistedOverSyncAppTests`).
    @MainActor
    struct UnlistedOverSyncTests {
        /// Home's copy (the fixture's device, as the CLI would) and its runs, off the main actor.
        struct Home: Sendable {
            let vault: URL
            let keys: DeviceKeys
            let state: URL
            let remote: MemoryRemote

            @concurrent func sync() async throws {
                let v = try Vault.open(at: vault, identities: [keys.nativeIdentity], signing: keys.signing)
                _ = try SyncEngine(directory: vault, vault: v, remote: remote, stateURL: state, options: SyncOptions()).run()
            }

            /// Approves a new device named "Phone": its keys and the reply words.
            @concurrent func approvePhone() async throws -> (DeviceKeys, [String]) {
                var home = try Vault.open(at: vault, identities: [keys.nativeIdentity], signing: keys.signing)
                let phone = try DeviceKeys.generate()
                return (phone, try home.approveDevice(phone.joinRequest(vaultId: home.vaultId, name: "Phone", kind: "iphone")))
            }

            /// Removes `ids` from the list (a new epoch) and syncs the change.
            @concurrent func remove(_ ids: [String]) async throws {
                var home = try Vault.open(at: vault, identities: [keys.nativeIdentity], signing: keys.signing)
                try home.removeDevices(ids)
                try await sync()
            }
        }

        struct Setup {
            let home: Home
            let model: AppModel
            let phone: DeviceKeys
            let server: EngineWebDAVRemote
            let listing: WebDAVVaultListing
        }

        /// Home approves a phone; the phone connects over WebDAV and, with `trust`, confirms its join as the app does
        /// (KH5 part 2), then unlocks.
        static func setUp(trust: MemoryEpochTrustStore?, writeStores: URL? = nil) async throws -> Setup {
            let (vault, keyURL) = try await ModelFixture.vault()
            let server = EngineWebDAVRemote(store: MemoryStore(name: "server"))
            let home = Home(vault: vault, keys: try DeviceKeys.parse(try await ModelFixture.keyText(keyURL)),
                            state: vault.deletingLastPathComponent().appendingPathComponent("home-sync.json"), remote: server.remote)
            let (phone, words) = try await home.approvePhone()
            try await home.sync()
            let listing = try await WebDAVFixture.listing(of: vault, name: "Shared", url: "https://dav.example.org/shared/")
            let (model, library) = WebDAVFixture.device(server, trust: trust)
            if let writeStores {
                model.writeStores = DeviceWriteStores(ledgerDirectory: writeStores.appendingPathComponent("Ledger"),
                                                      setAside: SetAsideStore(directory: writeStores.appendingPathComponent("SetAside")),
                                                      key: { Data(repeating: 7, count: 32) })
            }
            let location = try await model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: library)
            if let trust {
                let folder = try #require(model.webdavLocations.location(location).map { model.webdavLocations.copy(of: $0).folder })
                try await Self.confirm(folder, phone: phone, words: words, trust: trust)
            }
            try await model.unlock(device: phone)
            _ = await model.webdav?.syncNow()
            #expect(model.deviceNotices.isEmpty)
            return Setup(home: home, model: model, phone: phone, server: server, listing: listing)
        }

        @concurrent static func confirm(_ folder: URL, phone: DeviceKeys, words: [String], trust: MemoryEpochTrustStore) async throws {
            var v = try Vault.open(at: folder, identities: [phone.nativeIdentity], signing: phone.signing, trust: trust)
            try v.confirmJoin(words: words)
        }

        @Test func aDeviceRemovedElsewhereShowsTheBannerAndWritesNothing() async throws {
            let s = try await Self.setUp(trust: MemoryEpochTrustStore())
            let model = s.model
            defer { model.close() }
            #expect(model.listAlert == nil, "the join is confirmed")
            _ = try await model.createNote(title: "Before", paper: Paper(kind: .ruled), notebook: nil)
            _ = await model.webdav?.syncNow()
            try await s.home.remove([s.phone.id])
            _ = await model.webdav?.syncNow()
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.deviceNotices.contains(.unlisted) },
                    "\(String(describing: model.webdav?.lastReport?.epoch))")
            #expect(model.isUnlisted)
            #expect(model.isVaultReadOnly)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.vault?.unlistedNotice != nil },
                    "the vault was opened again: it refuses writes itself")
            await #expect(throws: (any Error).self) {
                _ = try await model.createNote(title: "No", paper: Paper(kind: .ruled), notebook: nil)
            }
            let facts = await model.unlistedFacts()
            #expect(facts.unsynced.isEmpty, "everything it wrote reached the server")
        }

        /// Review of #87, M3, and its re-check, R1: once unlisted, the device takes no new voice notes (its profile is
        /// suspended, not deleted), while the recording in progress and a leftover are still sealed into `inbox/` with
        /// ledger entries, counted apart and saved by Save Files. Listed again, the suspension is lifted with the
        /// notebook kept.
        @Test func anUnlistedDeviceSuspendsVoiceNotesSealsWhatItHoldsAndResumesWhenListed() async throws {
            let root = try TestTemp.directory("unlisted-capture")
            let s = try await Self.setUp(trust: MemoryEpochTrustStore(), writeStores: root)
            let model = s.model
            defer { model.close() }
            let qc = Self.quickCapture(for: model)
            try model.enableQuickCapture(notebook: "Field", transcribe: false)
            // A voice note in progress when the removal arrives.
            try await qc.start()
            #expect(qc.state == .recording)

            try await s.home.remove([s.phone.id])
            _ = await model.webdav?.syncNow()
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.vault?.unlistedNotice != nil })
            #expect(await TS.waitUntil(timeout: .seconds(30)) { (try? model.storedQuickCaptureProfile())??.suspended == true },
                    "suspended, not deleted")
            #expect(try model.storedQuickCaptureProfile()?.profile.notebook == "Field")

            let outcome = try await qc.stop()
            #expect(outcome.delivery == .vault, "the recording in progress is still sealed")
            await #expect(throws: QuickCaptureError.notOnDeviceList) { try await qc.start() }
            #expect(qc.state == .idle)
            // A recording a crash left: the sweep still seals it.
            let leftover = try Self.crashLeftRecording(in: qc.root)
            await qc.sweep()
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
            let leftoverID = try #require(UUID(uuidString: leftover.lastPathComponent))

            let facts = await model.unlistedFacts()
            #expect(facts.captures == 2, "\(facts.unsynced)")
            #expect(facts.unsynced.contains("inbox/\(CaptureFile.name(outcome.id, .capture))"))
            #expect(facts.unsynced.contains("inbox/\(CaptureFile.name(leftoverID, .capture))"))
            #expect(facts.notes.isEmpty, "Export of notes would not cover them")
            let out = try TestTemp.directory("unlisted-out")
            #expect(try await model.exportUnsyncedFiles(facts.unsynced, to: out) == facts.unsynced.count)
            let saved = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            let copy = try #require(saved.first).appendingPathComponent("inbox/\(CaptureFile.name(outcome.id, .capture))")
            let folder = try #require(model.vaultURL)
            #expect(try Data(contentsOf: copy) == Data(contentsOf: folder.appendingPathComponent("inbox/\(CaptureFile.name(outcome.id, .capture))")))

            // Forget All (the warning's choice) forgets the removal marker: the vault reopens listed until a sync meets
            // the change again.
            #expect(!model.sightingRows.isEmpty)
            try await model.forgetSightings(anchoredToo: true)
            #expect(model.vault?.unlistedNotice == nil)
            #expect(model.sightingRows.isEmpty)
        }

        /// Re-check of #87, R1: a device listed again (its open vault and its targets say so) gets voice notes back,
        /// with the notebook it had.
        @Test func aListedDeviceLiftsTheSuspensionKeepingTheNotebook() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let model = try await w.model("Phone")
            defer { model.close() }
            let qc = Self.quickCapture(for: model)
            try model.enableQuickCapture(notebook: "Field", transcribe: false)
            var stored = try #require(try model.storedQuickCaptureProfile())
            stored.suspended = true   // as an earlier unlisting left it
            try qc.store.save(stored)
            await #expect(throws: QuickCaptureError.notOnDeviceList) { try await qc.start() }
            model.refreshQuickCaptureProfile()
            let lifted = try #require(try model.storedQuickCaptureProfile())
            #expect(lifted.suspended == nil)
            #expect(lifted.profile.notebook == "Field")
            try await qc.start()
            #expect(qc.state == .recording)
            _ = try await qc.stop()
        }

        /// A quick capture for `model` on the capture suites' fakes (`CaptureTestKit.swift`: the recorder, the audio
        /// files, the Live Activity, the app's state), its files in temp folders and its sleeps held (no heartbeat
        /// races the test), recording into the model's ledger.
        static func quickCapture(for model: AppModel) -> QuickCapture {
            let clock = CaptureClock(), sleeper = ManualSleeper()
            let audio = FakeAudio(clock: clock)
            let qc = QuickCapture(store: MemoryCaptureProfileStore(), audio: audio, audioFiles: FakeAudioFiles(),
                                  liveActivity: FakeLiveActivity(audio: audio), app: FakeApp(),
                                  root: CaptureFixture.temp("qc-root"), queueRoot: CaptureFixture.temp("qc-queue"))
            qc.now = { clock.now }
            qc.sleep = { await sleeper.sleep($0) }
            qc.showsActivity = false
            if let stores = model.writeStores { qc.ledger = { stores.ledger(for: $0) } }
            model.quickCapture = qc
            return qc
        }

        /// A recording a crash left in `root`: one finished segment and a manifest naming it.
        static func crashLeftRecording(in root: URL) throws -> URL {
            let id = UUID()
            let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("AUDIO-FRAMES".utf8).write(to: folder.appendingPathComponent("segment-001.aac"))
            let manifest = RecordingManifest(note: UUID(), recording: id, started: Date(), codec: "aac",
                                             segments: ["segment-001.aac"], finished: 1)
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
            return folder
        }

        /// Design §5.2 step 2: a target the run before a change cannot reach is named; the change goes ahead.
        @Test func aChangeWhoseTargetCannotBeReachedNamesIt() async throws {
            let s = try await Self.setUp(trust: nil)
            s.model.close()
            let (model, library) = WebDAVFixture.device(s.server)
            model.deviceChangeRunBound = 2
            _ = try await model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: library)
            try await model.unlock(device: s.home.keys)
            defer { model.close() }
            #expect(model.vault?.isHome == true)
            try await model.completePartialCopy()   // a change needs the whole copy
            s.server.failing(URLError(.notConnectedToInternet))
            let done = try await model.removeDevices([s.phone.id])
            #expect(done.report.reason == .remove)
            #expect(done.unreachable.count == 1)
            s.server.failing(nil)
        }

        @Test func aChangeThatCannotBeVerifiedHoldsSyncBackAndSaysSoAfterADay() async throws {
            let s = try await Self.setUp(trust: nil)
            let model = s.model
            defer { model.close() }
            try await s.home.remove([s.phone.id])
            _ = await model.webdav?.syncNow()
            let since = try #require(model.webdav?.lastReport?.epoch?.heldSince, "\(String(describing: model.webdav?.lastReport))")
            #expect(model.deviceNotices.isEmpty, "held back for less than a day: no banner")
            model.deviceNoticeNow = { since.addingTimeInterval(2 * 86_400) }
            #expect(model.deviceNotices == [.heldBack(since: since)])
        }
    }
}
