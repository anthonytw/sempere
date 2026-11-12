import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Joining nearby through the model (docs/design/nearby-join.md): home's Add Device and an iPad's join screen over
    /// `MemoryNearbyTransport`, while the folder target's provider holds the iPad's request back (iCloud Drive taking
    /// minutes, build 11 and the 2026-11-11 report). The sync path keeps working beside it. Every wait is bounded.
    @MainActor
    @Suite(.timeLimit(.minutes(1)))
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
                m.nearbyTimeouts = NearbyJoin.Timeouts(handshake: .seconds(3), session: .seconds(20))
            }
            return Asked(home: home, pad: pad, provider: provider, words: words, padKeys: padKeys, link: link)
        }

        /// What home's own copy holds in `joins/` (nothing comes from the link: design N5).
        static func homeJoinFiles(_ w: Asked) -> [String] {
            guard let url = w.home.model.vaultURL else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("joins").path)) ?? [])
                .filter { $0.hasSuffix(".join.json") }
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
            #expect(Self.homeJoinFiles(w).isEmpty, "held in memory only, never written to home's vault")

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
            #expect(w.home.model.nearbyRequests.isEmpty, "forgotten when Add Device closes")
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
                                                     timeouts: .init(handshake: .seconds(3), session: .seconds(5)))
            #expect(outcome == .refused(.busy))
            #expect(w.home.model.nearbyRequests.map(\.key) == [w.pad.model.joinIdentity?.recipient.string])
            #expect(w.pad.model.nearbyJoining == .connected)
        }

        /// Declined on home: the iPad is told over the link, and (since any device that knows the vault's id could say
        /// it) keeps looking.
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
            #expect(w.pad.model.nearby.joinTask != nil, "still looking")
            #expect(w.home.model.vault?.devices.count == 1)
            #expect(w.home.model.nearbyRequests.isEmpty)
        }

        /// Add Device closed while a device waits nearby: the session is torn down (its connection too), nothing is
        /// approved, and a new Add Device takes a new session at once (no `busy` left over).
        @Test func closingAddDeviceEndsTheSessionAndANewOneStarts() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            let approval = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            approval.startNearby()
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
            approval.close()
            #expect(w.home.model.nearby.sessionToken == nil, "torn down at once")
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .looking })
            #expect(w.home.model.nearbyApproving == .off)
            #expect(w.home.model.vault?.devices.count == 1)
            #expect(await approval.approve(words: w.words, qr: nil) == false)

            let again = AddDeviceApprovalCore<TestHost>(model: w.home.model)
            again.startNearby()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.home.model.nearbyApproving == .connected })
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
            #expect(await again.approve(words: w.words, qr: nil))
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .received })
        }

        /// The system fails the listener and the browser (an app suspended, the local network refused): both sides say
        /// so and start again while their screens show.
        @Test func aFailedLinkStartsAgain() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.home.model.startNearbyApproving()
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
            w.link.fail()
            #expect(await TS.waitUntil(timeout: .seconds(10)) {
                w.home.model.nearbyApproving == .advertising || w.home.model.nearbyApproving == .connected
            })
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
            #expect(w.home.model.nearbyRequests.count == 1)
        }

        /// In the background nothing advertises or browses; back in the foreground both start again, while their
        /// screens still show (and not once they are gone).
        @Test func theBackgroundStopsTheLinkAndTheForegroundRestartsIt() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.home.model.startNearbyApproving()
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
            for m in [w.home.model, w.pad.model] { m.nearbyEnteredBackground() }
            #expect(w.home.model.nearbyApproving == .off)
            #expect(w.home.model.nearby.advertisement == nil && w.home.model.nearby.sessionToken == nil)
            #expect(w.pad.model.nearbyJoining == .off)
            #expect(w.pad.model.nearby.browsing == nil)
            for m in [w.home.model, w.pad.model] { m.nearbyEnteredForeground() }
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })

            w.pad.model.stopNearbyJoin()
            w.pad.model.nearbyEnteredBackground()
            w.pad.model.nearbyEnteredForeground()
            #expect(w.pad.model.nearbyJoining == .off, "the join screen went: nothing starts")
        }

        /// Home keeps at most four requests that came nearby, one per commitment, the oldest dropped first.
        @Test func homeKeepsAFewNearbyRequests() throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let store = MemoryDeviceKeyStore()
            let id = UUID()
            let requests = try (0..<6).map { _ in try store.generate().joinRequest(vaultId: id, name: "x", kind: "ipad") }
            for r in requests { model.keepNearbyRequest(r) }
            model.keepNearbyRequest(requests[3])
            #expect(model.nearbyRequests.map(\.commitment)
                    == [requests[2], requests[4], requests[5], requests[3]].map(\.commitment))
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

        /// A device that knows nothing connects, sends nothing, and reconnects as soon as home drops it: it holds only a
        /// handshake place (never the session) for at most the request limit, and the iPad's request gets through.
        @Test func aSilentDeviceKeepsNobodyOut() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.home.model.startNearbyApproving()
            let peers = NearbyPeerBox()
            let watch = w.link.browse(found: { peers.set($0) }, onFailure: {})
            defer { watch.stop() }
            #expect(await TS.waitUntil(timeout: .seconds(5)) { !peers.get().isEmpty })
            let peer = try #require(peers.get().first)
            let link = w.link
            let silent = Task.detached {
                while !Task.isCancelled {
                    guard let c = try? await link.open(peer) else {
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    // Home ends it within the request limit (3 s here); the suite's time limit bounds the rest.
                    while let d = try? await c.receive(maximum: 1 << 16), !d.isEmpty {}
                }
            }
            defer { silent.cancel() }
            try await Task.sleep(for: .milliseconds(200))
            #expect(w.home.model.nearby.sessionToken == nil, "a silent connection holds no session")
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(15)) { w.home.model.nearbyRequests.count == 1 })
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
        }

        /// More connections than handshake places: the oldest is ended to make room, never the newest refused.
        @Test func aNewConnectionEndsTheOldestHandshake() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.home.model.startNearbyApproving()
            let peers = NearbyPeerBox()
            let watch = w.link.browse(found: { peers.set($0) }, onFailure: {})
            defer { watch.stop() }
            #expect(await TS.waitUntil(timeout: .seconds(5)) { !peers.get().isEmpty })
            let peer = try #require(peers.get().first)
            var opened: [any NearbyJoinConnection] = []
            for _ in 0..<(NearbyJoinRuntime.handshakeLimit + 1) { opened.append(try await w.link.open(peer)) }
            #expect(await TS.waitUntil(timeout: .seconds(5)) {
                w.home.model.nearby.handshakes.count == NearbyJoinRuntime.handshakeLimit
            })
            // The first one was ended: its stream ends without a byte.
            let first = opened[0]
            let ended: Data? = await withTaskGroup(of: Data?.self) { group in
                group.addTask { try? await first.receive(maximum: 64) }
                group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
                let got = await group.next() ?? nil
                first.abort()
                group.cancelAll()
                return got
            }
            #expect(ended == Data(), "ended, not timed out")
            for c in opened { c.abort() }
        }

        /// The listener fails alone: Add Device starts it again, and the join screen's browser is not touched.
        @Test func aFailedListenerLeavesTheBrowserAlone() async throws {
            let w = try await Self.asked()
            defer { w.home.model.close(); w.pad.model.close() }
            w.home.model.startNearbyApproving()
            w.pad.model.startNearbyJoin()
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearbyJoining == .connected })
            let browsing = try #require(w.pad.model.nearby.browsing)
            w.link.failAdvertisers()
            #expect(await TS.waitUntil(timeout: .seconds(5)) { w.home.model.nearby.listenerFailures == 1 })
            #expect(w.pad.model.nearby.browserFailures == 0)
            #expect(w.pad.model.nearby.browsing === browsing, "the browser runs on")
            #expect(await TS.waitUntil(timeout: .seconds(10)) {
                w.home.model.nearbyApproving == .advertising || w.home.model.nearbyApproving == .connected
            })
            // And the browser alone: home keeps advertising.
            w.link.failBrowsers()
            #expect(await TS.waitUntil(timeout: .seconds(5)) { w.pad.model.nearby.browserFailures == 1 })
            #expect(w.home.model.nearby.advertisement != nil)
            #expect(await TS.waitUntil(timeout: .seconds(10)) { w.pad.model.nearby.browsing != nil })
        }

        /// Each failure in a row waits longer before the side starts again, at most a minute.
        @Test func restartsBackOff() {
            let base = Duration.milliseconds(500)
            #expect(NearbyJoinRuntime.restartDelay(base: base, failures: 1) == base)
            #expect(NearbyJoinRuntime.restartDelay(base: base, failures: 2) == base * 2)
            #expect(NearbyJoinRuntime.restartDelay(base: base, failures: 4) == base * 8)
            #expect(NearbyJoinRuntime.restartDelay(base: base, failures: 40) == .seconds(60))
            #expect(NearbyJoinRuntime.restartDelay(base: .seconds(90), failures: 3) == .seconds(90))
        }

        /// A decision for a session torn down since (another token) changes nothing of the session going now.
        @Test func aDecisionNeedsTheSessionsToken() {
            let runtime = NearbyJoinRuntime()
            let now = UUID()
            runtime.sessionToken = now
            runtime.decide(.closed, token: UUID())
            #expect(runtime.decision == nil)
            runtime.decide(.approved, token: now)
            #expect(runtime.decision == .approved)
        }

        /// Declining matches by commitment: a request of the same 8-hex name but another commitment stays listed.
        @Test func aNearbyDeclineMatchesByCommitment() throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let keys = try MemoryDeviceKeyStore().generate()
            let id = UUID()
            let a = try keys.joinRequest(vaultId: id, name: "x", kind: "ipad")
            let b = try keys.joinRequest(vaultId: id, name: "x", kind: "iphone")
            #expect(a.fileName == b.fileName && a.commitment != b.commitment)
            model.keepNearbyRequest(a)
            model.keepNearbyRequest(b)
            model.nearbyDeclined(a)
            #expect(model.nearbyRequests.map(\.commitment) == [b.commitment])
        }

        /// The join screen picks devices at random, those never tried first, and at most a few new ones a minute.
        @Test func theJoinScreenPicksAtRandomWithACap() {
            let peers = (0..<4).map { NearbyPeer(id: "Sempere-\($0)") }
            var seen = Set<NearbyPeer>()
            for _ in 0..<400 {
                if let p = AppModel.nearbyPick(ready: peers, tried: [], newThisMinute: 0) { seen.insert(p) }
            }
            #expect(seen == Set(peers), "no device sorts its way ahead")
            let tried: Set<NearbyPeer> = [peers[0]]
            #expect(AppModel.nearbyPick(ready: peers, tried: tried, newThisMinute: 0).map { !tried.contains($0) } == true)
            #expect(AppModel.nearbyPick(ready: peers, tried: tried, newThisMinute: NearbyJoinRuntime.newPeersPerMinute) == peers[0])
            #expect(AppModel.nearbyPick(ready: Array(peers.dropFirst()), tried: tried,
                                        newThisMinute: NearbyJoinRuntime.newPeersPerMinute) == nil)
        }
    }
}

/// The peers a test's browser saw.
final class NearbyPeerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [NearbyPeer] = []
    func set(_ p: [NearbyPeer]) { lock.lock(); peers = p; lock.unlock() }
    func get() -> [NearbyPeer] { lock.lock(); defer { lock.unlock() }; return peers }
}
