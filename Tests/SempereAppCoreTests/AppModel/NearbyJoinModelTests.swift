import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Joining nearby through the model (docs/design/nearby-join.md): home's Add Device and an iPad's join screen over
    /// `MemoryNearbyTransport`, while the folder target's provider holds the iPad's request back (iCloud Drive taking
    /// minutes, build 11 and the 2026-11-11 report). The sync path keeps working beside it.
    @MainActor
    struct NearbyJoinModelTests {
        typealias Device = AddDeviceApprovalTests.Device

        /// Home and an iPad that asked to join; the target's copy of the request is a stand-in its provider does not
        /// deliver; both on one nearby link.
        struct Asked {
            let home: Device
            let pad: Device
            let provider: EvictingFolderProvider
            let words: [String]
            let padKeys: MemoryDeviceKeyStore
            let link: MemoryNearbyTransport
        }

        static func asked() async throws -> Asked {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
            let provider = EvictingFolderProvider(root: shared, cloud: drive.appendingPathComponent(".cloud"))
            let link = MemoryNearbyTransport()
            let home = AddDeviceApprovalTests.device(provider, joining: false)
            home.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            try await home.model.copyIn(picked: vault, library: home.library)
            _ = try await home.model.unlock(identityText: key)
            try home.model.addFolderTarget(shared, scope: drive, to: home.vaultID)
            await home.model.syncAllTargetsNow()
            let pad = AddDeviceApprovalTests.device(provider, joining: true)
            try await pad.model.copyIn(picked: shared, library: pad.library, followUp: .keepSyncing)
            let padKeys = MemoryDeviceKeyStore()
            guard case .waiting(let words, _) = try await pad.model.startJoin(store: padKeys) else { throw CancellationError() }
            await pad.model.syncAllTargetsNow()
            let joins = shared.appendingPathComponent("joins")
            let request = try #require(try FileManager.default.contentsOfDirectory(atPath: joins.path).first { $0.hasSuffix(".join.json") })
            try provider.evict("joins/\(request)", as: .standIn)
            provider.arrivalDelay = 1_000_000_000
            for m in [home.model, pad.model] {
                m.nearbyTransport = link
                m.nearbyRetry = .milliseconds(50)
                m.nearbyTimeouts = NearbyJoin.Timeouts(handshake: .seconds(5), session: .seconds(30))
            }
            return Asked(home: home, pad: pad, provider: provider, words: words, padKeys: padKeys, link: link)
        }

        /// The request reaches home over the link while the provider holds it back; home approves it by the six words
        /// without a sync; the approval comes back over the link and the iPad confirms with the reply words.
        @Test func aDeviceJoinsNearbyWhileTheTargetHoldsItsRequestBack() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            #expect(await w.home.model.lookForJoinRequests().requests.isEmpty, "the target has not delivered it")
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            approval.startNearby()
            #expect(w.home.model.nearbyApproving == .advertising)
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.home.model.nearbyRequests.count == 1 })
            #expect(await TS.waitUntil { w.pad.model.nearbyJoining == .connected })
            #expect(w.home.model.nearbyApproving == .connected)
            await approval.refresh()
            #expect(approval.lookout?.requests.count == 1, "listed with the synced ones")
            #expect(await w.home.model.pendingJoinRequests().count == 1, "and in home's joins/, for the vault's records")

            #expect(await approval.approve(words: w.words, qr: nil))
            let reply = try #require(approval.reply)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .received })
            let keys = RememberedKeys(store: w.padKeys)
            #expect(await keys.unlockWithDeviceKey(w.pad.model).outcome == .joining)
            #expect(keys.joinStage == .confirming)
            let device = try await w.padKeys.keys(for: w.pad.vaultID, reason: .unlock(vaultName: nil))
            try await w.pad.model.confirmJoin(words: reply.words, keys: device)
            #expect(w.pad.model.phase == .unlocked)
            #expect(w.pad.model.nearbyJoining == .off, "the link stops once confirmed")

            // The slow route arrives afterwards: nothing is approved twice, and the request is not listed again.
            approval.close()
            #expect(w.home.model.nearbyApproving == .off)
            w.provider.arrivalDelay = 0
            await w.home.model.syncAllTargetsNow()
            await w.home.model.syncAllTargetsNow()
            #expect(w.home.model.vault?.devices.count == 2)
            #expect(await w.home.model.pendingJoinRequests().isEmpty)
            await w.pad.model.syncAllTargetsNow()
            #expect(w.pad.model.phase == .unlocked)
        }

        /// A second device while a session waits is told `busy`, and the first session is not disturbed.
        @Test func aSecondDeviceIsToldBusy() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.home.model.startNearbyApproving()
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.home.model.nearbyRequests.count == 1 })
            let peer = try #require(w.pad.model.nearby.peers.first)
            let stranger = try MemoryDeviceKeyStore().generate()
            let raw = try JSONEncoder().encode(stranger.joinRequest(vaultId: w.home.vaultID, name: "Other", kind: "cli"))
            let second = try await w.link.open(peer)
            let outcome = try await NearbyJoiner.run(on: second, request: raw, nonce: NearbyJoin.randomBytes(32),
                                                     identity: stranger.nativeIdentity,
                                                     timeouts: .init(handshake: .seconds(5), session: .seconds(5)))
            #expect(outcome == .refused(.busy))
            #expect(w.home.model.nearbyRequests.map(\.key) == [w.pad.model.joinIdentity?.recipient.string])
            #expect(w.pad.model.nearbyJoining == .connected)
        }

        /// Declined on home: the iPad is told, over the link.
        @Test func aDeclineReachesTheDeviceNearby() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            approval.startNearby()
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.home.model.nearbyRequests.count == 1 })
            let request = try #require(w.home.model.nearbyRequests.first)
            #expect(await approval.decline(request))
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .declined })
            #expect(w.home.model.vault?.devices.count == 1)
        }

        /// Add Device closed while a device waits nearby: the session ends (`closed`), nothing is approved, and the
        /// iPad goes back to looking.
        @Test func closingAddDeviceEndsTheSession() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            approval.startNearby()
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
            approval.close()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .looking })
            #expect(w.home.model.nearbyApproving == .off)
            #expect(w.home.model.vault?.devices.count == 1)
            #expect(await approval.approve(words: w.words, qr: nil) == false)
        }

        /// Approved through the target before the iPad found home nearby: home answers at once with the approval it
        /// holds, and the iPad's copy takes it without a sync.
        @Test func aDeviceApprovedThroughTheTargetGetsItsReplyNearby() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.provider.arrivalDelay = 0
            await w.home.model.syncAllTargetsNow()
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            #expect(await approval.approve(words: w.words, qr: nil))
            let reply = try #require(approval.reply)
            approval.startNearby()
            // The approval is not on the iPad yet (no sync since): it comes over the link.
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .received })
            let device = try await w.padKeys.keys(for: w.pad.vaultID, reason: .unlock(vaultName: nil))
            try await w.pad.model.confirmJoin(words: reply.words, keys: device)
            #expect(w.pad.model.phase == .unlocked)
        }

        /// Without a link nothing starts, and the target path is untouched.
        @Test func withoutALinkNothingStarts() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.home.model.nearbyTransport = nil
            w.pad.model.nearbyTransport = nil
            w.home.model.startNearbyApproving()
            w.pad.model.startNearbyJoin()
            #expect(w.home.model.nearbyApproving == .off)
            #expect(w.pad.model.nearbyJoining == .off)
        }
    }
}
