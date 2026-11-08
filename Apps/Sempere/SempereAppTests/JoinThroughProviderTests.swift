import Foundation
import Sempere
import SempereAppCore
import SempereSync
import Testing
@testable import SempereApp

/// Add Device's sheet model (`AddDeviceApproval`, the app's) over a join through a folder target that a provider
/// holds (build 11; review of #117, B1), and the join's words. The join itself through the model is
/// `JoinThroughProviderTests` in `SempereAppCoreTests`. Simulated with `EvictingFolderProvider`: a request the
/// provider listed as a stand-in and delivers late.
@Suite(.serialized)
@MainActor
struct JoinThroughProviderTests {
    /// A device with its own store, device state and sync state, on `provider` (`FolderTargetTests.device` in
    /// `SempereAppCoreTests`); `trust`: a joining device confirms its join with the reply.
    struct Device {
        let model: AppModel
        let library: VaultLibrary
        @MainActor var vaultID: UUID { model.vault?.vaultId ?? UUID() }
    }

    static func device(_ provider: EvictingFolderProvider, joining: Bool) -> Device {
        let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50),
                             trust: joining ? MemoryEpochTrustStore() : nil)
        model.vaultStore = library.vaultStore
        model.webdavTick = .milliseconds(20)
        model.folderWriteDelay = 0.05
        model.folderArrivalWait = 0.5
        model.folderProvider = { _ in provider }
        model.deviceMemory = MemoryKeyValueStore()
        return Device(model: model, library: library)
    }

    /// An owner check that closes the sheet while it asks (the user dismissed Add Device during Touch ID).
    struct ClosingOwner: OwnerAuthenticator {
        let close: @MainActor @Sendable () -> Void
        func authenticate(reason: OwnerCheckReason) async throws { await close() }
    }

    /// Home and an iPad that asked to join; on home's side the request is a stand-in the provider has not delivered.
    struct Asked {
        let home: Device
        let pad: Device
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
        let home = Self.device(provider, joining: false)
        home.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
        try await home.model.copyIn(picked: vault, library: home.library)
        _ = try await home.model.unlock(identityText: key)
        try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
        await home.model.syncAllTargetsNow()
        let pad = Self.device(provider, joining: true)
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

    // MARK: - Declining (build 12: "no way to decline a request … you're stuck")

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
        let phone = Self.device(w.provider, joining: true)
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

    /// Where a join stands, in Add Device's and the join screen's words (the model's values: `JoinThroughProviderTests`
    /// in `SempereAppCoreTests`).
    @Test func theJoinWordsSayWhereTheRequestIs() {
        #expect(AddDeviceText.looking(JoinRequestLookout(requests: [], arriving: true, checked: Date())).contains("on its way"))
        #expect(AddDeviceText.looking(JoinRequestLookout(requests: [], arriving: false, checked: Date())).contains("Still looking"))
        #expect(DeviceChangeText.message(DeviceJoinError.requestNotArrived).contains("iCloud Drive"))
        // Without any target nothing can arrive: the message says nothing of syncs (review of #117, N1).
        #expect(!DeviceChangeText.message(DeviceJoinError.noMatchingRequest).contains("iCloud"))
        #expect(JoinDelivery.waitingForUpload(iCloud: true).text.contains("iCloud Drive"))
    }
}
