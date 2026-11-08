import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// The device list's words in the app (key-hierarchy design §5.5, §6.3 to §6.5; phase KH5): what the sheets, the
/// history and the banners say. The model's half moved to `SempereAppCoreTests` (`DevicesTests`); `World` stays for
/// the app suites that still build a model of a vault with devices (wave 5b part 3, step 4b moves them).
@Suite(.serialized)
@MainActor
struct DevicesAppTests {
    /// TestFlight 1.0.0 (9): Add Device says where the new device finds the vault (the sync folder's name and place,
    /// or the WebDAV server), from the vault's real targets; with none, that one is needed first.
    @Test func addDeviceNamesTheRealPlace() {
        let icloud = SyncTarget.folder(URL(fileURLWithPath:
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Sempere/Whoopie.sempere"))
        let line = AddDeviceText.instructions(targets: [icloud]) ?? ""
        #expect(line.contains("Open Vault…") && line.contains("“Whoopie.sempere”") && line.contains("iCloud Drive ▸ Sempere")
                && line.contains("Join This Device"), "\(line)")
        #expect(AddDeviceText.place(ofFolder: "/Users/me/Library/Mobile Documents/iCloud~io~github~anthonytw~sempere/Documents/Whoopie.sempere")
                == "iCloud Drive ▸ Sempere")
        #expect(AddDeviceText.place(ofFolder: "/Users/me/Library/CloudStorage/Dropbox-Personal/Notes/Whoopie.sempere")
                == "Dropbox ▸ Notes")
        #expect(AddDeviceText.place(ofFolder: "/Volumes/USB/Sync/Whoopie.sempere") == "USB ▸ Sync")
        let dav = SyncTarget.webdav("https://nas.example/dav/Whoopie/", user: "me", name: "nas")
        let both = AddDeviceText.instructions(targets: [icloud, dav]) ?? ""
        #expect(both.contains("Open from WebDAV…") && both.contains("https://nas.example/dav/Whoopie"), "\(both)")
        #expect(both.components(separatedBy: "\n").count == 2)
        #expect(AddDeviceText.instructions(targets: []) == nil)
        #expect(AddDeviceText.noTarget.contains("Add one first"))
    }

    /// Review of #109: place names for "On My iPad" and Google Drive, and no join instructions for a folder no other
    /// device reaches.
    @Test func addDeviceNamesLocalAndProviderPlaces() {
        let device = AddDeviceText.onMyDevice
        let local = "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-0000-4000-8000-000000000001/File Provider Storage/Notes/Wompa.sempere"
        // Files' local storage and other File Provider extensions share this kind of path: a neutral name, and the
        // join steps stay (review of #113).
        #expect(AddDeviceText.place(ofFolder: local) == "Notes")
        let other = "/private/var/mobile/Containers/Data/Application/0A1B2C3D-0000-4000-8000-000000000002/Documents/Sync/Wompa.sempere"
        #expect(AddDeviceText.place(ofFolder: other, container: "/elsewhere") == "\(device) ▸ Sync")
        #expect(AddDeviceText.place(ofFolder: "/home/app/Documents/Wompa.sempere", container: "/home/app") == "\(device) ▸ Sempere")
        #expect(AddDeviceText.place(ofFolder: "/Users/me/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/Wompa.sempere")
                == "Google Drive ▸ My Drive")
        #expect(!AddDeviceText.isOnlyOnThisDevice(local) && AddDeviceText.isOnlyOnThisDevice(other))
        #expect(!AddDeviceText.isOnlyOnThisDevice("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Wompa.sempere"))
        #expect(!AddDeviceText.isOnlyOnThisDevice("/Volumes/USB/Wompa.sempere"))
        let line = AddDeviceText.instructions(targets: [.folder(URL(fileURLWithPath: other))]) ?? ""
        #expect(line.contains("only on this device") && !line.contains("Join This Device"), "\(line)")
        let shared = AddDeviceText.instructions(targets: [.folder(URL(fileURLWithPath: local))]) ?? ""
        #expect(shared.contains("Join This Device"), "\(shared)")
    }

    /// A vault created by this device (home, "Home iPad"), with `others` approved and confirmed.
    struct World {
        let url: URL
        let home: DeviceKeys
        let homeTrust: MemoryEpochTrustStore
        let recovery: MLKEM768X25519Identity
        var others: [String: (keys: DeviceKeys, trust: MemoryEpochTrustStore)] = [:]

        init(others names: [String]) throws {
            let parent = TestTemp.root.appendingPathComponent("Devices-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            homeTrust = MemoryEpochTrustStore()
            var request = NewVaultRequest(name: "Mine", keySource: .generate, passphrase: nil)
            request.deviceName = "Home iPad"
            request.workFactor = 10
            let created = try VaultLibrary.createVault(request, folder: "Mine.sempere", in: parent, trust: homeTrust)
            url = created.url
            home = created.device
            guard case .mlkem768x25519(let r)? = try created.secretKey.map(IdentityFile.parse) else { throw CancellationError() }
            recovery = r
            var vault = try Vault.open(at: url, identities: [home.nativeIdentity], signing: home.signing, trust: homeTrust)
            for name in names {
                let keys = try DeviceKeys.generate()
                let words = try vault.approveDevice(keys.joinRequest(vaultId: vault.vaultId, name: name, kind: "iphone"))
                let trust = MemoryEpochTrustStore()
                var v = try Vault.open(at: url, identities: [keys.nativeIdentity], signing: keys.signing, trust: trust)
                try v.confirmJoin(words: words)
                others[name] = (keys, trust)
            }
        }

        @MainActor func model(_ name: String? = nil, defaults: UserDefaults? = nil) async throws -> AppModel {
            let (keys, trust) = name.flatMap { others[$0] } ?? (home, homeTrust)
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
            model.deviceMemory = defaults ?? DevicesAppTests.defaults()
            try await model.openVault(at: url)
            try await model.unlock(device: keys)
            return model
        }
    }

    nonisolated static func defaults() -> UserDefaults {
        TestDefaults.suite("DevicesAppTests-\(UUID().uuidString)") ?? .standard
    }

    struct PassingOwner: OwnerAuthenticator {
        func authenticate(reason: OwnerCheckReason) async throws {}
    }

    /// The history's lines name the devices (`DeviceChangeText.history`), after a removal, a handoff and the creation.
    @Test func theHistoryLinesNameTheDevices() async throws {
        let w = try World(others: ["Phone", "Old Mac", "Mac"])
        let model = try await w.model()
        defer { model.close() }
        #expect(DeviceChangeText.history(try #require(try await model.loadDeviceList().history.first)).contains("Home iPad"))
        _ = try await model.removeDevices([try #require(w.others["Old Mac"]?.keys.id)])
        #expect(DeviceChangeText.history(try #require(try await model.loadDeviceList().history.first)).contains("Old Mac"))
        _ = try await model.makeHome(try #require(w.others["Mac"]?.keys.id))
        #expect(DeviceChangeText.history(try #require(try await model.loadDeviceList().history.first)).contains("Mac"))
    }

    /// The takeover banner names the device and says what to do (`TakeoverAlert.message`).
    @Test func theTakeoverAlertNamesTheDevice() {
        let alert = TakeoverAlert(vaultID: UUID(), epochIds: [Data(count: 32)], vaultName: "Mine", by: "New iPad", date: Date())
        #expect(alert.message.contains("New iPad"))
        #expect(alert.message.contains("Mine"))
        #expect(alert.message.contains("replace the recovery kit"))
        #expect(!TakeoverAlert(vaultID: UUID(), epochIds: [], vaultName: "Mine", by: nil, date: nil).message.isEmpty)
    }

    /// The sheets' messages for the library's typed errors (`DeviceChangeText.message`): the re-encryption's refusals
    /// say which target and why, as before they were typed.
    @Test func theTypedRefusalsHaveTheirWords() {
        let refused = DeviceChangeText.message(ReencryptRefusal.targetUnreachable(name: "nas", error: AppModel.KeyError.notUnlocked))
        #expect(refused.contains("“nas” cannot be reached (") && refused.contains("Unlock the vault first."), "\(refused)")
        #expect(refused.contains("every sync target must be, to start"))
        #expect(DeviceChangeText.message(ReencryptRefusal.targetCannotBeOpened) == "This target cannot be opened for re-encryption.")
        #expect(DeviceChangeText.message(KeyProblem.recoveryKeyNeeded).contains("AGE-SECRET-KEY-PQ-1"))
        #expect(DeviceChangeText.message(DeviceJoinError.rootNeeded).contains("root fingerprint"))
        #expect(AppModel.KeyError.vaultChanged.description.contains("Another vault"))
        #expect(DeviceKeyReason.unlock(vaultName: "Mine").text.contains("Mine"))
        #expect(DeviceKeyReason.withdrawJoin.text.isEmpty)
        #expect(OwnerCheckReason.approveDevice.text == "Let a new device into the vault")
    }

    /// The sheet's "Lost or Stolen" removes the device and the ones it approved; its storage advice names the servers.
    @Test func theRemovalSheetAddsTheApprovedDevicesAndNamesTheServers() {
        #expect(Set(RemoveDeviceSheet.ids(removing: "aaaaaaaa", approved: ["bbbbbbbb"])) == ["aaaaaaaa", "bbbbbbbb"])
        #expect(RemoveDeviceSheet.storageAdvice(servers: [], hasFolder: false).contains("no sync targets"))
        #expect(RemoveDeviceSheet.storageAdvice(servers: ["nas"], hasFolder: false).contains("nas"))
        #expect(!RemoveDeviceSheet.storageAdvice(servers: ["nas"], hasFolder: false).contains("iCloud"))
    }

    /// Review of #87, M2: the line typed back is never the fixed prefix line.
    @Test func theKitCheckNeverAsksForThePrefixLine() throws {
        let kit = try MLKEM768X25519Identity()
        let lines = PaperKey.identityLines(kit.string)
        #expect(lines.first.map { PaperKey.identityPrefixes.contains($0.text) } == true, "line 1 is the prefix")
        for pick in [{ (r: ClosedRange<Int>) in r.lowerBound }, { (r: ClosedRange<Int>) in r.upperBound }] {
            let n = ReplaceKitSheet.checkLine(of: kit.string, random: pick)
            #expect(n >= 2 && n <= lines.count)
            #expect(!PaperKey.identityPrefixes.contains(lines[n - 1].text))
        }
        for _ in 0..<50 { #expect(ReplaceKitSheet.checkLine(of: kit.string) != 1) }
        #expect(!ReplaceKitSheet.lineMatches("AGE-SECRET-KEY-PQ-1", line: 2, of: kit.string))
    }

    @Test func theKitLineCheckTakesAnyCaseAndSpacesButOnlyThatLine() throws {
        let kit = try MLKEM768X25519Identity()
        let lines = PaperKey.identityLines(kit.string)
        let line2 = lines[1]
        #expect(ReplaceKitSheet.lineMatches(line2.groups.joined(separator: " ").lowercased(), line: 2, of: kit.string))
        #expect(ReplaceKitSheet.lineMatches(line2.text, line: 2, of: kit.string))
        #expect(!ReplaceKitSheet.lineMatches(line2.text, line: 3, of: kit.string))
        #expect(!ReplaceKitSheet.lineMatches("", line: 2, of: kit.string))
        #expect(!ReplaceKitSheet.lineMatches(line2.text, line: lines.count + 1, of: kit.string))
    }

    @Test func theNoticesHaveTheirWords() {
        for notice in [DeviceNotice.unlisted, .heldBack(since: Date()), .homeConflict] {
            #expect(!notice.text.isEmpty)
            #expect(!notice.symbol.isEmpty)
        }
    }
}

/// A removal reaching a device over sync (design §5.5): its runs report it unlisted, the banner says so, and the
/// model refuses writes. A device that cannot verify the change yet is held back, and says so after a day.
@Suite(.serialized)
@MainActor
struct UnlistedOverSyncAppTests {
    struct Setup {
        var home: Vault
        let model: AppModel
        let phone: DeviceKeys
        let sync: () throws -> Void
        let server: EngineWebDAVRemote
        let homeKeys: DeviceKeys
        let listing: WebDAVVaultListing
    }

    /// Home (the fixture's device, as the CLI would) approves a phone; the phone connects over WebDAV and,
    /// with `trust`, confirms its join as the app will (KH5 part 2), then unlocks.
    static func setUp(trust: MemoryEpochTrustStore?, writeStores: URL? = nil) async throws -> Setup {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let server = EngineWebDAVRemote(store: MemoryStore(name: "server"))
        let homeKeys = try DeviceKeys.parse(try String(contentsOf: keyURL, encoding: .utf8))
        var home = try Vault.open(at: vault, identities: [homeKeys.nativeIdentity], signing: homeKeys.signing)
        let phone = try DeviceKeys.generate()
        let words = try home.approveDevice(phone.joinRequest(vaultId: home.vaultId, name: "Phone", kind: "iphone"))
        let homeState = vault.deletingLastPathComponent().appendingPathComponent("home-sync.json")
        let sync = {
            _ = try SyncEngine(directory: vault, vault: try Vault.open(at: vault, identities: [homeKeys.nativeIdentity],
                                                                      signing: homeKeys.signing),
                               remote: server.remote, stateURL: homeState, options: SyncOptions()).run()
        }
        try sync()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.appendingPathComponent("vault.json")))
        let vaultId = try #require((manifest as? [String: Any])?["vaultId"] as? String).lowercased()
        let listing = WebDAVVaultListing(path: [], name: "Shared", vaultId: vaultId, format: "sempere/1",
                                         url: "https://dav.example.org/shared/")
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: trust)
        model.deviceMemory = DevicesAppTests.defaults()
        if let writeStores {
            model.writeStores = DeviceWriteStores(ledgerDirectory: writeStores.appendingPathComponent("Ledger"),
                                                  setAside: SetAsideStore(directory: writeStores.appendingPathComponent("SetAside")),
                                                  key: { Data(repeating: 7, count: 32) })
        }
        model.webdavRemote = server
        model.webdavPasswords = MemoryWebDAVPasswordStore()
        model.webdavTick = .milliseconds(20)
        model.webdavWriteDelay = 0.05
        let library = VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("recents-\(UUID().uuidString).json"))
        let location = try await model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: library)
        if let trust {
            let folder = try #require(model.webdavLocations.location(location).map { model.webdavLocations.copy(of: $0).folder })
            var v = try Vault.open(at: folder, identities: [phone.nativeIdentity], signing: phone.signing, trust: trust)
            try v.confirmJoin(words: words)
        }
        try await model.unlock(device: phone)
        _ = await model.webdav?.syncNow()
        #expect(model.deviceNotices.isEmpty)
        return Setup(home: home, model: model, phone: phone, sync: sync, server: server, homeKeys: homeKeys, listing: listing)
    }

    @Test func aDeviceRemovedElsewhereShowsTheBannerAndWritesNothing() async throws {
        var s = try await Self.setUp(trust: MemoryEpochTrustStore())
        let model = s.model
        defer { model.close() }
        #expect(model.listAlert == nil, "the join is confirmed")
        _ = try await model.createNote(title: "Before", paper: Paper(kind: .ruled), notebook: nil)
        _ = await model.webdav?.syncNow()
        try s.home.removeDevices([s.phone.id])
        try s.sync()
        _ = await model.webdav?.syncNow()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.deviceNotices.contains(.unlisted) },
                "\(String(describing: model.webdav?.lastReport?.epoch))")
        #expect(model.isUnlisted)
        #expect(model.isVaultReadOnly)
        #expect(await TS.waitUntil { model.vault?.unlistedNotice != nil }, "the vault was opened again: it refuses writes itself")
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
        var s = try await Self.setUp(trust: MemoryEpochTrustStore(), writeStores: root)
        let model = s.model
        defer { model.close() }
        let qc = Self.quickCapture(for: model)
        try model.enableQuickCapture(notebook: "Field", transcribe: false)
        // A voice note in progress when the removal arrives.
        try await qc.start()
        #expect(qc.state == .recording)

        try s.home.removeDevices([s.phone.id])
        try s.sync()
        _ = await model.webdav?.syncNow()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.vault?.unlistedNotice != nil })
        #expect(await TS.waitUntil { (try? model.storedQuickCaptureProfile())??.suspended == true }, "suspended, not deleted")
        #expect(try model.storedQuickCaptureProfile()?.profile.notebook == "Field")

        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault, "the recording in progress is still sealed")
        await #expect(throws: QuickCaptureError.notOnDeviceList) { try await qc.start() }
        #expect(qc.state == .idle)
        // A recording a crash left: the sweep still seals it.
        let leftover = try QuickCaptureTests.crashLeftRecording(in: qc.root)
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
        let w = try DevicesAppTests.World(others: ["Phone"])
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

    /// A quick-capture instance for `model` that records with the fake backend and keeps its files in temp folders.
    static func quickCapture(for model: AppModel) -> QuickCapture {
        let qc = QuickCapture.testing()
        if let stores = model.writeStores { qc.ledger = { stores.ledger(for: $0) } }
        model.quickCapture = qc
        return qc
    }

    /// Design §5.2 step 2: a target the run before a change cannot reach is named; the change goes ahead.
    @Test func aChangeWhoseTargetCannotBeReachedNamesIt() async throws {
        let s = try await Self.setUp(trust: nil)
        s.model.close()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.deviceMemory = DevicesAppTests.defaults()
        model.webdavRemote = s.server
        model.webdavPasswords = MemoryWebDAVPasswordStore()
        model.webdavTick = .milliseconds(20)
        model.deviceChangeRunBound = 2
        let library = VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("recents-\(UUID().uuidString).json"))
        _ = try await model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: library)
        try await model.unlock(device: s.homeKeys)
        defer { model.close() }
        #expect(model.vault?.isHome == true)
        try await model.completePartialCopy()   // a change needs the whole copy
        s.server.failing(URLError(.notConnectedToInternet))
        let done = try await model.removeDevices([s.phone.id])
        #expect(done.report.reason == .remove)
        #expect(done.unreachable.count == 1)
        #expect(DeviceChangeText.done(done, action: "Removed.").contains("was not reachable"))
        s.server.failing(nil)
    }

    @Test func aChangeThatCannotBeVerifiedHoldsSyncBackAndSaysSoAfterADay() async throws {
        var s = try await Self.setUp(trust: nil)
        let model = s.model
        defer { model.close() }
        try s.home.removeDevices([s.phone.id])
        try s.sync()
        _ = await model.webdav?.syncNow()
        let since = try #require(model.webdav?.lastReport?.epoch?.heldSince, "\(String(describing: model.webdav?.lastReport))")
        #expect(model.deviceNotices.isEmpty, "held back for less than a day: no banner")
        model.deviceNoticeNow = { since.addingTimeInterval(2 * 86_400) }
        #expect(model.deviceNotices == [.heldBack(since: since)])
    }
}
