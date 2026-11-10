import Foundation
import Sempere
@testable import SempereAppCore
import SempereCaptureShared
import Testing

/// Quick voice notes' state machine (docs/quick-capture.md), on fakes: capture with only the stored profile (no
/// key, no unlock), delivery to the vault's inbox or the queue, pauses on the Live Activity and the widgets'
/// status, the banner, and what a sweep or a seal keeps, seals or deletes. Moved from the app's
/// `QuickCaptureTests` (wave 5b); what needs AVFoundation, the real recorder or the `AppModel` stays there.
@Suite(.serialized)
@MainActor
struct QuickCaptureFlowTests {
    // MARK: - Recording

    /// The core promise: capture needs nothing but the profile. The sealed files read back with the identity,
    /// and no plaintext audio is left on disk. (On the app's recorder and AVFoundation:
    /// `QuickCaptureTests.captureWithoutUnlockingSealsAudioAndTranscriptIntoTheInbox`, SempereAppTests.)
    @Test func aVoiceNoteIsSealedWithTheProfileAloneIntoTheInbox() async throws {
        let rig = try CaptureRig(transcribe: true, transcriber: FakeTranscriber())
        let qc = rig.capture
        try await qc.start()
        #expect(qc.state == .recording)
        let outcome = try await qc.stop()
        #expect(outcome.error == nil && outcome.delivery == .vault && outcome.transcribed)
        #expect(qc.state == .idle)
        #expect(rig.inbox == [CaptureFile.name(outcome.id, .capture), CaptureFile.name(outcome.id, .transcript)].sorted())
        #expect(rig.leftovers.isEmpty, "no plaintext audio is kept")
        let sealed = try Data(contentsOf: rig.vault.appendingPathComponent("inbox/\(CaptureFile.name(outcome.id, .capture))"))
        #expect(sealed.range(of: Data("AUDIO-FRAMES".utf8)) == nil, "encrypted on disk")
        let pending = try rig.openVault().readCapture(outcome.id)
        #expect(pending.audio == Data("AUDIO-FRAMES".utf8))
        #expect(pending.manifest?.audio.type == "audio/mp4")
        #expect(pending.manifest?.title == CaptureWriter.defaultTitle(rig.clock.now), "no title given: the library's")
        #expect(pending.transcript?.segments.first?.words?.map(\.t) == ["Linear", "maps."])
        #expect(rig.audio.formats == [CaptureSegments.captureFormat(.default)])
        #expect(rig.audio.lastRecording?.segments.first?.pathExtension == CaptureSegments.segmentExtension)
    }

    /// The app's title, in the device's language, when it gives one (`noteTitle`).
    @Test func theAppNamesTheVoiceNote() async throws {
        let rig = try CaptureRig()
        rig.capture.noteTitle = { _ in "Nota de voz" }
        try await rig.capture.start()
        let outcome = try await rig.capture.stop()
        #expect(try rig.openVault().readCapture(outcome.id).manifest?.title == "Nota de voz")
    }

    /// Device check c48: a voice note stopped at once is saved, not dropped as too short; and again from the
    /// other side of a pause.
    @Test func aVoiceNoteStoppedAtOnceIsSaved() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        try await qc.start()
        let outcome = try await qc.stop()   // no time passes
        #expect(outcome.error == nil && outcome.delivery == .vault)
        #expect(qc.notice?.result == .savedToInbox)
        #expect(rig.inbox == [CaptureFile.name(outcome.id, .capture)])
        #expect(rig.leftovers.isEmpty)
        try await qc.start()
        try #require(rig.audio.lastRecording).interrupt()
        let second = try await qc.stop()
        #expect(second.error == nil)
        #expect(rig.inbox.count == 2)
    }

    /// The widget and Control Center fired together: the second start used to pass the idle check during the
    /// first one's microphone prompt and start a second recording that nothing could stop.
    @Test func aSecondStartDuringTheFirstIsRefused() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        let gate = AsyncStream<Void>.makeStream()
        final class Gated: CaptureAudio {
            let inner: FakeAudio
            let stream: AsyncStream<Void>
            init(_ inner: FakeAudio, _ stream: AsyncStream<Void>) { self.inner = inner; self.stream = stream }
            func requestMicrophone() async -> Bool {
                for await _ in stream { break }
                return true
            }
            var microphonePermission: String { "granted" }
            var preferredFormat: RecordingFormat { .default }
            func makeRecorder() -> any CaptureRecorder { inner.makeRecorder() }
        }
        qc.audio = Gated(rig.audio, gate.stream)
        let first = Task { try await qc.start() }
        #expect(await rig.settle { qc.state == .starting })
        await #expect(throws: QuickCaptureError.alreadyRecording) { try await qc.start() }
        gate.continuation.yield()
        try await first.value
        #expect(qc.state == .recording)
        _ = try await qc.stop()
        #expect(qc.state == .idle)
    }

    /// Bug audit B41: the Live Activity shows a pause (its timer stands still) and the resumption, and its last
    /// state gives the length of the audio, not the time since the start.
    @Test func theLiveActivityShowsAPause() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        try await qc.start()
        let rec = try #require(rig.audio.lastRecording)
        let start = try #require(rec.timeline.started)
        rig.clock.advance(2)
        rec.interrupt()
        #expect(qc.isPaused)
        #expect(await rig.settle { rig.live.states.contains { $0.paused } })
        let paused = try #require(rig.live.states.last)
        #expect(paused.paused && paused.isRecording && !paused.timerRuns)
        #expect(try #require(paused.ended).timeIntervalSince(paused.started) == 2)
        rig.clock.advance(0.3)   // paused: no audio, and the timer must not count it
        rec.resume()
        #expect(await rig.settle { rig.live.states.last?.paused == false })
        let resumed = try #require(rig.live.states.last)
        #expect(resumed.timerRuns)
        #expect(abs(resumed.started.timeIntervalSince(start) - 0.3) < 1e-6, "the timer starts later by the pause")
        rig.clock.advance(1)
        _ = try await qc.stop()
        let last = try #require(rig.live.states.last)
        #expect(last.result == .savedToInbox)
        #expect(abs(try #require(last.ended).timeIntervalSince(last.started) - 3) < 1e-6, "3 s of audio, not 3.3 s")
    }

    // MARK: - Delivery

    /// When the vault folder cannot be reached the sealed capture waits in a local queue (encrypted) and moves
    /// into the vault later.
    @Test func anUnreachableVaultQueuesTheCapture() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        let stored = try rig.stored
        qc.vaultStore = VaultStore(root: CaptureFixture.temp("not-the-store"))   // no copy of the vault there
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .queued)
        #expect(qc.notice?.result == .savedOnDevice, "the banner says the note is on this device, not in the vault yet")
        let vaultID = stored.profile.vaultId
        #expect(CaptureRig.names(qc.queueFolder(vaultID))
                == [CaptureFile.name(outcome.id, .capture), CaptureFile.name(outcome.id, .capture) + ".epoch"])
        #expect(rig.inbox.isEmpty)
        #expect(qc.flushQueue(into: rig.vault, vaultId: vaultID, coordinated: false) == 1)
        #expect(rig.inbox == [CaptureFile.name(outcome.id, .capture)])
        #expect(CaptureRig.names(qc.queueFolder(vaultID)).isEmpty)
    }

    /// Security review 2026-10 (N2): a vault whose `vault.json` names a newer format is read-only for this
    /// version (format.md §7.3), so a voice note for it waits in the queue, and the queue is not flushed into it.
    @Test func aReadOnlyVaultGetsNoCaptures() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        let manifest = rig.vault.appendingPathComponent("vault.json")
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        obj["format"] = "sempere/9"
        try JSONSerialization.data(withJSONObject: obj).write(to: manifest)
        let vaultID = try rig.stored.profile.vaultId
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .queued)
        #expect(rig.inbox.isEmpty, "nothing written into the read-only vault")
        #expect(qc.flushQueue(into: rig.vault, vaultId: vaultID, coordinated: false) == 0)
        #expect(CaptureRig.names(qc.queueFolder(vaultID)).filter { CaptureFile.parse(name: $0) != nil } == [CaptureFile.name(outcome.id, .capture)])
    }

    /// A queued voice note is recorded under the epoch of the profile that SEALED it, not the profile current when
    /// the queue is flushed (review M4: else it would be set aside for good).
    @Test func aQueuedVoiceNoteKeepsTheEpochItWasSealedUnder() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        let ledger = MemoryWriteLedger()
        qc.ledger = { _ in ledger }
        var stored = try rig.stored
        let sealedEpoch = stored.profile.epoch
        qc.vaultStore = nil   // no copy of the vault to deliver into
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .queued)
        stored.profile.epoch = sealedEpoch + 1
        stored.profile.epochId = String(repeating: "ab", count: 32)
        try rig.store.save(stored)
        #expect(qc.flushQueue(into: rig.vault, vaultId: stored.profile.vaultId, coordinated: false) == 1)
        let entry = try #require(try ledger.entries().first { $0.path == "inbox/\(CaptureFile.name(outcome.id, .capture))" })
        #expect(entry.epoch == sealedEpoch)
        #expect(CaptureRig.names(qc.queueFolder(stored.profile.vaultId)).isEmpty, "the sidecar goes with the file")
    }

    /// A voice note is recorded in its vault's ledger, under the profile's epoch, before it is placed in the inbox
    /// (design §5.4, §5.7): a device change before it is adopted is caught up from there. A coordinated flush goes
    /// through `files`.
    @Test func voiceNotesAreRecordedInTheLedgerBeforeTheInbox() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        let ledger = MemoryWriteLedger()
        qc.ledger = { _ in ledger }
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        let name = CaptureFile.name(outcome.id, .capture)
        let entry = try #require(try ledger.entries().first { $0.path == "inbox/\(name)" })
        #expect(entry.epoch == (try rig.openVault()).manifest.epoch)
        #expect(entry.sha256 == FileDigest.sha256(try Data(contentsOf: rig.vault.appendingPathComponent("inbox/\(name)"))))
    }

    /// Moving the queue when the app becomes active says when the profile cannot be read, instead of doing
    /// nothing silently.
    @Test func flushingTheStoredQueueSaysWhenTheProfileCannotBeRead() throws {
        let rig = try CaptureRig()
        rig.capture.store = FailingCaptureProfileStore()
        #expect(throws: QuickCaptureError.profileUnreadable) { try rig.capture.flushStoredQueue() }
        rig.capture.store = MemoryCaptureProfileStore()
        #expect(try rig.capture.flushStoredQueue() == 0, "no profile: nothing to move, and nothing wrong")
    }

    // MARK: - Status for the widgets, and the setup

    /// The widgets and the control read what `publishStatus` writes into the App Group: set up or not, ready,
    /// recording (with its start), and back. Widgets are reloaded only when the status changed, and each time
    /// they are asked to (launch, activation).
    @Test func statusFollowsSetupAndTheRecorder() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        let statusStore = VoiceNoteStatusStore(directory: CaptureFixture.temp("qc-status"))
        var reloads = 0
        qc.statusStore = statusStore
        qc.reloadSurfaces = { reloads += 1 }

        qc.publishStatus()
        #expect(statusStore.read() == VoiceNoteStatus(phase: .ready))
        #expect(reloads == 1)
        qc.publishStatus()
        #expect(reloads == 1, "an unchanged status reloads nothing")
        qc.publishStatus(forceReload: true)
        #expect(reloads == 2, "launch and activation reload although the file is the same")

        try await qc.start()
        let recording = try #require(statusStore.read())
        #expect(recording.phase == .recording && recording.started == qc.started && recording.action == .stop)

        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        #expect(statusStore.read() == VoiceNoteStatus(phase: .ready))
        #expect(qc.notice?.result == .savedToInbox, "the banner says where the voice note went")

        rig.live.areEnabled = false
        qc.publishStatus()
        #expect(statusStore.read()?.phase == .liveActivitiesOff)
        #expect(statusStore.read()?.action == .open(.settings))

        try rig.store.delete()
        qc.publishStatus()
        #expect(statusStore.read()?.phase == .notSetUp)
        #expect(statusStore.read()?.action == .open(.settings))
    }

    /// The status widget's timer follows a pause as the Live Activity's does (B41): it stands still at the audio's
    /// length while paused, and runs again from a start moved later by the pause.
    @Test func theStatusWidgetTimerStandsStillDuringAPause() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        let statusStore = VoiceNoteStatusStore(directory: CaptureFixture.temp("qc-status"))
        qc.statusStore = statusStore
        try await qc.start()
        let rec = try #require(rig.audio.lastRecording)
        let start = try #require(rec.timeline.started)
        #expect(statusStore.read()?.timerRuns == true)
        rig.clock.advance(1.5)
        rec.interrupt()
        #expect(await rig.settle { statusStore.read()?.paused != nil })
        let paused = try #require(statusStore.read())
        #expect(paused.phase == .recording && !paused.timerRuns && paused.action == .stop)
        #expect(try #require(paused.paused).timeIntervalSince(try #require(paused.started)) == 1.5)
        rig.clock.advance(0.3)   // paused: the timer must not count this
        rec.resume()
        #expect(await rig.settle { statusStore.read()?.paused == nil })
        let resumed = try #require(statusStore.read())
        #expect(resumed.timerRuns)
        #expect(abs(try #require(resumed.started).timeIntervalSince(start) - 0.3) < 1e-6, "the timer starts later by the pause")
        _ = try await qc.stop()
        #expect(statusStore.read() == VoiceNoteStatus(phase: .ready))
    }

    /// Live Activities off: iOS would end an intent's recording, so nothing starts, and the status sends the next
    /// tap to Settings. Where there are none (a Mac) the check does not apply.
    @Test func liveActivitiesOffRefusesAndShowsInTheStatus() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        qc.showsActivity = true
        rig.live.areEnabled = false
        await #expect(throws: QuickCaptureError.liveActivitiesOff) { try await qc.start() }
        #expect(qc.state == .idle)
        #expect(qc.status.phase == .liveActivitiesOff)
        rig.live.isSupported = false
        rig.live.areEnabled = true
        try await qc.start()
        #expect(qc.recentStarts.first?.first.activity == .notRequested("no Live Activities on this platform"))
        _ = try await qc.stop()
    }

    @Test func nothingStartsWithoutAProfile() async throws {
        let rig = try CaptureRig(profile: false)
        let qc = rig.capture
        await #expect(throws: QuickCaptureError.notSetUp) { try await qc.start() }
        await #expect(throws: QuickCaptureError.notRecording) { try await qc.stop() }
        #expect(qc.state == .idle, "a refused start leaves nothing claimed")
        #expect(rig.audio.recorders.isEmpty, "the microphone was not even asked for")
    }

    /// A profile the store cannot read now is not "not set up": the setup is not offered again, and a start says
    /// what is wrong.
    @Test func anUnreadableProfileIsNotNotSetUp() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        qc.store = FailingCaptureProfileStore()
        #expect(qc.isSetUp)
        #expect(qc.status.phase == .ready)
        await #expect(throws: QuickCaptureError.profileUnreadable) { try await qc.start() }
        #expect(qc.state == .idle)
        qc.store = MemoryCaptureProfileStore()
        #expect(!qc.isSetUp)
        await #expect(throws: QuickCaptureError.notSetUp) { try await qc.start() }
    }

    /// The new device list dropped this device (`suspended`): no new voice note starts, while one in progress is
    /// still sealed.
    @Test func aSuspendedProfileStartsNothingButSealsWhatRecords() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        try await qc.start()
        var stored = try rig.stored
        stored.suspended = true
        try rig.store.save(stored)
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        await #expect(throws: QuickCaptureError.notOnDeviceList) { try await qc.start() }
    }

    // MARK: - The banner

    /// A failed seal says so (and why) instead of "Saved"; the banner's notice can be dismissed.
    @Test func aStopWithoutAProfileSaysNotSaved() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        try await qc.start()
        try rig.store.delete()   // turned off while recording
        await #expect(throws: QuickCaptureError.notSetUp) { try await qc.stop() }
        #expect(qc.notice?.result == .failed)
        #expect(qc.notice?.error == "\(QuickCaptureError.notSetUp)" && qc.notice?.kept == false)
        #expect(rig.leftovers.isEmpty, "nothing can seal it: discarded")
        qc.dismissNotice()
        #expect(qc.notice == nil)
    }

    /// A stop whose profile cannot be read keeps the recording (it may well be there) and says so; the next sweep
    /// seals it.
    @Test func aStopWithAnUnreadableProfileKeepsTheRecording() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        try await qc.start()
        qc.store = FailingCaptureProfileStore()
        await #expect(throws: QuickCaptureError.profileUnreadable) { try await qc.stop() }
        #expect(qc.state == .idle)
        #expect(qc.notice?.result == .failed)
        #expect(qc.notice?.error == "\(QuickCaptureError.profileUnreadable)" && qc.notice?.kept == true)
        #expect(rig.leftovers.count == 1, "the recording is kept")
        qc.store = rig.store
        await qc.sweep()
        #expect(rig.inbox.count == 1)
        #expect(rig.leftovers.isEmpty)
    }

    /// A saved voice note's banner goes by itself after its 5 seconds, unless it was replaced meanwhile (the old
    /// timer must not clear a newer notice). The Live Activity is dismissed after the same time.
    @Test func theBannerClearsItselfAfterItsTime() async throws {
        let rig = try CaptureRig()
        let qc = rig.capture
        try await qc.start()
        _ = try await qc.stop()
        let first = try #require(qc.notice)
        #expect(first.result == .savedToInbox && first.kind == .stopped && first.error == nil)
        let shown = Duration.seconds(VoiceNoteResult.savedToInbox.shownFor)
        #expect(await rig.settle { rig.sleeper.pending(shown) == 1 })
        #expect(qc.notice == first, "still shown")
        let end = try #require(rig.live.ends.last)
        #expect(end.1 == rig.clock.now.addingTimeInterval(5) && end.0.result == .savedToInbox)
        // Replaced before its time is up: the old timer leaves the new one alone.
        try await qc.start()
        _ = try await qc.stop()
        let second = try #require(qc.notice)
        #expect(second.id != first.id)
        #expect(await rig.settle { rig.sleeper.pending(shown) == 2 })
        rig.sleeper.releaseFirst(shown)
        #expect(await rig.settle { rig.sleeper.pending(shown) == 1 })
        for _ in 0..<50 { await Task.yield() }
        #expect(qc.notice == second, "the first one's time is up, not this one's")
        rig.sleeper.releaseFirst(shown)
        #expect(await rig.settle { qc.notice == nil }, "gone after its time")
    }

    // MARK: - Sweeps

    /// A voice note interrupted by a crash is sealed from its finished segments at the next launch, its plaintext
    /// deleted, and the banner says so.
    @Test func sweepSealsWhatACrashLeftAndSaysSo() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        let id = try #require(UUID(uuidString: folder.lastPathComponent))
        await rig.capture.sweep()
        #expect(rig.inbox == [CaptureFile.name(id, .capture)])
        #expect(rig.leftovers.isEmpty)
        #expect(rig.capture.notice?.kind == .interruptedSaved && rig.capture.notice?.result == .savedToInbox)
    }

    /// A leftover that started under another vault's profile is never sealed into the stored profile's vault; one that
    /// started under this vault's is.
    @Test func sweepSealsOnlyUnderAProfileOfTheRecordingsVault() async throws {
        let rig = try CaptureRig()
        let other = try rig.crashLeftRecording(vault: UUID())
        await rig.capture.sweep()
        #expect(rig.inbox.isEmpty, "another vault's recording is not sealed here")
        #expect(rig.leftovers == [other.lastPathComponent], "and it is not deleted either")
        #expect(rig.capture.notice?.kind == .interruptedNotSaved && rig.capture.notice?.kept == true, "and it is said, once")
        let own = try rig.crashLeftRecording(vault: try rig.stored.profile.vaultId)
        let ownId = try #require(UUID(uuidString: own.lastPathComponent))
        await rig.capture.sweep()
        #expect(rig.inbox == [CaptureFile.name(ownId, .capture)])
        #expect(rig.leftovers == [other.lastPathComponent])
    }

    /// The sweep also runs each time the app becomes active, which at launch overlaps the launch's sweep: one
    /// recording is sealed by one of them only (two seals would merge into the same file at once).
    @Test func overlappingSweepsSealARecordingOnce() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        var sealing = 0
        rig.capture.willSeal = { _ in sealing += 1 }
        async let first: Void = rig.capture.sweep()
        async let second: Void = rig.capture.sweep()
        _ = await (first, second)
        #expect(sealing == 1)
        #expect(rig.inbox.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// A profile that cannot be read now (the Keychain before the first unlock after a reboot) is not "no
    /// profile": the recordings wait for a later launch instead of being deleted (bug audit B39).
    @Test func sweepKeepsRecordingsWhenTheProfileCannotBeRead() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        rig.capture.store = FailingCaptureProfileStore()
        await rig.capture.sweep()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("segment-001.aac").path))
        #expect(rig.inbox.isEmpty)
    }

    /// No profile at all: nothing can seal the recordings, so they are deleted.
    @Test func sweepDeletesRecordingsWithoutAProfile() async throws {
        let rig = try CaptureRig()
        try rig.crashLeftRecording()
        try rig.store.delete()
        await rig.capture.sweep()
        #expect(rig.leftovers.isEmpty)
    }

    /// A manifest that is there but cannot be read now (data protection) keeps its folder (B39), and nothing is
    /// sealed from it yet. (Not checkable as root, which reads anything: a Linux container.)
    @Test func sweepKeepsAFolderWhoseManifestCannotBeRead() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        let manifest = folder.appendingPathComponent(RecordingManifest.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: manifest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path) }
        guard CaptureRig.permissionsApply(manifest) else { return }
        await rig.capture.sweep()
        #expect(rig.leftovers == [folder.lastPathComponent])
        #expect(rig.inbox.isEmpty)
    }

    /// A manifest that is missing or does not decode no longer deletes the voice note with it (audit leftovers):
    /// the folder is sealed from its segment files under the id it is named by, and deleted only then.
    @Test func sweepSealsAFolderWhoseManifestIsMissingOrGarbled() async throws {
        let rig = try CaptureRig()
        let missing = try rig.crashLeftRecording(content: Data("FIRST".utf8), manifest: false)
        let garbled = try rig.crashLeftRecording(content: Data("SECOND".utf8))
        try Data("not json".utf8).write(to: garbled.appendingPathComponent(RecordingManifest.fileName))
        await rig.capture.sweep()
        let ids = try [missing, garbled].map { try #require(UUID(uuidString: $0.lastPathComponent)) }
        #expect(rig.inbox == ids.map { CaptureFile.name($0, .capture) }.sorted())
        #expect(rig.leftovers.isEmpty)
        let vault = try rig.openVault()
        #expect(try vault.readCapture(ids[0]).audio == Data("FIRST".utf8))
        #expect(try vault.readCapture(ids[1]).audio == Data("SECOND".utf8))
    }

    /// A folder with no manifest and an empty segment holds nothing: it is deleted. One that is not named by an id
    /// and holds audio is never sealed under a made-up id, and never deleted.
    @Test func sweepDeletesOnlyFoldersWithoutAudio() async throws {
        let rig = try CaptureRig()
        let root = rig.capture.root
        let empty = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("segment-001.aac"))
        let stray = root.appendingPathComponent("not-an-id", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("AUDIO".utf8).write(to: stray.appendingPathComponent("segment-001.aac"))
        await rig.capture.sweep()
        #expect(rig.leftovers == ["not-an-id"])
        #expect(rig.inbox.isEmpty)
    }

    /// A recording the sweep cannot save yet (nothing of it decodes) is kept and reported once per launch, never
    /// dropped without a word.
    @Test func aRecordingThatCannotBeSavedYetIsReportedOnce() async throws {
        let rig = try CaptureRig()
        try rig.crashLeftRecording(content: FakeAudioFiles.undecodable, manifest: false)
        await rig.capture.sweep()
        #expect(rig.leftovers.count == 1, "kept")
        let notice = try #require(rig.capture.notice)
        #expect(notice.kind == .interruptedNotSaved && notice.persists && notice.kept)
        #expect(notice.error == "\(CaptureAssemblyError.noReadableAudio)")
        rig.capture.dismissNotice()
        await rig.capture.sweep()
        #expect(rig.capture.notice == nil, "said once per launch")
    }

    // MARK: - What a seal keeps

    /// A segment begun just before the app died may be missing from the manifest: it is sealed with the others,
    /// not deleted with the folder.
    @Test func sealIncludesASegmentTheManifestDidNotName() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording(content: Data("ONE".utf8))
        try Data("TWO".utf8).write(to: folder.appendingPathComponent("segment-002.aac"))
        let id = try #require(UUID(uuidString: folder.lastPathComponent))
        await rig.capture.sweep()
        #expect(rig.inbox == [CaptureFile.name(id, .capture)])
        #expect(rig.leftovers.isEmpty)
        #expect(try rig.openVault().readCapture(id).audio == Data("ONETWO".utf8), "both segments are in the voice note")
    }

    /// A complete segment that does not decode is not skipped: sealing the rest and deleting the folder would
    /// lose it. Nothing is sealed, the recording is kept, and the outcome says so.
    @Test func sealKeepsTheRecordingWhenACompleteSegmentDoesNotDecode() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        let second = folder.appendingPathComponent("segment-002.aac")
        try FakeAudioFiles.undecodable.write(to: second)
        let outcome = await rig.capture.seal(segments: [folder.appendingPathComponent("segment-001.aac"), second], finished: 2,
                                             folder: folder, id: UUID(), started: Date(), stored: try rig.stored)
        #expect(outcome.delivery == nil && outcome.kept)
        #expect(outcome.error == "\(CaptureAssemblyError.segmentUndecodable("segment-002.aac"))")
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(rig.inbox.isEmpty)
    }

    /// The segment being written when the app died (after the manifest's `finished`) may not decode: the voice
    /// note is sealed without it (docs/attachments.md §13), and the folder is deleted once it is.
    @Test func sealLeavesOutAnUnfinishedSegmentThatDoesNotDecode() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        let second = folder.appendingPathComponent("segment-002.aac")
        try FakeAudioFiles.undecodable.write(to: second)
        let id = UUID()
        let outcome = await rig.capture.seal(segments: [folder.appendingPathComponent("segment-001.aac"), second], finished: 1,
                                             folder: folder, id: id, started: Date(), stored: try rig.stored)
        #expect(outcome.delivery == .vault)
        #expect(rig.inbox == [CaptureFile.name(id, .capture)])
        #expect(rig.leftovers.isEmpty)
    }

    /// A finished segment of no length (stopped before its first frame) holds nothing: sealed from the others.
    @Test func sealSkipsAFinishedSegmentOfNoLength() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        let second = folder.appendingPathComponent("segment-002.aac")
        try FakeAudioFiles.emptyTrack.write(to: second)
        let id = UUID()
        let outcome = await rig.capture.seal(segments: [folder.appendingPathComponent("segment-001.aac"), second], finished: 2,
                                             folder: folder, id: id, started: Date(), stored: try rig.stored)
        #expect(outcome.delivery == .vault)
        #expect(try rig.openVault().readCapture(id).audio == Data("AUDIO-FRAMES".utf8))
        #expect(rig.leftovers.isEmpty)
    }

    /// A segment that is there but cannot be read now (data protection before the first unlock) keeps the
    /// recording: nothing is sealed or deleted until it can be read (bug audit: seal deleted the folder whatever
    /// happened). Not checkable as root (a Linux container).
    @Test func sealKeepsTheRecordingWhenASegmentCannotBeRead() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        let segment = folder.appendingPathComponent("segment-001.aac")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: segment.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path) }
        guard CaptureRig.permissionsApply(segment) else { return }
        let outcome = await rig.capture.seal(segments: [segment], folder: folder, id: UUID(), started: Date(), stored: try rig.stored)
        #expect(outcome.delivery == nil && outcome.kept)
        #expect(FileManager.default.fileExists(atPath: segment.path), "the voice note is kept for the next seal")
        #expect(rig.inbox.isEmpty)
        // Readable again (after the unlock): the next sweep seals it and only then deletes it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
        await rig.capture.sweep()
        #expect(rig.inbox.count == 1)
        #expect(rig.leftovers.isEmpty)
    }

    /// A sealed capture that cannot be written anywhere (neither the vault nor the queue) keeps the recording for
    /// the next seal.
    @Test func sealKeepsTheRecordingWhenTheSealedCaptureCannotBeWritten() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording()
        let stored = try rig.stored
        rig.capture.vaultStore = nil   // no copy of the vault to deliver into
        // The queue's folder is a file: the queued write fails too.
        try FileManager.default.createDirectory(at: rig.capture.queueRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: rig.capture.queueRoot)
        let outcome = await rig.capture.seal(segments: [folder.appendingPathComponent("segment-001.aac")], folder: folder,
                                             id: UUID(), started: Date(), stored: stored)
        #expect(outcome.delivery == nil && outcome.kept && outcome.error != nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("segment-001.aac").path))
        #expect(rig.inbox.isEmpty)
    }

    /// Bytes of which nothing decodes (the app died in the first segment) are not "no audio": the voice note was
    /// not sealed into an inbox file, so it is kept and the outcome says so (audit leftovers: the folder used to be
    /// deleted).
    @Test func sealKeepsARecordingOfWhichNothingDecodes() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording(content: FakeAudioFiles.undecodable)
        let segment = folder.appendingPathComponent("segment-001.aac")
        for finished in [0, 1] {
            let outcome = await rig.capture.seal(segments: [segment], finished: finished, folder: folder, id: UUID(),
                                                 started: Date(), stored: try rig.stored)
            #expect(outcome.delivery == nil && outcome.kept)
            #expect(FileManager.default.fileExists(atPath: segment.path), "finished: \(finished)")
        }
        #expect(rig.inbox.isEmpty)
        await rig.capture.sweep()
        #expect(FileManager.default.fileExists(atPath: segment.path), "the sweep keeps it too")
    }

    /// A recording without a single byte of audio (stopped before the recorder wrote any) holds nothing to save:
    /// it is deleted, not kept forever.
    @Test func sealDeletesARecordingWithoutAByteOfAudio() async throws {
        let rig = try CaptureRig()
        let folder = try rig.crashLeftRecording(content: Data())
        let outcome = await rig.capture.seal(segments: [folder.appendingPathComponent("segment-001.aac"),
                                                        folder.appendingPathComponent("segment-002.aac")],
                                             folder: folder, id: UUID(), started: Date(), stored: try rig.stored)
        #expect(outcome.delivery == nil && !outcome.kept)
        #expect(outcome.error == "\(CaptureAssemblyError.noAudio)")
        #expect(rig.leftovers.isEmpty)
        #expect(rig.inbox.isEmpty)
    }

    @Test func resultsSayWhereTheNoteWent() {
        #expect(QuickCapture.result(for: .vault) == .savedToInbox)
        #expect(QuickCapture.result(for: .queued) == .savedOnDevice)
        #expect(QuickCapture.result(for: nil) == .failed)
    }
}
