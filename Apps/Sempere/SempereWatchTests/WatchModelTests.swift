import Age
import Foundation
import Sempere
import SempereCapture
import XCTest
@testable import SempereWatch

/// The watch app's model on a fake recorder, an in-memory Keychain and no WatchConnectivity (the pieces Linux cannot run:
/// the app's own wiring; the logic under it is `SempereCaptureTests`, `SempereAppCoreTests`). The audio is a fake that writes
/// real ADTS frames, so the seal and the outbox are the real code.
@MainActor
final class WatchModelTests: XCTestCase {
    struct Rig {
        var model: WatchModel
        var transport: NoWatchTransport
        var audio: FakeWatchAudio
        var secrets: MemoryWatchSecretStore
        var support: URL
        var haptics: HapticLog
    }

    final class HapticLog: @unchecked Sendable {
        var events: [WatchHaptic] = []
    }

    /// A timer that waits until the test fires it (a fire before the wait is kept).
    final class ManualTimer: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
        func wait() async { for await _ in stream { return } }
        func fire() { continuation.yield() }
    }

    func rig(free: Int64? = nil, limits: WatchOutbox.Limits = WatchOutbox.Limits(), timer: ManualTimer? = nil) throws -> Rig {
        let support = try TestTemp.directory("watch")
        let secrets = MemoryWatchSecretStore()
        let transport = NoWatchTransport()
        let audio = FakeWatchAudio()
        let haptics = HapticLog()
        let env = WatchEnvironment(secrets: secrets, audio: audio, transport: transport, support: support, statusStore: nil,
                                   freeBytes: { free }, haptic: { haptics.events.append($0) }, outboxLimits: limits)
        let model = try WatchModel(environment: env)
        model.savedDuration = .milliseconds(50)
        if let timer { model.savedWait = { _ in await timer.wait() } }
        return Rig(model: model, transport: transport, audio: audio, secrets: secrets, support: support, haptics: haptics)
    }

    /// What the phone would send this watch: the profile encrypted to the recipient the watch asked with.
    func provisioning(_ rig: Rig, seq: Int, vaultName: String = "Home", profile: CaptureProfile? = nil) throws -> [String: Any] {
        let recipient = try NativeRecipient(string: try XCTUnwrap(rig.transport.requests.last))
        let message = try WatchProvisioning.provision(profile: profile ?? WatchDebugLaunch.profile, vaultName: vaultName, seq: seq,
                                                     issued: Date(), to: recipient)
        return WatchProvisioning.dictionary(message)
    }

    func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Provisioning

    func testAWatchWithNoProfileAsksOnceAndShowsNotSetUp() async throws {
        let r = try rig()
        await r.model.activate()
        XCTAssertEqual(r.model.screen, .notSetUp)
        XCTAssertEqual(r.transport.requests.count, 1)
        await r.model.activate()
        XCTAssertEqual(r.transport.requests.count, 2, "with no profile it asks at every activation (the transport drops a duplicate)")
        XCTAssertTrue(try XCTUnwrap(r.transport.requests.first).hasPrefix("age1pq1"), "its own post-quantum key")
    }

    /// A cold launch asks before the session is activated: that request is not lost, and an unsent file is not "failed".
    func testARequestBeforeTheSessionIsActivatedIsMadeOnceItIs() async throws {
        let r = try rig()
        r.transport.activated = false
        await r.model.activate()
        XCTAssertTrue(r.transport.requests.isEmpty, "nothing could be queued yet")
        r.transport.activated = true
        r.model.requestProvisioningIfNeeded()   // what the session's activation callback does
        XCTAssertEqual(r.transport.requests.count, 1)
        XCTAssertEqual(r.transport.requestSeqs, [-1], "the counter the watch holds rides with it")
        r.model.requestProvisioningIfNeeded()
        XCTAssertEqual(r.transport.requests.count, 1, "once")
    }

    func testAnOutboxFlushBeforeActivationDoesNotPushTheRetryBack() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        r.transport.activated = false
        await r.model.record()
        await r.model.stop()
        let id = try XCTUnwrap(r.model.outbox.unsent.first?.id)
        r.model.flushOutbox(launch: true)
        let entry = try XCTUnwrap(r.model.outbox.entry(id))
        XCTAssertNil(entry.nextAttempt, "no backoff was set")
        XCTAssertEqual(entry.attempts, 0)
        r.transport.activated = true
        r.model.flushOutbox(launch: true)
        XCTAssertEqual(r.transport.sent.map(\.id), [id])
    }

    func testResetMakesANewProvisioningKey() async throws {
        let r = try rig()
        await r.model.activate()
        let old = try XCTUnwrap(r.transport.requests.last)
        r.model.receive(try provisioning(r, seq: 3))
        let oldPayload = try provisioning(r, seq: 4)   // what the phone's persisted context still holds
        r.model.reset()
        let new = try XCTUnwrap(r.transport.requests.last)
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(r.transport.requestSeqs.last, -1)
        r.model.receive(oldPayload)
        XCTAssertEqual(r.model.screen, .notSetUp, "the old context cannot be opened any more")
        XCTAssertNil(r.model.state.payload)
    }

    func testTheProvisioningKeyPersistsAcrossLaunches() async throws {
        let r = try rig()
        await r.model.activate()
        let first = try XCTUnwrap(r.transport.requests.last)
        let again = WatchModelTests.makeModel(secrets: r.secrets, support: r.support)
        await again.model.activate()
        XCTAssertEqual(again.transport.requests.last, first)
    }

    static func makeModel(secrets: MemoryWatchSecretStore, support: URL) -> (model: WatchModel, transport: NoWatchTransport) {
        let transport = NoWatchTransport()
        let env = WatchEnvironment(secrets: secrets, audio: FakeWatchAudio(), transport: transport, support: support, statusStore: nil,
                                   freeBytes: { nil }, haptic: { _ in })
        return (try! WatchModel(environment: env), transport)
    }

    func testAProfileFromThePhoneMakesTheWatchReadyAndSurvivesALaunch() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0, vaultName: "Home"))
        XCTAssertEqual(r.model.screen, .ready)
        XCTAssertEqual(r.model.vaultName, "Home")
        let again = WatchModelTests.makeModel(secrets: r.secrets, support: r.support)
        XCTAssertEqual(again.model.screen, .ready, "the profile is in the Keychain")
        XCTAssertEqual(again.model.state.seq, 0)
    }

    func testAnOlderPayloadAndAPayloadForAnotherKeyAreIgnored() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 5, vaultName: "Home"))
        r.model.receive(try provisioning(r, seq: 4, vaultName: "Older"))
        XCTAssertEqual(r.model.vaultName, "Home")
        let other = try NativeIdentity.generate(.postQuantum)
        let forged = WatchProvisioning.dictionary(try WatchProvisioning.provision(profile: WatchDebugLaunch.profile, vaultName: "Forged",
                                                                                 seq: 9, issued: Date(), to: other.recipient))
        r.model.receive(forged)
        XCTAssertEqual(r.model.vaultName, "Home")
        XCTAssertEqual(r.model.state.seq, 5)
        r.model.receive(["unrelated": 1])
        XCTAssertEqual(r.model.vaultName, "Home")
    }

    func testAClearForgetsTheProfileButKeepsSealedNotes() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        await r.model.record()
        await r.model.stop()
        XCTAssertEqual(r.model.unsent, 1)
        r.model.receive(WatchProvisioning.dictionary(.clear(seq: 1)))
        XCTAssertEqual(r.model.screen, .saved(try XCTUnwrap(r.model.recorder.lastSaved)), "the saved screen is still up")
        r.model.dismissSaved()
        XCTAssertEqual(r.model.screen, .notSetUp)
        XCTAssertEqual(r.model.unsent, 1, "the pending note is kept and still sent")
    }

    /// A clear that arrives mid-recording takes effect after the seal, and a cleared watch asks the phone again by itself.
    func testAClearMidRecordingIsSealedWithTheStartProfileAndTheWatchAsksAgain() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        await r.model.record()
        r.model.receive(WatchProvisioning.dictionary(.clear(seq: 1)))
        XCTAssertNil(r.model.state.payload)
        XCTAssertEqual(r.transport.requests.count, 2, "a cleared watch asks again")
        await r.model.stop()
        XCTAssertEqual(r.model.unsent, 1, "sealed with the profile the recording started with")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.support.appendingPathComponent("Capture").path), [],
                       "no plaintext left")
    }

    func testResetDeletesTheProfileAndTheCounterAndAsksAgain() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 7))
        XCTAssertEqual(r.model.state.seq, 7)
        r.model.reset()
        XCTAssertEqual(r.model.screen, .notSetUp)
        XCTAssertEqual(r.model.state, WatchProfileState(), "seq is back to -1")
        XCTAssertEqual(r.transport.requests.count, 2, "it asks the phone again")
        // The phone's counter does not reset, but a payload with a LOWER counter than the old one is taken too: the watch's -1
        // is below any counter.
        r.model.receive(try provisioning(r, seq: 0, vaultName: "Again"))
        XCTAssertEqual(r.model.vaultName, "Again")
        let reloaded = WatchModelTests.makeModel(secrets: r.secrets, support: r.support)
        XCTAssertEqual(reloaded.model.state.seq, 0, "Reset was saved")
    }

    /// The sweep deletes nothing while the stored state is unreadable; once a Reset or a new profile has written the state, it
    /// is readable again and the sweep is back on without waiting for the next activation.
    func testAResetAndANewProfileEndTheUnreadableState() async throws {
        let secrets = MemoryWatchSecretStore()
        secrets.failProfileStateLoads = true
        let a = WatchModelTests.makeModel(secrets: secrets, support: try TestTemp.directory("watch-unreadable-a"))
        XCTAssertTrue(a.model.stateUnreadable)
        a.model.reset()
        XCTAssertFalse(a.model.stateUnreadable, "Reset wrote the state")

        let secrets2 = MemoryWatchSecretStore()
        secrets2.failProfileStateLoads = true
        let support = try TestTemp.directory("watch-unreadable-b")
        let b = WatchModelTests.makeModel(secrets: secrets2, support: support)
        XCTAssertTrue(b.model.stateUnreadable)
        b.model.requestProvisioningIfNeeded()
        let r = Rig(model: b.model, transport: b.transport, audio: FakeWatchAudio(), secrets: secrets2, support: support,
                    haptics: HapticLog())
        b.model.receive(try provisioning(r, seq: 0))
        XCTAssertNotNil(b.model.state.payload)
        XCTAssertFalse(b.model.stateUnreadable, "a stored profile is the state now")
    }

    /// The safety half: a Reset whose save fails leaves the state unreadable, so the sweep still deletes nothing.
    func testAResetWhoseSaveFailsKeepsTheStateUnreadable() async throws {
        let secrets = MemoryWatchSecretStore()
        secrets.failProfileStateLoads = true
        let a = WatchModelTests.makeModel(secrets: secrets, support: try TestTemp.directory("watch-unreadable-c"))
        XCTAssertTrue(a.model.stateUnreadable)
        secrets.failProfileStateSaves = true
        a.model.reset()
        XCTAssertTrue(a.model.stateUnreadable, "nothing was written: still a stand-in, not \"no profile\"")
    }

    // MARK: Recording

    func testRecordStopSealsIntoTheOutboxAndHandsItOver() async throws {
        let timer = ManualTimer()
        let r = try rig(timer: timer)
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        await r.model.record()
        XCTAssertEqual(r.model.screen, .recording)
        await r.model.stop()
        guard case .saved(let note) = r.model.screen else { return XCTFail("\(r.model.screen)") }
        XCTAssertEqual(note.vaultName, "Home")
        XCTAssertEqual(r.haptics.events.count, 2)
        XCTAssertEqual(r.model.unsent, 1)
        XCTAssertEqual(r.transport.sent.map(\.id), [note.id], "handed to WatchConnectivity at once")
        XCTAssertEqual(r.transport.sent.first?.vault, WatchDebugLaunch.profile.vaultId)
        // The plaintext folder is gone; the sealed file waits for the phone.
        let capture = r.support.appendingPathComponent("Capture")
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: capture.path)) ?? []).count, 0)
        // No ack, no delete.
        r.model.transferFinished(id: note.id, failed: false)
        XCTAssertEqual(r.model.unsent, 1)
        r.model.receive(ack: WatchAck(acked: [note.id]))
        XCTAssertEqual(r.model.unsent, 0)
        // Saved stays until its timer runs out, then goes back to Ready by itself.
        guard case .saved = r.model.screen else { return XCTFail("Saved went before its timer: \(r.model.screen)") }
        timer.fire()
        await r.model.savedTask?.value
        XCTAssertEqual(r.model.screen, .ready)
    }

    func testAFailedTransferKeepsTheFileAndALaunchRetriesIt() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        r.transport.accepts = false
        await r.model.record()
        await r.model.stop()
        XCTAssertEqual(r.model.unsent, 1)
        XCTAssertTrue(r.transport.sent.isEmpty)
        r.transport.accepts = true
        r.model.sendNow()
        XCTAssertEqual(r.transport.sent.count, 1)
    }

    func testEveryRefusalHasItsOwnScreen() async throws {
        var r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        r.audio.microphoneAllowed = false
        await r.model.record()
        XCTAssertEqual(r.model.screen, .cannotRecord(.microphoneDenied))
        r.model.dismissProblem()
        XCTAssertEqual(r.model.screen, .ready)

        var limits = WatchOutbox.Limits()
        limits.maxFiles = 0
        r = try rig(limits: limits)
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        await r.model.record()
        XCTAssertEqual(r.model.screen, .cannotRecord(.outboxFull))
        XCTAssertFalse(r.model.recorder.isRecording)

        r = try rig(free: 1 << 20)
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        await r.model.record()
        XCTAssertEqual(r.model.screen, .cannotRecord(.lowStorage))

        r = try rig()
        await r.model.record()
        XCTAssertEqual(r.model.screen, .notSetUp, "no profile: the screen that says to set up, never silence")
    }

    func testASurfaceStartsRecordingAndTheAppGridDoesNot() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        XCTAssertEqual(r.model.screen, .ready, "launched from the app grid: nothing records")
        XCTAssertFalse(r.model.recorder.isRecording)
        r.model.open(url: try XCTUnwrap(URL(string: "sempere-watch://record")))
        try await eventually("recording") { r.model.recorder.isRecording }
        r.model.open(url: try XCTUnwrap(URL(string: "https://example.com/record")))
        await r.model.stop()
    }

    /// A surface's recording ends on a "Saved" that stays, with nothing to tap, until the app goes to the background; one
    /// from the app grid goes back to Ready by itself.
    func testASurfacesRecordingEndsOnSavedUntilTheBackground() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        r.model.startFromSurface()
        try await eventually("recording") { r.model.recorder.isRecording }
        await r.model.stop()
        guard case .saved = r.model.screen else { return XCTFail("\(r.model.screen)") }
        XCTAssertTrue(r.model.savedStays)
        try await Task.sleep(for: .milliseconds(200))   // four times savedDuration
        guard case .saved = r.model.screen else { return XCTFail("Saved went by itself: \(r.model.screen)") }
        await r.model.activate()   // the wrist comes back up: still Saved
        guard case .saved = r.model.screen else { return XCTFail("\(r.model.screen)") }
        r.model.enteredBackground()
        XCTAssertEqual(r.model.screen, .ready)
        XCTAssertFalse(r.model.savedStays)

        await r.model.record()
        await r.model.stop()
        XCTAssertFalse(r.model.savedStays, "the app grid's Record: the usual two-second Saved")
        r.model.enteredBackground()
        guard case .saved = r.model.screen else { return XCTFail("\(r.model.screen)") }
        try await eventually("saved to go") { r.model.screen == .ready }
    }

    func testASurfacesRecordingThatEndsInTheBackgroundDoesNotStay() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        r.model.startFromSurface()
        try await eventually("recording") { r.model.recorder.isRecording }
        r.model.enteredBackground()   // the watch face is back; Siri or the time limit stops it later
        await r.model.stop()
        XCTAssertFalse(r.model.savedStays)
        try await eventually("saved to go") { r.model.screen == .ready }
        r.model.enteredForeground()
        await r.model.activate()
        XCTAssertEqual(r.model.screen, .ready)

        r.model.startFromSurface()
        try await eventually("recording") { r.model.recorder.isRecording }
        await r.model.record()   // a second start while recording: refused, the surface flag stands
        await r.model.stop()
        XCTAssertTrue(r.model.savedStays, "the running recording came from a surface")
    }

    func testARecordingACrashCutOffIsSealedAtTheNextLaunch() async throws {
        let r = try rig()
        await r.model.activate()
        r.model.receive(try provisioning(r, seq: 0))
        // What a crash leaves: a folder with a manifest and one ADTS segment.
        let id = UUID()
        let folder = r.support.appendingPathComponent("Capture/\(id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var audio = Data()
        for i in 0..<40 { audio.append(FakeWatchRecording.frame(seed: UInt8(i))) }
        try audio.write(to: folder.appendingPathComponent("segment-001.aac"))
        // The recording started under the provisioned profile, so its manifest names that vault (a leftover naming none
        // is kept, not sealed: WatchRecorderTests.aLeftoverWithNoVaultIsKeptNotSealed).
        let profile = WatchDebugLaunch.profile
        let manifest = RecordingManifest(note: id, recording: id, started: Date(), codec: "aac", segments: ["segment-001.aac"], finished: 0,
                                         vault: profile.vaultId, epochId: profile.epochId)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
        await r.model.activate()
        guard case .saved(let note) = r.model.screen else { return XCTFail("\(r.model.screen)") }
        XCTAssertTrue(note.recovered, "\"Interrupted voice note saved\"")
        XCTAssertEqual(r.model.unsent, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Keychain

    func testTheKeychainStoreKeepsTheIdentityAndTheState() throws {
        let store = KeychainWatchSecretStore()
        // An unsigned test host (CODE_SIGNING_ALLOWED=NO, the gate's and `scripts/app.sh test-watch`'s) has no Keychain access
        // group: errSecMissingEntitlement. The signed app and a signed test run exercise this.
        do { try store.save(Data("probe".utf8), as: .profileState) } catch KeychainWatchSecretStore.Failure.status(-34018) {
            throw XCTSkip("the Keychain needs a signed test host")
        }
        try? store.delete(.provisioningKey)
        try? store.delete(.profileState)
        defer { try? store.delete(.provisioningKey); try? store.delete(.profileState) }
        let secrets = WatchSecrets(store: store)
        let identity = try secrets.identity()
        XCTAssertTrue(identity.isPostQuantum)
        XCTAssertEqual(try secrets.identity().string, identity.string, "made once")
        XCTAssertEqual(secrets.state(), WatchProfileState())
        let payload = WatchProfilePayload(profile: WatchDebugLaunch.profile, vaultName: "Home", seq: 3, issued: Date(timeIntervalSince1970: 1_700_000_000))
        try secrets.save(WatchProfileState(seq: 3, payload: payload))
        XCTAssertEqual(secrets.state().payload?.vaultName, "Home")
        XCTAssertEqual(secrets.state().seq, 3)
    }
}
