import Age
import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// The device list in the app (key-hierarchy design §5.5, §6.3 to §6.5; phase KH5): rows and history, rename,
/// removal, Make Home and Replace Recovery Kit through the model (the vault opened again under each new epoch),
/// takeover alerts and the words the sheets show. One shared vault folder, devices in process (no sync).
@Suite(.serialized)
@MainActor
struct DevicesAppTests {
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
            model.takeoverDefaults = defaults ?? DevicesAppTests.defaults()
            try await model.openVault(at: url)
            try await model.unlock(device: keys)
            return model
        }
    }

    nonisolated static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "DevicesAppTests-\(UUID().uuidString)") ?? .standard
    }

    struct PassingOwner: OwnerAuthenticator {
        func authenticate(reason: String) async throws {}
    }

    @Test func theListShowsEveryDeviceWhoAddedItAndTheHistory() async throws {
        let w = try World(others: ["Phone"])
        let model = try await w.model()
        defer { model.close() }
        let list = try await model.loadDeviceList()
        #expect(list.thisIsHome)
        #expect(list.homeName == "Home iPad")
        #expect(list.devices.map(\.name) == ["Home iPad", "Phone"])
        let home = try #require(list.devices.first)
        #expect(home.isHome && home.isThisDevice)
        #expect(home.addedBy == .creation)
        #expect(home.symbol == "ipad")
        let phone = try #require(list.devices.last)
        #expect(phone.addedBy == .device("Home iPad"))
        #expect(!phone.isHome && !phone.isThisDevice)
        #expect(phone.lastSynced == nil)
        #expect(list.history.map(\.reason) == [.create])
        #expect(DeviceChangeText.history(try #require(list.history.first)).contains("Home iPad"))
        #expect(list.recoveryAdded != nil)
        #expect(!list.passphraseCopy)
    }

    @Test func homeRenamesAndAnotherDeviceSeesWhoManagesDevices() async throws {
        let w = try World(others: ["Phone"])
        let model = try await w.model()
        defer { model.close() }
        let phoneID = try #require(w.others["Phone"]?.keys.id)
        try await model.renameDevice(phoneID, to: "Alex's iPhone")
        #expect(try await model.loadDeviceList().devices.last?.name == "Alex's iPhone")

        let phone = try await w.model("Phone")
        defer { phone.close() }
        let seen = try await phone.loadDeviceList()
        #expect(!seen.thisIsHome)
        #expect(seen.homeName == "Home iPad")
        await #expect(throws: VaultError.self, "only home renames") { try await phone.renameDevice(phoneID, to: "Mine") }
    }

    @Test func aRemovalStartsANewEpochReopensTheVaultAndShowsInTheHistory() async throws {
        let w = try World(others: ["Phone", "Old Mac"])
        let model = try await w.model()
        defer { model.close() }
        _ = try await model.createNote(title: "Before", paper: Paper(kind: .ruled), notebook: nil)
        let oldMac = try #require(w.others["Old Mac"]?.keys.id)
        let review = try #require(try await model.removalReview([oldMac]).first)
        #expect(review.stale, "no recorded sync")
        #expect(review.approved.isEmpty)
        let epochBefore = model.keyEpoch
        let done = try await model.removeDevices([oldMac])
        #expect(done.report.epoch == 2)
        #expect(done.report.reason == .remove)
        #expect(done.unreachable.isEmpty, "no targets")
        #expect(model.vault?.manifest.epoch == 2)
        #expect(model.keyEpoch > epochBefore, "editors reopened under the new key")
        #expect(!model.isChangingKeys)
        let list = try await model.loadDeviceList()
        #expect(list.devices.map(\.name) == ["Home iPad", "Phone"])
        #expect(list.history.map(\.reason) == [.remove, .create])
        #expect(DeviceChangeText.history(try #require(list.history.first)).contains("Old Mac"))
        // Writes go on under the new key; the phone follows.
        _ = try await model.createNote(title: "After", paper: Paper(kind: .ruled), notebook: nil)
        let phone = try await w.model("Phone")
        defer { phone.close() }
        #expect(phone.notes.count == 2)
        #expect(phone.vault?.manifest.epoch == 2)
    }

    @Test func makeHomeHandsTheRoleOver() async throws {
        let w = try World(others: ["Mac"])
        let model = try await w.model()
        defer { model.close() }
        let mac = try #require(w.others["Mac"]?.keys.id)
        let done = try await model.makeHome(mac)
        #expect(done.report.reason == .handoff)
        let list = try await model.loadDeviceList()
        #expect(!list.thisIsHome)
        #expect(list.homeName == "Mac")
        #expect(list.history.first?.reason == .handoff)
        #expect(DeviceChangeText.history(try #require(list.history.first)) .contains("Mac"))
        await #expect(throws: VaultError.self, "not home any more") { _ = try await model.makeHome(mac) }
    }

    @Test func replacingTheKitNeedsEveryDeviceAnsweredAndRetiresTheOldKit() async throws {
        let w = try World(others: ["Phone", "Lost iPad"])
        let model = try await w.model()
        defer { model.close() }
        model.ownerAuthenticator = PassingOwner()
        let review = try await model.kitReview()
        #expect(Set(review.compactMap(\.device.id)) == Set(w.others.values.map(\.keys.id)))
        let phone = try #require(w.others["Phone"]?.keys.id), lost = try #require(w.others["Lost iPad"]?.keys.id)
        let newKit = try MLKEM768X25519Identity()
        await #expect(throws: VaultError.self, "every device must be answered") {
            _ = try await model.replaceRecoveryKit(newKit, keep: [phone], remove: [], oldKit: nil, passphrase: nil)
        }
        await #expect(throws: VaultLibrary.LibraryError.self, "a weak passphrase is refused first") {
            _ = try await model.replaceRecoveryKit(newKit, keep: [phone], remove: [lost], oldKit: nil, passphrase: "short")
        }
        let done = try await model.replaceRecoveryKit(newKit, keep: [phone], remove: [lost], oldKit: w.recovery, passphrase: nil)
        #expect(done.report.reason == .recovery)
        #expect(model.vault?.manifest.recoveryEntry?.key == newKit.recipient.string)
        let list = try await model.loadDeviceList()
        #expect(list.devices.map(\.name) == ["Home iPad", "Phone"])
        #expect(list.history.first?.reason == .recovery)
    }

    /// Review of #87, M1: a takeover whose parent is below this device's frontier gets an epoch number at or below
    /// the one it had seen; it is still reported (acknowledged by id, not by number).
    @Test func aTakeoverFromBelowTheFrontierIsStillReported() async throws {
        let w = try World(others: ["Phone", "Pad"])
        let defaults = Self.defaults()
        let home = try await w.model(defaults: defaults)
        let x = try #require(w.others["Pad"]?.keys.id)
        _ = try await home.removeDevices([x])   // epoch 2: the home (as a thief would) removes the pad
        home.close()
        let phone = try await w.model("Phone", defaults: defaults)
        #expect(phone.vault?.manifest.epoch == 2)
        #expect(phone.takeoverAlert == nil, "first sight")
        phone.close()
        // Someone with the kit takes over on the pad, from epoch 1 (its frontier): the takeover is epoch 2 too.
        let pad = try #require(w.others["Pad"])
        let (taken, _) = try Vault.takeover(at: w.url, device: pad.keys, recovery: w.recovery,
                                            keep: [try #require(w.others["Phone"]?.keys.fingerprint)], name: "Pad", kind: "ipad",
                                            trust: pad.trust, root: nil)
        #expect(taken.manifest.epoch == 2)
        let again = try await w.model("Phone", defaults: defaults)
        defer { again.close() }
        #expect(again.vault?.manifest.epochId == taken.manifest.epochId, "the phone follows the takeover")
        let alert = try #require(again.takeoverAlert, "reported although its number is the one seen before")
        #expect(alert.by == "Pad")
        again.dismissTakeoverAlert()
        await again.checkTakeovers()
        #expect(again.takeoverAlert == nil)
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

    /// Review of #87, S1: a change that fails leaves the editors open again and the vault following the disk, also
    /// when it failed after writing its `vault.json`.
    @Test func aFailedChangeReopensTheEditorAndFollowsTheDisk() async throws {
        struct Boom: Error {}
        let w = try World(others: ["Phone", "Old Mac"])
        let model = try await w.model()
        defer { model.close() }
        let note = try await model.createNote(title: "Open", paper: Paper(kind: .ruled), notebook: nil)
        try await model.openEditor(for: note)
        await #expect(throws: Boom.self) { _ = try await model.performDeviceChange { _ in throw Boom() } }
        #expect(model.editor?.noteID == note, "the editor is back")
        #expect(!model.isChangingKeys)
        let oldMac = try #require(w.others["Old Mac"]?.keys.id)
        await #expect(throws: Boom.self) {
            _ = try await model.performDeviceChange { v in
                _ = try v.removeDevices([oldMac])
                throw Boom()
            }
        }
        #expect(model.vault?.manifest.epoch == 2, "the vault follows what was written")
        #expect(model.editor?.noteID == note)
        _ = try await model.createNote(title: "Under the new key", paper: Paper(kind: .ruled), notebook: nil)
    }

    /// The sheet's "Lost or Stolen": the devices the removed one approved go too (the current home never).
    @Test func removingAFormerHomeAlsoRemovesTheDevicesItApproved() async throws {
        let w = try World(others: ["Mac", "Spare"])
        let first = try await w.model()
        let mac = try #require(w.others["Mac"]?.keys.id)
        _ = try await first.makeHome(mac)
        first.close()
        let model = try await w.model("Mac")
        defer { model.close() }
        let homePad = try #require(model.vault?.manifest.devices.first { $0.name == "Home iPad" }?.id)
        let review = try #require(try await model.removalReview([homePad]).first)
        #expect(review.approved.map(\.name) == ["Spare"], "the Mac manages devices now and is never offered")
        let ids = RemoveDeviceSheet.ids(removing: homePad, approved: Set(review.approved.compactMap(\.id)))
        _ = try await model.removeDevices(ids)
        #expect(try await model.loadDeviceList().devices.map(\.name) == ["Mac"])
        #expect(RemoveDeviceSheet.storageAdvice(servers: [], hasFolder: false).contains("no sync targets"))
        #expect(RemoveDeviceSheet.storageAdvice(servers: ["nas"], hasFolder: false).contains("nas"))
        #expect(!RemoveDeviceSheet.storageAdvice(servers: ["nas"], hasFolder: false).contains("iCloud"))
    }

    /// Repair through the model (design §5.8): Export copies a set-aside file, Keep of a body the vault holds changes
    /// nothing, Delete removes it from this device.
    @Test func repairExportsKeepsAndClearsSetAsideFiles() async throws {
        let w = try World(others: [])
        let root = try TestTemp.directory("repair")
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: w.homeTrust)
        model.takeoverDefaults = Self.defaults()
        let setAside = SetAsideStore(directory: root.appendingPathComponent("SetAside"))
        model.writeStores = DeviceWriteStores(ledgerDirectory: root.appendingPathComponent("Ledger"), setAside: setAside,
                                              key: { Data(repeating: 7, count: 32) })
        try await model.openVault(at: w.url)
        try await model.unlock(device: w.home)
        defer { model.close() }
        let note = try await model.createNote(title: "Kept", paper: Paper(kind: .ruled), notebook: nil)
        let vault = try #require(model.vault)
        let name = try #require(try vault.revisionNames(of: note).first).description
        let path = "notes/\(note.uuidString.lowercased())/\(name)"
        _ = try setAside.keep(try Data(contentsOf: w.url.appendingPathComponent(path)), path: path, vaultId: vault.vaultId,
                              reason: .notSealed, epoch: 1)
        let items = await model.setAsideItems()
        #expect(items.count == 1)
        let out = try TestTemp.directory("repair-out")
        #expect(try await model.exportSetAside(items.map(\.item), to: out) == 1)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(path).path))
        try await model.keepSetAside(items.map(\.item))
        try await model.clearSetAside(items.map(\.item))
        #expect(await model.setAsideItems().isEmpty)
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

    @Test func aTakeoverByAnotherDeviceRaisesTheAlertUntilDismissed() async throws {
        let w = try World(others: ["Phone"])
        let defaults = Self.defaults()
        let model = try await w.model("Phone", defaults: defaults)
        #expect(model.takeoverAlert == nil, "first sight: nothing before it is reported")
        model.close()
        // The owner's new iPad takes over with the kit, keeping the phone.
        let newcomer = try DeviceKeys.generate()
        let phone = try #require(w.others["Phone"])
        let root = try Vault.open(at: w.url).root
        _ = try Vault.takeover(at: w.url, device: newcomer, recovery: w.recovery, keep: [phone.keys.fingerprint],
                               name: "New iPad", kind: "ipad", trust: MemoryEpochTrustStore(), root: root)
        let again = try await w.model("Phone", defaults: defaults)
        defer { again.close() }
        let alert = try #require(again.takeoverAlert)
        #expect(alert.by == "New iPad")
        #expect(alert.message.contains("New iPad"))
        #expect(alert.message.contains("replace the recovery kit"))
        again.dismissTakeoverAlert()
        #expect(again.takeoverAlert == nil)
        await again.checkTakeovers()
        #expect(again.takeoverAlert == nil, "acknowledged")
        let list = try await again.loadDeviceList()
        #expect(list.homeName == "New iPad")
        #expect(list.history.first?.reason == .takeover)
        #expect(list.devices.first { $0.name == "New iPad" }?.addedBy == .recoveryKit)
    }

    @Test func theUnlistedFactsNameTheNotesOfTheUnsyncedFiles() {
        let a = UUID(), b = UUID()
        let facts = UnlistedFacts(by: "Home iPad", seen: Date(), unsynced: [
            "notes/\(a.uuidString.lowercased())/x.delta.age", "notes/\(a.uuidString.lowercased())/att/y.image.age",
            "notes/\(b.uuidString.lowercased())/z.delta.age", "settings.age", "inbox/c.capture.age",
        ])
        #expect(facts.notes == [a, b])
    }

    @Test func theNoticesHaveTheirWords() {
        for notice in [DeviceNotice.unlisted, .heldBack(since: Date()), .homeConflict] {
            #expect(!notice.text.isEmpty)
            #expect(!notice.symbol.isEmpty)
        }
    }

    @Test func anOpenVaultWithNoDeviceProblemsShowsNoBanner() async throws {
        let w = try World(others: [])
        let model = try await w.model()
        defer { model.close() }
        #expect(model.deviceNotices.isEmpty)
        #expect(!model.isUnlisted)
        #expect(model.sightingRows.isEmpty)
        #expect(await model.setAsideItems().isEmpty)
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
        model.takeoverDefaults = DevicesAppTests.defaults()
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

    /// Review of #87, M3: once unlisted, the device takes no more voice notes (its profile is gone), and the ones it
    /// holds that never reached a target are counted apart and saved by Save Files.
    @Test func anUnlistedDeviceStopsTakingVoiceNotesAndSavesTheOnesItHolds() async throws {
        let root = try TestTemp.directory("unlisted-capture")
        var s = try await Self.setUp(trust: MemoryEpochTrustStore(), writeStores: root)
        let model = s.model
        defer { model.close() }
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        model.quickCapture = qc
        try model.enableQuickCapture()
        let profile = try #require(try model.storedQuickCaptureProfile()).profile
        // A voice note recorded here that has not reached the server yet.
        let writer = try CaptureWriter(profile: profile)
        let sealed = try writer.seal(audio: Data("audio".utf8), started: Date())
        let vaultID = try #require(model.vault?.vaultId)
        try writer.record(sealed, in: try #require(model.writeStores).ledger(for: vaultID))
        let folder = try #require(model.vaultURL)
        try CaptureWriter.store(sealed, in: folder.appendingPathComponent("inbox"))

        try s.home.removeDevices([s.phone.id])
        try s.sync()
        _ = await model.webdav?.syncNow()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.vault?.unlistedNotice != nil })
        #expect(try model.storedQuickCaptureProfile() == nil, "quick capture is suspended")
        let facts = await model.unlistedFacts()
        #expect(facts.captures == 1, "\(facts.unsynced)")
        #expect(facts.unsynced.contains("inbox/\(sealed.name)"))
        #expect(facts.notes.isEmpty, "Export of notes would not cover it")
        let out = try TestTemp.directory("unlisted-out")
        #expect(try await model.exportUnsyncedFiles(facts.unsynced, to: out) == facts.unsynced.count)
        let saved = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        let inbox = try #require(saved.first).appendingPathComponent("inbox/\(sealed.name)")
        #expect(try Data(contentsOf: inbox) == sealed.data)

        // Forget All (the warning's choice) forgets the removal marker: the vault reopens listed until a sync meets
        // the change again.
        #expect(!model.sightingRows.isEmpty)
        try await model.forgetSightings(anchoredToo: true)
        #expect(model.vault?.unlistedNotice == nil)
        #expect(model.sightingRows.isEmpty)
    }

    /// Design §5.2 step 2: a target the run before a change cannot reach is named; the change goes ahead.
    @Test func aChangeWhoseTargetCannotBeReachedNamesIt() async throws {
        let s = try await Self.setUp(trust: nil)
        s.model.close()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.takeoverDefaults = DevicesAppTests.defaults()
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
