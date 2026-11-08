import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Two devices on one WebDAV vault, through the model (docs/design/device-first-sync.md §9 "App"; moved from the
    /// app's `TwoDeviceSyncAppTests`): two `AppModel`s, each with its own device state, local copy and sync state, on one server running the
    /// real engine. What one writes reaches the other's list and its open editor in place (RemoteMerge);
    /// settings, conflicts made offline, large attachments, failures, a vanished server and a vault
    /// reopened while a run goes all end with both copies the same.
    @MainActor
    struct TwoDeviceSyncTests {
        struct Device {
            let model: AppModel
            let library: VaultLibrary
            let location: UUID
            @MainActor var copy: LocalCopy { model.webdavLocations.copy(of: model.webdavLocations.location(location)!) }
        }

        struct World {
            let server: EngineWebDAVRemote
            let key: String
            let keyURL: URL
            let listing: WebDAVVaultListing
            var a: Device
            var b: Device
        }

        /// The fixture vault on the server, and two devices connected to it and unlocked.
        static func world() async throws -> World {
            let (vault, keyURL) = try await ModelFixture.vault()
            let server = EngineWebDAVRemote(store: MemoryStore(name: "server"))
            let upload = try await WebDAVFixture.seed(server, from: vault)
            #expect(upload.errors.isEmpty)
            let listing = try await WebDAVFixture.listing(of: vault, name: "Shared", url: "https://dav.example.org/shared/")
            let key = try await ModelFixture.keyText(keyURL)
            func device() async throws -> Device {
                let (model, library) = WebDAVFixture.device(server)
                let id = try await model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: library)
                try await model.unlock(identityText: key)
                return Device(model: model, library: library, location: id)
            }
            let a = try await device()
            let b = try await device()
            let w = World(server: server, key: key, keyURL: keyURL, listing: listing, a: a, b: b)
            // Both copies complete and in step before the test starts.
            try await settle(w)
            return w
        }

        /// Sync Now on each device in turn until a round changes nothing on either.
        static func settle(_ w: World, rounds: Int = 6) async throws {
            for _ in 0..<rounds {
                let x = await w.a.model.webdav?.syncNow(), y = await w.b.model.webdav?.syncNow()
                if x?.isEmpty == true, y?.isEmpty == true { return }
            }
        }

        /// Every visible file under the copy's `notes/` (revisions and blobs).
        static func noteFiles(_ d: Device) -> Set<String> {
            let notes = d.copy.folder.appendingPathComponent("notes")
            guard let e = FileManager.default.enumerator(atPath: notes.path) else { return [] }
            return Set(e.compactMap { $0 as? String }.filter {
                !($0 as NSString).lastPathComponent.hasPrefix(".") && ($0.hasSuffix(".age"))
            })
        }

        /// Hidden files under the copy's `notes/` (transfers in progress).
        static func hiddenFiles(_ d: Device) -> [String] {
            let notes = d.copy.folder.appendingPathComponent("notes")
            guard let e = FileManager.default.enumerator(atPath: notes.path) else { return [] }
            return e.compactMap { $0 as? String }.filter { ($0 as NSString).lastPathComponent.hasPrefix(".") }
        }

        // MARK: Arrivals

        /// A note made on one device is in the other's list after a run there, and a rename reaches the
        /// other's open editor in place.
        @Test func whatOneDeviceWritesReachesTheOthersListAndOpenEditor() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let note = try await w.a.model.createNote(title: "From A", paper: .ruled, notebook: nil)
            await w.a.model.webdav?.syncNow()
            await w.b.model.webdav?.syncNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.contains { $0.id == note && $0.title == "From A" } })

            w.b.model.selectedNoteID = note
            try await w.b.model.openEditor(for: note)
            let editor = try #require(w.b.model.editor)
            try await w.a.model.renameNote(note, to: "Renamed on A")
            await w.a.model.webdav?.syncNow()
            await w.b.model.webdav?.syncNow()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { editor.meta.title == "Renamed on A" })
            #expect(w.b.model.editor === editor, "merged in place, not reopened")
            #expect(editor.remoteUpdates >= 1)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.first { $0.id == note }?.title == "Renamed on A" })
            try await Self.settle(w)
            #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
        }

        /// Both devices rename and tag one note while offline; once back, both read the same note (a
        /// last-writer-wins title, both tags) and hold the same files.
        @Test func twoDevicesEditingTheSameNoteOfflineConverge() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let note = try #require(w.a.model.notes.first?.id)
            w.server.failing(WebDAVError.offline("offline"))
            try await w.a.model.renameNote(note, to: "Title from A")
            try await w.a.model.addTag("a", to: note)
            try await w.b.model.renameNote(note, to: "Title from B")
            try await w.b.model.addTag("b", to: note)
            await w.a.model.webdav?.syncNow()
            #expect(w.a.model.webdav?.problems == [.offline])
            #expect(w.a.model.webdav?.status.kind == .offline)
            w.server.failing(nil)
            try await Self.settle(w)
            #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
            let sa = try #require(w.a.model.vault).reconstruct(noteId: note), sb = try #require(w.b.model.vault).reconstruct(noteId: note)
            #expect(sa == sb)
            #expect(Set(sa.meta.tags.map { $0.lowercased() }).isSuperset(of: ["a", "b"]))
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.a.model.notes.first { $0.id == note }?.title == w.b.model.notes.first { $0.id == note }?.title })
        }

        /// Shared settings changed on one device are merged into the other's copy by a two-way run.
        @Test func settingsChangedElsewhereAreMergedLocally() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let va = try #require(w.a.model.vault)
            var s = try va.readSharedSettings() ?? SharedSettings()
            try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date())
            try va.writeSharedSettings(s)
            await w.a.model.webdav?.syncNow()
            let pulled = await w.b.model.webdav?.syncNow()
            #expect(pulled?.changed?.settings == true)
            #expect(try #require(w.b.model.vault).readSharedSettings() == s)
        }

        /// A large attachment (6 MB) written on one device arrives whole on the other.
        @Test func aLargeAttachmentArrivesWhole() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let note = try await w.a.model.createNote(title: "Big", paper: .ruled, notebook: nil)
            let (ref, bytes) = try await WebDAVFixture.writeBigAttachment(to: note, in: try #require(w.a.model.vault))
            try await Self.settle(w)
            #expect(try #require(w.b.model.vault).readBlob(note: note, ref) == bytes)
            #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
        }

        // MARK: Failures and interruptions

        /// Runs cut midway again and again (bodies cut, answers lost, requests dropped): nothing half-written
        /// shows up in either copy, and once the faults stop both copies are the same.
        @Test func runsCutMidwayLeaveNothingHalfDone() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            for i in 0..<4 { _ = try await w.a.model.createNote(title: "Note \(i)", paper: .ruled, notebook: nil) }
            let faults = MemoryFaults(seed: 11, rates: .transport(0.3))
            w.server.faulting(faults)
            for _ in 0..<6 {
                await w.a.model.webdav?.syncNow()
                await w.b.model.webdav?.syncNow()
                // Only transfers in progress are hidden; nothing half-written is under a real name (`noteFiles` reads).
                #expect(Self.hiddenFiles(w.b).allSatisfy { ($0 as NSString).lastPathComponent.hasPrefix(".sempere-") },
                        "\(Self.hiddenFiles(w.b))")
            }
            #expect(faults.injected > 0)
            w.server.faulting(nil)
            try await Self.settle(w)
            #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
            let last = await w.a.model.webdav?.syncNow()
            #expect(Self.hiddenFiles(w.a).isEmpty, "\(Self.hiddenFiles(w.a)) \(String(describing: last?.skipped)) \(String(describing: last?.errors)) \(String(describing: last?.quarantined)) \(String(describing: last?.partial))")
            #expect(Self.hiddenFiles(w.b).isEmpty, "\(Self.hiddenFiles(w.b))")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.filter { $0.title.hasPrefix("Note ") }.count == 4 })
        }

        /// The server folder disappears: the run fails, the status says so and the copy keeps working;
        /// when it is back, the next run puts everything there again (an emptied target deletes nothing).
        @Test func aVanishedServerDeletesNothingAndRecovers() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let before = Self.noteFiles(w.a)
            w.server.failing(WebDAVError.http(method: "PROPFIND", path: "", status: 404))
            await w.a.model.webdav?.syncNow()
            let session = try #require(w.a.model.webdav)
            #expect(session.problems == [.notFound])
            #expect(session.needsAttention)
            let note = try await w.a.model.createNote(title: "Written meanwhile", paper: .ruled, notebook: nil)
            // The server comes back empty (recreated): nothing local is deleted, everything goes up again.
            w.server.store.removeDirect(["vault"])
            w.server.failing(nil)
            await session.syncNow()
            #expect(session.problems.isEmpty)
            #expect(Self.noteFiles(w.a).isSuperset(of: before))
            try await Self.settle(w)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.contains { $0.id == note } })
        }

        /// The vault is closed and opened again while a run is going: the reopen waits for the run (one
        /// sync state, one copy), and the copy then syncs as before.
        @Test func reopeningWhileARunGoesWaitsForIt() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let gate = DispatchSemaphore(value: 0)
            w.server.gating(gate)
            _ = try await w.a.model.createNote(title: "During a slow run", paper: .ruled, notebook: nil)
            let session = try #require(w.a.model.webdav)
            let slow = Task { await session.syncNow() }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { session.isSyncing })
            let reopen = Task { try await w.a.model.openWebDAV(w.a.location, library: w.a.library) }
            try await Task.sleep(for: .milliseconds(200))   // kept: a negative check, nothing to wait on
            #expect(w.a.model.vault == nil || w.a.model.phase == .noVault || w.a.model.phase == .locked)
            w.server.gating(nil)
            gate.signal(); gate.signal()
            _ = await slow.value
            try await reopen.value
            try await w.a.model.unlock(identityText: w.key)
            try await Self.settle(w)
            #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
        }

        /// A closed vault keeps uploading (a capture or an edit made before it closed reaches the server),
        /// but takes nothing until it is unlocked again.
        @Test func aClosedVaultOnlyUploads() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let fromB = try await w.b.model.createNote(title: "B, unseen by A while closed", paper: .ruled, notebook: nil)
            await w.b.model.webdav?.syncNow()
            let coordinator = w.a.model.syncCoordinator
            coordinator.start()
            let location = try #require(w.a.model.webdavLocations.location(w.a.location))
            // A writes into its copy, then closes: its session goes on, upload-only.
            _ = try await w.a.model.createNote(title: "A before closing", paper: .ruled, notebook: nil)
            w.a.model.close()
            let session = try #require(coordinator.sessions[location.id])
            let runs = w.server.twoWayRuns
            let report = await session.syncNow()
            #expect(w.server.twoWayRuns == runs, "no two-way run without the key")
            #expect(report?.uploaded.contains { $0.hasPrefix("notes/") } == true)
            #expect(!(report?.downloaded.contains { $0.contains(fromB.uuidString.lowercased()) } ?? true))
            #expect(session.status.kind == .waitingForUnlock || session.status.kind == .synced)
            _ = coordinator.stop(location.id)
        }

        /// Review of #70, F1 and F4: home (here the CLI, with the fixture's device keys) approves a device.
        /// B's run takes the new `vault.json`; B runs upload-only until it has opened the vault again under
        /// it, reopens the note it had open (and says so), and the notes written afterwards arrive.
        /// TODO(KH3): a removal (a new epoch, its key rotated) arriving the same way.
        @Test func aRemoteKeyChangeIsAppliedAndNotesWrittenAfterItArrive() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let note = try #require(w.b.model.notes.first?.id)
            w.b.model.selectedNoteID = note
            try await w.b.model.openEditor(for: note)
            let editorBefore = try #require(w.b.model.editor)

            // Another device, with the CLI: a folder copy of the server, opened as home, approves a device.
            let home = try DeviceKeys.parse(w.key)
            let identity = home.nativeIdentity
            let cliDir = TestTemp.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("cli.sempere")
            let cliState = cliDir.deletingLastPathComponent().appendingPathComponent("state.json")
            let remote = w.server.remote
            // Off the main actor: a whole download of the vault, then runs of the CLI's copy.
            @concurrent func cliSync(_ v: Vault?) async throws {
                var o = SyncOptions(deviceLabel: "cli")
                o.firstPullIdentities = [identity]
                _ = try SyncEngine(directory: cliDir, vault: v, remote: remote, stateURL: cliState, options: o).run()
            }
            try await cliSync(nil)
            var cli = try Vault.open(at: cliDir, identities: [identity], signing: home.signing)
            #expect(cli.isHome)
            // A device approved (the list grows, the epoch stays): B reopens the vault and the note it had open.
            let before = w.b.model.vault?.devices.count ?? 0
            let other = try DeviceKeys.generate()
            _ = try cli.approveDevice(other.joinRequest(vaultId: cli.vaultId, name: "Other", kind: "ipad"))
            try await cliSync(cli)
            await w.b.model.webdav?.syncNow()
            #expect(await TS.waitUntil(timeout: .seconds(60)) {
                !w.b.model.syncVaultStale && w.b.model.vault?.devices.count == before + 1
            }, "B opened the vault again under the new list")
            #expect(w.b.model.listAlert == nil, "the later version by home checks")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.editor?.noteID == note }, "the open note was opened again")
            #expect(w.b.model.editor !== editorBefore)
            #expect((w.b.model.editor?.remoteUpdates ?? 0) >= 1, "and says it was updated from another device")

            // A note written after the change arrives.
            let fresh = UUID()
            _ = try cli.apply([.setMeta(.title("After the key change"))], to: fresh, deviceState: TS.deviceStateURL(), app: "cli/0")
            try await cliSync(cli)
            await w.b.model.webdav?.syncNow()
            let report = await w.b.model.webdav?.syncNow()
            #expect(report?.quarantined.isEmpty == true, "\(String(describing: report?.quarantined))")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { w.b.model.notes.contains { $0.id == fresh } })
        }

        /// While the open vault is stale (a new `vault.json` arrived and the reopen has not been applied, or
        /// failed), its runs only upload.
        @Test func aStaleOpenVaultOnlyUploads() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let runs = w.server.twoWayRuns
            w.b.model.syncVaultStale = true
            await w.b.model.webdav?.syncNow()
            #expect(w.server.twoWayRuns == runs, "no two-way run with a vault that may not match the disk")
            w.b.model.syncVaultStale = false
            await w.b.model.webdav?.syncNow()
            #expect(w.server.twoWayRuns == runs + 1)
        }

        /// Review of #70, F3 (its probe): a settings pass that read `settings.age` before a two-way run merged
        /// another device's change never writes its stale result over it; it runs again on what is there.
        @Test func aSettingsPassNeverOverwritesAMergeThatLandedMeanwhile() async throws {
            let w = try await Self.world()
            defer { w.a.model.close(); w.b.model.close() }
            let vb = try #require(w.b.model.vault)
            var sb = try vb.readSharedSettings() ?? SharedSettings()
            try sb.set(SettingSlotKey("photos.removeMetadata"), to: .bool(false), type: nil, now: Date())
            try vb.writeSharedSettings(sb)
            await w.b.model.webdav?.syncNow()
            await w.a.model.runSettingsStep(enabling: true) { _, _, file, _, now in
                _ = await w.a.model.webdav?.syncNow()
                var write = file ?? SharedSettings()
                try write.set(SettingSlotKey("history.thinAfterDays"), to: .number(7), type: nil, now: now)
                return SettingsSyncState.Pass(write: write)
            }
            try await TwoDeviceSyncTests.settle(w)
            let onA = try #require(w.a.model.vault).readSharedSettings()?.value(SettingSlotKey("photos.removeMetadata"))
            let onB = try #require(w.b.model.vault).readSharedSettings()?.value(SettingSlotKey("photos.removeMetadata"))
            #expect(onA == .bool(false), "A lost B's setting: \(String(describing: onA))")
            #expect(onB == .bool(false), "B lost its own setting: \(String(describing: onB))")
        }
    }
}
