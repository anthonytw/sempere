import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Add Device's sheet model (`AddDeviceApprovalCore`; the app words its failures, `JoinThroughProviderTests` in
    /// SempereAppTests) over a join through a folder target that a provider holds (build 11; review of #117, B1). The join
    /// itself through the model is `JoinThroughProviderTests`. Simulated with `EvictingFolderProvider`: a request the
    /// provider listed as a stand-in and delivers late.
    @MainActor
    struct AddDeviceApprovalTests {
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
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
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
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            #expect(await approval.approve(words: w.words, qr: nil) == false)
            #expect(approval.pending == AddDeviceApprovalCore<TestHost>.Pending(words: w.words, qr: nil), "kept for when it arrives")
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
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
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
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
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
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
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

        // MARK: - They Match (docs/design/1.2-join-confirm.md): approving a listed request by tapping

        /// The tap approves a request in `joins/` as the typed route does: owner check, one device added, the reply.
        @Test func theTapApprovesARequestInJoins() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.provider.arrivalDelay = 0
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            await approval.look()
            let request = try #require(approval.lookout?.requests.first)
            #expect(JoinCodes.words(request.commitment) == w.words, "the row shows the words the new device shows")
            #expect(await approval.approve(request: request))
            #expect(approval.reply != nil)
            #expect(approval.approvals == 1)
            #expect(w.home.model.vault?.devices.count == 2)
            #expect(await approval.approve(request: request) == false, "a reply is in: nothing more")
        }

        /// A request the model never listed (not nearby, not in `joins/`) is refused, and nothing is written.
        @Test func theTapRefusesARequestTheModelDoesNotHold() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            let stranger = try MemoryDeviceKeyStore().generate().joinRequest(vaultId: w.home.vaultID, name: "Other", kind: "cli")
            await #expect(throws: DeviceJoinError.noMatchingRequest) {
                _ = try await w.home.model.approveDevice(request: stranger)
            }
            #expect(w.home.model.vault?.devices.count == 1)
        }

        /// A file that took a listed request's name after it was listed, with other keys, is not approved: the tap names
        /// the request by its commitment, never by a file name.
        @Test func theTapNamesTheCommitmentNeverTheFileName() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.provider.arrivalDelay = 0
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            await approval.look()
            let listed = try #require(approval.lookout?.requests.first)
            // The copy's file of that name is replaced by another device's request.
            let other = try MemoryDeviceKeyStore().generate().joinRequest(vaultId: w.home.vaultID, name: "Impostor", kind: "ipad")
            let url = try #require(w.home.model.vaultURL).appendingPathComponent("joins").appendingPathComponent(listed.fileName)
            try JSONEncoder().encode(other).write(to: url)
            await #expect(throws: DeviceJoinError.noMatchingRequest) {
                _ = try await w.home.model.approveDevice(request: listed)
            }
            #expect(w.home.model.vault?.devices.count == 1)
            // The impostor's own request is approvable as itself, and adds only its own key.
            #expect(await approval.approve(request: other))
            #expect(w.home.model.vault?.devices.contains { $0.key == other.key } == true)
            #expect(w.home.model.vault?.devices.contains { $0.key == listed.key } == false)
        }

        /// The owner check refused, or the sheet closed (`proceed` false): nothing is written.
        @Test func theTapStopsAtTheOwnerCheckAndAtAClosedSheet() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.provider.arrivalDelay = 0
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            await approval.look()
            let request = try #require(approval.lookout?.requests.first)
            w.home.model.ownerAuthenticator = ScriptedOwnerCheck(.refuse(VaultError.locked))
            #expect(await approval.approve(request: request) == false)
            #expect(approval.failedWith != nil)
            #expect(w.home.model.vault?.devices.count == 1)
            w.home.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            await #expect(throws: CancellationError.self) {
                _ = try await w.home.model.approveDevice(request: request, proceed: { false })
            }
            #expect(w.home.model.vault?.devices.count == 1)
            approval.close()
            #expect(await approval.approve(request: request) == false, "a closed sheet approves nothing")
            #expect(w.home.model.vault?.devices.count == 1)
        }

        // MARK: - The warning for several requests (§3.5)

        @Test func twoRequestsWarnAndOneDoesNot() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.provider.arrivalDelay = 0
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            await approval.look()
            #expect(approval.lookout?.warnsOfSeveral == false)
            let phone = Self.device(w.provider, joining: true)
            defer { phone.model.close() }
            try await phone.model.copyIn(picked: w.provider.root, library: phone.library, followUp: .keepSyncing)
            _ = try await phone.model.startJoin(store: MemoryDeviceKeyStore())
            await phone.model.syncAllTargetsNow()
            await approval.look()
            #expect(approval.lookout?.warnsOfSeveral == true)
        }

        @Test func theConfirmGateWaitsOutItsDelay() {
            let t0 = Date(timeIntervalSince1970: 1_000)
            var gate = MatchConfirmGate()
            #expect(!gate.isEnabled(at: t0), "not shown yet")
            gate.shown(at: t0)
            gate.shown(at: t0.addingTimeInterval(1))   // a later show does not restart it
            #expect(!gate.isEnabled(at: t0.addingTimeInterval(1.4)))
            #expect(gate.isEnabled(at: t0.addingTimeInterval(1.5)))
            #expect(!gate.isEnabled(at: t0.addingTimeInterval(5), busy: true), "disabled while the owner check runs")
        }
    }
}
