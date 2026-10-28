import Age
import AVFoundation
import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp

/// Quick voice notes (docs/quick-capture.md): capture with only the stored
/// profile (no key, no unlock), delivery to the vault's inbox or the queue,
/// interruptions, transcripts now or later, adoption into notes.
@Suite(.serialized)
@MainActor
struct QuickCaptureTests {
    static func temp(_ name: String) -> URL {
        TestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A fixture vault copy, its key, and a quick-capture instance whose
    /// stored profile was made from it while unlocked.
    static func setUp(transcribe: Bool = true, transcriber: (any RecordingTranscribing)? = FakeTranscriber())
        throws -> (url: URL, key: URL, identity: NativeIdentity, capture: QuickCapture, center: NotificationCenter) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
        let store = MemoryCaptureProfileStore()
        try store.save(StoredCaptureProfile(profile: profile, vaultName: "sample",
                                            bookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                                            transcribe: transcribe))
        let center = NotificationCenter()
        let qc = QuickCapture()
        qc.store = store
        qc.backend = { FakeCapture() }
        qc.microphoneAllowed = { true }
        qc.transcriber = transcriber
        qc.root = temp("qc-root")
        qc.queueRoot = temp("qc-queue")
        qc.center = center
        qc.showsActivity = false
        return (url, key, identity, qc, center)
    }

    static func inbox(_ vault: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("inbox").path)) ?? []).sorted()
    }

    static func leftovers(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    /// The core promise: capture needs nothing but the profile. Nothing is
    /// unlocked here; the sealed files read back with the identity, and no
    /// plaintext audio is left on disk.
    @Test func captureWithoutUnlockingSealsAudioAndTranscriptIntoTheInbox() async throws {
        let (url, _, identity, qc, _) = try Self.setUp()
        try await qc.start()
        #expect(qc.state == .recording)
        let outcome = try await qc.stop()
        #expect(outcome.error == nil)
        #expect(outcome.delivery == .vault)
        #expect(outcome.transcribed)
        #expect(qc.state == .idle)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture), CaptureFile.name(outcome.id, .transcript)].sorted())
        #expect(Self.leftovers(qc.root).isEmpty, "no plaintext audio is kept")
        // Encrypted on disk: the recorded (ADTS) tone's bytes are not there.
        let tone = try Data(contentsOf: try TestAudio.adtsTone())
        let sealed = try Data(contentsOf: url.appendingPathComponent("inbox/\(CaptureFile.name(outcome.id, .capture))"))
        #expect(sealed.range(of: tone.prefix(256)) == nil)
        // Readable later with the key: the ADTS segment rewritten as MPEG-4 audio (`audio/mp4`).
        let vault = try Vault.open(at: url, identities: [identity])
        let pending = try vault.readCapture(outcome.id)
        let audio = try #require(pending.audio)
        #expect(audio.dropFirst(4).prefix(4) == Data("ftyp".utf8))
        #expect(pending.manifest?.audio.type == "audio/mp4")
        #expect(pending.manifest?.notebook == "Inbox")
        #expect(pending.manifest?.title.hasPrefix("Voice note ") == true)
        #expect(pending.transcript?.segments.first?.words?.map(\.t) == ["Linear", "maps."])
    }

    /// Device check c48: a voice note stopped within a second of starting (before the first segment tick, and with
    /// a recorder that wrote almost nothing) is saved, not dropped as too short.
    @Test func aVoiceNoteStoppedWithinASecondIsSaved() async throws {
        let (url, _, identity, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        let outcome = try await qc.stop()   // no time passes
        #expect(outcome.error == nil && outcome.delivery == .vault)
        #expect(qc.notice?.result == .savedToInbox)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture)])
        #expect(Self.leftovers(qc.root).isEmpty)
        let pending = try Vault.open(at: url, identities: [identity]).readCapture(outcome.id)
        #expect((pending.audio?.count ?? 0) > 0)
        // And again right after, from the other side of a pause: start, interruption, stop.
        try await qc.start()
        let session = try #require(qc.session)
        session.interruption(began: true, shouldResume: false)
        let second = try await qc.stop()
        #expect(second.error == nil)
        #expect(Self.inbox(url).count == 2)
    }

    /// A voice note started and stopped on the Lock Screen is assembled and
    /// read back from closed files before any unlock: its files must use a
    /// class that is readable while locked (after the first unlock), not
    /// `completeUnlessOpen`, under which sealing would fail and the note be
    /// lost. In-note recordings keep `completeUnlessOpen`. (The simulator has
    /// no Data Protection, so the class itself is what is checked.)
    @Test func voiceNotesAreRecordedInAClassReadableWhileLocked() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        let session = try #require(qc.session)
        #expect(session.protection == .completeUntilFirstUserAuthentication)
        _ = try await qc.stop()
        let inNote = RecordingSession(noteID: UUID(), format: .default, root: Self.temp("rec"), backend: FakeCapture())
        #expect(inNote.protection == .completeUnlessOpen)
        #expect(RecordingSession.writingOption(.completeUntilFirstUserAuthentication) == .completeFileProtectionUntilFirstUserAuthentication)
        #expect(RecordingSession.writingOption(.completeUnlessOpen) == .completeFileProtectionUnlessOpen)
    }

    /// A call during a voice note pauses it; it resumes and is sealed whole.
    @Test func interruptionDuringAVoiceNote() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        let session = try #require(qc.session)
        // The iOS 27 deactivation and resumption messages cannot be built in a
        // test (their contexts are made by the system): drive the session directly.
        session.interruption(began: true, shouldResume: false)
        #expect(session.state == .interrupted)
        session.interruption(began: false, shouldResume: true)
        #expect(session.state == .recording)
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture)])
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Bug audit B41: the Live Activity shows a pause (its timer stands still)
    /// and the resumption, and its last state gives the length of the audio,
    /// not the time since the start.
    @Test func theLiveActivityShowsAPause() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        var states: [VoiceNoteAttributes.ContentState] = []
        qc.activityStates = { states.append($0) }
        try await qc.start()
        let session = try #require(qc.session)
        session.interruption(began: true, shouldResume: false)
        #expect(qc.isPaused)
        #expect(await TS.waitUntil { states.contains { $0.paused } })
        let paused = try #require(states.last)
        #expect(paused.paused && paused.isRecording && !paused.timerRuns)
        let length = try #require(paused.ended).timeIntervalSince(paused.started)
        #expect(abs(length - session.timeline.audioLength(at: Date())) < 0.5)
        try await Task.sleep(for: .milliseconds(300))   // paused: no audio, and the timer must not count it
        session.interruption(began: false, shouldResume: true)
        #expect(await TS.waitUntil { states.count >= 2 && states.last?.paused == false })
        let resumed = try #require(states.last)
        #expect(resumed.timerRuns)
        let start = try #require(session.timeline.started)
        #expect(resumed.started.timeIntervalSince(start) >= 0.3, "the timer starts later by the pause")
        _ = try await qc.stop()
        let last = try #require(states.last)
        let ended = try #require(last.ended)
        let shown = ended.timeIntervalSince(last.started)
        #expect(abs(shown - session.timeline.audioLength(at: Date())) < 0.05)
        #expect(shown < ended.timeIntervalSince(start) - 0.25)
    }
    #endif

    /// When the vault folder cannot be reached the sealed capture waits in a
    /// local queue (encrypted) and moves into the vault later.
    @Test func unreachableVaultQueuesTheCapture() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        // The bookmark now names a folder that is not the vault (gone, renamed, another vault).
        let other = Self.temp("not-the-vault")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var stored = try #require(try qc.store.load())
        stored.bookmark = try other.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try qc.store.save(stored)
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .queued)
        #expect(qc.notice?.result == .savedOnDevice, "the banner says the note is on this device, not in the vault yet")
        let vaultID = stored.profile.vaultId
        #expect(Self.leftovers(qc.queueFolder(vaultID)).sorted()
                == [CaptureFile.name(outcome.id, .capture), CaptureFile.name(outcome.id, .capture) + ".epoch"])
        #expect(Self.inbox(url).isEmpty)
        #expect(qc.flushQueue(into: url, vaultId: vaultID, coordinated: false) == 1)
        #expect(Self.inbox(url) == [CaptureFile.name(outcome.id, .capture)])
        #expect(Self.leftovers(qc.queueFolder(vaultID)).isEmpty)
    }

    /// Security review 2026-10 (N2): a vault whose `vault.json` names a newer
    /// format is read-only for this version (format.md §7.3), so a voice note
    /// for it waits in the local queue, and the queue is not flushed into it.
    @Test func aReadOnlyVaultGetsNoCaptures() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let manifest = url.appendingPathComponent("vault.json")
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        obj["format"] = "sempere/9"
        try JSONSerialization.data(withJSONObject: obj).write(to: manifest)
        let vaultID = try #require(try qc.store.load()).profile.vaultId
        #expect(!QuickCapture.acceptsCaptures(at: url, vaultId: vaultID))

        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .queued)
        #expect(Self.inbox(url).isEmpty, "nothing written into the read-only vault")
        #expect(qc.flushQueue(into: url, vaultId: vaultID, coordinated: false) == 0)
        #expect(Self.inbox(url).isEmpty)
        #expect(Self.leftovers(qc.queueFolder(vaultID)).filter { CaptureFile.parse(name: $0) != nil } == [CaptureFile.name(outcome.id, .capture)])
    }

    /// The widget and Control Center fired together: the second start used to
    /// pass the idle check during the first one's microphone prompt and start
    /// a second recording that nothing could stop.
    @Test func aSecondStartDuringTheFirstIsRefused() async throws {
        let (_, _, _, qc, _) = try Self.setUp()
        let gate = AsyncStream<Void>.makeStream()
        qc.microphoneAllowed = {
            for await _ in gate.stream { break }
            return true
        }
        let first = Task { try await qc.start() }
        #expect(await TS.waitUntil { qc.state == .starting })
        await #expect(throws: QuickCaptureError.alreadyRecording) { try await qc.start() }
        gate.continuation.yield()
        try await first.value
        #expect(qc.state == .recording)
        _ = try await qc.stop()
        #expect(qc.state == .idle)
    }

    /// The widgets and the control read what `publishStatus` writes into the
    /// App Group: set up or not, ready, recording (with its start), and back.
    /// Widgets are reloaded only when the status changed.
    @Test func statusFollowsSetupAndTheRecorder() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let statusStore = VoiceNoteStatusStore(directory: Self.temp("qc-status"))
        let reloads = ReloadCounter()
        qc.statusStore = statusStore
        qc.activitiesEnabled = { true }
        qc.reloadSurfaces = { reloads.count += 1 }

        qc.publishStatus()
        #expect(statusStore.read() == VoiceNoteStatus(phase: .ready))
        #expect(reloads.count == 1)
        qc.publishStatus()
        #expect(reloads.count == 1, "an unchanged status reloads nothing")

        try await qc.start()
        let recording = try #require(statusStore.read())
        #expect(recording.phase == .recording)
        #expect(recording.started == qc.started)
        #expect(recording.action == .stop)

        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        #expect(statusStore.read() == VoiceNoteStatus(phase: .ready))
        #expect(qc.notice?.result == .savedToInbox, "the banner says where the voice note went")
        #expect(Self.inbox(url).count == 1)

        qc.activitiesEnabled = { false }
        qc.publishStatus()
        #expect(statusStore.read()?.phase == .liveActivitiesOff)
        #expect(statusStore.read()?.action == .open(.settings))

        try qc.store.delete()
        qc.publishStatus()
        #expect(statusStore.read()?.phase == .notSetUp)
        #expect(statusStore.read()?.action == .open(.settings))
    }

    /// The widgets are reloaded when the status changes, and also, unchanged, each time the
    /// app launches or becomes active: a widget can show an older status than the file.
    @Test func widgetsReloadOnChangeAndOnEveryActivation() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        let reloads = ReloadCounter()
        qc.statusStore = VoiceNoteStatusStore(directory: Self.temp("qc-status"))
        qc.activitiesEnabled = { true }
        qc.reloadSurfaces = { reloads.count += 1 }
        qc.publishStatus()
        #expect(reloads.count == 1)
        qc.publishStatus()
        #expect(reloads.count == 1)
        qc.publishStatus(forceReload: true)
        #expect(reloads.count == 2, "activation reloads although the file is the same")
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = qc
        await model.quickCaptureBecameActive().value
        #expect(reloads.count == 3)
        // Turning quick voice notes off and on changes the status: reloaded each time.
        try qc.store.delete()
        qc.publishStatus()
        #expect(reloads.count == 4)
        #expect(VoiceNoteStatus.refreshInterval > 0 && VoiceNoteStatus.refreshInterval <= 3600)
    }

    /// The status widget's timer follows a pause as the Live Activity's does
    /// (B41): it stands still at the audio's length while paused, and runs
    /// again from a start moved later by the pause.
    @Test func theStatusWidgetTimerStandsStillDuringAPause() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        let statusStore = VoiceNoteStatusStore(directory: Self.temp("qc-status"))
        qc.statusStore = statusStore
        qc.activitiesEnabled = { true }
        qc.reloadSurfaces = {}
        try await qc.start()
        let session = try #require(qc.session)
        let start = try #require(session.timeline.started)
        #expect(statusStore.read()?.timerRuns == true)
        session.interruption(began: true, shouldResume: false)
        #expect(await TS.waitUntil { statusStore.read()?.paused != nil })
        let paused = try #require(statusStore.read())
        #expect(paused.phase == .recording && !paused.timerRuns && paused.action == .stop)
        let shown = try #require(paused.paused).timeIntervalSince(try #require(paused.started))
        #expect(abs(shown - session.timeline.audioLength(at: Date())) < 0.05)
        try await Task.sleep(for: .milliseconds(300))   // paused: the timer must not count this
        session.interruption(began: false, shouldResume: true)
        #expect(await TS.waitUntil { statusStore.read()?.paused == nil })
        let resumed = try #require(statusStore.read())
        #expect(resumed.timerRuns)
        #expect(try #require(resumed.started).timeIntervalSince(start) >= 0.3, "the timer starts later by the pause")
        _ = try await qc.stop()
        #expect(statusStore.read() == VoiceNoteStatus(phase: .ready))
    }

    /// Live Activities off: iOS would end an intent's recording, so nothing
    /// starts, and the status sends the next tap to Settings.
    @Test func liveActivitiesOffRefusesAndShowsInTheStatus() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        let statusStore = VoiceNoteStatusStore(directory: Self.temp("qc-status"))
        qc.statusStore = statusStore
        qc.reloadSurfaces = {}
        qc.activitiesEnabled = { false }
        qc.showsActivity = true   // off in the other tests, which skips the check
        #if os(iOS) && !targetEnvironment(macCatalyst)
        await #expect(throws: QuickCaptureError.liveActivitiesOff) { try await qc.start() }
        #endif
        #expect(qc.state == .idle)
        qc.publishStatus()
        #expect(statusStore.read()?.phase == .liveActivitiesOff)
    }

    /// A failed seal says so (and why) instead of "Saved".
    @Test func aStopWithoutAProfileSaysNotSaved() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        try qc.store.delete()   // turned off while recording
        await #expect(throws: QuickCaptureError.notSetUp) { try await qc.stop() }
        #expect(qc.notice?.result == .failed)
        #expect(qc.notice?.error == QuickCaptureError.notSetUp.description)
        qc.dismissNotice()
        #expect(qc.notice == nil)
    }

    @Test func nothingStartsWithoutAProfile() async throws {
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        qc.showsActivity = false
        await #expect(throws: QuickCaptureError.notSetUp) { try await qc.start() }
        await #expect(throws: QuickCaptureError.notRecording) { try await qc.stop() }
        #expect(qc.state == .idle, "a refused start leaves nothing claimed")
    }

    /// A profile the store cannot read now is not "not set up": the setup is
    /// not offered again, and a start says what is wrong.
    @Test func anUnreadableProfileIsNotNotSetUp() async throws {
        let qc = QuickCapture()
        qc.store = FailingCaptureProfileStore()
        qc.showsActivity = false
        qc.activitiesEnabled = { true }
        #expect(qc.isSetUp)
        #expect(qc.status.phase == .ready)
        await #expect(throws: QuickCaptureError.profileUnreadable) { try await qc.start() }
        #expect(qc.state == .idle)
        #expect(QuickCaptureError.profileUnreadable.description != QuickCaptureError.notSetUp.description)
        qc.store = MemoryCaptureProfileStore()
        #expect(!qc.isSetUp)
        await #expect(throws: QuickCaptureError.notSetUp) { try await qc.start() }
    }

    /// A stop whose profile cannot be read keeps the recording (it may well
    /// be there) and says so; the next sweep seals it.
    @Test func aStopWithAnUnreadableProfileKeepsTheRecording() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let store = qc.store
        try await qc.start()
        qc.store = FailingCaptureProfileStore()
        await #expect(throws: QuickCaptureError.profileUnreadable) { try await qc.stop() }
        #expect(qc.state == .idle)
        #expect(qc.notice?.result == .failed)
        #expect(qc.notice?.error?.hasPrefix(QuickCaptureError.profileUnreadable.description) == true)
        #expect(Self.leftovers(qc.root).count == 1, "the recording is kept")
        qc.store = store
        await qc.sweep()
        #expect(Self.inbox(url).count == 1)
        #expect(Self.leftovers(qc.root).isEmpty)
    }

    /// The model tells "no profile" from "a profile it cannot read now", as
    /// `QuickCapture` does: Settings must not show Quick Voice Notes as off
    /// while it is on (bug audit follow-up: `quickCaptureProfile` made every
    /// read error nil).
    @Test func theModelSaysWhenTheProfileCannotBeRead() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = qc
        #expect(try model.storedQuickCaptureProfile() != nil)
        qc.store = FailingCaptureProfileStore()
        #expect(throws: QuickCaptureError.profileUnreadable) { try model.storedQuickCaptureProfile() }
        qc.store = MemoryCaptureProfileStore()
        #expect(try model.storedQuickCaptureProfile() == nil)
    }

    /// Settings' three states: off, on, and "cannot be read", which is shown
    /// as on (it is there, as far as anyone knows) and never as off; what
    /// only refreshes or syncs the profile leaves an unreadable one alone.
    @Test func settingsTellsOffFromUnreadable() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = qc
        let stored = try #require(try qc.store.load())
        #expect(model.quickCaptureSetting == .on(stored))
        #expect(!model.quickCaptureSwitchIsOn, "on, but for a vault that is not open")
        let store = qc.store
        qc.store = FailingCaptureProfileStore()
        #expect(model.quickCaptureSetting == .unreadable)
        #expect(model.quickCaptureSwitchIsOn)
        #expect(!model.quickCaptureIsForOpenVault)
        model.refreshQuickCaptureProfile()
        qc.store = store
        #expect(try qc.store.load() == stored)
        try qc.store.delete()
        #expect(model.quickCaptureSetting == .off)
        #expect(!model.quickCaptureSwitchIsOn)
    }

    /// Becoming active sweeps (audit leftovers, quick capture: the sweep ran
    /// only at launch): a recording the launch could not seal, its profile
    /// unreadable then, is sealed once the app is active with the profile
    /// readable, and the queue is moved into the vault.
    @Test func becomingActiveSealsWhatTheLaunchCouldNot() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        let store = qc.store
        qc.store = FailingCaptureProfileStore()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = qc
        await qc.sweep()   // the launch's
        await model.quickCaptureBecameActive().value
        #expect(FileManager.default.fileExists(atPath: folder.path), "still unreadable: kept")
        qc.store = store
        // A voice note queued while the vault folder was out of reach.
        let writer = try CaptureWriter(profile: try #require(try store.load()).profile)
        let queuedID = UUID()
        try CaptureWriter.store(try writer.seal(audio: try Data(contentsOf: RecordingTests.tone), started: Date(), id: queuedID),
                                in: qc.queueFolder(try #require(try store.load()).profile.vaultId))
        await model.quickCaptureBecameActive().value
        let id = try #require(UUID(uuidString: folder.lastPathComponent))
        #expect(Self.inbox(url) == [CaptureFile.name(id, .capture), CaptureFile.name(queuedID, .capture)].sorted())
        #expect(Self.leftovers(qc.root).isEmpty)
    }

    /// Moving the queue when the app becomes active says when the profile
    /// cannot be read, instead of doing nothing silently.
    @Test func flushingTheStoredQueueSaysWhenTheProfileCannotBeRead() throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        qc.store = FailingCaptureProfileStore()
        #expect(throws: QuickCaptureError.profileUnreadable) { try qc.flushStoredQueue() }
        qc.store = MemoryCaptureProfileStore()
        #expect(try qc.flushStoredQueue() == 0, "no profile: nothing to move, and nothing wrong")
    }

    /// The sweep also runs each time the app becomes active, which at launch
    /// overlaps the launch's sweep: one recording is sealed by one of them
    /// only (two seals would merge into the same file at once).
    @Test func overlappingSweepsSealARecordingOnce() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        var sealing = 0
        qc.willSeal = { _ in sealing += 1 }
        async let first: Void = qc.sweep()
        async let second: Void = qc.sweep()
        _ = await (first, second)
        #expect(sealing == 1)
        #expect(Self.inbox(url).count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// The model adopts the inbox once the vault is unlocked; a voice note
    /// captured without a transcript is transcribed then (task: "transcript
    /// added later").
    @Test func unlockingAdoptsVoiceNotesAndTranscribesThoseWithout() async throws {
        let (url, key, _, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        let outcome = try await qc.stop()
        var stored = try #require(try qc.store.load())
        stored.transcribe = true   // transcribe on this device from now on
        try qc.store.save(stored)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = Self.temp("blobs")
        model.transcriber = FakeTranscriber()
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.inboxAdoption == nil && model.capturesAdopted == 1 })
        let ids = CaptureAdoption.ids(for: outcome.id)
        let vault = try #require(model.vault)
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            (try? vault.reconstruct(noteId: ids.note))?.recordings.first?.transcript != nil
        })
        let state = try vault.reconstruct(noteId: ids.note)
        #expect(state.meta.notebook == "Inbox")
        #expect(state.meta.title.hasPrefix("Voice note "))
        #expect(state.recordings.map(\.id) == [ids.recording])
        #expect(Self.inbox(url).isEmpty, "adopted captures leave the inbox")
        #expect(model.notes.contains { $0.id == ids.note })
        #expect(model.inboxProblem == nil)
    }

    /// TestFlight build 10: a voice note recorded or synced while the vault is open appeared only after the
    /// vault was closed and opened again. A delivery into the open vault's inbox (or a sync run that
    /// reports inbox files) adopts it at once, also while an earlier adoption is still running.
    @Test func aCaptureDeliveredToTheOpenVaultIsAdoptedLive() async throws {
        let (url, key, _, qc, _) = try Self.setUp(transcribe: false)
        let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = Self.temp("blobs")
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.inboxAdoption == nil })
        let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        let tone = try Data(contentsOf: RecordingTests.tone)
        let vaultId = try #require(model.vault).vaultId

        // Recorded here: the delivery notification is all that tells the model.
        let local = UUID()
        try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: local), in: inbox)
        NotificationCenter.default.post(name: QuickCapture.deliveredNotification, object: nil, userInfo: ["vault": vaultId])
        let localNote = CaptureAdoption.ids(for: local).note
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.notes.contains { $0.id == localNote } })

        // Arrived by sync, while a run is going: the trigger is kept and looked at again.
        let synced = UUID()
        try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: synced), in: inbox)
        var changes = LocalChanges()
        changes.inbox = true
        model.startInboxAdoption()
        model.applySyncChanges(changes)
        let syncedNote = CaptureAdoption.ids(for: synced).note
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.notes.contains { $0.id == syncedNote } })
        #expect(model.inboxProblem == nil)
    }

    /// iCloud Drive uploads files in any order, so a voice note's transcript
    /// can reach a device before its capture. The transcript waits and nothing
    /// is written: a transcript blob alone would make a note folder without
    /// revisions, which `requireLocal` refuses in iCloud Drive, so the capture
    /// could never be adopted there. Once the capture arrives, both are.
    @Test func aTranscriptBeforeItsCaptureWritesNothingUntilTheCaptureArrives() async throws {
        let (url, key, _, qc, _) = try Self.setUp(transcribe: false)
        let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
        let id = UUID()
        let ids = CaptureAdoption.ids(for: id)
        let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        let transcript = Transcript(recording: ids.recording, engine: "test", language: "en", created: Date(),
                                    segments: [.init(start: 0, end: 1, text: "Linear maps.")])
        let tone = try Data(contentsOf: RecordingTests.tone)
        try CaptureWriter.store(try writer.seal(transcript: transcript, capture: id, audio: BlobRef(content: tone, type: "audio/mp4")),
                                in: inbox)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = Self.temp("blobs")
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.inboxAdoption == nil })
        let folder = url.appendingPathComponent("notes/\(ids.note.uuidString.lowercased())")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing is written while the transcript waits")
        #expect(Self.inbox(url) == [CaptureFile.name(id, .transcript)])
        #expect(model.inboxProblem == nil)

        try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: id), in: inbox)
        #expect(await model.adoptInbox() == 1)
        let state = try #require(model.vault).reconstruct(noteId: ids.note)
        #expect(state.recordings.map(\.id) == [ids.recording])
        #expect(state.recordings.first?.transcript != nil)
        #expect(Self.inbox(url).isEmpty)
        #expect(model.inboxProblem == nil)
    }

    @Test func enablingStoresAProfileWithoutTheIdentityAndRefreshFollowsKeyChanges() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        qc.showsActivity = false
        model.quickCapture = qc
        try await model.openVault(at: url)
        let keyText = try String(contentsOf: key, encoding: .utf8)
        try await model.unlock(identityText: keyText)
        try model.enableQuickCapture(notebook: "Voice/Inbox", transcribe: true)
        let stored = try #require(try qc.store.load())
        #expect(model.quickCaptureIsForOpenVault)
        #expect(stored.profile.notebook == "Voice/Inbox")
        let fresh = try #require(model.vault).captureProfile(device: try #require(DeviceID(stored.profile.device)))
        #expect(stored.profile.recipients == fresh.recipients, "sealed to the vault identity alone")
        #expect(stored.profile.recipients.count == 1)
        let data = try JSONEncoder().encode(stored)
        #expect(String(decoding: data, as: UTF8.self).contains("AGE-SECRET-KEY") == false, "never the identity")
        // A stale key in the profile is replaced on the next unlock.
        var old = stored
        old.profile.key = Data(repeating: 0, count: 32)
        try qc.store.save(old)
        model.refreshQuickCaptureProfile()
        #expect(try qc.store.load()?.profile.key == stored.profile.key)
        // Attributed to the key this device unlocked with (format.md §11.1, security review C2).
        let unlockedWith = try IdentityFile.parse(keyText)
        #expect(stored.profile.recipient == CaptureKey.fingerprint(of: unlockedWith.recipient.string))
        try model.disableQuickCapture()
        #expect(try qc.store.load() == nil)
    }

    /// A voice note interrupted by a crash is sealed from its finished
    /// segments at the next launch, and its plaintext deleted.
    @Test func sweepSealsWhatACrashLeft() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let id = UUID()
        let folder = qc.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: RecordingTests.tone, to: folder.appendingPathComponent("segment-001.m4a"))
        let manifest = RecordingManifest(note: UUID(), recording: id, started: Date(), codec: "aac",
                                         segments: ["segment-001.m4a"], finished: 1)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))
        await qc.sweep()
        #expect(Self.inbox(url) == [CaptureFile.name(id, .capture)])
        #expect(Self.leftovers(qc.root).isEmpty)
    }

    /// A crash-left recording folder with a finished segment and its manifest.
    static func crashLeftRecording(in root: URL) throws -> URL {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: RecordingTests.tone, to: folder.appendingPathComponent("segment-001.m4a"))
        let manifest = RecordingManifest(note: UUID(), recording: id, started: Date(), codec: "aac",
                                         segments: ["segment-001.m4a"], finished: 1)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))
        return folder
    }

    /// A profile that cannot be read now (the Keychain before the first unlock
    /// after a reboot) is not "no profile": the recordings wait for a later
    /// launch instead of being deleted (bug audit B39).
    @Test func sweepKeepsRecordingsWhenTheProfileCannotBeRead() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        qc.store = FailingCaptureProfileStore()
        await qc.sweep()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("segment-001.m4a").path))
        #expect(Self.inbox(url).isEmpty)
    }

    /// A manifest that is there but cannot be read now (data protection) keeps
    /// its folder (B39), and nothing is sealed from it yet.
    @Test func sweepKeepsAFolderWhoseManifestCannotBeRead() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let unreadable = try Self.crashLeftRecording(in: qc.root)
        let manifest = unreadable.appendingPathComponent(RecordingRecovery.manifestName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: manifest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path) }
        await qc.sweep()
        #expect(Self.leftovers(qc.root) == [unreadable.lastPathComponent])
        #expect(Self.inbox(url).isEmpty)
    }

    /// A manifest that is missing or does not decode no longer deletes the
    /// voice note with it (audit leftovers, quick capture): the folder is
    /// sealed from its segment files under the id it is named by, and deleted
    /// only then.
    @Test func sweepSealsAFolderWhoseManifestIsMissingOrGarbled() async throws {
        let (url, _, identity, qc, _) = try Self.setUp(transcribe: false)
        let missing = try Self.crashLeftRecording(in: qc.root)
        try FileManager.default.removeItem(at: missing.appendingPathComponent(RecordingRecovery.manifestName))
        let garbled = try Self.crashLeftRecording(in: qc.root)
        try Data("not json".utf8).write(to: garbled.appendingPathComponent(RecordingRecovery.manifestName))
        await qc.sweep()
        let ids = try [missing, garbled].map { try #require(UUID(uuidString: $0.lastPathComponent)) }
        #expect(Self.inbox(url) == ids.map { CaptureFile.name($0, .capture) }.sorted())
        #expect(Self.leftovers(qc.root).isEmpty)
        let vault = try Vault.open(at: url, identities: [identity])
        let tone = try Data(contentsOf: RecordingTests.tone)
        for id in ids { #expect(try vault.readCapture(id).audio == tone) }
    }

    /// A folder with no manifest and no segment holds nothing: it is deleted.
    /// One that is not named by an id and holds audio is never sealed under a
    /// made-up id, and never deleted.
    @Test func sweepDeletesOnlyFoldersWithoutAudio() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let empty = qc.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("segment-001.m4a"))
        let stray = qc.root.appendingPathComponent("not-an-id", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: RecordingTests.tone, to: stray.appendingPathComponent("segment-001.m4a"))
        await qc.sweep()
        #expect(Self.leftovers(qc.root) == ["not-an-id"])
        #expect(Self.inbox(url).isEmpty)
    }

    /// Segment names come from the session's pattern only, in numeric order;
    /// a manifest can never name a file outside its folder.
    @Test func segmentFilesAreTheSessionsOwnInOrder() throws {
        #expect(QuickCapture.segmentNumber("segment-007.m4a") == 7)
        #expect(QuickCapture.segmentNumber("segment-1000.m4a") == 1000)
        for name in ["capture.m4a", "manifest.json", "segment-.m4a", "segment-1a.m4a", "segment-+1.m4a", "segment-001.caf",
                     "../segment-001.m4a"] {
            #expect(QuickCapture.segmentNumber(name) == nil, "\(name)")
        }
        let folder = Self.temp("segments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["segment-1000.m4a", "segment-999.m4a", "segment-001.m4a", "capture.m4a", "manifest.json"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        let listed = [folder.appendingPathComponent("segment-001.m4a")]
        #expect(QuickCapture.segmentFiles(listed: listed, in: folder).map(\.lastPathComponent)
                == ["segment-001.m4a", "segment-999.m4a", "segment-1000.m4a"])
        let manifest = RecordingManifest(note: UUID(), recording: UUID(), started: nil, codec: "aac",
                                         segments: ["../../escape.m4a", "segment-001.m4a"], finished: 5)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))
        let leftover = try #require(QuickCapture.Leftover(folder: folder))
        #expect(leftover.id == manifest.recording)
        #expect(leftover.segments.map(\.lastPathComponent) == ["segment-001.m4a", "segment-999.m4a", "segment-1000.m4a"])
        #expect(leftover.finished == 1, "never more than the manifest lists")
    }

    /// A segment begun just before the app died may be missing from the
    /// manifest: it is sealed with the others, not deleted with the folder.
    @Test func sealIncludesASegmentTheManifestDidNotName() async throws {
        let (url, _, identity, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        try FileManager.default.copyItem(at: RecordingTests.tone, to: folder.appendingPathComponent("segment-002.m4a"))
        let id = try #require(UUID(uuidString: folder.lastPathComponent))
        await qc.sweep()
        #expect(Self.inbox(url) == [CaptureFile.name(id, .capture)])
        #expect(Self.leftovers(qc.root).isEmpty)
        let vault = try Vault.open(at: url, identities: [identity])
        let tone = try Data(contentsOf: RecordingTests.tone)
        let audio = try #require(try vault.readCapture(id).audio)
        #expect(audio.count > tone.count * 3 / 2, "both segments are in the voice note")
    }

    /// A complete segment that does not decode is not skipped: sealing the
    /// rest and deleting the folder would lose it. Nothing is sealed, the
    /// recording is kept, and the error says so.
    @Test func sealKeepsTheRecordingWhenACompleteSegmentDoesNotDecode() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        let second = folder.appendingPathComponent("segment-002.m4a")
        try Data("not audio".utf8).write(to: second)
        let segments = [folder.appendingPathComponent("segment-001.m4a"), second]
        let stored = try #require(try qc.store.load())
        let outcome = await qc.seal(segments: segments, finished: 2, folder: folder, id: UUID(), started: Date(), stored: stored)
        #expect(outcome.delivery == nil)
        #expect(outcome.error?.contains(QuickCapture.keptOnDevice) == true)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(Self.inbox(url).isEmpty)
    }

    /// The segment being written when the app died (after the manifest's
    /// `finished`) may not decode: the voice note is sealed without it
    /// (docs/attachments.md §13), and the folder is deleted once it is.
    @Test func sealLeavesOutAnUnfinishedSegmentThatDoesNotDecode() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        let second = folder.appendingPathComponent("segment-002.m4a")
        try Data("unfinished".utf8).write(to: second)
        let segments = [folder.appendingPathComponent("segment-001.m4a"), second]
        let stored = try #require(try qc.store.load())
        let id = UUID()
        let outcome = await qc.seal(segments: segments, finished: 1, folder: folder, id: id, started: Date(), stored: stored)
        #expect(outcome.delivery == .vault)
        #expect(Self.inbox(url) == [CaptureFile.name(id, .capture)])
        #expect(Self.leftovers(qc.root).isEmpty)
    }

    /// A segment that is there but cannot be read now (data protection before
    /// the first unlock) keeps the recording: nothing is sealed or deleted
    /// until it can be read, and the failure says the voice note was kept
    /// (bug audit: seal deleted the folder whatever happened).
    @Test func sealKeepsTheRecordingWhenASegmentCannotBeRead() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        let segment = folder.appendingPathComponent("segment-001.m4a")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: segment.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path) }
        let stored = try #require(try qc.store.load())
        let outcome = await qc.seal(segments: [segment], folder: folder, id: UUID(), started: Date(), stored: stored)
        #expect(outcome.delivery == nil)
        #expect(outcome.error?.contains(QuickCapture.keptOnDevice) == true)
        #expect(FileManager.default.fileExists(atPath: segment.path), "the voice note is kept for the next seal")
        #expect(Self.inbox(url).isEmpty)
        // Readable again (after the unlock): the next sweep seals it and only then deletes it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
        await qc.sweep()
        #expect(Self.inbox(url).count == 1)
        #expect(Self.leftovers(qc.root).isEmpty)
    }

    /// A sealed capture that cannot be written anywhere (neither the vault
    /// nor the queue) keeps the recording for the next seal.
    @Test func sealKeepsTheRecordingWhenTheSealedCaptureCannotBeWritten() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        var stored = try #require(try qc.store.load())
        let other = Self.temp("not-the-vault")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        stored.bookmark = try other.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        // The queue's folder is a file: the queued write fails too.
        try Data("not a folder".utf8).write(to: qc.queueRoot)
        let outcome = await qc.seal(segments: [folder.appendingPathComponent("segment-001.m4a")], folder: folder,
                                    id: UUID(), started: Date(), stored: stored)
        #expect(outcome.delivery == nil)
        #expect(outcome.error?.contains(QuickCapture.keptOnDevice) == true)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("segment-001.m4a").path))
        #expect(Self.inbox(url).isEmpty)
    }

    /// Bytes of which nothing decodes (the app died in the first segment) are
    /// not "no audio": the voice note was not sealed into an inbox file, so it
    /// is kept and the error says so (audit leftovers, quick capture: the
    /// folder used to be deleted).
    @Test func sealKeepsARecordingOfWhichNothingDecodes() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        let segment = folder.appendingPathComponent("segment-001.m4a")
        try Data("not audio".utf8).write(to: segment)
        let stored = try #require(try qc.store.load())
        for finished in [0, 1] {
            let outcome = await qc.seal(segments: [segment], finished: finished, folder: folder, id: UUID(), started: Date(), stored: stored)
            #expect(outcome.delivery == nil)
            #expect(outcome.error?.contains(QuickCapture.keptOnDevice) == true)
            #expect(FileManager.default.fileExists(atPath: segment.path), "finished: \(finished)")
        }
        #expect(Self.inbox(url).isEmpty)
        await qc.sweep()
        #expect(FileManager.default.fileExists(atPath: segment.path), "the sweep keeps it too")
    }

    /// A recording without a single byte of audio (stopped before the recorder
    /// wrote any) holds nothing to save: it is deleted, not kept forever.
    @Test func sealDeletesARecordingWithoutAByteOfAudio() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        let segment = folder.appendingPathComponent("segment-001.m4a")
        try Data().write(to: segment)
        let stored = try #require(try qc.store.load())
        let outcome = await qc.seal(segments: [segment, folder.appendingPathComponent("segment-002.m4a")], folder: folder,
                                    id: UUID(), started: Date(), stored: stored)
        #expect(outcome.delivery == nil)
        #expect(outcome.error?.contains(QuickCapture.keptOnDevice) == false)
        #expect(Self.leftovers(qc.root).isEmpty)
        #expect(Self.inbox(url).isEmpty)
    }

    /// A finished segment of no length (stopped just after a new segment
    /// began, before its first frame) holds nothing: the voice note is sealed
    /// from the other segments. It used to count as "a complete segment that
    /// does not decode", which kept the whole voice note unsealed for good.
    /// Bytes AVFoundation cannot read at all still count as undecodable.
    @Test func sealSkipsAFinishedSegmentOfNoLength() async throws {
        let (url, _, identity, qc, _) = try Self.setUp(transcribe: false)
        let folder = try Self.crashLeftRecording(in: qc.root)
        let second = folder.appendingPathComponent("segment-002.m4a")
        let file = try AVAudioFile(forWriting: second, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                  AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        file.close()
        #expect(QuickCapture.byteCount(second) > 0, "a finished file, not an empty one")
        #expect(await QuickCapture.segmentAudio(second) == .none)
        #expect(await QuickCapture.segmentAudio(RecordingTests.tone) == .audio)
        let garbage = Self.temp("garbage").appendingPathExtension("m4a")
        try Data("not audio".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        #expect(await QuickCapture.segmentAudio(garbage) == .undecodable)
        let segments = [folder.appendingPathComponent("segment-001.m4a"), second]
        let stored = try #require(try qc.store.load())
        let id = UUID()
        let outcome = await qc.seal(segments: segments, finished: 2, folder: folder, id: id, started: Date(), stored: stored)
        #expect(outcome.delivery == .vault)
        #expect(Self.inbox(url) == [CaptureFile.name(id, .capture)])
        #expect(Self.leftovers(qc.root).isEmpty)
        let vault = try Vault.open(at: url, identities: [identity])
        #expect(try vault.readCapture(id).audio == (try Data(contentsOf: RecordingTests.tone)))
    }

    /// No profile at all: nothing can seal the recordings, so they are deleted.
    @Test func sweepDeletesRecordingsWithoutAProfile() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        _ = try Self.crashLeftRecording(in: qc.root)
        qc.store = MemoryCaptureProfileStore()
        await qc.sweep()
        #expect(Self.leftovers(qc.root).isEmpty)
    }

    /// A queued voice note is recorded under the epoch of the profile that SEALED it, not the profile current when
    /// the queue is flushed (review M4: else it would be set aside for good).
    @Test func aQueuedVoiceNoteKeepsTheEpochItWasSealedUnder() async throws {
        let (url, _, _, qc, _) = try Self.setUp(transcribe: false)
        let stores = DeviceWriteStores.inMemoryKey(root: try TestTemp.directory("ledger-queue"))
        qc.writeStores = stores
        let other = Self.temp("not-the-vault-2")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var stored = try #require(try qc.store.load())
        let sealedEpoch = try #require(stored.profile.epoch)
        stored.bookmark = try other.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try qc.store.save(stored)
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .queued)
        // The profile is refreshed to a later epoch before the queue is flushed.
        stored.profile.epoch = sealedEpoch + 1
        stored.profile.epochId = String(repeating: "ab", count: 32)
        try qc.store.save(stored)
        #expect(qc.flushQueue(into: url, vaultId: stored.profile.vaultId, coordinated: false) == 1)
        let entry = try #require(try stores.ledger(for: stored.profile.vaultId).entries()
            .first { $0.path == "inbox/\(CaptureFile.name(outcome.id, .capture))" })
        #expect(entry.epoch == sealedEpoch)
        #expect(Self.leftovers(qc.queueFolder(stored.profile.vaultId)).isEmpty, "the sidecar goes with the file")
    }

    /// A voice note is recorded in its vault's ledger, under the profile's epoch, before it is placed in the
    /// inbox (design §5.4, §5.7): a device change before it is adopted is caught up from there.
    @Test func voiceNotesAreRecordedInTheLedgerBeforeTheInbox() async throws {
        let (url, _, _, qc, _) = try Self.setUp()
        let stores = DeviceWriteStores.inMemoryKey(root: try TestTemp.directory("ledger-capture"))
        qc.writeStores = stores
        try await qc.start()
        let outcome = try await qc.stop()
        #expect(outcome.delivery == .vault)
        let vault = try Vault.open(at: url)
        let entries = try stores.ledger(for: vault.vaultId).entries()
        let name = CaptureFile.name(outcome.id, .capture)
        let entry = try #require(entries.first { $0.path == "inbox/\(name)" })
        #expect(entry.epoch == vault.manifest.epoch)
        #expect(entry.sha256 == FileDigest.sha256(try Data(contentsOf: url.appendingPathComponent("inbox/\(name)"))))
    }
}

/// A profile store whose item cannot be read (the Keychain before the first unlock).
struct FailingCaptureProfileStore: CaptureProfileStore {
    struct Locked: Error {}
    func load() throws -> StoredCaptureProfile? { throw Locked() }
    func save(_ profile: StoredCaptureProfile) throws { throw Locked() }
    func delete() throws { throw Locked() }
}

@MainActor
final class ReloadCounter {
    var count = 0
}

extension QuickCaptureTests {
    /// An intent can deliver a voice note while the app is in the background with its locks released: nothing is
    /// written to the vault then (0xdead10cc, no store lease); the foreground path adopts it.
    @Test func aDeliveryWhileLocksAreSuspendedAdoptsNothing() async throws {
        let (url, key, _, qc, _) = try Self.setUp(transcribe: false)
        let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = Self.temp("blobs")
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.inboxAdoption == nil })
        let tone = try Data(contentsOf: RecordingTests.tone)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: id),
                                in: url.appendingPathComponent(CaptureFile.folderName, isDirectory: true))
        let vaultId = try #require(model.vault).vaultId
        model.locksSuspended = true
        NotificationCenter.default.post(name: QuickCapture.deliveredNotification, object: nil, userInfo: ["vault": vaultId])
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.inboxAdoption == nil)
        #expect(!model.notes.contains { $0.id == CaptureAdoption.ids(for: id).note })
        model.locksSuspended = false
        #expect(await model.adoptInbox() == 1, "the foreground path adopts it")
    }
}

/// Lets a test act once, from the model's `afterIO` seam.
private final class MidRunSwitch: @unchecked Sendable {
    @MainActor weak var model: AppModel?
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    private func take() -> Bool { lock.withLock { let go = armed; armed = false; return go } }
    func fire() async {
        let go = take()
        if go { await MainActor.run { model?.locksSuspended = true } }
    }
}

extension QuickCaptureTests {
    /// The app goes to the background (locks released) while an adoption runs: it stops between captures and leaves
    /// the rest in the inbox; the rerun flag does not restart it.
    @Test func anAdoptionInProgressStopsWhenLocksAreSuspended() async throws {
        let (url, key, _, qc, _) = try Self.setUp(transcribe: false)
        let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
        let switcher = MidRunSwitch()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50),
                             afterIO: { await switcher.fire() })
        switcher.model = model
        model.blobCacheFolder = Self.temp("blobs")
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.inboxAdoption == nil })
        let tone = try Data(contentsOf: RecordingTests.tone)
        let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        let ids = [UUID(), UUID()]
        for id in ids { try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: id), in: inbox) }
        switcher.arm()
        let done = await model.adoptInbox()
        #expect(model.locksSuspended)
        #expect(done == 1, "stopped between captures")
        #expect(Self.inbox(url).count == 1, "the other capture stays in the inbox")
        model.startInboxAdoption()
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.inbox(url).count == 1, "nothing is adopted while suspended")
        model.locksSuspended = false
        #expect(await model.adoptInbox() == 1)
        #expect(Self.inbox(url).isEmpty)
    }
}
