import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Released 1.1.0, iPhone + Apple Watch: after the vault's epoch changed (a device removed), every Watch note was held
    /// ("The vault has a newer key than this device"), and Add made it vanish. The quick-capture refresh took the new
    /// epoch's key and recipient but kept the old epoch's number and id, so the phone and the watch labeled captures sealed
    /// under the new key with the old epoch.
    @MainActor
    struct CaptureEpochRefreshTests {
        struct Rig {
            var model: AppModel
            var capture: QuickCapture
            var stores: DeviceWriteStores
            var url: URL
            var root: URL
            var oldMac: String
            var home: DeviceKeys
        }

        /// Home ("Home iPad") with an "Old Mac" approved; its store copy opened and unlocked with a ledger, quick voice
        /// notes on.
        static func rig() async throws -> Rig {
            let w = try await DeviceWorld.make(others: ["Old Mac"])
            let root = try TestTemp.directory("capture-epoch")
            let store = VaultStore(root: root.appendingPathComponent("store", isDirectory: true))
            let url = try store.importVault(from: w.url).url
            let stores = DeviceWriteStores.inMemoryKey(root: root)
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: w.homeTrust)
            model.vaultStore = store
            model.writeStores = stores
            let qc = QuickCapture(store: MemoryCaptureProfileStore(), root: root.appendingPathComponent("qc", isDirectory: true),
                                  queueRoot: root.appendingPathComponent("queue", isDirectory: true))
            qc.vaultStore = store
            qc.ledger = { stores.ledger(for: $0) }
            model.quickCapture = qc
            try await model.openVault(at: url)
            try await model.unlock(device: w.home)
            try model.enableQuickCapture(notebook: "Voice", transcribe: false)
            return Rig(model: model, capture: qc, stores: stores, url: url, root: root,
                       oldMac: try #require(w.others["Old Mac"]?.keys.id), home: w.home)
        }

        func receiver(_ rig: Rig) -> WatchReceiver {
            WatchReceiver(quickCapture: rig.capture, enabled: { true }, received: WatchReceivedSet(url: nil),
                          quarantine: rig.root.appendingPathComponent("quarantine", isDirectory: true),
                          held: WatchHeldStore(root: rig.root.appendingPathComponent("held", isDirectory: true)))
        }

        func transfer(_ profile: CaptureProfile, in rig: Rig, id: UUID = UUID()) throws -> (URL, [String: Any], SealedCapture) {
            let sealed = try CaptureWriter(profile: profile).seal(audio: try InboxTests.audio(), started: Date(), id: id)
            let meta = try WatchTransferMeta(sealed: sealed, vault: profile.vaultId)
            let folder = rig.root.appendingPathComponent("wc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(sealed.name)
            try sealed.data.write(to: file)
            return (file, meta.dictionary, sealed)
        }

        func adopted(_ model: AppModel, _ sealed: SealedCapture) async throws -> Bool {
            let id = try #require(CaptureFile.parse(name: sealed.name)?.id)
            let note = CaptureAdoption.ids(for: id).note
            return await TS.waitUntil(timeout: .seconds(60)) { model.notes.contains { $0.id == note } }
        }

        /// The epoch's number and id follow its key: after a removal the stored profile is the one the vault makes now,
        /// and a Watch note sealed with it is admitted, placed and adopted.
        @Test func aDeviceChangeGivesTheProfileTheNewEpochAndWatchNotesAreAdmitted() async throws {
            let rig = try await Self.rig()
            let model = rig.model
            defer { model.close() }
            let before = try #require(try rig.capture.store.load())
            _ = try await model.removeDevices([rig.oldMac])
            let vault = try #require(model.vault)
            #expect(vault.manifest.epoch == 2)
            let stored = try #require(try rig.capture.store.load())
            let fresh = try vault.captureProfile(device: try #require(DeviceID(stored.profile.device)), notebook: "Voice")
            #expect(stored.profile == fresh, "key, recipient and the epoch they belong to")
            #expect(stored.profile.epoch == 2 && stored.profile.epochId != before.profile.epochId)

            let (file, meta, sealed) = try transfer(stored.profile, in: rig)
            let receipt = try #require(try receiver(rig).receive(file: file, metadata: meta))
            #expect(receipt.result.outcome == .placed(.vault))
            #expect(try await adopted(model, sealed))
            #expect(model.inboxProblem == nil)
            let report = try vault.catchUp()
            #expect(report.problems.isEmpty, "\(report.problems)")
        }

        /// A device left in 1.1.0's state (the key current, the epoch stale) since a device change: its Watch notes are held
        /// as "newer key". The next unlock repairs the profile and the watch is given it again; a held note added meanwhile
        /// (the vault closed) is adopted at that unlock, and catch-up has nothing left to retry.
        @Test func aStaleEpochIsRepairedAtTheNextUnlockAndAnAddedNoteIsAdopted() async throws {
            let rig = try await Self.rig()
            let model = rig.model
            let before = try #require(try rig.capture.store.load())
            _ = try await model.removeDevices([rig.oldMac])
            let good = try #require(try rig.capture.store.load())
            #expect(good.profile.epoch == 2 && before.profile.epoch == 1)
            var bad = good
            bad.profile.epoch = before.profile.epoch
            bad.profile.epochId = before.profile.epochId
            try rig.capture.store.save(bad)

            // The watch holds the bad profile.
            let watch = try NativeIdentity.generate(.postQuantum)
            let provisioner = WatchProvisioner(store: MemoryWatchLinkStore())
            try provisioner.setEnabled(true)
            try provisioner.watchRequested(recipient: watch.recipient.string)
            #expect(try provisioner.nextMessage(stored: bad) != nil)
            #expect(try provisioner.nextMessage(stored: bad) == nil, "the watch has it")

            // Its note is held; the owner adds it while the vault is closed.
            let (file, meta, sealed) = try transfer(bad.profile, in: rig)
            #expect(try receiver(rig).receive(file: file, metadata: meta)?.result.outcome == .held(.newerEpoch))
            // A second one the owner leaves held.
            let (fileB, metaB, sealedB) = try transfer(bad.profile, in: rig)
            #expect(try receiver(rig).receive(file: fileB, metadata: metaB)?.result.outcome == .held(.newerEpoch))
            let idB = try #require(CaptureFile.parse(name: sealedB.name)?.id)
            #expect(!receiver(rig).needsCheck(try #require(receiver(rig).heldNotes().first { $0.id == idB })))
            model.close()
            let firstId = try #require(CaptureFile.parse(name: sealed.name)?.id)
            let held = try #require(receiver(rig).heldNotes().first { $0.id == firstId })
            #expect(receiver(rig).canAddNow(held))
            #expect(try receiver(rig).addHeld(held) == .vault)
            #expect(InboxTests.inbox(rig.url) == [sealed.name])

            // A reinstall empties the ledger (the App Group container goes; the profile, in the Keychain, stays).
            try FileManager.default.removeItem(at: rig.root.appendingPathComponent("Ledger", isDirectory: true))

            // The next unlock repairs the profile and adopts the note.
            try await model.openVault(at: rig.url)
            try await model.unlock(device: rig.home)
            defer { model.close() }
            #expect(try rig.capture.store.load() == good, "repaired")
            #expect(try provisioner.nextMessage(stored: try rig.capture.store.load()) != nil, "the watch is given the repaired profile")
            #expect(try await adopted(model, sealed))
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.inboxAdoption == nil })
            #expect(InboxTests.inbox(rig.url).isEmpty)
            #expect(model.inboxProblem == nil)
            let report = try #require(model.vault).catchUp()
            #expect(report.problems.isEmpty, "\(report.problems)")

            // The one left held: stored as newerEpoch, judged now as of an earlier key, so Settings and `held add --all`
            // treat it as one (the warning, Add Anyway, skipped by --all); it is not placed by itself.
            let leftB = try #require(receiver(rig).heldNotes().first { $0.id == idB })
            #expect(leftB.reason == .newerEpoch)
            #expect(receiver(rig).currentReason(leftB) == .oldEpoch)
            #expect(receiver(rig).needsCheck(leftB))
            #expect(receiver(rig).admitReady().isEmpty)
            #expect(try receiver(rig).addHeld(leftB) == .vault)
            #expect(try await adopted(model, sealedB))

            // A note still on the watch, sealed with the bad profile, arrives after the repair: held as sealed under an
            // earlier key (the phone cannot tell it from one that was), and it can be added: the repair remembered the
            // epoch the profile was made under, which the emptied ledger had forgotten.
            let (file2, meta2, sealed2) = try transfer(bad.profile, in: rig)
            #expect(try receiver(rig).receive(file: file2, metadata: meta2)?.result.outcome == .held(.oldEpoch))
            let held2 = try #require(receiver(rig).heldNotes().first)
            #expect(receiver(rig).admitReady().isEmpty, "an earlier key's note waits for the user, also after a profile change")
            #expect(try receiver(rig).addHeld(held2) == .vault)
            #expect(try await adopted(model, sealed2))
            #expect(try #require(model.vault).catchUp().problems.isEmpty)
        }
    }
}
