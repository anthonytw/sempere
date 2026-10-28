import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp

/// A join through a folder target that a provider holds (build 11, syncjoin-mac/ipad/iphone: "after entering the words
/// it continued to say there was no device trying to join"): the new device's request reaches the sync folder only
/// once a run and the provider's upload carried it, and home's copy only once its provider delivered it and a run took
/// it. Add Device looked once when it opened, and typed words matched only what the copy held then. Simulated with
/// `EvictingFolderProvider` (no iCloud in tests): a request the provider listed as a stand-in and delivers late.
@Suite(.serialized)
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

    /// A new device as `FolderTargetAppTests.device` makes one, with a trust store: it confirms its join with the reply.
    static func joiningDevice(_ provider: EvictingFolderProvider) -> FolderTargetAppTests.Device {
        let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: MemoryEpochTrustStore())
        model.vaultStore = library.vaultStore
        model.webdavTick = .milliseconds(20)
        model.folderWriteDelay = 0.05
        model.folderArrivalWait = 0.5
        model.folderProvider = { _ in provider }
        model.takeoverDefaults = DevicesAppTests.defaults()
        return FolderTargetAppTests.Device(model: model, library: library)
    }

    @Test func addDeviceWaitsForARequestTheProviderDeliversLate() async throws {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
        let provider = EvictingFolderProvider(root: shared, cloud: drive.appendingPathComponent(".cloud"))

        // Home (the Mac): the vault, unlocked with its device key, synced into the shared folder.
        let home = FolderTargetAppTests.device(provider)
        home.model.ownerAuthenticator = JoinTakeoverAppTests.PassingOwner()
        home.model.takeoverDefaults = DevicesAppTests.defaults()
        try await home.model.copyIn(picked: vault, library: home.library)
        _ = try await home.model.unlock(identityText: key)
        try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
        await home.model.syncAllTargetsNow()
        defer { home.model.close() }

        // The iPad opens the shared folder, keeps syncing with it and asks to join.
        let pad = Self.joiningDevice(provider)
        let uploads = Uploads()   // its provider has not uploaded what the runs wrote yet
        pad.model.providerUploadCheck = { _ in uploads.done ? .uploaded : .waiting }
        try await pad.model.copyIn(picked: shared, library: pad.library, followUp: .keepSyncing)
        defer { pad.model.close() }
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
        #expect(AddDeviceText.looking(look).contains("on its way"))
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
        #expect(await padKeys.unlockWithDeviceKey(pad.model) == .joining)
        #expect(padKeys.joinStage == .confirming, "\(String(describing: pad.model.syncSessions.first?.lastReport))")
        let device = try await padKeys.store.keys(for: try #require(pad.model.vault?.vaultId), reason: "")
        try await pad.model.confirmJoin(words: reply.words, keys: device)
        #expect(pad.model.phase == .unlocked)
    }

    /// Words typed for a request nobody made, with nothing arriving: the old answer, in words that say requests can
    /// be late.
    @Test func wordsOfNoRequestAreRefusedAfterASync() async throws {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
        let home = FolderTargetAppTests.device(nil)
        home.model.ownerAuthenticator = JoinTakeoverAppTests.PassingOwner()
        try await home.model.copyIn(picked: vault, library: home.library)
        _ = try await home.model.unlock(identityText: key)
        try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
        defer { home.model.close() }
        await #expect(throws: DeviceJoinError.requestNotArrived) {
            _ = try await home.model.approveDevice(words: ["abandon", "ability", "able", "about", "above", "absent"], qr: nil)
        }
        #expect(home.model.syncSessions.first?.lastReport != nil, "it synced before saying so")
        #expect(DeviceChangeText.message(DeviceJoinError.requestNotArrived).contains("iCloud Drive"))
        // Without any target nothing can arrive: the message says nothing of syncs (review of #117, N1).
        #expect(!DeviceChangeText.message(DeviceJoinError.noMatchingRequest).contains("iCloud"))
        let look = await home.model.lookForJoinRequests()
        #expect(look.requests.isEmpty && !look.arriving)
        #expect(AddDeviceText.looking(look).contains("Still looking"))
    }

    // MARK: - Add Device's approving (review of #117, B1)

    /// An owner check that closes the sheet while it asks (the user dismissed Add Device during Touch ID).
    struct ClosingOwner: OwnerAuthenticator {
        let close: @MainActor @Sendable () -> Void
        func authenticate(reason: String) async throws { await close() }
    }

    /// Home and an iPad that asked to join; on home's side the request is a stand-in the provider has not delivered.
    struct Asked {
        let home: FolderTargetAppTests.Device
        let pad: FolderTargetAppTests.Device
        let provider: EvictingFolderProvider
        let words: [String]
    }

    static func asked() async throws -> Asked {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
        let provider = EvictingFolderProvider(root: shared, cloud: drive.appendingPathComponent(".cloud"))
        let home = FolderTargetAppTests.device(provider)
        home.model.ownerAuthenticator = JoinTakeoverAppTests.PassingOwner()
        home.model.takeoverDefaults = DevicesAppTests.defaults()
        try await home.model.copyIn(picked: vault, library: home.library)
        _ = try await home.model.unlock(identityText: key)
        try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
        await home.model.syncAllTargetsNow()
        let pad = Self.joiningDevice(provider)
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
    }

    /// Words typed before their request arrived wait; once the sheet is closed, its arrival approves nothing.
    @Test func aClosedSheetNeverApprovesWhatArrivesLater() async throws {
        let w = try await Self.asked()
        defer { w.home.model.close(); w.pad.model.close() }
        let approval = AddDeviceApproval(model: w.home.model)
        #expect(await approval.approve(words: w.words, qr: nil) == false)
        #expect(approval.pending == AddDeviceApproval.Pending(words: w.words, qr: nil), "kept for when it arrives")
        approval.close()
        w.provider.arrivalDelay = 0
        await approval.look()
        #expect(approval.pending == nil)
        #expect(approval.reply == nil)
        #expect(approval.approvals == 0)
        #expect(await approval.approve(words: w.words, qr: nil) == false, "nor a late button press")
        // The request did arrive: only the closed sheet kept it from being approved.
        #expect(await w.home.model.lookForJoinRequests().requests.count == 1)
        #expect(w.home.model.vault?.devices.count == 1)
    }

    /// The look and the button at once: one approval, not two.
    @Test func concurrentTriggersApproveOnce() async throws {
        let w = try await Self.asked()
        defer { w.home.model.close(); w.pad.model.close() }
        let approval = AddDeviceApproval(model: w.home.model)
        #expect(await approval.approve(words: w.words, qr: nil) == false)
        w.provider.arrivalDelay = 0
        _ = await w.home.model.lookForJoinRequests()   // delivered into home's copy
        async let looked: Void = approval.look()
        async let pressed = approval.approve(words: w.words, qr: nil)
        async let pressedAgain = approval.approve(words: w.words, qr: nil)
        _ = await (looked, pressed, pressedAgain)
        #expect(approval.approvals == 1)
        #expect(approval.reply != nil)
        #expect(w.home.model.vault?.devices.count == 2)
        #expect(await approval.approve(words: w.words, qr: nil) == false, "a reply is in: nothing more")
    }

    /// Closed while the owner check asks: nothing is written.
    @Test func closingDuringTheOwnerCheckWritesNothing() async throws {
        let w = try await Self.asked()
        defer { w.home.model.close(); w.pad.model.close() }
        w.provider.arrivalDelay = 0
        _ = await w.home.model.lookForJoinRequests()
        let approval = AddDeviceApproval(model: w.home.model)
        w.home.model.ownerAuthenticator = ClosingOwner { approval.close() }
        #expect(await approval.approve(words: w.words, qr: nil) == false)
        #expect(approval.reply == nil)
        #expect(w.home.model.vault?.devices.count == 1)
        #expect(await w.home.model.pendingJoinRequests().count == 1, "the request is still there")
    }

    // MARK: - Declining and withdrawing (build 12: "no way to decline a request … you're stuck")

    static func targetRequests(_ w: Asked) -> [String] {
        let joins = w.provider.root.appendingPathComponent("joins")
        return ((try? FileManager.default.contentsOfDirectory(atPath: joins.path)) ?? [])
            .filter { Vault.isJoinRequestName($0) || $0.hasSuffix(".join.json.icloud") }
    }

    /// Home declines a request nobody will confirm: it leaves the list and, with the next runs, the target; a second
    /// device's request is approved as if the first had never been there.
    @Test func homeDeclinesARequestAndApprovesTheNext() async throws {
        let w = try await Self.asked()
        defer { w.home.model.close(); w.pad.model.close() }
        w.provider.arrivalDelay = 0
        let approval = AddDeviceApproval(model: w.home.model)
        await approval.look()
        let stale = try #require(approval.lookout?.requests.first)
        // A second device asks too.
        let phone = Self.joiningDevice(w.provider)
        defer { phone.model.close() }
        try await phone.model.copyIn(picked: w.provider.root, library: phone.library, followUp: .keepSyncing)
        guard case .waiting(let phoneWords, _) = try await phone.model.startJoin(store: MemoryDeviceKeyStore()) else {
            Issue.record("not waiting")
            return
        }
        await phone.model.syncAllTargetsNow()
        await approval.look()
        #expect(approval.lookout?.requests.count == 2)

        #expect(await approval.decline(stale))
        let phoneFile = try #require(phone.model.joinRequestedFile(phone.vaultID))
        #expect(approval.lookout?.requests.map(\.fileName) == [phoneFile])
        await w.home.model.syncAllTargetsNow()
        #expect(!Self.targetRequests(w).contains(stale.fileName), "declined on the target too")
        await #expect(throws: DeviceJoinError.self) { _ = try await w.home.model.approveDevice(words: w.words, qr: nil) }

        #expect(await approval.approve(words: phoneWords, qr: nil))
        #expect(w.home.model.vault?.devices.count == 2)
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
        #expect(JoinDelivery.waitingForUpload(iCloud: true).text.contains("iCloud Drive"))
    }
}
