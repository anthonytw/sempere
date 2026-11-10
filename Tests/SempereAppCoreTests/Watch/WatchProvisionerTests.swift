import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing
import VaultTestSupport

/// "Use on Apple Watch" (docs/design/1.1-watch.md §3.4): what the phone sends, and its persisted counter.
struct WatchProvisionerTests {
    struct Rig {
        var stored: StoredCaptureProfile
        var watch: NativeIdentity
        var store: MemoryWatchLinkStore
        var provisioner: WatchProvisioner
    }

    static func rig(enabled: Bool = true, requested: Bool = true) throws -> Rig {
        let dir = try QuickCaptureLogicTests.tempDir("provision")
        let (_, stored) = try QuickCaptureLogicTests.profile(in: dir)
        let watch = try NativeIdentity.generate(.postQuantum)
        let store = MemoryWatchLinkStore()
        let p = WatchProvisioner(store: store)
        try p.setEnabled(enabled)
        if requested { try p.watchRequested(recipient: watch.recipient.string) }
        return Rig(stored: stored, watch: watch, store: store, provisioner: p)
    }

    /// The watch's side: applies `message` to `state`.
    static func apply(_ m: WatchProvisioning.Message?, _ rig: Rig, _ state: inout WatchProfileState) throws -> WatchProvisioning.Outcome? {
        guard let m else { return nil }
        return try WatchProvisioning.apply(m, identity: rig.watch, to: &state)
    }

    @Test func nothingIsSentWhileTheToggleIsOffOrTheWatchHasNotAsked() throws {
        let off = try Self.rig(enabled: false)
        #expect(try off.provisioner.nextMessage(stored: off.stored) == nil)
        #expect(off.provisioner.status(stored: off.stored) == .off)
        let silent = try Self.rig(requested: false)
        #expect(try silent.provisioner.nextMessage(stored: silent.stored) == nil)
        #expect(silent.provisioner.status(stored: silent.stored) == .waitingForWatch)
        #expect(silent.store.load().seq == -1)
    }

    @Test func theProfileIsSentOnceAndAgainOnlyWhenItChanges() throws {
        let r = try Self.rig()
        var watch = WatchProfileState()
        guard case .stored(let payload)? = try Self.apply(try r.provisioner.nextMessage(stored: r.stored), r, &watch) else {
            Issue.record("no profile sent"); return
        }
        #expect(payload.seq == 0)
        #expect(payload.profile == r.stored.profile)
        #expect(payload.vaultName == r.stored.vaultName)
        #expect(r.provisioner.status(stored: r.stored) == .provisioned(vaultName: r.stored.vaultName))
        #expect(try r.provisioner.nextMessage(stored: r.stored) == nil, "the watch holds it")
        var later = r.stored
        later.profile.epoch += 1
        guard case .stored(let next)? = try Self.apply(try r.provisioner.nextMessage(stored: later), r, &watch) else {
            Issue.record("a new epoch is not sent"); return
        }
        #expect(next.seq == 1)
        #expect(next.profile.epoch == later.profile.epoch)
        var renamed = later
        renamed.vaultName = "Other name"
        #expect(try r.provisioner.nextMessage(stored: renamed) != nil, "the vault's name is on the watch's screen")
        // Transcription is this device's choice and never reaches the watch.
        var transcribing = renamed
        transcribing.transcribe.toggle()
        #expect(try r.provisioner.nextMessage(stored: transcribing) == nil)
    }

    @Test func theCounterOnlyGoesUpAndSurvivesARestart() throws {
        let r = try Self.rig()
        var seqs: [Int] = []
        var stored = r.stored
        for i in 0..<4 {
            stored.profile.epoch += 1
            // A new provisioner on the same store each time: the counter is the store's, never the clock's.
            let p = WatchProvisioner(store: r.store)
            guard case .profile(let data)? = try p.nextMessage(stored: stored, issued: Date(timeIntervalSince1970: i % 2 == 0 ? 4_000_000_000 : 0)) else {
                Issue.record("nothing sent"); return
            }
            seqs.append(try WatchProfilePayload.open(data, with: r.watch).seq)
        }
        #expect(seqs == [0, 1, 2, 3])
        #expect(r.store.load().seq == 3)
    }

    @Test func aFileStoreKeepsTheCounterAcrossInstances() throws {
        let url = try QuickCaptureLogicTests.tempDir("link").appendingPathComponent("WatchLink.json")
        let dir = try QuickCaptureLogicTests.tempDir("provision")
        let (_, stored) = try QuickCaptureLogicTests.profile(in: dir)
        let watch = try NativeIdentity.generate(.postQuantum)
        let first = WatchProvisioner(store: FileWatchLinkStore(url: url))
        try first.setEnabled(true)
        try first.watchRequested(recipient: watch.recipient.string)
        #expect(try first.nextMessage(stored: stored) != nil)
        let second = WatchProvisioner(store: FileWatchLinkStore(url: url))
        #expect(second.enabled)
        #expect(second.state.seq == 0)
        #expect(try second.nextMessage(stored: stored) == nil, "what the watch holds is remembered too")
        // No secret on disk: the public recipient, a counter and a hash.
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!text.contains("AGE-SECRET-KEY"))
        #expect(try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aFailedSaveSendsNothingAndAFailedSendIsRetried() throws {
        let r = try Self.rig()
        r.store.failing = true
        #expect(throws: WatchProvisionerError.self) { try r.provisioner.nextMessage(stored: r.stored) }
        r.store.failing = false
        #expect(r.store.load().seq == -1, "the counter did not move")
        #expect(try r.provisioner.nextMessage(stored: r.stored) != nil)
        r.provisioner.sendFailed()
        guard case .profile(let data)? = try r.provisioner.nextMessage(stored: r.stored) else { Issue.record("not retried"); return }
        #expect(try WatchProfilePayload.open(data, with: r.watch).seq == 1, "a retry is a new, higher counter")
    }

    @Test func turningItOffOrLosingTheProfileClearsTheWatchOnce() throws {
        let r = try Self.rig()
        var watch = WatchProfileState()
        _ = try Self.apply(try r.provisioner.nextMessage(stored: r.stored), r, &watch)
        try r.provisioner.setEnabled(false)
        let clear = try r.provisioner.nextMessage(stored: r.stored)
        #expect(clear == .clear(seq: 1))
        #expect(try Self.apply(clear, r, &watch) == .cleared)
        #expect(watch.payload == nil)
        #expect(try r.provisioner.nextMessage(stored: r.stored) == nil, "nothing left to clear")
        // On again: the watch gets the profile with a counter above the clear's, or it would ignore it.
        try r.provisioner.setEnabled(true)
        guard case .stored(let p)? = try Self.apply(try r.provisioner.nextMessage(stored: r.stored), r, &watch) else {
            Issue.record("not provisioned again"); return
        }
        #expect(p.seq == 2)
        // Quick voice notes off: no profile, so a clear.
        #expect(try r.provisioner.nextMessage(stored: nil) == .clear(seq: 3))
        #expect(r.provisioner.status(stored: nil) == .needsQuickVoiceNotes)
    }

    @Test func aSuspendedProfileClearsTheWatchAndALiftedOneProvisionsIt() throws {
        let r = try Self.rig()
        var watch = WatchProfileState()
        _ = try Self.apply(try r.provisioner.nextMessage(stored: r.stored), r, &watch)
        var suspended = r.stored
        suspended.suspended = true
        #expect(r.provisioner.status(stored: suspended) == .suspended)
        #expect(try r.provisioner.nextMessage(stored: suspended) == .clear(seq: 1))
        #expect(try r.provisioner.nextMessage(stored: r.stored) != nil)
    }

    @Test func aWatchThatResetsAsksAgainAndGetsTheProfileWithAnyCounter() throws {
        let r = try Self.rig()
        var watch = WatchProfileState()
        _ = try Self.apply(try r.provisioner.nextMessage(stored: r.stored), r, &watch)
        _ = try Self.apply(try r.provisioner.nextMessage(stored: { var s = r.stored; s.profile.epoch += 1; return s }()), r, &watch)
        #expect(watch.seq == 1)
        // "Reset" on the watch: no profile, and its counter back to -1 (WatchProfileState()).
        watch = WatchProfileState()
        try r.provisioner.watchRequested(recipient: r.watch.recipient.string)
        guard case .stored(let again)? = try Self.apply(try r.provisioner.nextMessage(stored: r.stored), r, &watch) else {
            Issue.record("not given again"); return
        }
        #expect(again.seq == 2, "the phone's counter does not reset: the watch's -1 is below it")
        #expect(watch.payload != nil)
    }

    @Test func aNewWatchKeyIsUsedForTheNextProfile() throws {
        let r = try Self.rig()
        _ = try r.provisioner.nextMessage(stored: r.stored)
        let reinstalled = try NativeIdentity.generate(.postQuantum)
        try r.provisioner.watchRequested(recipient: reinstalled.recipient.string)
        guard case .profile(let data)? = try r.provisioner.nextMessage(stored: r.stored) else { Issue.record("not sent"); return }
        #expect(throws: WatchPayloadError.self) { try WatchProfilePayload.open(data, with: r.watch) }
        #expect(try WatchProfilePayload.open(data, with: reinstalled).profile == r.stored.profile)
    }

    @Test func aRequestThatIsNotAPostQuantumKeyIsRefused() throws {
        let r = try Self.rig(requested: false)
        for bad in ["", "hello", String(repeating: "a", count: 5000), try NativeIdentity.generate(.x25519).recipient.string] {
            #expect(throws: WatchProvisionerError.badRecipient) { try r.provisioner.watchRequested(recipient: bad) }
        }
        #expect(r.store.load().recipient == nil)
    }

    @Test func theCounterStopsBeforeItOverflowsTheWatchsInt() throws {
        let r = try Self.rig()
        r.store.setSeq(Int(Int32.max))
        #expect(throws: WatchProvisionerError.counterExhausted) { try r.provisioner.nextMessage(stored: r.stored) }
    }

    @Test func theLastNoteDateOnlyMovesForward() {
        let p = WatchProvisioner(store: MemoryWatchLinkStore())
        p.noteReceived(at: Date(timeIntervalSince1970: 100))
        p.noteReceived(at: Date(timeIntervalSince1970: 50))
        #expect(p.lastNote == Date(timeIntervalSince1970: 100))
    }

    @Test func aDamagedStateFileStartsOver() throws {
        let url = try QuickCaptureLogicTests.tempDir("link").appendingPathComponent("WatchLink.json")
        try Data("{not json".utf8).write(to: url)
        #expect(FileWatchLinkStore(url: url).load() == WatchLinkState())
    }
}

extension MemoryWatchLinkStore {
    func setSeq(_ seq: Int) {
        var s = load()
        s.seq = seq
        try? save(s)
    }
}
