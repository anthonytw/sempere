import Age
import AVFoundation
import Foundation
import Sempere
import SempereAppCore
import SempereCaptureShared
import SempereSync
import Testing
@testable import SempereApp

/// Quick voice notes in the app (docs/quick-capture.md): capture on the app's recorder (`RecordingSession`, files
/// protected for the Lock Screen) and AVFoundation (ADTS segments merged into MPEG-4), interruptions of the real
/// session, transcripts now or later, adoption into notes by the `AppModel`. The state machine itself (starts,
/// stops, sweeps, seals, the status and the banner) is tested on Linux with fakes: `QuickCaptureFlowTests`
/// (SempereAppCoreTests).
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
        let qc = QuickCapture.testing(store: store, center: center, transcriber: transcriber)
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

    /// A voice note started and stopped on the Lock Screen is assembled and
    /// read back from closed files before any unlock: its files must use a
    /// class that is readable while locked (after the first unlock), not
    /// `completeUnlessOpen`, under which sealing would fail and the note be
    /// lost. In-note recordings keep `completeUnlessOpen`. (The simulator has
    /// no Data Protection, so the class itself is what is checked.)
    @Test func voiceNotesAreRecordedInAClassReadableWhileLocked() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        try await qc.start()
        let session = try #require(qc.session as? RecordingSession)
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
        let session = try #require(qc.session as? RecordingSession)
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

    /// The widgets are reloaded when the status changes, and also, unchanged, each time the
    /// app launches or becomes active: a widget can show an older status than the file.
    @Test func widgetsReloadOnChangeAndOnEveryActivation() async throws {
        let (_, _, _, qc, _) = try Self.setUp(transcribe: false)
        let reloads = ReloadCounter()
        qc.statusStore = VoiceNoteStatusStore(directory: Self.temp("qc-status"))
        qc.liveActivity = NoLiveActivity()   // enabled
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
        #expect(QuickCaptureError.profileUnreadable.description != QuickCaptureError.notSetUp.description)
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
        let qc = QuickCapture.testing()
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

    /// A crash-left recording folder with a finished segment and its manifest.
    static func crashLeftRecording(in root: URL) throws -> URL {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TestAudio.adtsTone(), to: folder.appendingPathComponent("segment-001.aac"))
        let manifest = RecordingManifest(note: UUID(), recording: id, started: Date(), codec: "aac",
                                         segments: ["segment-001.aac"], finished: 1)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingRecovery.manifestName))
        return folder
    }

    /// A finished segment of no length (stopped just after a new segment began, before its first frame) holds
    /// nothing: AVFoundation reads it as an audio track of no length, which a seal leaves out
    /// (`QuickCaptureFlowTests.sealSkipsAFinishedSegmentOfNoLength`). It used to count as "a complete segment that
    /// does not decode", which kept the whole voice note unsealed for good. Bytes AVFoundation cannot read at all
    /// still count as undecodable (`AVCaptureAudioFiles.classify`).
    @Test func aFinishedSegmentOfNoLengthHoldsNoAudio() async throws {
        let dir = Self.temp("no-length")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let empty = dir.appendingPathComponent("segment-002.m4a")
        let file = try AVAudioFile(forWriting: empty, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                 AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        file.close()
        #expect(CaptureSegments.byteCount(empty) > 0, "a finished file, not an empty one")
        let files = AVCaptureAudioFiles()
        #expect(await files.classify(empty) == .none)
        #expect(await files.classify(RecordingTests.tone) == .audio)
        #expect(await files.classify(try TestAudio.adtsTone()) == .audio)
        let garbage = dir.appendingPathComponent("garbage.m4a")
        try Data("not audio".utf8).write(to: garbage)
        #expect(await files.classify(garbage) == .undecodable)
        #expect(await files.classify(dir.appendingPathComponent("missing.m4a")) == .none)
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

extension QuickCapture {
    /// The app's quick capture on a fake recorder (`FakeCapture`) with the microphone allowed, no Live Activity and
    /// no widget status, in folders of its own (tests).
    static func testing(store: any CaptureProfileStore = MemoryCaptureProfileStore(), center: NotificationCenter = NotificationCenter(),
                        transcriber: (any RecordingTranscribing)? = nil) -> QuickCapture {
        let qc = QuickCapture.app(store: store, root: QuickCaptureTests.temp("qc-root"), queueRoot: QuickCaptureTests.temp("qc-queue"),
                                  statusStore: nil)
        let audio = AppCaptureAudio()
        audio.backend = { FakeCapture() }
        audio.microphoneAllowed = { true }
        audio.center = center
        qc.audio = audio
        qc.transcriber = transcriber
        qc.showsActivity = false
        return qc
    }

    /// Its `AppCaptureAudio` (tests change the backend or the permission).
    var appAudio: AppCaptureAudio {
        // swiftlint:disable:next force_cast
        audio as! AppCaptureAudio
    }
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
        try await Task.sleep(for: .milliseconds(500))   // kept: a negative check, nothing to wait on
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
        try await Task.sleep(for: .milliseconds(300))   // kept: a negative check, nothing to wait on
        #expect(Self.inbox(url).count == 1, "nothing is adopted while suspended")
        model.locksSuspended = false
        #expect(await model.adoptInbox() == 1)
        #expect(Self.inbox(url).isEmpty)
    }
}
