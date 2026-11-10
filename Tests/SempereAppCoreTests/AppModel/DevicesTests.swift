import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

/// A vault created by this device (home, "Home iPad"), with `others` approved and confirmed: devices in process on
/// one vault folder, no sync.
struct DeviceWorld: Sendable {
    let url: URL
    let home: DeviceKeys
    let homeTrust: MemoryEpochTrustStore
    let recovery: MLKEM768X25519Identity
    var others: [String: (keys: DeviceKeys, trust: MemoryEpochTrustStore)] = [:]

    /// Made off the main actor (key generation, the vault's creation and the approvals).
    @concurrent static func make(others names: [String]) async throws -> DeviceWorld {
        let parent = TestTemp.root.appendingPathComponent("Devices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let homeTrust = MemoryEpochTrustStore()
        var request = NewVaultRequest(name: "Mine", keySource: .generate, passphrase: nil)
        request.deviceName = "Home iPad"
        request.workFactor = 10
        let created = try VaultLibrary.createVault(request, folder: "Mine.sempere", in: parent, trust: homeTrust)
        guard case .mlkem768x25519(let recovery)? = try created.secretKey.map(IdentityFile.parse) else { throw CancellationError() }
        var world = DeviceWorld(url: created.url, home: created.device, homeTrust: homeTrust, recovery: recovery)
        var vault = try Vault.open(at: created.url, identities: [created.device.nativeIdentity], signing: created.device.signing,
                                   trust: homeTrust)
        for name in names {
            let keys = try DeviceKeys.generate()
            let words = try vault.approveDevice(keys.joinRequest(vaultId: vault.vaultId, name: name, kind: "iphone"))
            let trust = MemoryEpochTrustStore()
            var v = try Vault.open(at: created.url, identities: [keys.nativeIdentity], signing: keys.signing, trust: trust)
            try v.confirmJoin(words: words)
            world.others[name] = (keys, trust)
        }
        return world
    }

    /// The model of `name` (home when nil), unlocked; `memory` is where it remembers takeovers and names (shared by
    /// the models of one device).
    @MainActor func model(_ name: String? = nil, memory: (any KeyValueStore)? = nil) async throws -> AppModel {
        let (keys, trust) = name.flatMap { others[$0] } ?? (home, homeTrust)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        if let memory { model.deviceMemory = memory }
        try await model.openVault(at: url)
        try await model.unlock(device: keys)
        return model
    }

    /// A takeover with the kit by `device`, off the main actor.
    @concurrent func takeover(by device: DeviceKeys, keep: Set<Data>, name: String, trust: MemoryEpochTrustStore,
                              root: Data?) async throws -> Vault {
        try Vault.takeover(at: url, device: device, recovery: recovery, keep: keep, name: name, kind: "ipad", trust: trust,
                           root: root).0
    }

    /// The vault's root (read off the main actor).
    @concurrent func root() async throws -> Data { try Vault.open(at: url).root }
}

extension AppModelSuites {
    /// The device list through the model (key-hierarchy design §5.5, §6.3 to §6.5; phase KH5; moved from the app's
    /// `DevicesAppTests`, which keeps the sheets' words): rows and history, rename, removal, Make Home and Replace
    /// Recovery Kit (the vault opened again under each new epoch), takeover alerts, Repair, the passphrase copy and
    /// re-encryption's steps.
    @MainActor
    struct DevicesTests {
        @Test func theListShowsEveryDeviceWhoAddedItAndTheHistory() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let model = try await w.model()
            defer { model.close() }
            let list = try await model.loadDeviceList()
            #expect(list.thisIsHome)
            #expect(list.homeName == "Home iPad")
            #expect(list.devices.map(\.name) == ["Home iPad", "Phone"])
            let home = try #require(list.devices.first)
            #expect(home.isHome && home.isThisDevice)
            #expect(home.addedBy == .creation)
            #expect(home.kind == "ipad")
            let phone = try #require(list.devices.last)
            #expect(phone.addedBy == .device("Home iPad"))
            #expect(!phone.isHome && !phone.isThisDevice)
            #expect(phone.lastSynced == nil)
            #expect(list.history.map(\.reason) == [.create])
            #expect(list.history.first?.author.name == "Home iPad")
            #expect(list.recoveryAdded != nil)
            #expect(!list.passphraseCopy)
            #expect(model.vaultDevices.filter(\.isRecovery).count == 1)
            #expect(model.vaultDevices.first { $0.isThisDevice }?.isHome == true)
        }

        @Test func homeRenamesAndAnotherDeviceSeesWhoManagesDevices() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
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
            let w = try await DeviceWorld.make(others: ["Phone", "Old Mac"])
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
            #expect(list.history.first?.removed.map(\.name) == ["Old Mac"], "named from this device's memory")
            // Writes go on under the new key; the phone follows.
            _ = try await model.createNote(title: "After", paper: Paper(kind: .ruled), notebook: nil)
            let phone = try await w.model("Phone")
            defer { phone.close() }
            #expect(phone.notes.count == 2)
            #expect(phone.vault?.manifest.epoch == 2)
        }

        @Test func makeHomeHandsTheRoleOver() async throws {
            let w = try await DeviceWorld.make(others: ["Mac"])
            let model = try await w.model()
            defer { model.close() }
            let mac = try #require(w.others["Mac"]?.keys.id)
            let done = try await model.makeHome(mac)
            #expect(done.report.reason == .handoff)
            let list = try await model.loadDeviceList()
            #expect(!list.thisIsHome)
            #expect(list.homeName == "Mac")
            #expect(list.history.first?.reason == .handoff)
            #expect(list.history.first?.newHome?.name == "Mac")
            await #expect(throws: VaultError.self, "not home any more") { _ = try await model.makeHome(mac) }
        }

        @Test func replacingTheKitNeedsEveryDeviceAnsweredAndRetiresTheOldKit() async throws {
            let w = try await DeviceWorld.make(others: ["Phone", "Lost iPad"])
            let model = try await w.model()
            defer { model.close() }
            let review = try await model.kitReview()
            #expect(Set(review.compactMap(\.device.id)) == Set(w.others.values.map(\.keys.id)))
            let phone = try #require(w.others["Phone"]?.keys.id), lost = try #require(w.others["Lost iPad"]?.keys.id)
            let newKit = try MLKEM768X25519Identity()
            let owner = ScriptedOwnerCheck(.pass)
            model.ownerAuthenticator = owner
            await #expect(throws: VaultError.self, "every device must be answered") {
                _ = try await model.replaceRecoveryKit(newKit, keep: [phone], remove: [], oldKit: nil, passphrase: nil)
            }
            let done = try await model.replaceRecoveryKit(newKit, keep: [phone], remove: [lost], oldKit: w.recovery, passphrase: "a")
            #expect(owner.reasons == [.replaceRecoveryKit, .replaceRecoveryKit], "each change asks for the owner first")
            #expect(try model.vault?.openPassphraseCopy(passphrase: "a").identity.recipient.string == newKit.recipient.string,
                    "any passphrase is taken for the new kit's copy")
            #expect(done.report.reason == .recovery)
            #expect(model.vault?.manifest.recoveryEntry?.key == newKit.recipient.string)
            let list = try await model.loadDeviceList()
            #expect(list.devices.map(\.name) == ["Home iPad", "Phone"])
            #expect(list.history.first?.reason == .recovery)
        }

        /// Replace Recovery Kit and Re-encrypt Everything ask for the device owner themselves (design §6.5 step 3, §7.1),
        /// so no front end can leave the check out: without an owner to ask (headless) or with the check refused,
        /// nothing changes: no new epoch, the old kit, no journal.
        /// Review of #27: on Mac Catalyst the passcode dialog leaves the menus usable, so the vault may be closed, or
        /// another one opened, while the owner check asks. Then neither change is made, to either vault.
        @Test func aVaultClosedOrReplacedDuringTheOwnerCheckIsNotChanged() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let other = try await DeviceWorld.make(others: [])
            let model = try await w.model()
            defer { model.close() }
            let keep = try await Self.everyDeviceKept(model)
            let before = try await Self.recoveryAndEpoch(w.url), otherBefore = try await Self.recoveryAndEpoch(other.url)
            let actions: [(String, @MainActor () async throws -> Void)] = [
                ("closed", { model.close() }),
                ("another vault opened", {
                    try await model.openVault(at: other.url)
                    try await model.unlock(device: other.home)
                }),
            ]
            for (label, act) in actions {
                for reencrypt in [false, true] {
                    if model.vaultURL?.standardizedFileURL != w.url.standardizedFileURL || model.phase != .unlocked {
                        try await model.openVault(at: w.url)
                        try await model.unlock(device: w.home)
                    }
                    model.ownerAuthenticator = ActingOwnerCheck(act)
                    await #expect(throws: (any Error).self, "\(label), re-encrypt \(reencrypt)") {
                        if reencrypt {
                            _ = try await model.startReencryption(try MLKEM768X25519Identity(), keep: keep, remove: [], passphrase: nil)
                        } else {
                            _ = try await model.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: keep, remove: [], oldKit: nil,
                                                                   passphrase: nil)
                        }
                    }
                    #expect(try await Self.recoveryAndEpoch(w.url) == before, "\(label): nothing written to the first vault")
                    #expect(try await Self.recoveryAndEpoch(other.url) == otherBefore, "\(label): nor to the other")
                    #expect(!FileManager.default.fileExists(atPath: w.url.appendingPathComponent("reencrypt-journal.age").path))
                    #expect(!FileManager.default.fileExists(atPath: other.url.appendingPathComponent("reencrypt-journal.age").path))
                }
            }
        }

        /// The recovery key and the epoch id in the vault's `vault.json` on disk (off the main actor).
        @concurrent static func recoveryAndEpoch(_ url: URL) async throws -> [String] {
            let manifest = try Vault.open(at: url).manifest
            return [manifest.recoveryEntry?.key ?? "", manifest.epochId.base64EncodedString()]
        }

        @Test func replacingTheKitAndReencryptingNeedTheOwner() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let model = try await w.model()
            defer { model.close() }
            let keep = try await Self.everyDeviceKept(model)
            let epoch = try #require(model.vault?.manifest.epochId)
            let kit = try #require(model.vault?.manifest.recoveryEntry?.key)
            await #expect(throws: OwnerCheckUnavailable.self, "headless: no owner can be asked") {
                _ = try await model.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: keep, remove: [], oldKit: nil, passphrase: nil)
            }
            await #expect(throws: OwnerCheckUnavailable.self, "headless: no owner can be asked") {
                _ = try await model.startReencryption(try MLKEM768X25519Identity(), keep: keep, remove: [], passphrase: nil)
            }
            let owner = ScriptedOwnerCheck(.refuse(CancellationError()))
            model.ownerAuthenticator = owner
            await #expect(throws: CancellationError.self) {
                _ = try await model.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: keep, remove: [], oldKit: nil, passphrase: nil)
            }
            await #expect(throws: CancellationError.self) {
                _ = try await model.startReencryption(try MLKEM768X25519Identity(), keep: keep, remove: [], passphrase: nil)
            }
            #expect(owner.reasons == [.replaceRecoveryKit, .reencrypt])
            #expect(model.vault?.manifest.epochId == epoch, "no new epoch")
            #expect(model.vault?.manifest.recoveryEntry?.key == kit, "the old kit")
            #expect(try await !model.reencryptStatus().pending)
            #expect(!FileManager.default.fileExists(atPath: try #require(model.vaultURL).appendingPathComponent("reencrypt-journal.age").path))
            let list = try await model.loadDeviceList()
            #expect(list.history.map(\.reason) == [.create])
        }

        /// Review of #87, M1: a takeover whose parent is below this device's frontier gets an epoch number at or
        /// below the one it had seen; it is still reported (acknowledged by id, not by number).
        @Test func aTakeoverFromBelowTheFrontierIsStillReported() async throws {
            let w = try await DeviceWorld.make(others: ["Phone", "Pad"])
            let memory = MemoryKeyValueStore()
            let home = try await w.model(memory: memory)
            let x = try #require(w.others["Pad"]?.keys.id)
            _ = try await home.removeDevices([x])   // epoch 2: the home (as a thief would) removes the pad
            home.close()
            let phone = try await w.model("Phone", memory: memory)
            #expect(phone.vault?.manifest.epoch == 2)
            #expect(phone.takeoverAlert == nil, "first sight")
            phone.close()
            // Someone with the kit takes over on the pad, from epoch 1 (its frontier): the takeover is epoch 2 too.
            let pad = try #require(w.others["Pad"])
            let taken = try await w.takeover(by: pad.keys, keep: [try #require(w.others["Phone"]?.keys.fingerprint)],
                                             name: "Pad", trust: pad.trust, root: nil)
            #expect(taken.manifest.epoch == 2)
            let again = try await w.model("Phone", memory: memory)
            defer { again.close() }
            #expect(again.vault?.manifest.epochId == taken.manifest.epochId, "the phone follows the takeover")
            let alert = try #require(again.takeoverAlert, "reported although its number is the one seen before")
            #expect(alert.by == "Pad")
            again.dismissTakeoverAlert()
            await again.checkTakeovers()
            #expect(again.takeoverAlert == nil)
        }

        /// Re-check of #87, M1: a device that first runs the alerts with no stored set (an upgrade) is told of a
        /// takeover made after it was added; one added after the takeover is not.
        @Test func firstSightReportsTakeoversAfterTheDeviceWasAdded() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let phone = try #require(w.others["Phone"])
            let newcomer = try DeviceKeys.generate()
            let newcomerTrust = MemoryEpochTrustStore()
            _ = try await w.takeover(by: newcomer, keep: [phone.keys.fingerprint], name: "New iPad", trust: newcomerTrust,
                                     root: try await w.root())
            let upgraded = try await w.model("Phone")
            let alert = try #require(upgraded.takeoverAlert, "added at epoch 1, before the takeover: reported")
            #expect(alert.by == "New iPad")
            upgraded.close()

            // A device the new home adds afterwards: the takeover is history from before it.
            let late = try DeviceKeys.generate()
            let lateTrust = MemoryEpochTrustStore()
            try await Self.approveAndConfirm(late, at: w.url, home: newcomer, homeTrust: newcomerTrust, trust: lateTrust)
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: lateTrust)
            try await model.openVault(at: w.url)
            try await model.unlock(device: late)
            defer { model.close() }
            #expect(model.vault?.deviceAddedEpoch == model.vault?.manifest.epoch)
            await model.checkTakeovers()
            #expect(model.takeoverAlert == nil, "added after the takeover: not reported")
        }

        @concurrent static func approveAndConfirm(_ keys: DeviceKeys, at url: URL, home: DeviceKeys,
                                                  homeTrust: MemoryEpochTrustStore, trust: MemoryEpochTrustStore) async throws {
            var vault = try Vault.open(at: url, identities: [home.nativeIdentity], signing: home.signing, trust: homeTrust)
            let words = try vault.approveDevice(keys.joinRequest(vaultId: vault.vaultId, name: "Late", kind: "iphone"))
            var joined = try Vault.open(at: url, identities: [keys.nativeIdentity], signing: keys.signing, trust: trust)
            try joined.confirmJoin(words: words)
        }

        /// Review of #87, S1: a change that fails leaves the editors open again and the vault following the disk,
        /// also when it failed after writing its `vault.json`.
        @Test func aFailedChangeReopensTheEditorAndFollowsTheDisk() async throws {
            struct Boom: Error {}
            let w = try await DeviceWorld.make(others: ["Phone", "Old Mac"])
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
            let w = try await DeviceWorld.make(others: ["Mac", "Spare"])
            let first = try await w.model()
            let mac = try #require(w.others["Mac"]?.keys.id)
            _ = try await first.makeHome(mac)
            first.close()
            let model = try await w.model("Mac")
            defer { model.close() }
            let homePad = try #require(model.vault?.manifest.devices.first { $0.name == "Home iPad" }?.id)
            let review = try #require(try await model.removalReview([homePad]).first)
            #expect(review.approved.map(\.name) == ["Spare"], "the Mac manages devices now and is never offered")
            _ = try await model.removeDevices([homePad] + review.approved.compactMap(\.id))
            #expect(try await model.loadDeviceList().devices.map(\.name) == ["Mac"])
        }

        /// Repair through the model (design §5.8): Export copies a set-aside file, Keep of a body the vault holds
        /// changes nothing, Delete removes it from this device.
        @Test func repairExportsKeepsAndClearsSetAsideFiles() async throws {
            let w = try await DeviceWorld.make(others: [])
            let root = try TestTemp.directory("repair")
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: w.homeTrust)
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

        @Test func aTakeoverByAnotherDeviceRaisesTheAlertUntilDismissed() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let memory = MemoryKeyValueStore()
            let model = try await w.model("Phone", memory: memory)
            #expect(model.takeoverAlert == nil, "first sight: nothing before it is reported")
            model.close()
            // The owner's new iPad takes over with the kit, keeping the phone.
            let newcomer = try DeviceKeys.generate()
            let phone = try #require(w.others["Phone"])
            _ = try await w.takeover(by: newcomer, keep: [phone.keys.fingerprint], name: "New iPad", trust: MemoryEpochTrustStore(),
                                     root: try await w.root())
            let notifier = RecordingNotifier()
            let again = AppModel(deviceStateURL: TS.deviceStateURL(), trust: phone.trust, backupNotifier: notifier)
            again.deviceMemory = memory
            try await again.openVault(at: w.url)
            try await again.unlock(device: phone.keys)
            defer { again.close() }
            let alert = try #require(again.takeoverAlert)
            #expect(alert.by == "New iPad")
            #expect(alert.vaultName == "Mine")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { notifier.scheduled["takeover-\(alert.vaultID.uuidString)"]?.notice == .takeover(alert) },
                    "and a notification")
            #expect(notifier.prompts == 0, "no permission prompt for a notice nobody asked for")
            again.dismissTakeoverAlert()
            #expect(again.takeoverAlert == nil)
            await again.checkTakeovers()
            #expect(again.takeoverAlert == nil, "acknowledged")
            let list = try await again.loadDeviceList()
            #expect(list.homeName == "New iPad")
            #expect(list.history.first?.reason == .takeover)
            #expect(list.devices.first { $0.name == "New iPad" }?.addedBy == .recoveryKit)
            // Closing the vault forgets a banner not dismissed.
            again.takeoverAlert = alert
            again.close()
            #expect(again.takeoverAlert == nil)
        }

        /// Where notifications are not allowed, the banner is the notice: the model does not ask for permission to show one.
        @Test func aTakeoverNeverAsksForNotificationPermission() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let memory = MemoryKeyValueStore()
            let first = try await w.model("Phone", memory: memory)
            first.close()
            let phone = try #require(w.others["Phone"])
            _ = try await w.takeover(by: try DeviceKeys.generate(), keep: [phone.keys.fingerprint], name: "New iPad",
                                     trust: MemoryEpochTrustStore(), root: try await w.root())
            let notifier = RecordingNotifier()
            notifier.allowed = false
            let again = AppModel(deviceStateURL: TS.deviceStateURL(), trust: phone.trust, backupNotifier: notifier)
            again.deviceMemory = memory
            try await again.openVault(at: w.url)
            try await again.unlock(device: phone.keys)
            defer { again.close() }
            let alert = try #require(again.takeoverAlert, "the banner is raised")
            try await Task.sleep(for: .seconds(1))
            #expect(notifier.prompts == 0)
            #expect(notifier.scheduled["takeover-\(alert.vaultID.uuidString)"] == nil)
        }

        /// Review of #26, note (a): a takeover by another device that arrives while the vault is open reopens it
        /// (`syncedVaultFileArrived`, then `adoptReopened`), which checks the takeovers again: the alert is raised.
        @Test func aTakeoverSeenOnAReopenRaisesTheAlert() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let phone = try #require(w.others["Phone"])
            let model = try await w.model("Phone")
            defer { model.close() }
            #expect(model.takeoverAlert == nil, "first sight: nothing before it is reported")
            _ = try await w.takeover(by: try DeviceKeys.generate(), keep: [phone.keys.fingerprint], name: "New iPad",
                                     trust: MemoryEpochTrustStore(), root: try await w.root())
            await model.syncedVaultFileArrived()
            #expect(model.vault?.isHome == false)
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.takeoverAlert != nil }, "the reopen checked the takeovers")
            #expect(model.takeoverAlert?.by == "New iPad")
            #expect(try await model.loadDeviceList().homeName == "New iPad", "the vault follows the takeover")
        }

        @Test func theUnlistedFactsNameTheNotesOfTheUnsyncedFiles() {
            let a = UUID(), b = UUID()
            let facts = UnlistedFacts(by: "Home iPad", seen: Date(), unsynced: [
                "notes/\(a.uuidString.lowercased())/x.delta.age", "notes/\(a.uuidString.lowercased())/att/y.image.age",
                "notes/\(b.uuidString.lowercased())/z.delta.age", "settings.age", "inbox/c.capture.age",
            ])
            #expect(facts.notes == [a, b])
            #expect(facts.captures == 1)
        }

        @Test func anOpenVaultWithNoDeviceProblemsShowsNoBanner() async throws {
            let w = try await DeviceWorld.make(others: [])
            let model = try await w.model()
            defer { model.close() }
            #expect(model.deviceNotices.isEmpty)
            #expect(!model.isUnlisted)
            #expect(model.sightingRows.isEmpty)
            #expect(model.undoneRemovals.isEmpty)
            #expect(await model.setAsideItems().isEmpty)
        }

        /// Offline audit P16: a device whose removals a takeover undid sees them (those still listed) in a banner.
        @Test func removalsATakeoverUndidShowInABanner() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let model = try await w.model()
            defer { model.close() }
            let phone = try #require(w.others["Phone"]?.keys.id)
            model.undoneRemovalsSource = { _ in [UndoneRemoval(id: phone, name: "Phone"), UndoneRemoval(id: "0badf00d", name: "Gone")] }
            #expect(model.undoneRemovals == [UndoneRemoval(id: phone, name: "Phone")], "only the devices still listed")
            #expect(model.deviceNotices == [.removalsUndone(names: ["Phone"], home: true)])
        }

        // MARK: The passphrase copy (build 10)

        /// A vault made without a passphrase copy can get one later (Devices ▸ Add Passphrase Copy…, from the printed
        /// kit), after the owner check.
        @Test func aCopyIsAddedLaterFromTheKitAndOpensTheVault() async throws {
            let w = try await DeviceWorld.make(others: [])
            let model = try await w.model()
            defer { model.close() }
            let owner = ScriptedOwnerCheck(.pass)
            model.ownerAuthenticator = owner
            #expect(model.vault?.passphraseCopyNames().isEmpty == true)
            let strong = "Wafwi4-nokmoj-jykpuf"
            let kit = NativeIdentity.mlkem768x25519(w.recovery)
            await #expect(throws: KeyProblem.recoveryKeyNeeded, "no key given") {
                try await model.addPassphraseCopy(recoveryKey: nil, passphrase: strong)
            }
            #expect(owner.reasons.isEmpty, "no owner check without a key")
            let other = NativeIdentity.mlkem768x25519(try MLKEM768X25519Identity())
            await #expect(throws: VaultError.self, "not the current kit") {
                try await model.addPassphraseCopy(recoveryKey: other, passphrase: strong)
            }
            try await model.addPassphraseCopy(recoveryKey: kit, passphrase: strong)
            #expect(owner.reasons == [.addPassphraseCopy, .addPassphraseCopy])
            let vault = try #require(model.vault)
            #expect(vault.passphraseCopyNames().count == 1)
            let copy = try vault.openPassphraseCopy(passphrase: strong)
            #expect(copy.identity.recipient.string == w.recovery.recipient.string)
            let list = try await model.loadDeviceList()
            #expect(list.passphraseCopy)
            await #expect(throws: VaultError.self, "add-only: sync never replaces a copy") {
                try await model.addPassphraseCopy(recoveryKey: kit, passphrase: "tedPes-6fiqre-rynbid")
            }
            #expect(try model.vault?.openPassphraseCopy(passphrase: strong) != nil, "the first copy is untouched")
        }

        /// Any passphrase is taken, a one-letter one too.
        @Test func anyPassphraseIsTaken() async throws {
            let w = try await DeviceWorld.make(others: [])
            let model = try await w.model()
            defer { model.close() }
            model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            try await model.addPassphraseCopy(recoveryKey: .mlkem768x25519(w.recovery), passphrase: "a")
            let vault = try #require(model.vault)
            #expect(vault.passphraseCopyNames().count == 1)
            #expect(try vault.openPassphraseCopy(passphrase: "a").identity.recipient.string == w.recovery.recipient.string)
        }

        /// Without a device owner to ask (headless services) or with the check failed, no copy is written.
        @Test func aFailedOwnerCheckWritesNoCopy() async throws {
            let w = try await DeviceWorld.make(others: [])
            let model = try await w.model()
            defer { model.close() }
            await #expect(throws: OwnerCheckUnavailable.self, "headless: no owner can be asked") {
                try await model.addPassphraseCopy(recoveryKey: .mlkem768x25519(w.recovery), passphrase: "a")
            }
            model.ownerAuthenticator = ScriptedOwnerCheck(.refuse(CancellationError()))
            await #expect(throws: CancellationError.self) {
                try await model.addPassphraseCopy(recoveryKey: .mlkem768x25519(w.recovery), passphrase: "a")
            }
            #expect(model.vault?.passphraseCopyNames().isEmpty == true)
        }

        // MARK: Joining (the device's name and the owner check)

        /// A join request names this device as its platform does (`PlatformServices.deviceName`, `deviceKind`), and
        /// home's approval asks for the owner first; a withdrawal reads the keys for that reason only.
        @Test func aJoinNamesThisDeviceFromThePlatformAndHomeAsksForTheOwner() async throws {
            let w = try await DeviceWorld.make(others: [])
            let home = try await w.model()
            defer { home.close() }
            var services = AppModelServices.headless()
            services.platform = HeadlessPlatform(isPhone: true, deviceName: "Test Phone 3F2A")
            let phone = AppModel(deviceStateURL: TS.deviceStateURL(), trust: MemoryEpochTrustStore(), services: services)
            defer { phone.close() }
            try await phone.openVault(at: w.url)
            let store = MemoryDeviceKeyStore()
            guard case .waiting(let words, _) = try await phone.startJoin(store: store) else { Issue.record("not waiting"); return }
            let request = try #require(await home.pendingJoinRequests().first)
            #expect(request.name == "Test Phone 3F2A")
            #expect(request.kind == "iphone")

            await #expect(throws: OwnerCheckUnavailable.self, "headless: no owner, no approval") {
                _ = try await home.approveDevice(words: words, qr: nil)
            }
            let owner = ScriptedOwnerCheck(.pass)
            home.ownerAuthenticator = owner
            let reply = try await home.approveDevice(words: words, qr: nil)
            #expect(owner.reasons == [.approveDevice])
            #expect(reply.deviceName == "Test Phone 3F2A")
            #expect(home.vault?.devices.count == 2)

            // A withdrawn join reads the keys only to name its request file.
            await phone.cancelJoin(store: store)
            #expect(store.reasons == [.withdrawJoin])
            #expect(!(await store.hasKeys(for: try #require(phone.vault?.vaultId))))
        }

        @Test func theMemoryStoreKeepsOneSetPerVault() async throws {
            let store = MemoryDeviceKeyStore()
            let id = UUID()
            let k = try store.generate()
            try await store.save(k, for: id, vaultName: "V")
            await #expect(throws: DeviceKeyStoreError.duplicateItem) { try await store.save(k, for: id, vaultName: "V") }
            #expect(try await store.keys(for: id, reason: .takeover).key == k.key)
            #expect(store.reads == 1 && store.reasons == [.takeover])
            try await store.setRequiresBiometry(true, for: id, vaultName: "V")
            #expect(await store.requiresBiometry(for: id))
            store.unreadable = true
            await #expect(throws: DeviceKeyStoreError.notFound) { _ = try await store.keys(for: id, reason: .unlock(vaultName: "V")) }
            try await store.delete(for: id)
            #expect(!(await store.hasKeys(for: id)))
            #expect(!store.unreadable)
        }

        // MARK: Re-encryption (KH6), on a vault without targets

        static func everyDeviceKept(_ model: AppModel) async throws -> Set<String> {
            Set(try await model.kitReview().compactMap(\.device.id))
        }

        @Test func aVaultWithoutTargetsFinishesInOneStep() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let model = try await w.model()
            defer { model.close() }
            model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            let titles = Set(model.notes.map(\.id))
            let before = try #require(model.vault?.manifest.epoch)
            let newKit = try MLKEM768X25519Identity()
            let started = try await model.startReencryption(newKit, keep: try await Self.everyDeviceKept(model), remove: [],
                                                            passphrase: nil)
            #expect(started.report.reason == .reencrypt)
            #expect(model.vault?.manifest.epoch == before + 1)
            #expect(try await model.reencryptStatus().pending)
            let step = try await model.advanceReencryption()
            #expect(step.finished)
            #expect(step.status?.pending == false)
            #expect(step.status?.remaining == 0)
            #expect(!FileManager.default.fileExists(atPath: try #require(model.vaultURL).appendingPathComponent("reencrypt-journal.age").path))
            #expect(Set(model.notes.map(\.id)) == titles)
            #expect(model.vault?.manifest.recoveryEntry?.key == newKit.recipient.string)
            let list = try await model.loadDeviceList()
            #expect(list.history.first?.reason == .reencrypt)
        }

        /// Review of #89, S7: one step at a time; Stop ends it with `CancellationError`, and a later step goes on.
        /// The Stop races the step on purpose: either outcome is checked (stopped, or finished before the Stop).
        @Test func oneStepAtATimeAndStopEndsIt() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let model = try await w.model()
            defer { model.close() }
            model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            _ = try await model.startReencryption(try MLKEM768X25519Identity(), keep: try await Self.everyDeviceKept(model),
                                                  remove: [], passphrase: nil)
            model.isAdvancingReencryption = true
            await #expect(throws: VaultError.self, "a second step is refused while one goes") { _ = try await model.advanceReencryption() }
            model.isAdvancingReencryption = false
            let step = Task { try await model.advanceReencryption() }
            await Task.yield()
            model.cancelReencryptionStep()
            let first = await step.result
            #expect(!model.isAdvancingReencryption)
            switch first {
            case .success(let p):
                #expect(p.finished, "not stopped in time: the step ran to its end")
            case .failure(let e):
                #expect(e is CancellationError, "\(e)")
                #expect(try await model.advanceReencryption().finished, "the next step goes on and finishes")
            }
        }

        @Test func onlyHomeAdvances() async throws {
            let w = try await DeviceWorld.make(others: ["Phone"])
            let phone = try await w.model("Phone")
            defer { phone.close() }
            await #expect(throws: VaultError.self) { _ = try await phone.advanceReencryption() }
        }
    }
}

/// An owner check that does something while it asks (the user acting meanwhile), then passes.
final class ActingOwnerCheck: OwnerAuthenticator, @unchecked Sendable {
    let act: @MainActor () async throws -> Void

    init(_ act: @escaping @MainActor () async throws -> Void) { self.act = act }

    func authenticate(reason: OwnerCheckReason) async throws { try await act() }
}
