import Age
import Foundation
import Observation
import Sempere
@testable import SempereAppCore
import SempereCaptureShared
import TempDirSupport
import Testing
import VaultTestSupport

// Fakes for `QuickCapture`'s platform (`QuickCapturePlatform.swift`) and a vault to capture into. Nothing here waits
// on the wall clock: the recording's time is `CaptureClock`, the banner's and the heartbeat's waits are
// `ManualSleeper`, and a test waits for the main actor's queued work with `CaptureRig.settle`.

/// A vault and a capture profile of it, made once per process (key generation is slow on the CI runner) and copied
/// for each test.
enum CaptureFixture {
    struct Template: Sendable {
        let url: URL
        let identity: NativeIdentity
        let profile: CaptureProfile
    }

    static let template: Result<Template, any Error> = Result {
        let identity = try NativeIdentity.generate(.postQuantum)
        let dir = TestTemp.root.appendingPathComponent("capture-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.sempere", isDirectory: true)
        let vault = try TestVaults.create(at: url, identities: [identity])
        return Template(url: url, identity: identity, profile: try vault.captureProfile(device: DeviceID("0badf00d")!))
    }

    /// A copy of the template vault in a store of its own (a capture finds its vault by id there, as the app's does),
    /// and its stored profile.
    static func vault(transcribe: Bool = false) throws -> (url: URL, identity: NativeIdentity, stored: StoredCaptureProfile,
                                                           store: VaultStore) {
        let t = try template.get()
        let dir = TestTemp.root.appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("sample.sempere", isDirectory: true)
        try FileManager.default.copyItem(at: t.url, to: source)
        let store = VaultStore(root: dir.appendingPathComponent("store", isDirectory: true))
        let entry = try store.importVault(from: source)
        try FileManager.default.removeItem(at: source)
        let stored = StoredCaptureProfile(profile: t.profile, vaultName: "sample", transcribe: transcribe)
        return (entry.url, t.identity, stored, store)
    }

    static func temp(_ name: String) -> URL {
        TestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}

/// The time the recording and quick capture read (the test moves it).
@MainActor
final class CaptureClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
}

/// Waits that end when the test says (`release`), never on the clock.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var asked: [Duration] = []

    func sleep(_ d: Duration) async {
        await withCheckedContinuation { c in
            lock.withLock {
                waiting.append((d, c))
                asked.append(d)
            }
        }
    }

    /// The waits asked for so far, in order (released or not).
    var requested: [Duration] { lock.withLock { asked } }

    /// How many waits of `d` are waiting.
    func pending(_ d: Duration) -> Int { lock.withLock { waiting.filter { $0.0 == d }.count } }

    /// Ends the oldest wait of `d`.
    func releaseFirst(_ d: Duration) {
        let ready = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let i = waiting.firstIndex(where: { $0.0 == d }) else { return nil }
            return waiting.remove(at: i).1
        }
        ready?.resume()
    }

    /// Ends every wait of `d`.
    func release(_ d: Duration) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let (go, stay) = (waiting.filter { $0.0 == d }, waiting.filter { $0.0 != d })
            waiting = stay
            return go.map(\.1)
        }
        for c in ready { c.resume() }
    }
}

/// A recording that writes `content` into each segment file it begins.
@MainActor
@Observable
final class FakeRecording: CaptureRecording {
    enum State: Equatable { case idle, recording, interrupted, stopped }

    let id = UUID()
    let folder: URL
    private(set) var segments: [URL] = []
    private(set) var timeline = RecordingTimeline()
    private(set) var state = State.idle
    @ObservationIgnored var onStoppedBySystem: (@MainActor () -> Void)?
    @ObservationIgnored let segmentExtension: String
    @ObservationIgnored let clock: CaptureClock
    @ObservationIgnored var content = Data("AUDIO-FRAMES".utf8)
    @ObservationIgnored var failStart = false

    init(root: URL, segmentExtension: String, clock: CaptureClock) {
        folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        self.segmentExtension = segmentExtension
        self.clock = clock
    }

    var isActive: Bool { state == .recording || state == .interrupted }
    var isPaused: Bool { state == .interrupted }

    func start() throws {
        if failStart { throw RecorderRefused() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("segment-001.\(segmentExtension)")
        try content.write(to: url)
        segments.append(url)
        timeline.resume(at: clock.now)
        state = .recording
    }

    /// A call: the audio pauses.
    func interrupt() {
        guard state == .recording else { return }
        timeline.pause(at: clock.now)
        state = .interrupted
    }

    /// The call ended.
    func resume() {
        guard state == .interrupted else { return }
        timeline.resume(at: clock.now)
        state = .recording
    }

    func stop() {
        guard isActive else { return }
        timeline.stop(at: clock.now)
        state = .stopped
    }

    func discardFiles() { try? FileManager.default.removeItem(at: folder) }
}

/// The audio system's refusal to start the recorder (the app's `RecordingError.cannotRecord`): it may work in front.
struct RecorderRefused: Error, CaptureStartRefusal, CustomStringConvertible {
    var mayWorkInForeground: Bool { true }
    var description: String { "Could not record: test" }
}

/// One start's recorder: its session activations go into `events`.
@MainActor
final class FakeRecorder: CaptureRecorder {
    struct SessionRefused: Error, CaptureStartRefusal, CustomStringConvertible {
        var mixable: Bool
        var mayWorkInForeground: Bool { true }
        var description: String { "Operation denied (setActive\(mixable ? " (mixable)" : ""): '!int' cannotInterruptOthers)" }
    }

    let audio: FakeAudio
    var log: [String] = []
    var failNonMixable = false
    var failMixable = false
    var failStart = false
    private(set) var recordings: [FakeRecording] = []

    init(audio: FakeAudio) { self.audio = audio }

    func activateSession(mixable: Bool) async throws {
        log.append(mixable ? "activate-mixable" : "activate")
        audio.events.append(mixable ? "activate-mixable" : "activate")
        if mixable ? failMixable : failNonMixable { throw SessionRefused(mixable: mixable) }
    }

    func deactivate() { log.append("deactivate") }

    func makeRecording(format: RecordingFormat, root: URL, segmentExtension: String) -> any CaptureRecording {
        let r = FakeRecording(root: root, segmentExtension: segmentExtension, clock: audio.clock)
        r.failStart = failStart
        audio.formats.append(format)
        recordings.append(r)
        return r
    }
}

/// The microphone and the recorders; `configure` sets up each new recorder (what it refuses).
@MainActor
final class FakeAudio: CaptureAudio {
    let clock: CaptureClock
    var allowed: @MainActor () -> Bool = { true }
    var permission: @MainActor () -> String = { "granted" }
    var preferredFormat = RecordingFormat.default
    var configure: @MainActor (FakeRecorder) -> Void = { _ in }
    /// Activations and Live Activity requests in order, across recorders (`FakeLiveActivity` adds "activity").
    var events: [String] = []
    var formats: [RecordingFormat] = []
    private(set) var recorders: [FakeRecorder] = []

    init(clock: CaptureClock) { self.clock = clock }

    func requestMicrophone() async -> Bool { allowed() }
    var microphonePermission: String { permission() }
    func makeRecorder() -> any CaptureRecorder {
        let r = FakeRecorder(audio: self)
        configure(r)
        recorders.append(r)
        return r
    }

    /// The recording in progress, or the last one made.
    var lastRecording: FakeRecording? { recorders.last?.recordings.last }
}

/// Segment files as the tests write them: no byte or `emptyTrack` holds no audio, a file starting with
/// `undecodable` does not decode, anything else is audio. `merge` joins the bytes.
struct FakeAudioFiles: CaptureAudioFiles {
    static let undecodable = Data("not audio".utf8)
    static let emptyTrack = Data("an audio track of no length".utf8)

    func classify(_ url: URL) async -> CaptureSegments.Audio {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data != Self.emptyTrack else { return .none }
        return data.starts(with: Self.undecodable) ? .undecodable : .audio
    }

    func merge(_ segments: [URL], into out: URL) async throws {
        try await ByteCaptureAudioFiles().merge(segments, into: out)
    }
}

/// A Live Activity that keeps what it was sent.
@MainActor
final class FakeLiveActivity: CaptureLiveActivity {
    let audio: FakeAudio?
    var isSupported = true
    var areEnabled = true
    var requestError: (any Error)?
    private(set) var requested: [VoiceNoteActivityState] = []
    /// Every state sent (`request`, `update`, `end`), in order.
    private(set) var states: [VoiceNoteActivityState] = []
    private(set) var ends: [(VoiceNoteActivityState, Date)] = []
    private(set) var endAllCalls = 0
    var orphans = 0

    init(audio: FakeAudio? = nil) { self.audio = audio }

    func request(_ state: VoiceNoteActivityState, staleDate: Date?) throws {
        audio?.events.append("activity")
        if let requestError { throw requestError }
        requested.append(state)
        states.append(state)
    }
    func update(_ state: VoiceNoteActivityState, staleDate: Date?) { states.append(state) }
    func end(_ state: VoiceNoteActivityState, dismissal: Date) {
        states.append(state)
        ends.append((state, dismissal))
    }
    func endAll(startedBefore cutoff: Date) async { endAllCalls += 1 }
    func endOrphans(startedBefore cutoff: Date) async -> Int { orphans }
}

/// The app's state as the test sets it; `waitUntilActive` is the test's too.
@MainActor
final class FakeApp: CaptureAppState {
    var activity = CaptureAppActivity.active
    var protectedDataAvailable = true
    var waits = 0
    /// What a wait does (default: the app comes to the front).
    var wait: @MainActor (FakeApp) async -> Bool = { app in
        app.activity = .active
        return true
    }
    func waitUntilActive(timeout: Duration) async -> Bool {
        waits += 1
        return await wait(self)
    }
}

/// A profile store whose item cannot be read (the Keychain before the first unlock).
struct FailingCaptureProfileStore: CaptureProfileStore {
    struct Locked: Error {}
    func load() throws -> StoredCaptureProfile? { throw Locked() }
    func save(_ profile: StoredCaptureProfile) throws { throw Locked() }
    func delete() throws { throw Locked() }
}

/// A fixed transcript for any recording.
struct FakeTranscriber: RecordingTranscribing {
    func transcribe(file: URL, recording: UUID, noteLanguage: String?, allowModelDownload: Bool) async throws -> Transcript {
        TranscriptBuilder.transcript(recording: recording, engine: "test-1", language: "en-US",
                                     segments: TranscriptBuilder.segments(fromWords: [
                                         RecognizedSpan(text: "Linear", start: 0.2, end: 0.6, confidence: 0.9),
                                         RecognizedSpan(text: "maps.", start: 0.6, end: 1.0, confidence: 0.4)]))
    }
}

/// A quick capture on fakes, with a vault copy whose profile is stored.
@MainActor
final class CaptureRig {
    let clock = CaptureClock()
    let sleeper = ManualSleeper()
    let audio: FakeAudio
    let live: FakeLiveActivity
    let app = FakeApp()
    let capture: QuickCapture
    let vault: URL
    let identity: NativeIdentity
    let store = MemoryCaptureProfileStore()

    /// - Parameter profile: store the vault's profile (else quick voice notes are off).
    init(transcribe: Bool = false, profile: Bool = true, transcriber: (any RecordingTranscribing)? = nil) throws {
        let (url, identity, stored, vaultStore) = try CaptureFixture.vault(transcribe: transcribe)
        vault = url
        self.identity = identity
        if profile { try store.save(stored) }
        audio = FakeAudio(clock: clock)
        live = FakeLiveActivity(audio: audio)
        capture = QuickCapture(store: store, audio: audio, audioFiles: FakeAudioFiles(), transcriber: transcriber,
                               liveActivity: live, app: app, root: CaptureFixture.temp("qc-root"),
                               queueRoot: CaptureFixture.temp("qc-queue"))
        let clock = self.clock, sleeper = self.sleeper
        capture.vaultStore = vaultStore
        capture.now = { clock.now }
        capture.sleep = { await sleeper.sleep($0) }
        capture.showsActivity = false
    }

    var stored: StoredCaptureProfile {
        get throws { try #require(try store.load()) }
    }

    var inbox: [String] { Self.names(vault.appendingPathComponent(CaptureFile.folderName)) }
    var leftovers: [String] { Self.names(capture.root) }

    static func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// The vault opened with its key (to read what was sealed).
    func openVault() throws -> Vault { try TestVaults.open(at: vault, identity: identity) }

    /// Lets the main actor's queued work run (pause follow-ups, heartbeats) until `condition` holds; false when it
    /// never did. No clock: a fixed number of turns.
    func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// A folder a crash left in `root`: one finished segment (`content`) and a manifest naming it.
    @discardableResult
    func crashLeftRecording(content: Data = Data("AUDIO-FRAMES".utf8), name: String = "segment-001.aac",
                            manifest: Bool = true) throws -> URL {
        let id = UUID()
        let folder = capture.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try content.write(to: folder.appendingPathComponent(name))
        if manifest {
            let m = RecordingManifest(note: UUID(), recording: id, started: clock.now, codec: "aac", segments: [name], finished: 1)
            try JSONEncoder().encode(m).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
        }
        return folder
    }

    /// Whether `chmod 0` makes a file unreadable here (not as root, as in a Linux container).
    static func permissionsApply(_ url: URL) -> Bool { !FileManager.default.isReadableFile(atPath: url.path) }
}
