import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing
import VaultTestSupport

/// The iPhone's side of the Watch hand-off over the real `CaptureDelivery`, a vault store and ledgers
/// (docs/design/1.1-watch.md §3.6, "Multiple vaults"): a file goes where its own vault is, never into the stored
/// profile's inbox by default.
struct WatchReceiverTests {
    /// One ledger per vault, as `DeviceWriteStores` keeps them.
    final class Ledgers: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [UUID: MemoryWriteLedger] = [:]
        func ledger(_ vault: UUID) -> MemoryWriteLedger {
            lock.withLock {
                if let l = all[vault] { return l }
                let l = MemoryWriteLedger()
                all[vault] = l
                return l
            }
        }
    }

    struct Rig {
        var dir: URL
        var storeRoot: URL
        var ledgers = Ledgers()
        var told = QuickCaptureLogicTests.Box()
        /// The vault the device's capture profile serves, its folder, and the profile.
        var current: (url: URL, stored: StoredCaptureProfile)
        var profileStore: MemoryCaptureProfileStore
        var received = WatchReceivedSet(url: nil)
        /// "Use on Apple Watch".
        var enabled = true
        var held: WatchHeldStore { WatchHeldStore(root: dir.appendingPathComponent("held")) }

        var delivery: CaptureDelivery {
            let ledgers = self.ledgers, told = self.told
            return CaptureDelivery(queueRoot: dir.appendingPathComponent("queue"), vaultStore: VaultStore(root: storeRoot),
                                   bookmarks: PathBookmarks(), ledger: { ledgers.ledger($0) }, delivered: { told.add($0) })
        }
        var receiver: WatchReceiver {
            let on = enabled
            return WatchReceiver(delivery: delivery, store: profileStore, received: received,
                                 quarantine: dir.appendingPathComponent("quarantine"), held: held, enabled: { on })
        }
        var quarantineNames: [String] { QuickCaptureLogicTests.names(dir.appendingPathComponent("quarantine")) }
    }

    static func rig() throws -> Rig {
        let dir = try QuickCaptureLogicTests.tempDir("watch")
        let (url, stored) = try QuickCaptureLogicTests.profile(in: dir)
        let store = MemoryCaptureProfileStore()
        try store.save(stored)
        return Rig(dir: dir, storeRoot: dir.appendingPathComponent("store"), current: (url, stored), profileStore: store)
    }

    /// A second vault, in the same store when `stored`, else nowhere on this device. Its capture profile is the watch's.
    static func otherVault(_ rig: Rig, inStore: Bool) throws -> (url: URL?, profile: CaptureProfile, source: URL) {
        let identity = try NativeIdentity.generate(.postQuantum)
        let source = rig.dir.appendingPathComponent("other-\(UUID().uuidString).sempere")
        let created = try TestVaults.create(at: source, identities: [identity])
        // Opened with this device's ledger for it: making the profile remembers the epoch's key there, which is how the
        // phone knows the epoch of a vault it holds but whose profile it does not store.
        let vault = try Vault.open(at: source, identities: [identity], ledger: rig.ledgers.ledger(created.vaultId))
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
        guard inStore else { return (nil, profile, source) }
        let url = try VaultStore(root: rig.storeRoot).importVault(from: source).url
        try FileManager.default.removeItem(at: source)
        return (url, profile, source)
    }

    /// What the watch transfers: the sealed file (its own copy, as WatchConnectivity's) and the metadata dictionary.
    static func transfer(_ profile: CaptureProfile, in rig: Rig, id: UUID = UUID()) throws
        -> (file: URL, metadata: [String: Any], sealed: SealedCapture, meta: WatchTransferMeta) {
        let sealed = try CaptureWriter(profile: profile).seal(audio: Data("watch audio".utf8), started: Date(), id: id)
        let meta = try WatchTransferMeta(sealed: sealed, vault: profile.vaultId)
        let folder = rig.dir.appendingPathComponent("wc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(sealed.name)
        try sealed.data.write(to: file)
        return (file, meta.dictionary, sealed, meta)
    }

    static func inbox(_ vault: URL) -> [String] { QuickCaptureLogicTests.names(vault.appendingPathComponent("inbox")) }

    // MARK: The stored profile's vault

    @Test func aFileOfTheCurrentVaultIsDeliveredLedgerFirstAndAcknowledged() throws {
        let rig = try Self.rig()
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        let receipt = try #require(try rig.receiver.receive(file: t.file, metadata: t.metadata))
        #expect(receipt.result.outcome == .placed(.vault))
        #expect(Self.inbox(rig.current.url) == [t.sealed.name])
        #expect(try rig.ledgers.ledger(rig.current.stored.profile.vaultId).entries().map(\.path) == ["inbox/\(t.sealed.name)"])
        #expect(rig.told.all == [rig.current.stored.profile.vaultId])
        #expect(rig.receiver.ack([receipt]).acked == [t.sealed.name].compactMap { CaptureFile.parse(name: $0)?.id })
        #expect(rig.quarantineNames.isEmpty, "the quarantine copy goes once delivery returned")
        #expect(rig.received.contains(t.meta.id))
    }

    @Test func aSecondTransferOfTheSameFilePlacesNothingButIsAcknowledged() throws {
        let rig = try Self.rig()
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        _ = try rig.receiver.receive(file: t.file, metadata: t.metadata)
        let again = try #require(try rig.receiver.receive(file: t.file, metadata: t.metadata))
        #expect(again.result.outcome == .duplicate)
        #expect(again.result.acknowledged)
        #expect(Self.inbox(rig.current.url).count == 1)
        #expect(try rig.ledgers.ledger(rig.current.stored.profile.vaultId).entries().count == 1)
        // Even with the received set lost, the id already in the inbox makes it a duplicate.
        var fresh = rig
        fresh.received = WatchReceivedSet(url: nil)
        #expect(try fresh.receiver.receive(file: t.file, metadata: t.metadata)?.result.outcome == .duplicate)
        #expect(Self.inbox(rig.current.url).count == 1)
    }

    @Test func aSuspendedProfileStillDeliversAPendingFile() throws {
        let rig = try Self.rig()
        var suspended = rig.current.stored
        suspended.suspended = true
        try rig.profileStore.save(suspended)
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        #expect(try rig.receiver.receive(file: t.file, metadata: t.metadata)?.result.outcome == .placed(.vault))
        #expect(Self.inbox(rig.current.url) == [t.sealed.name])
    }

    @Test func anUnreachableCurrentVaultQueuesTheFileWithItsEpoch() throws {
        var rig = try Self.rig()
        rig.storeRoot = try QuickCaptureLogicTests.tempDir("not-the-store")
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        #expect(try rig.receiver.receive(file: t.file, metadata: t.metadata)?.result.outcome == .placed(.queued))
        let queue = rig.delivery.queueFolder(rig.current.stored.profile.vaultId)
        #expect(QuickCaptureLogicTests.names(queue) == [t.sealed.name, t.sealed.name + ".epoch"])
        #expect(try rig.ledgers.ledger(rig.current.stored.profile.vaultId).entries().isEmpty, "recorded when it is placed")
    }

    // MARK: The checks

    @Test func aFileThatDoesNotMatchItsMetadataIsRefusedAndNeverAcknowledged() throws {
        let rig = try Self.rig()
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        try Data("tampered".utf8).write(to: t.file)
        let receipt = try #require(try rig.receiver.receive(file: t.file, metadata: t.metadata))
        guard case .refused = receipt.result.outcome else { Issue.record("not refused"); return }
        #expect(rig.receiver.ack([receipt]).acked.isEmpty)
        #expect(Self.inbox(rig.current.url).isEmpty)
        #expect(rig.quarantineNames.isEmpty)
        #expect(!rig.received.contains(t.meta.id))
    }

    @Test func metadataThatDoesNotParseDropsTheTransfer() throws {
        let rig = try Self.rig()
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        #expect(try rig.receiver.receive(file: t.file, metadata: nil) == nil)
        #expect(try rig.receiver.receive(file: t.file, metadata: ["id": "nope"]) == nil)
        #expect(rig.quarantineNames.isEmpty)
    }

    @Test func aCrashedRunsQuarantineIsSwept() throws {
        let rig = try Self.rig()
        let quarantine = rig.dir.appendingPathComponent("quarantine")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: quarantine.appendingPathComponent("left.part"))
        rig.receiver.sweepQuarantine()
        #expect(rig.quarantineNames.isEmpty)
    }

    // MARK: Other vaults

    @Test func aFileOfAnotherHeldVaultGoesToThatVaultsInboxNotTheCurrentOne() throws {
        let rig = try Self.rig()
        let other = try Self.otherVault(rig, inStore: true)
        let url = try #require(other.url)
        let t = try Self.transfer(other.profile, in: rig)
        #expect(try rig.receiver.receive(file: t.file, metadata: t.metadata)?.result.outcome == .placed(.otherVault))
        #expect(Self.inbox(url) == [t.sealed.name])
        #expect(Self.inbox(rig.current.url).isEmpty, "never the current vault's inbox")
        #expect(try rig.ledgers.ledger(other.profile.vaultId).entries().first?.epoch == other.profile.epoch,
                "recorded in the file's vault, under its own epoch")
        #expect(try rig.ledgers.ledger(rig.current.stored.profile.vaultId).entries().isEmpty)
        #expect(rig.told.all == [other.profile.vaultId])
    }

    @Test func aFileOfAVaultTheDeviceDoesNotHoldIsHeldForDeleteOnly() throws {
        let rig = try Self.rig()
        let other = try Self.otherVault(rig, inStore: false)
        let t = try Self.transfer(other.profile, in: rig)
        #expect(try rig.receiver.receive(file: t.file, metadata: t.metadata)?.result.outcome == .held(.unknownVault))
        #expect(rig.delivery.queuedCount(excluding: rig.current.stored.profile.vaultId) == 0, "not queued")
        #expect(Self.inbox(rig.current.url).isEmpty)
        #expect(try rig.ledgers.ledger(other.profile.vaultId).entries().isEmpty)
        let note = try #require(rig.receiver.heldNotes().first)
        #expect(!note.canAdd)
        #expect(throws: (any Error).self) { try rig.receiver.addHeld(note) }
        rig.receiver.deleteHeld(note)
        #expect(rig.receiver.heldNotes().isEmpty)
    }

    @Test func aQueuedFileOfAVaultThatArrivesIsFlushedUnderItsOwnEpoch() throws {
        let rig = try Self.rig()
        let other = try Self.otherVault(rig, inStore: false)
        let t = try Self.transfer(other.profile, in: rig)
        let queue = rig.delivery.queueFolder(other.profile.vaultId)
        try WatchQueue.store(t.sealed, in: queue)
        #expect(QuickCaptureLogicTests.names(queue) == [t.sealed.name, t.sealed.name + ".epoch"])
        #expect(rig.delivery.queuedCount(excluding: rig.current.stored.profile.vaultId) == 1)
        #expect(rig.delivery.queuedCount(excluding: other.profile.vaultId) == 0)
        #expect(try rig.ledgers.ledger(other.profile.vaultId).entries().isEmpty, "unrecorded until placed (one hour grace)")
        // The vault arrives (copied in) and is opened writable: the app flushes its queue, with the CURRENT profile in hand
        // (another vault's), which is no obstacle: the file's sidecar names its epoch.
        let arrived = try VaultStore(root: rig.storeRoot).importVault(from: other.source).url
        #expect(rig.delivery.flushQueue(into: arrived, vaultId: other.profile.vaultId, profile: rig.current.stored.profile,
                                        files: nil) == 1)
        #expect(Self.inbox(arrived) == [t.sealed.name])
        #expect(try rig.ledgers.ledger(other.profile.vaultId).entries().first?.epoch == other.profile.epoch)
        #expect(QuickCaptureLogicTests.names(queue).isEmpty)
    }

    // MARK: Held files (the toggle, the epoch)

    @Test func aFileThatArrivesWhileTheToggleIsOffIsHeldUntilTheUserAddsIt() throws {
        var rig = try Self.rig()
        rig.enabled = false
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        let receipt = try #require(try rig.receiver.receive(file: t.file, metadata: t.metadata))
        #expect(receipt.result.outcome == .held(.linkOff))
        #expect(rig.receiver.ack([receipt]).acked == [t.meta.id], "acknowledged: the watch drops its copy")
        #expect(Self.inbox(rig.current.url).isEmpty)
        #expect(try rig.ledgers.ledger(rig.current.stored.profile.vaultId).entries().isEmpty)
        let note = try #require(rig.receiver.heldNotes().first)
        #expect(note.canAdd)
        #expect(try rig.receiver.addHeld(note) == .vault)
        #expect(Self.inbox(rig.current.url) == [t.sealed.name])
        #expect(try rig.ledgers.ledger(rig.current.stored.profile.vaultId).entries().count == 1)
        #expect(rig.receiver.heldNotes().isEmpty)
    }

    @Test func aFileOfAnEpochThePhoneMovedPastIsHeldNotLaunderedThroughTheLedger() throws {
        let rig = try Self.rig()
        // The watch holds the epoch the profile had; the phone's stored profile has moved on.
        var moved = rig.current.stored
        moved.profile.epoch += 1
        moved.profile.epochId = String(repeating: "ee", count: 32)
        try rig.profileStore.save(moved)
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        #expect(try rig.receiver.receive(file: t.file, metadata: t.metadata)?.result.outcome == .held(.unknownEpoch))
        #expect(Self.inbox(rig.current.url).isEmpty)
        #expect(try rig.ledgers.ledger(rig.current.stored.profile.vaultId).entries().isEmpty)
    }

    @Test func anUnreadableProfileLeavesTheFileUnacknowledgedNotHeld() throws {
        struct Unreadable: CaptureProfileStore {
            func load() throws -> StoredCaptureProfile? { throw QuickCaptureError.profileUnreadable }
            func save(_ profile: StoredCaptureProfile) throws {}
            func delete() throws {}
        }
        let rig = try Self.rig()
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        let r = WatchReceiver(delivery: rig.delivery, store: Unreadable(), received: rig.received,
                              quarantine: rig.dir.appendingPathComponent("quarantine"), held: rig.held, enabled: { true })
        #expect(throws: QuickCaptureError.profileUnreadable) { try r.receive(file: t.file, metadata: t.metadata) }
        #expect(rig.held.list().isEmpty)
        #expect(!rig.received.contains(t.meta.id))
    }

    // MARK: One flush, both kinds of sidecar

    @Test func oneFlushReadsTheSidecarOfAVoiceNoteAndOfAWatchNote() throws {
        var rig = try Self.rig()
        let vault = rig.current.stored.profile.vaultId
        let away = try QuickCaptureLogicTests.tempDir("not-the-store")
        let realRoot = rig.storeRoot
        rig.storeRoot = away   // the vault is unreachable: both queue
        // A voice note recorded on this device (CaptureDelivery's own queue write) ...
        let voice = try QuickCaptureLogicTests.seal(rig.current.stored)
        #expect(try rig.delivery.deliver(voice, rig.current.stored) == .queued)
        // ... a Watch note (WatchQueue through the receiver), sealed under an OLDER epoch than the profile now has ...
        var older = rig.current.stored.profile
        older.epoch = max(0, older.epoch - 1)
        let t = try Self.transfer(older, in: rig)
        try WatchQueue.store(t.sealed, in: rig.delivery.queueFolder(vault))
        // ... and one a version before sidecars were durable (plain bytes): all in one folder.
        let legacy = try QuickCaptureLogicTests.seal(rig.current.stored)
        let queue = rig.delivery.queueFolder(vault)
        try legacy.data.write(to: queue.appendingPathComponent(legacy.name))
        try Data("\(older.epoch) \(legacy.epochId!.map { String(format: "%02x", $0) }.joined())\n".utf8)
            .write(to: CaptureDelivery.epochSidecar(queue.appendingPathComponent(legacy.name)))
        rig.storeRoot = realRoot
        #expect(rig.delivery.flushQueue(into: rig.current.url, vaultId: vault, profile: rig.current.stored.profile, files: nil) == 3)
        #expect(Self.inbox(rig.current.url).count == 3)
        let epochs = try rig.ledgers.ledger(vault).entries().reduce(into: [String: Int]()) { $0[$1.path] = $1.epoch }
        #expect(epochs["inbox/\(voice.name)"] == rig.current.stored.profile.epoch)
        #expect(epochs["inbox/\(t.sealed.name)"] == older.epoch, "the epoch it was sealed under, not the profile's")
        #expect(epochs["inbox/\(legacy.name)"] == older.epoch)
        #expect(QuickCaptureLogicTests.names(queue).isEmpty)
    }

    @Test func aQueueFileWithoutASidecarStillNeedsTheVaultsProfile() throws {
        let rig = try Self.rig()
        let vault = rig.current.stored.profile.vaultId
        let sealed = try QuickCaptureLogicTests.seal(rig.current.stored)
        let queue = rig.delivery.queueFolder(vault)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try sealed.data.write(to: queue.appendingPathComponent(sealed.name))
        #expect(rig.delivery.flushQueue(into: rig.current.url, vaultId: vault, profile: nil, files: nil) == 0)
        #expect(rig.delivery.flushQueue(into: rig.current.url, vaultId: vault, profile: rig.current.stored.profile, files: nil) == 1)
    }

    @Test func aReadOnlyVaultTakesNoWatchNote() throws {
        let rig = try Self.rig()
        let manifest = rig.current.url.appendingPathComponent("vault.json")
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        obj["format"] = "sempere/9"
        try JSONSerialization.data(withJSONObject: obj).write(to: manifest)
        let t = try Self.transfer(rig.current.stored.profile, in: rig)
        #expect(try rig.receiver.receive(file: t.file, metadata: t.metadata)?.result.outcome == .placed(.queued))
        #expect(Self.inbox(rig.current.url).isEmpty)
    }
}
