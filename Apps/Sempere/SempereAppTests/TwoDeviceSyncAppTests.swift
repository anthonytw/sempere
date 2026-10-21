import Age
import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// A WebDAV server as the app sees it, backed by the real engine on a shared in-memory store
/// (`MemoryRemote`): two models (two devices) connected to it sync through it for real. Faults are
/// injected per call (`failNext`, `gate`).
final class EngineWebDAVRemote: WebDAVRemote, @unchecked Sendable {
    let store: MemoryStore
    private let lock = NSLock()
    private var _runs = 0, _twoWay = 0, _fetches = 0
    private var _failure: (any Error)?
    private var _gate: DispatchSemaphore?
    private var _faults: MemoryFaults?

    init(store: MemoryStore) { self.store = store }

    var remote: MemoryRemote { lock.lock(); defer { lock.unlock() }; return MemoryRemote(store: store, base: ["vault"], faults: _faults) }
    var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
    var twoWayRuns: Int { lock.lock(); defer { lock.unlock() }; return _twoWay }
    /// Every run throws this until it is cleared (the server gone, offline).
    func failing(_ error: (any Error)?) { lock.lock(); _failure = error; lock.unlock() }
    /// Runs wait for this before they start (a slow server).
    func gating(_ gate: DispatchSemaphore?) { lock.lock(); _gate = gate; lock.unlock() }
    /// Seeded transport faults on every operation (cut bodies, lost answers...).
    func faulting(_ faults: MemoryFaults?) { lock.lock(); _faults = faults; lock.unlock() }

    private func enter(twoWay: Bool) throws -> MemoryRemote {
        lock.lock()
        _runs += 1
        if twoWay { _twoWay += 1 }
        let failure = _failure, gate = _gate
        lock.unlock()
        gate?.wait()
        if let failure { throw failure }
        return remote
    }

    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe { .failed(.notFound, message: "not used", certificate: nil) }
    func download(_ endpoint: WebDAVEndpoint, into copy: LocalCopy) throws -> SyncReport {
        try copy.download(remote: remote)
    }
    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: LocalCopy, options: SyncOptions) throws -> SyncReport {
        try copy.downloadMetadata(remote: remote, options: options)
    }
    func fetch(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, scope: FetchScope) throws -> SyncReport {
        lock.lock(); let failure = _failure; _fetches += 1; lock.unlock()
        if let failure { throw failure }   // offline: an on-demand fetch fails like a run (not gated)
        return try copy.fetch(remote: remote, vault: vault, scope: scope)
    }
    /// On-demand fetches made (`AppModel+Join`).
    var fetches: Int { lock.lock(); defer { lock.unlock() }; return _fetches }
    func push(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        try copy.push(remote: try enter(twoWay: false), vault: vault, options: options)
    }
    func sync(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        try copy.sync(remote: try enter(twoWay: true), vault: vault, options: options)
    }
    func redownload(_ endpoint: WebDAVEndpoint, copy: LocalCopy, identities: [any AgeIdentity],
                    partial: Bool, options: SyncOptions) throws -> (report: SyncReport, replaced: Bool) {
        try copy.redownload(remote: remote, identities: identities, partial: partial, options: options)
    }
}

/// Two devices on one WebDAV vault, through the app (docs/design/device-first-sync.md §9 "App"): two
/// `AppModel`s, each with its own device state, local copy and sync state, on one server running the
/// real engine. What one writes reaches the other's list and its open editor in place (RemoteMerge);
/// settings, conflicts made offline, large attachments, failures, a vanished server and a vault
/// reopened while a run goes all end with both copies the same.
@MainActor
struct TwoDeviceSyncAppTests {
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
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let store = MemoryStore(name: "server")
        let server = EngineWebDAVRemote(store: store)
        let upload = try SyncEngine(directory: vault, vault: nil, remote: server.remote,
                                    stateURL: vault.deletingLastPathComponent().appendingPathComponent("seed.json"),
                                    options: SyncOptions()).run()
        #expect(upload.errors.isEmpty)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.appendingPathComponent("vault.json")))
        let vaultId = try #require((manifest as? [String: Any])?["vaultId"] as? String).lowercased()
        let listing = WebDAVVaultListing(path: [], name: "Shared", vaultId: vaultId, format: "sempere/1",
                                         url: "https://dav.example.org/shared/")
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        func device() async throws -> Device {
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
            model.webdavRemote = server
            model.webdavPasswords = MemoryWebDAVPasswordStore()
            model.webdavTick = .milliseconds(20)
            model.webdavWriteDelay = 0.05
            let library = VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("recents-\(UUID().uuidString).json"))
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
        let note = try await w.a.model.createNote(title: "From A", paper: .ruled, notebook: nil)
        await w.a.model.webdav?.syncNow()
        await w.b.model.webdav?.syncNow()
        #expect(await TS.waitUntil { w.b.model.notes.contains { $0.id == note && $0.title == "From A" } })

        w.b.model.selectedNoteID = note
        try await w.b.model.openEditor(for: note)
        let editor = try #require(w.b.model.editor)
        try await w.a.model.renameNote(note, to: "Renamed on A")
        await w.a.model.webdav?.syncNow()
        await w.b.model.webdav?.syncNow()
        #expect(await TS.waitUntil { editor.meta.title == "Renamed on A" })
        #expect(w.b.model.editor === editor, "merged in place, not reopened")
        #expect(editor.remoteUpdates >= 1)
        #expect(await TS.waitUntil { w.b.model.notes.first { $0.id == note }?.title == "Renamed on A" })
        try await Self.settle(w)
        #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
        w.a.model.close(); w.b.model.close()
    }

    /// Both devices rename and tag one note while offline; once back, both read the same note (a
    /// last-writer-wins title, both tags) and hold the same files.
    @Test func twoDevicesEditingTheSameNoteOfflineConverge() async throws {
        let w = try await Self.world()
        let note = try #require(w.a.model.notes.first?.id)
        w.server.failing(WebDAVError.offline("offline"))
        try await w.a.model.renameNote(note, to: "Title from A")
        try await w.a.model.addTag("a", to: note)
        try await w.b.model.renameNote(note, to: "Title from B")
        try await w.b.model.addTag("b", to: note)
        await w.a.model.webdav?.syncNow()
        #expect(w.a.model.webdav?.problems == [.offline])
        #expect(w.a.model.webdav?.headline.hasPrefix("Offline.") == true)
        w.server.failing(nil)
        try await Self.settle(w)
        #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
        let sa = try #require(w.a.model.vault).reconstruct(noteId: note), sb = try #require(w.b.model.vault).reconstruct(noteId: note)
        #expect(sa == sb)
        #expect(Set(sa.meta.tags.map { $0.lowercased() }).isSuperset(of: ["a", "b"]))
        #expect(await TS.waitUntil { w.a.model.notes.first { $0.id == note }?.title == w.b.model.notes.first { $0.id == note }?.title })
        w.a.model.close(); w.b.model.close()
    }

    /// Shared settings changed on one device are merged into the other's copy by a two-way run.
    @Test func settingsChangedElsewhereAreMergedLocally() async throws {
        let w = try await Self.world()
        let va = try #require(w.a.model.vault)
        var s = try va.readSharedSettings() ?? SharedSettings()
        try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date())
        try va.writeSharedSettings(s)
        await w.a.model.webdav?.syncNow()
        let pulled = await w.b.model.webdav?.syncNow()
        #expect(pulled?.changed?.settings == true)
        #expect(try #require(w.b.model.vault).readSharedSettings() == s)
        w.a.model.close(); w.b.model.close()
    }

    /// A large attachment (6 MB) written on one device arrives whole on the other.
    @Test func aLargeAttachmentArrivesWhole() async throws {
        let w = try await Self.world()
        let note = try await w.a.model.createNote(title: "Big", paper: .ruled, notebook: nil)
        var bytes = Data(count: 6 << 20)
        for i in stride(from: 0, to: bytes.count, by: 997) { bytes[i] = UInt8(truncatingIfNeeded: i) }
        let va = try #require(w.a.model.vault)
        let ref = try va.writeBlob(note: note, bytes, type: "image/png")
        let page = UUID()
        _ = try va.apply([.addPage(Page(id: page, order: "z")),
                          .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                            frame: Rect(x: 0, y: 0, w: 40, h: 30), z: "a"))],
                         to: note, deviceState: TS.deviceStateURL(), app: "test/0")
        try await Self.settle(w)
        #expect(try #require(w.b.model.vault).readBlob(note: note, ref) == bytes)
        #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
        w.a.model.close(); w.b.model.close()
    }

    // MARK: Failures and interruptions

    /// Runs cut midway again and again (bodies cut, answers lost, requests dropped): nothing half-written
    /// shows up in either copy, and once the faults stop both copies are the same.
    @Test func runsCutMidwayLeaveNothingHalfDone() async throws {
        let w = try await Self.world()
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
        #expect(await TS.waitUntil { w.b.model.notes.filter { $0.title.hasPrefix("Note ") }.count == 4 })
        w.a.model.close(); w.b.model.close()
    }

    /// The server folder disappears: the run fails, the status says so and the copy keeps working;
    /// when it is back, the next run puts everything there again (an emptied target deletes nothing).
    @Test func aVanishedServerDeletesNothingAndRecovers() async throws {
        let w = try await Self.world()
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
        #expect(await TS.waitUntil { w.b.model.notes.contains { $0.id == note } })
        w.a.model.close(); w.b.model.close()
    }

    /// The vault is closed and opened again while a run is going: the reopen waits for the run (one
    /// sync state, one copy), and the copy then syncs as before.
    @Test func reopeningWhileARunGoesWaitsForIt() async throws {
        let w = try await Self.world()
        let gate = DispatchSemaphore(value: 0)
        w.server.gating(gate)
        _ = try await w.a.model.createNote(title: "During a slow run", paper: .ruled, notebook: nil)
        let session = try #require(w.a.model.webdav)
        let slow = Task { await session.syncNow() }
        #expect(await TS.waitUntil { session.isSyncing })
        let reopen = Task { try await w.a.model.openWebDAV(w.a.location, library: w.a.library) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(w.a.model.vault == nil || w.a.model.phase == .noVault || w.a.model.phase == .locked)
        w.server.gating(nil)
        gate.signal(); gate.signal()
        _ = await slow.value
        try await reopen.value
        try await w.a.model.unlock(identityText: w.key)
        try await Self.settle(w)
        #expect(Self.noteFiles(w.a) == Self.noteFiles(w.b))
        w.a.model.close(); w.b.model.close()
    }

    /// A closed vault keeps uploading (a capture or an edit made before it closed reaches the server),
    /// but takes nothing until it is unlocked again.
    @Test func aClosedVaultOnlyUploads() async throws {
        let w = try await Self.world()
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
        w.b.model.close()
    }

    /// Review of #70, F1 and F4: another device (the CLI) rotates the vault's secret. B's run takes the new
    /// `vault.json`; B runs upload-only until it has opened the vault again under it, reopens the note it
    /// had open (and says so), and the notes the other device writes under the new secret arrive.
    @Test func aRemoteKeyChangeIsAppliedAndNotesWrittenAfterItArrive() async throws {
        let w = try await Self.world()
        let note = try #require(w.b.model.notes.first?.id)
        w.b.model.selectedNoteID = note
        try await w.b.model.openEditor(for: note)
        let before = try #require(w.b.model.editor)

        // Another device, with the CLI: a folder copy of the server, a key added, then removed (rotation).
        let identity = try IdentityFile.parse(w.key)
        let cliDir = TestTemp.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("cli.sempere")
        let cliState = cliDir.deletingLastPathComponent().appendingPathComponent("state.json")
        func cliSync(_ v: Vault?) throws {
            var o = SyncOptions(deviceLabel: "cli")
            o.firstPullIdentities = [identity]
            _ = try SyncEngine(directory: cliDir, vault: v, remote: w.server.remote, stateURL: cliState, options: o).run()
        }
        try cliSync(nil)
        var cli = try Vault.open(at: cliDir, identities: [identity])
        // 1. A key added (the list changes, the secret stays): B reopens the vault and the note it had open.
        let other = try NativeIdentity.generate(.postQuantum)
        _ = try cli.addRecipient(other.recipient, label: "other")
        try cliSync(cli)
        await w.b.model.webdav?.syncNow()
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            !w.b.model.syncVaultStale && w.b.model.vault?.keysMatchManifestOnDisk() == true
        }, "B opened the vault again under the new list")
        #expect(await TS.waitUntil { w.b.model.editor?.noteID == note }, "the open note was opened again")
        #expect(w.b.model.editor !== before)
        #expect((w.b.model.editor?.remoteUpdates ?? 0) >= 1, "and says it was updated from another device")

        // 2. That key removed: the secret rotates. (B's older files stay under the old secret until
        // rewrap-replace, KH6; what matters here is what is written from now on.)
        _ = try cli.removeRecipient(other.recipient)
        try cliSync(cli)
        await w.b.model.webdav?.syncNow()
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            !w.b.model.syncVaultStale && w.b.model.vault?.keysMatchManifestOnDisk() == true
        }, "B opened the vault again under the new secret")

        // A note written under the new secret arrives.
        let fresh = UUID()
        _ = try cli.apply([.setMeta(.title("After the key change"))], to: fresh, deviceState: TS.deviceStateURL(), app: "cli/0")
        try cliSync(cli)
        await w.b.model.webdav?.syncNow()
        let report = await w.b.model.webdav?.syncNow()
        #expect(report?.quarantined.isEmpty == true, "\(String(describing: report?.quarantined))")
        #expect(await TS.waitUntil { w.b.model.notes.contains { $0.id == fresh } })
        w.a.model.close(); w.b.model.close()
    }

    /// While the open vault is stale (a new `vault.json` arrived and the reopen has not been applied, or
    /// failed), its runs only upload.
    @Test func aStaleOpenVaultOnlyUploads() async throws {
        let w = try await Self.world()
        let runs = w.server.twoWayRuns
        w.b.model.syncVaultStale = true
        await w.b.model.webdav?.syncNow()
        #expect(w.server.twoWayRuns == runs, "no two-way run with a vault that may not match the disk")
        w.b.model.syncVaultStale = false
        await w.b.model.webdav?.syncNow()
        #expect(w.server.twoWayRuns == runs + 1)
        w.a.model.close(); w.b.model.close()
    }

    /// Review of #70, F3 (its probe): a settings pass that read `settings.age` before a two-way run merged
    /// another device's change never writes its stale result over it; it runs again on what is there.
    @Test func aSettingsPassNeverOverwritesAMergeThatLandedMeanwhile() async throws {
        let w = try await Self.world()
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
        try await TwoDeviceSyncAppTests.settle(w)
        let onA = try #require(w.a.model.vault).readSharedSettings()?.value(SettingSlotKey("photos.removeMetadata"))
        let onB = try #require(w.b.model.vault).readSharedSettings()?.value(SettingSlotKey("photos.removeMetadata"))
        #expect(onA == .bool(false), "A lost B's setting: \(String(describing: onA))")
        #expect(onB == .bool(false), "B lost its own setting: \(String(describing: onB))")
        w.a.model.close(); w.b.model.close()
    }
}

/// The app's session and coordinator logic without a server (`SyncSchedule`, `SyncStatus`, budget).
@MainActor
struct SyncCoordinatorTests {
    @Test func statusKinds() {
        var s = SyncStatus(syncing: false, problems: [], unconfirmed: 0, arriving: 0, twoWay: true, lastSuccess: nil)
        #expect(s.kind == .synced)
        s.unconfirmed = 3
        #expect(s.kind == .pending(3))
        s.problems = [.offline]
        #expect(s.kind == .offline && !s.needsAttention)
        s.problems = [.unauthorized]
        #expect(s.needsAttention)
        s = SyncStatus(syncing: false, problems: [], unconfirmed: 0, arriving: 0, twoWay: false, lastSuccess: nil)
        #expect(s.kind == .waitingForUnlock && !s.needsAttention)
    }

    /// One vault's failing target never delays or fails another's, and background runs leave the open
    /// vault's slot free (at most `maxConcurrentRuns - 1` of them at once).
    @Test func vaultsAreIsolatedAndTheBudgetHolds() async throws {
        let inFlight = RunCounter(), most = RunCounter()
        func location() -> SyncTargetRef {
            var t = SyncTarget.webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V")
            t.joined = true
            return SyncTargetRef(vaultID: UUID(), vaultName: "V", target: t)
        }
        let failing = location(), fine = [location(), location(), location()]
        let all = [failing] + fine
        let coordinator = SyncCoordinator(targets: { all }, makeSession: { loc in
            SyncSession(locationID: loc.id, vaultID: loc.vaultID, name: loc.vaultName, lastSuccess: nil, run: { _ in
                most.raise(to: inFlight.add(1))
                defer { _ = inFlight.add(-1) }
                try await Task.sleep(for: .milliseconds(50))
                if loc.id == failing.id { throw WebDAVError.http(method: "PROPFIND", path: "", status: 503) }
                return SyncReport()
            }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        coordinator.start()
        #expect(coordinator.sessions.count == 4)
        #expect(await TS.waitUntil(timeout: .seconds(5)) { fine.allSatisfy { coordinator.sessions[$0.id]?.lastSuccess != nil } })
        #expect(coordinator.sessions[failing.id]?.lastSuccess == nil)
        #expect(coordinator.sessions[failing.id]?.needsAttention == true)
        #expect(most.value <= coordinator.maxConcurrentRuns - 1)
        for l in all { _ = coordinator.stop(l.id) }
        #expect(coordinator.sessions.isEmpty)
    }

    /// Review of #70, F2 (its probe): two closed vaults whose runs take long held both slots, and the open
    /// vault's Sync Now waited for them. One slot is the open vault's.
    @Test func theOpenVaultIsNeverStarvedBySlowBackgroundRuns() async throws {
        func location() -> SyncTargetRef {
            SyncTargetRef(vaultID: UUID(), vaultName: "V",
                          target: .webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V"))
        }
        let slow = [location(), location()], open = location()
        let slowIDs = Set(slow.map(\.id))
        let inFlight = RunCounter()
        let coordinator = SyncCoordinator(targets: { slow + [open] }, makeSession: { loc in
            SyncSession(locationID: loc.id, vaultID: loc.vaultID, name: loc.vaultName, lastSuccess: nil, run: { _ in
                _ = inFlight.add(1)
                defer { _ = inFlight.add(-1) }
                if slowIDs.contains(loc.id) { try await Task.sleep(for: .seconds(4)) }
                return SyncReport()
            }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        for l in slow { coordinator.session(for: l) }
        #expect(await TS.waitUntil(timeout: .seconds(3)) { inFlight.value >= 1 })
        let session = try #require(coordinator.attachOpen(open.vaultID).first)
        session.vaultUnlocked()
        let finished = RunCounter()
        Task { _ = await session.syncNow(); _ = finished.add(1) }
        #expect(await TS.waitUntil(timeout: .seconds(2)) { finished.value == 1 }, "the open vault's run waited behind background runs")
        #expect(coordinator.runsGoing <= coordinator.maxConcurrentRuns)
        for l in slow + [open] { _ = coordinator.stop(l.id) }
    }

    /// Re-check of #70: a run queued as a background one before its vault was opened kept background
    /// priority, so the unlock's run and Sync Now waited behind another closed vault's slow upload.
    /// Priority is asked again when slots are handed out, and opening the vault hands them out.
    @Test func aRunQueuedBeforeItsVaultOpenedTakesTheOpenVaultsSlot() async throws {
        func location() -> SyncTargetRef {
            SyncTargetRef(vaultID: UUID(), vaultName: "V",
                          target: .webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V"))
        }
        let blocked = location(), queued = location()
        let released = RunCounter()
        let coordinator = SyncCoordinator(targets: { [blocked, queued] }, makeSession: { loc in
            SyncSession(locationID: loc.id, vaultID: loc.vaultID, name: loc.vaultName, lastSuccess: nil, run: { _ in
                if loc.id == blocked.id {
                    // A slow upload of a closed vault, until the test releases it.
                    while released.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
                }
                return SyncReport()
            }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        let slow = try #require(coordinator.session(for: blocked))
        #expect(await TS.waitUntil { slow.isSyncing })
        let waiting = try #require(coordinator.session(for: queued))
        try await Task.sleep(for: .milliseconds(100))
        #expect(waiting.lastSuccess == nil, "queued behind the background slot")
        let open = try #require(coordinator.attachOpen(queued.vaultID).first)
        open.vaultUnlocked()
        let finished = RunCounter()
        Task { _ = await open.syncNow(); _ = finished.add(1) }
        #expect(await TS.waitUntil(timeout: .seconds(2)) { finished.value == 1 }, "the open vault's runs wait for no background run")
        _ = released.add(1)
        for l in [blocked, queued] { _ = coordinator.stop(l.id) }
    }

    /// Review of #72: in the background, closed vaults' periodic runs pause, but a write into one (a voice
    /// note) still runs; the open vault's sessions keep their pace; back in the foreground all run again.
    @Test func closedVaultsPauseTheirPaceInTheBackground() async throws {
        let runs = RunCounter()
        let closed = SyncTargetRef(vaultID: UUID(), vaultName: "Closed",
                                   target: { var t = SyncTarget.webdav("https://dav.example.org/c/", user: nil, name: "C"); t.joined = true; return t }())
        let coordinator = SyncCoordinator(targets: { [closed] }, makeSession: { l in
            SyncSession(locationID: l.id, vaultID: l.vaultID, name: l.vaultName, lastSuccess: nil,
                        run: { _ in _ = runs.add(1); return SyncReport() }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        coordinator.configure = { $0.idleInterval = 0.05; $0.maxIdleInterval = 0.05; $0.arrivingInterval = 0.05; $0.writeDelay = 0.01 }
        coordinator.start()
        #expect(await TS.waitUntil { runs.value >= 2 }, "the idle pace runs")
        coordinator.setInBackground(true)
        try await Task.sleep(for: .milliseconds(100))   // a run already going ends
        let paused = runs.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.value == paused, "no periodic run in the background")
        coordinator.sessions[closed.id]?.noteWrite()
        #expect(await TS.waitUntil { runs.value > paused }, "a write still runs")
        coordinator.setInBackground(false)
        let after = runs.value
        #expect(await TS.waitUntil { runs.value > after + 1 }, "the pace is back")
        _ = coordinator.stop(closed.id)
    }

    /// The reviewer's Q4: a voice note delivered into a closed vault's copy asks its session for a run
    /// soon (a write), not at the idle pace.
    @Test func aCaptureIntoAClosedVaultAsksForARun() async throws {
        let vault = UUID()
        var target = SyncTarget.webdav("https://dav.example.org/x/", user: nil, name: "V")
        target.joined = true
        let loc = SyncTargetRef(vaultID: vault, vaultName: "V", target: target)
        let coordinator = SyncCoordinator(targets: { [loc] }, makeSession: { l in
            SyncSession(locationID: l.id, vaultID: l.vaultID, name: l.vaultName, lastSuccess: nil,
                        run: { _ in SyncReport() }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .seconds(60)   // the loop does not run meanwhile
        let session = try #require(coordinator.session(for: loc))
        #expect(session.schedule.pendingWrite == nil)
        NotificationCenter.default.post(name: QuickCapture.deliveredNotification, object: nil, userInfo: ["vault": vault])
        #expect(await TS.waitUntil { session.schedule.pendingWrite != nil })
        _ = coordinator.stop(loc.id)
    }
}

/// A thread-safe count.
final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    /// Adds `d`; returns the new value.
    func add(_ d: Int) -> Int { lock.lock(); defer { lock.unlock() }; n += d; return n }
    func raise(to x: Int) { lock.lock(); n = max(n, x); lock.unlock() }
}
