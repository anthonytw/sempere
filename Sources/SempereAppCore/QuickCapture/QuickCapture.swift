import Foundation
import Observation
import Sempere
import SempereCaptureShared

/// Quick voice notes (docs/quick-capture.md): one tap (Siri, Shortcuts, the
/// Action button, a widget, Control Center) records; stopping seals the audio
/// with the capture profile alone (`CaptureWriter`: age-encrypted to the
/// vault's recipients and tagged with the capture key), so neither the vault
/// nor the device needs unlocking and no Face ID is asked. The sealed file goes
/// into the vault's `inbox/` (a coordinated write in iCloud Drive), or into a
/// local queue when the vault folder cannot be reached, moved into the vault
/// later. The plaintext audio exists only in protected temporary files (the
/// recorder's, `CaptureRecording`: readable after the first unlock, since a
/// voice note started from the Lock Screen is read back from closed files and
/// sealed before any unlock) and in memory, and is deleted as soon as the capture
/// (and its transcript, made on device from it) is sealed; leftovers from a crash or
/// a failed seal are sealed at the next launch or activation (`sweep`), and
/// never deleted before their audio is sealed. The app adopts inbox
/// captures as notes once the vault is unlocked (`AppModel+Inbox`).
///
/// The platform is behind protocols (`QuickCapturePlatform.swift`): the recorder (`CaptureAudio`), decoding the
/// segments (`CaptureAudioFiles`), the Live Activity, the app's state and background time. The app makes the
/// shared instance with its own (`QuickCapture+App.swift`) and words the values (`QuickCapture+Text.swift`).
@MainActor
@Observable
public final class QuickCapture {
    public enum State: Equatable, Sendable { case idle, starting, recording, saving }

    public typealias Delivery = CaptureDelivery.Destination

    /// What one capture did.
    public struct Outcome: Equatable, Sendable {
        public var id: UUID
        public var delivery: Delivery?
        public var transcribed = false
        /// What went wrong (the error's description), when nothing was delivered.
        public var error: String?
        /// The recording is kept on this device for the next seal (`sweep`): said after `error`.
        public var kept = false

        init(id: UUID, delivery: Delivery? = nil, transcribed: Bool = false, error: String? = nil, kept: Bool = false) {
            self.id = id
            self.delivery = delivery
            self.transcribed = transcribed
            self.error = error
            self.kept = kept
        }
    }

    /// What the banner says after a stop, a failed start or a sweep.
    public struct Notice: Equatable, Sendable {
        /// What the banner is about (its title; the app words it).
        public enum Kind: Equatable, Sendable {
            /// A voice note just stopped: where it went (`result`).
            case stopped
            /// A start that failed: nothing was recorded to save.
            case notRecorded
            /// A voice note cut off by a restart or a force quit, saved by a sweep.
            case interruptedSaved
            /// One cut off by a restart, kept on the device for now.
            case interruptedNotSaved
        }

        public var result: VoiceNoteResult
        public var kind: Kind
        /// Why it failed (the error's description, `Outcome.error`).
        public var error: String?
        /// The recording is kept on this device (said after `error`).
        public var kept: Bool
        /// Stays until dismissed rather than for `result.shownFor`.
        var persists: Bool
        var id: UUID

        init(result: VoiceNoteResult, kind: Kind = .stopped, error: String? = nil, kept: Bool = false,
                    persists: Bool = false, id: UUID = UUID()) {
            self.result = result
            self.kind = kind
            self.error = error
            self.kept = kept
            self.persists = persists
            self.id = id
        }
    }

    public private(set) var state = State.idle {
        didSet { if state != oldValue { publishStatus() } }
    }
    /// The recording in progress.
    public private(set) var session: (any CaptureRecording)?
    /// A `sweep()` is running.
    @ObservationIgnored private var sweeping = false
    /// The last capture's outcome.
    private(set) var lastOutcome: Outcome?
    /// Where the last stopped voice note went, while the app's banner shows it
    /// (cleared after `VoiceNoteResult.shownFor`).
    public private(set) var notice: Notice?
    /// A place a widget, the control or the Live Activity asked the app to
    /// show (`sempere://quick-voice/…`, `VoiceNoteControlIntent`); the window
    /// that shows it clears it.
    public var pendingLink: VoiceNoteLink?

    /// When the recording in progress started.
    var started: Date? { session?.timeline.started }

    /// Whether the recording in progress is paused (a call, a headset unplugged).
    public var isPaused: Bool { session?.isPaused ?? false }

    /// When the recording in progress would have started had it never paused:
    /// a timer counting from it shows the audio recorded (`audioLength` while paused).
    /// `at` nil: `now()`.
    public func timerStart(at time: Date? = nil) -> Date? {
        guard let s = session, s.timeline.started != nil else { return nil }
        let t = time ?? now()
        return t.addingTimeInterval(-s.timeline.audioLength(at: t))
    }

    /// Seconds of audio recorded so far (`at` nil: `now()`).
    public func audioLength(at time: Date? = nil) -> Double { session?.timeline.audioLength(at: time ?? now()) ?? 0 }

    // MARK: - Platform and settings

    /// Where the profile is (the Keychain in the app).
    @ObservationIgnored public var store: any CaptureProfileStore
    /// The microphone and the recorder.
    @ObservationIgnored public var audio: any CaptureAudio
    /// Decodes and joins the segment files.
    @ObservationIgnored var audioFiles: any CaptureAudioFiles
    @ObservationIgnored public var transcriber: (any RecordingTranscribing)?
    @ObservationIgnored public var liveActivity: any CaptureLiveActivity
    @ObservationIgnored var app: any CaptureAppState
    @ObservationIgnored var backgroundTime: any BackgroundTime
    /// Holds the vault folder's scope while a capture is written (the app's security-scoped bookmarks).
    @ObservationIgnored var bookmarks: any FolderBookmarks
    /// Coordinates a queue flush into a vault in iCloud Drive (`flushQueue(…coordinated: true)`).
    @ObservationIgnored var files: any FileCoordinating
    /// The start diagnostics' log lines.
    @ObservationIgnored var perf: any PerfSink
    /// The default title of a voice note (the app: in the device's language); nil: `CaptureWriter.defaultTitle`.
    @ObservationIgnored public var noteTitle: (@Sendable (Date) -> String)?
    /// The time now (tests set their own, with a recording that reads it too).
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// Waits (the banner's time, the Live Activity's heartbeat); tests set their own.
    @ObservationIgnored var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// How long after its last update the recording's Live Activity counts as stale: the app refreshes
    /// it every `activityHeartbeat` while recording, so an activity whose app died (force quit, crash)
    /// shows "interrupted" and an Open button instead of a Stop that reaches nothing.
    @ObservationIgnored var activityStaleAfter: TimeInterval = 120
    @ObservationIgnored var activityHeartbeat: Duration = .seconds(45)
    /// Interrupted recordings a sweep could not save yet that the banner already reported (once per launch).
    @ObservationIgnored private var reportedKept: Set<UUID> = []
    /// Where recordings in progress are (plaintext, protected, deleted once sealed).
    @ObservationIgnored public var root: URL
    /// Sealed captures waiting for the vault folder, per vault id.
    @ObservationIgnored var queueRoot: URL
    /// The in-app vault store (the app sets it at launch): a voice note for a store vault goes straight into
    /// its in-app inbox, found by vault id, open or not (docs/design/device-first-sync.md §5.3).
    @ObservationIgnored public var vaultStore: VaultStore?
    /// This device's write ledger of a vault (the app sets it at launch, `DeviceWriteStores`): a voice note is
    /// recorded in its vault's ledger before it is placed in the vault's inbox (key-hierarchy design §5.4, §5.7),
    /// so one sealed under an earlier epoch's profile is re-sealed at the next unlock. Nil records nothing (tests).
    @ObservationIgnored public var ledger: (@Sendable (UUID) -> any WriteLedgerStore)?
    /// Starts a Live Activity while recording (off in tests).
    @ObservationIgnored public var showsActivity = true
    /// Where the widgets read `VoiceNoteStatus` (the App Group; nil without one, and in tests unless set).
    @ObservationIgnored public var statusStore: VoiceNoteStatusStore?
    /// Reloads the widgets and the control after the status changed.
    @ObservationIgnored public var reloadSurfaces: @MainActor () -> Void = {}
    /// Called after the stored profile changed (turned on or off, a new epoch's key, the notebook, the vault, a suspension):
    /// the app gives the Apple Watch its new profile (`WatchProvisioner`).
    @ObservationIgnored public var profileChanged: @MainActor () -> Void = {}
    /// How long a start that continued in the app waits for the app to be active before trying again.
    @ObservationIgnored var foregroundWait: Duration = .seconds(12)
    /// The last voice-note starts, kept for Settings (`VoiceNoteStartLog`); memory only unless the app gives a file.
    @ObservationIgnored public var startLog = VoiceNoteStartLog(url: nil)
    /// `startLog`'s attempts, newest first, for Settings ▸ Quick Voice Notes ▸ Recent Starts (observed through the log).
    public var recentStarts: [VoiceNoteStartAttempt] { startLog.attempts }
    /// The last taps on a widget, the control or a voice note shortcut, from the app and the widget
    /// extension (`VoiceNoteTapLog`), newest first; read again by `refreshTaps()`.
    public private(set) var recentTaps: [VoiceNoteTap] = []
    /// Words the error a banner or an outcome carries (the app's `AppModel.describe`; the error's own description by
    /// default).
    @ObservationIgnored public var describeError: ErrorDescriber = plainErrorDescription
    /// Called with the capture id as each seal begins (tests).
    @ObservationIgnored var willSeal: (@MainActor (UUID) -> Void)?

    /// - Parameters: the platform's services (`QuickCapturePlatform.swift`); the defaults record nothing, show no
    ///   Live Activity and run as an app in front, for tests and the CLI.
    public init(store: any CaptureProfileStore = MemoryCaptureProfileStore(), audio: any CaptureAudio = NoCaptureAudio(),
                audioFiles: any CaptureAudioFiles = ByteCaptureAudioFiles(), transcriber: (any RecordingTranscribing)? = nil,
                liveActivity: any CaptureLiveActivity = NoLiveActivity(), app: any CaptureAppState = ActiveCaptureApp(),
                backgroundTime: any BackgroundTime = NoBackgroundTime(), bookmarks: any FolderBookmarks = PathBookmarks(),
                files: any FileCoordinating = UncoordinatedFiles(), perf: any PerfSink = NoPerfSink(),
                root: URL = QuickCapture.defaultRoot, queueRoot: URL = QuickCapture.defaultQueueRoot) {
        self.store = store
        self.audio = audio
        self.audioFiles = audioFiles
        self.transcriber = transcriber
        self.liveActivity = liveActivity
        self.app = app
        self.backgroundTime = backgroundTime
        self.bookmarks = bookmarks
        self.files = files
        self.perf = perf
        self.root = root
        self.queueRoot = queueRoot
    }

    public nonisolated static var defaultRoot: URL { AppSupport.folder("QuickCapture") }
    public nonisolated static var defaultQueueRoot: URL { AppSupport.folder("CaptureQueue") }

    /// Whether a failed start may work with the app in front: the audio system's refusal, which iOS
    /// can give a background start (`CaptureStartRefusal`), and a Live Activity iOS would not start in the
    /// background (`start(_:)` then continues in the app).
    public nonisolated static func worksInForeground(_ error: Error) -> Bool {
        if (error as? any CaptureStartRefusal)?.mayWorkInForeground == true { return true }
        if case .liveActivityRefused = error as? QuickCaptureError { return true }
        if case .microphoneUnconfirmed = error as? QuickCaptureError { return true }
        return false
    }

    /// Hooks the intents (Siri, Shortcuts, widgets, Control Center) up to this instance (the app's shared one,
    /// `QuickCapture.register()` in the app, which adds what only the platform can watch).
    public func installActions() {
        VoiceNoteActions.open = { [weak self] in self?.pendingLink = $0 }
        VoiceNoteActions.status = { [weak self] in self?.status ?? .unknown }
        VoiceNoteActions.appState = { [weak self] in self?.app.activity.rawValue ?? CaptureAppActivity.unknown.rawValue }
        VoiceNoteActions.tapRecorded = { [weak self] _ in self?.refreshTaps() }
        refreshTaps()
        VoiceNoteActions.start = { [weak self] in
            guard let self else { throw VoiceNoteIntentError.unavailable }
            try await self.start($0)
        }
        VoiceNoteActions.stop = { [weak self] in
            do { _ = try await self?.stop() } catch QuickCaptureError.notRecording {
                // Stop on an orphaned Live Activity: it is gone now (stop ended it); nothing to report.
            }
        }
    }

    // MARK: - Status for the widgets and the control

    /// The status the widgets and the control show now. Its timer counts the
    /// audio, as the Live Activity's does: it starts later by the pauses so far
    /// and stands still during one (`VoiceNoteStatus.paused`).
    var status: VoiceNoteStatus {
        // From the current run alone, so that the status (compared to skip widget reloads) is the same until the next pause or resumption.
        let run = session?.timeline.runs.last
        return VoiceNoteStatus.make(setUp: isSetUp, activitiesEnabled: liveActivity.areEnabled,
                                    recording: state == .recording, saving: state == .saving,
                                    started: run.map { $0.wallStart.addingTimeInterval(-$0.audioStart) },
                                    paused: run?.wallEnd)
    }

    /// Writes `status` for the widget extension and reloads the widgets and
    /// the control when it changed. Called on every state change, when the
    /// profile is turned on, off or changed, and when the app becomes active
    /// (Live Activities may have been switched in Settings meanwhile).
    ///
    /// `forceReload` reloads even when the file is unchanged: at launch and on
    /// activation, because a widget can show a status older than the file (a
    /// reload lost while the app was in the background) and would then send a
    /// tap to Settings instead of recording.
    public func publishStatus(forceReload: Bool = false) {
        guard let statusStore else { return }
        do {
            if try statusStore.write(status) || forceReload { reloadSurfaces() }
        } catch {
            // The widgets keep their last status; the next change writes again.
        }
    }

    /// The stored profile. Throws `notSetUp` when there is none, and
    /// `profileUnreadable` when the store would not hand it over: not the
    /// same thing, and "not set up" would send the user to turn on what is on.
    func storedProfile() throws -> StoredCaptureProfile {
        let stored: StoredCaptureProfile?
        do { stored = try store.load() } catch { throw QuickCaptureError.profileUnreadable }
        guard let stored else { throw QuickCaptureError.notSetUp }
        return stored
    }

    /// Whether quick voice notes are set up on this device: false only when
    /// no profile is stored. A profile that cannot be read now counts as set
    /// up, so that a tap starts and `start()` says why it cannot.
    public var isSetUp: Bool {
        do {
            _ = try storedProfile()
            return true
        } catch QuickCaptureError.notSetUp {
            return false
        } catch {
            return true
        }
    }

    // MARK: - Taps (diagnostics)

    /// Reads the tap log again (`VoiceNoteActions.tapLog`): after a tap in this process, and when the
    /// app becomes active (the widget extension may have added one).
    func refreshTaps() {
        recentTaps = VoiceNoteActions.tapLog?.read() ?? []
    }

    /// Clears Recent Starts: the starts and the taps.
    public func clearDiagnostics() {
        startLog.clear()
        VoiceNoteActions.tapLog?.clear()
        refreshTaps()
    }

    /// The app was opened by the widget's own URL (`VoiceNoteLink.widgetTapURL`): a widget tap that
    /// did not run the widget's intent. Kept in Recent Starts, then done here as the intent would
    /// have done it, from the live state: record, stop, or show the setup or the banner. The app is
    /// in front, so a start needs no background permission.
    ///
    /// Anyone can open the URL; it does nothing a tap on the widget, the control or Siri could not
    /// do on this device (docs/quick-capture.md "Threat model": a voice note is sealed to the vault's
    /// keys, and recording shows the banner, the Live Activity and the system's microphone indicator).
    @discardableResult
    public func widgetOpenedApp() -> Task<Void, Never> {
        let action = status.action
        let decision: VoiceNoteTap.Decision
        switch action {
        case .start: decision = .start
        case .stop: decision = .stop
        case .open(let link): decision = link == .settings ? .openSettings : .openRecording
        }
        VoiceNoteActions.recordTap(.widgetOpenedApp, decision: decision)
        return Task { @MainActor in
            switch action {
            case .start:
                do {
                    try await start(VoiceNoteStartRequest(source: .widgetOrControl, intentMode: "opened by the widget's link"))
                } catch {
                    announceStartFailure(error)
                }
            case .stop:
                do { _ = try await stop() } catch {
                    // Already stopped (a second tap): nothing to report.
                }
            case .open(let link):
                pendingLink = link
            }
        }
    }

    // MARK: - Recording

    /// Starts a voice note from the app (File ▸ Start Voice Note, the menu-bar item). Needs only the
    /// stored profile: no vault, no key.
    public func start() async throws {
        try await start(VoiceNoteStartRequest(source: .app))
    }

    /// Starts a voice note for `request` and keeps what happened in `startLog`.
    ///
    /// An intent's start runs in the background. When iOS refuses it there (the audio system's
    /// refusal, or no Live Activity: `worksInForeground`), the intent continues in the app
    /// (`request.continueInApp`), this waits until the app is actually active (`app.waitUntilActive`, at
    /// most `foregroundWait`: from the Lock Screen that is after the unlock) and tries once more. If
    /// that fails too, the banner says so (`announceStartFailure`) and the error goes to the intent.
    /// The retry runs in a task of its own, so it is not cancelled with the intent's.
    public func start(_ request: VoiceNoteStartRequest) async throws {
        var attempt = VoiceNoteStartAttempt(date: now(), source: request.source, intentMode: request.intentMode,
                                            first: VoiceNoteStartTry(appState: app.activity.rawValue))
        let continueInApp: @MainActor () async throws -> Void
        do {
            try await startRecorder(&attempt.first)
            attempt.outcome = .recording
            startLog.append(attempt)
            return
        } catch {
            guard let resume = request.continueInApp, Self.worksInForeground(error) else {
                startLog.append(attempt)
                throw error
            }
            continueInApp = resume
        }
        let work = Task { @MainActor [self, attempt] () async throws -> Void in
            var attempt = attempt
            var foreground = VoiceNoteStartAttempt.Foreground()
            let clock = ContinuousClock(), asked = clock.now
            do {
                try await continueInApp()
            } catch {
                foreground.error = VoiceNoteErrorInfo(error)
            }
            if foreground.error != nil, app.activity != .active {
                // iOS would not bring the app forward (or the user did not unlock): nothing to wait for.
                attempt.foreground = foreground
                startLog.append(attempt)
                let error = QuickCaptureError.couldNotOpenApp(foreground.error?.description ?? "")
                announceStartFailure(error)
                throw error
            }
            foreground.becameActive = await app.waitUntilActive(timeout: foregroundWait)
            let waited = clock.now - asked
            foreground.waited = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
            attempt.foreground = foreground
            var retry = VoiceNoteStartTry(appState: app.activity.rawValue)
            do {
                try await startRecorder(&retry)
                attempt.retry = retry
                attempt.outcome = .recordingInApp
                startLog.append(attempt)
            } catch {
                attempt.retry = retry
                startLog.append(attempt)
                announceStartFailure(error)
                throw error
            }
        }
        try await work.value
    }

    /// One try at starting the recorder; `trace` gets what the Live Activity request and the
    /// recorder answered.
    private func startRecorder(_ trace: inout VoiceNoteStartTry) async throws {
        do {
            try await startRecorderOnce(&trace)
        } catch {
            trace.error = VoiceNoteErrorInfo(error)
            throw error
        }
    }

    private func startRecorderOnce(_ trace: inout VoiceNoteStartTry) async throws {
        guard state == .idle else { throw QuickCaptureError.alreadyRecording }
        // Claimed before the first suspension: a second tap (widget and Control Center at
        // once) used to pass the idle check too and start a second, unstoppable recording.
        state = .starting
        var started = false
        defer { if !started { state = .idle } }
        let unlocked = app.protectedDataAvailable
        trace.protectedData = unlocked
        let stored: StoredCaptureProfile
        do { stored = try storedProfile() } catch QuickCaptureError.profileUnreadable where !unlocked {
            throw QuickCaptureError.beforeFirstUnlock
        }
        // New captures only: a stop, the sweep and the queue still seal under a suspended profile.
        if stored.suspended == true { throw QuickCaptureError.notOnDeviceList }
        if showsActivity, liveActivity.isSupported, !liveActivity.areEnabled { throw QuickCaptureError.liveActivitiesOff }
        let allowed = await audio.requestMicrophone()
        trace.microphone = audio.microphonePermission
        if !allowed {
            // In front the answer is the user's (and the prompt can show); in a process an intent launched
            // in the background it may be neither (TestFlight 1.0.0 (6): Siri after a restart).
            throw app.activity == .active ? QuickCaptureError.microphoneDenied : QuickCaptureError.microphoneUnconfirmed
        }
        // Nothing records here yet, so any Live Activity still shown is an orphan.
        await liveActivity.endAll(startedBefore: .distantFuture)
        // The audio session first, while the intent's fake-foreground assertion still holds: iOS ends that
        // assertion the moment the Live Activity begins, and a non-mixable session activated after it is
        // refused ('!int' cannotInterruptOthers; iPhone, iOS 27.0.1, TestFlight 1.0.0 (6), unified log).
        let capture = audio.makeRecorder()
        trace.session = try await activateSession(capture)
        // Read back and sealed on stop, often with the device still locked: the recorder's files stay readable
        // after the first unlock (`CaptureRecording`). ADTS segments (`CaptureSegments.segmentExtension`): a
        // recording cut off by a restart keeps its audio.
        let s = capture.makeRecording(format: CaptureSegments.captureFormat(audio.preferredFormat), root: root,
                                      segmentExtension: CaptureSegments.segmentExtension)
        // The manifest names the vault: a leftover is sealed only under a profile of the same vault (`sweep`).
        s.bind(vault: stored.profile.vaultId, epochId: stored.profile.epochId)
        // Ended by the system (media services reset, no new segment file): sealed as after Stop.
        s.onStoppedBySystem = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            Task { _ = try? await self.finish(s) }
        }
        // Then the Live Activity, before the recorder. `AudioRecordingIntent`: "you must start a Live Activity
        // when you begin the audio recording … If you don't start a Live Activity, the audio recording stops",
        // and only a `LiveActivityIntent` may start one from the background (`Activity.request`). Its result
        // goes to the start diagnostics; with the app in the background a failed request ends the try here.
        let request = startActivity(started: now())
        trace.activity = request
        if case .failed(let why) = request, app.activity != .active {
            // No Live Activity, no background recording (`AudioRecordingIntent`): the app continues in front.
            capture.deactivate()
            throw QuickCaptureError.liveActivityRefused(why.summary)
        }
        do {
            try s.start()
        } catch {
            endActivity(VoiceNoteActivityState(started: now(), result: .failed, ended: now()), after: 0)
            capture.deactivate()
            throw error
        }
        session = s
        state = .recording
        started = true
        if let begun = s.timeline.started { updateActivity(VoiceNoteActivityState(started: begun)) }
        followPauses(of: s, paused: false)
        keepActivityFresh(for: s)
    }

    /// Makes the audio session active for a start (`startRecorderOnce`), not mixable; when iOS refuses that
    /// with the app not in front, mixable (it interrupts no one). Returns how, for the diagnostics; throws the
    /// first refusal when both fail (`worksInForeground`: the intent then continues in the app).
    private func activateSession(_ capture: any CaptureRecorder) async throws -> String {
        do {
            try await capture.activateSession(mixable: false)
            return "not mixable"
        } catch {
            let refused = error
            guard app.activity != .active else { throw refused }
            do { try await capture.activateSession(mixable: true) } catch { throw refused }
            return "mixable after a refusal (\(VoiceNoteErrorInfo(refused).description))"
        }
    }

    /// Shows on the Live Activity and the widgets when `s` pauses (an
    /// interruption) and resumes: the timer stands still meanwhile, as the audio does.
    private func followPauses(of s: any CaptureRecording, paused: Bool) {
        withObservationTracking {
            _ = s.isPaused
            _ = s.isActive
        } onChange: { [weak self, weak s] in
            Task { @MainActor in
                guard let self, let s, self.session === s, self.state == .recording, s.isActive else { return }
                let pausedNow = self.isPaused
                if pausedNow != paused {
                    let at = self.now()
                    let length = s.timeline.audioLength(at: at)
                    self.updateActivity(VoiceNoteActivityState(started: at.addingTimeInterval(-length), paused: pausedNow,
                                                               ended: pausedNow ? at : nil))
                    self.publishStatus()
                }
                self.followPauses(of: s, paused: pausedNow)
            }
        }
    }

    /// Stops the voice note and seals it (and its transcript, when that is on).
    @discardableResult
    public func stop() async throws -> Outcome {
        guard let s = session, s.isActive else {
            // Stop pressed on a Live Activity this process did not start (the app was force quit, crashed or
            // restarted while recording): end it, and save what that recording left (`sweep`).
            if state == .idle {
                await liveActivity.endAll(startedBefore: .distantFuture)
                await sweep()
            }
            throw QuickCaptureError.notRecording
        }
        s.stop()
        return try await finish(s)
    }

    /// Seals a stopped session (`stop`, or the system ended it).
    private func finish(_ s: any CaptureRecording) async throws -> Outcome {
        guard session === s, state == .recording else { throw QuickCaptureError.notRecording }
        let started = s.timeline.started ?? now(), ended = now()
        // The Live Activity shows the length of the audio, without the pauses.
        let shown = ended.addingTimeInterval(-s.timeline.audioLength(at: ended))
        state = .saving
        updateActivity(VoiceNoteActivityState(started: shown, saving: true, ended: ended))
        defer {
            session = nil
            state = .idle
        }
        let stored: StoredCaptureProfile
        do {
            stored = try storedProfile()
        } catch QuickCaptureError.notSetUp {
            // Turned off while recording: nothing can seal it.
            s.discardFiles()
            announce(nil, error: describeError(QuickCaptureError.notSetUp), kept: false, started: shown, ended: ended)
            throw QuickCaptureError.notSetUp
        } catch {
            // The profile may still be there: the recording waits for `sweep()`.
            announce(nil, error: describeError(QuickCaptureError.profileUnreadable), kept: true, started: shown, ended: ended)
            throw QuickCaptureError.profileUnreadable
        }
        let outcome = await seal(segments: s.segments, folder: s.folder, id: s.id, started: started, stored: stored) { [weak self] delivery in
            // Said as soon as the audio is in the inbox (or the queue), not after the transcript.
            self?.announce(delivery, error: nil, kept: false, started: shown, ended: ended)
        }
        // `delivered` is called exactly when the audio was delivered.
        if outcome.delivery == nil { announce(nil, error: outcome.error, kept: outcome.kept, started: shown, ended: ended) }
        lastOutcome = outcome
        return outcome
    }

    /// Where a stopped voice note went: the Live Activity's last state (then
    /// dismissed) and the app's banner. `started` is the activity's (`VoiceNoteActivityState.started`).
    private func announce(_ delivery: Delivery?, error: String?, kept: Bool, started: Date, ended: Date) {
        let result = Self.result(for: delivery)
        endActivity(VoiceNoteActivityState(started: started, result: result, ended: ended), after: result.shownFor)
        show(Notice(result: result, error: result == .failed ? error : nil, kept: result == .failed && kept))
    }

    /// Shows `notice` in the banner; unless it persists, it goes after `result.shownFor` (if not replaced meanwhile).
    private func show(_ notice: Notice) {
        self.notice = notice
        guard !notice.persists else { return }
        let sleep = self.sleep
        Task { [weak self] in
            await sleep(.seconds(notice.result.shownFor))
            if self?.notice?.id == notice.id { self?.notice = nil }
        }
    }

    nonisolated static func result(for delivery: Delivery?) -> VoiceNoteResult {
        switch delivery {
        case .vault: return .savedToInbox
        case .queued: return .savedOnDevice
        case nil: return .failed
        }
    }

    /// Says in the app's banner that a voice note did not start (`start(_:)` after continuing in
    /// the app): kept until it is dismissed, since the app may come to the front only later.
    func announceStartFailure(_ error: Error) {
        show(Notice(result: .failed, kind: .notRecorded, error: describeError(error), persists: true))
    }

    /// Hides the banner's notice (tapped away).
    public func dismissNotice() { notice = nil }

    /// Seals the audio in `segments` as capture `id`, delivers it, transcribes
    /// it on device from the plaintext when the profile says so and delivers
    /// the transcript, then deletes `folder` (the plaintext).
    ///
    /// The folder is deleted only once the sealed audio is in the inbox or
    /// the queue, or when no segment holds any audio (`audioFiles.classify`: not a
    /// byte, or a finished file of no length): a voice note whose
    /// audio was not sealed into an inbox file is never deleted. Everything
    /// else keeps it for the next seal (`sweep()`, at launch and each time
    /// the app becomes active), and the outcome says so
    /// (`kept`): a segment that is there but cannot be opened now
    /// (data protection), a finished segment that does not decode, bytes of
    /// which nothing decodes, a seal or a write that fails. Besides
    /// `segments`, every other `segment-NNN` file in `folder` is sealed too
    /// (`CaptureSegments.files`). Of the segments, the first `finished` (all of them
    /// when nil) are complete; only a later one, the segment being written
    /// when the app died, may be undecodable and is then left out
    /// (docs/attachments.md §13: a crash loses at most that segment).
    func seal(segments listed: [URL], finished: Int? = nil, folder: URL, id: UUID, started: Date, stored: StoredCaptureProfile,
                     delivered: (@MainActor (Delivery) -> Void)? = nil) async -> Outcome {
        var outcome = Outcome(id: id)
        willSeal?(id)
        let background = backgroundTime.begin("Seal voice note") {
            // Out of time: the folder stays. If the app is resumed, this seal
            // finishes and deletes it; if it is terminated, `sweep()` seals it
            // at the next launch. Deleting it here lost a voice note whose
            // merge or seal had not finished.
        }
        var keep = true
        defer {
            if !keep { try? FileManager.default.removeItem(at: folder) }
            background.end()
        }
        do {
            let writer = try CaptureWriter(profile: stored.profile)
            let segments = CaptureSegments.files(listed: listed, in: folder)
            // Throws for a segment that is there but cannot be opened: its audio is not lost, only out of reach now.
            for url in segments where FileManager.default.fileExists(atPath: url.path) {
                try FileHandle(forReadingFrom: url).close()
            }
            var held: [(url: URL, audio: CaptureSegments.Audio)] = []
            for url in segments { held.append((url, await audioFiles.classify(url))) }
            // What may be deleted, what waits and what is sealed: `CaptureSegments.plan`.
            let audio: [URL]
            switch CaptureSegments.plan(held: held, listed: listed, finished: finished) {
            case .nothingRecorded:
                keep = false
                throw CaptureAssemblyError.noAudio
            case .completeSegmentUndecodable(let name):
                throw CaptureAssemblyError.segmentUndecodable(name)
            case .noReadableAudio:
                throw CaptureAssemblyError.noReadableAudio
            case .seal(let urls):
                audio = urls
            }
            let out = folder.appendingPathComponent("capture.m4a")
            try await audioFiles.merge(audio, into: out)
            let title = noteTitle?(started)
            let (sealed, audioRef) = try await Task.detached(priority: .userInitiated) { () throws -> (SealedCapture, BlobRef) in
                let audio = try BoundedRead.contents(of: out, maxBytes: CaptureFile.maxBytes - (1 << 20))
                return (try writer.seal(audio: audio, started: started, info: try? AudioProbe.probe(audio), title: title, id: id),
                        BlobRef(content: audio, type: "audio/mp4"))
            }.value
            let delivery = try deliver(sealed, stored)
            keep = false
            outcome.delivery = delivery
            delivered?(delivery)
            if stored.transcribe, let transcriber {
                do {
                    // Never a model download here (offline it would fail or wait): adoption transcribes it later.
                    let transcript = try await transcriber.transcribe(file: out, recording: CaptureAdoption.ids(for: id).recording,
                                                                      noteLanguage: nil, allowModelDownload: false)
                    _ = try deliver(try writer.seal(transcript: transcript, capture: id, audio: audioRef), stored)
                    outcome.transcribed = true
                } catch {
                    // Transcribed later, once the vault is unlocked (AppModel+Inbox).
                }
            }
        } catch {
            outcome.error = describeError(error)
            outcome.kept = keep
        }
        return outcome
    }

    // MARK: - Delivery

    /// Where sealed voice notes go (`CaptureDelivery`): the vault's inbox through its bookmark or
    /// the store, recorded in this device's ledger, else the queue.
    var delivery: CaptureDelivery {
        CaptureDelivery(queueRoot: queueRoot, vaultStore: vaultStore, bookmarks: bookmarks, ledger: ledger, delivered: { vault in
            // A synced copy runs soon, open or not (`SyncCoordinator.captureDelivered`).
            NotificationCenter.default.post(name: QuickCapture.deliveredNotification, object: nil, userInfo: ["vault": vault])
        })
    }

    /// Writes `sealed` into the vault's inbox, or into the local queue (`CaptureDelivery.deliver`).
    func deliver(_ sealed: SealedCapture, _ stored: StoredCaptureProfile) throws -> Delivery {
        try delivery.deliver(sealed, stored)
    }

    /// Posted (userInfo `vault`: the vault id) when a voice note was written into a vault's inbox.
    public nonisolated static let deliveredNotification = Notification.Name("io.github.anthonytw.sempere.captureDelivered")

    public func queueFolder(_ vault: UUID) -> URL { delivery.queueFolder(vault) }

    /// Captures waiting in the queue of a vault other than the stored profile's: Watch notes of a vault this device
    /// does not hold or has not opened since (`flushQueue(into:…)` moves them when it is opened writable).
    public func queuedForOtherVaults() -> Int {
        delivery.queuedCount(excluding: (try? store.load())?.profile.vaultId)
    }

    /// Moves queued captures of `vaultId` into the vault at `vaultURL` (`CaptureDelivery.flushQueue`), recorded under
    /// the stored profile when it is this vault's; `coordinated`: each write coordinated (`files`, iCloud Drive).
    @discardableResult
    func flushQueue(into vaultURL: URL, vaultId: UUID, coordinated: Bool) -> Int {
        delivery.flushQueue(into: vaultURL, vaultId: vaultId, profile: (try? store.load())?.profile,
                            files: coordinated ? files : nil)
    }

    /// Moves queued captures into the stored profile's vault when its folder
    /// can be reached (the app became active). Returns how many moved;
    /// throws `profileUnreadable` when the profile cannot be read now (the
    /// captures stay queued; unlocking the vault moves them too).
    @discardableResult
    func flushStoredQueue() throws -> Int {
        let stored: StoredCaptureProfile
        do { stored = try storedProfile() } catch QuickCaptureError.notSetUp { return 0 }
        return delivery.flushQueue(of: stored)
    }

    /// Recordings a crash or a failed seal left in `root`: sealed when the
    /// profile is there (no transcript), and deleted only as `seal` allows,
    /// once their audio is in the inbox or the queue (or they hold no byte of
    /// audio). What cannot be read now is not "nothing to recover": a profile
    /// the Keychain will not hand over (a launch before the first unlock after
    /// a reboot) leaves every folder for later, and a manifest that is there
    /// but cannot be read (data protection) leaves its folder. A folder whose
    /// manifest is missing, too large or does not decode is sealed from its
    /// segment files (`CaptureSegments.Leftover`). With no profile at all (quick voice notes
    /// were turned off) nothing can seal them, and they are deleted.
    ///
    /// Runs at launch and each time the app becomes active (a profile the
    /// launch could not read may be readable then); one sweep at a time, so
    /// two never seal the same recording into the same file at once.
    public func sweep() async {
        guard session == nil, !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        guard !dirs.isEmpty else { return }
        let stored: StoredCaptureProfile?
        do { stored = try store.load() } catch { return }
        guard var noTranscript = stored else {
            for dir in dirs { try? fm.removeItem(at: dir) }
            return
        }
        noTranscript.transcribe = false
        for dir in dirs {
            // A manifest that is there but cannot be read now: so are its segments; later.
            guard let leftover = CaptureSegments.Leftover(folder: dir) else { continue }
            // Started under another vault's profile (the user switched since): never sealed into this one. It stays,
            // protected, until quick voice notes are turned off (then the no-profile rule deletes it).
            if let vault = leftover.vault, vault != stored?.profile.vaultId {
                // Said once, rather than skipped silently.
                if let id = leftover.id, reportedKept.insert(id).inserted {
                    show(Notice(result: .failed, kind: .interruptedNotSaved, error: nil, kept: true, persists: true))
                }
                continue
            }
            guard let id = leftover.id else {
                // Not a folder a session made (its name is not an id) and no manifest names one: deleted
                // only when it holds no audio, else left alone rather than sealed under a made-up id.
                if leftover.segments.allSatisfy({ CaptureSegments.byteCount($0) == 0 }) { try? fm.removeItem(at: dir) }
                continue
            }
            let outcome = await seal(segments: leftover.segments, finished: leftover.finished, folder: dir, id: id,
                                     started: leftover.started ?? now(), stored: noTranscript)
            // Said in the app's banner: a voice note a force quit, a crash or a restart cut off is never
            // saved (or kept) without a word.
            if let delivery = outcome.delivery {
                show(Notice(result: Self.result(for: delivery), kind: .interruptedSaved))
            } else if fm.fileExists(atPath: dir.path), reportedKept.insert(id).inserted {
                show(Notice(result: .failed, kind: .interruptedNotSaved, error: outcome.error, kept: outcome.kept, persists: true))
            }
        }
    }

    // MARK: - Live Activity

    /// The stale date of a recording's Live Activity content sent now: `activityStaleAfter` from now while it
    /// records (`keepActivityFresh` moves it on), none once it is saving or done.
    private func staleDate(for recording: Bool) -> Date? {
        recording ? now().addingTimeInterval(activityStaleAfter) : nil
    }

    /// Asks for the recording's Live Activity and says what came of it (the start diagnostics):
    /// the error is kept, never swallowed (TestFlight 1.0.0 (3) and (4) dropped it with `try?`).
    private func startActivity(started: Date) -> VoiceNoteActivityRequest {
        guard showsActivity else { return .notRequested("turned off") }
        guard liveActivity.isSupported else { return .notRequested("no Live Activities on this platform") }
        guard liveActivity.areEnabled else { return .notRequested("Live Activities are off") }
        do {
            // Stale unless the app refreshes it (`keepActivityFresh`): if the app dies, the activity says
            // the recording was interrupted instead of offering a Stop that reaches nothing.
            try liveActivity.request(VoiceNoteActivityState(started: started), staleDate: staleDate(for: true))
            return .started
        } catch {
            return .failed(VoiceNoteErrorInfo(error))
        }
    }

    /// While `s` records, sends the Live Activity its current state again every `activityHeartbeat`, which
    /// moves its stale date on. When the process dies (force quit, crash), the updates stop and the activity
    /// turns stale within `activityStaleAfter`: the widget then shows "interrupted" and opens the app, whose
    /// launch ends it and saves the recording (`endOrphanedActivities`, `sweep`).
    private func keepActivityFresh(for s: any CaptureRecording) {
        let beat = activityHeartbeat, sleep = self.sleep
        Task { [weak self, weak s] in
            while true {
                await sleep(beat)
                guard let self, let s, self.session === s, self.state == .recording, s.isActive else { return }
                let at = self.now()
                let length = s.timeline.audioLength(at: at)
                let paused = self.isPaused
                self.updateActivity(VoiceNoteActivityState(started: at.addingTimeInterval(-length), paused: paused,
                                                           ended: paused ? at : nil))
            }
        }
    }

    /// Shows `state` on the recording's Live Activity (paused, resumed, saving).
    private func updateActivity(_ state: VoiceNoteActivityState) {
        liveActivity.update(state, staleDate: staleDate(for: state.isRecording))
    }

    /// Ends the recording's Live Activity on `state` (where the voice
    /// note went), dismissed `seconds` later.
    private func endActivity(_ state: VoiceNoteActivityState, after seconds: TimeInterval) {
        liveActivity.end(state, dismissal: now().addingTimeInterval(seconds))
    }

    /// Ends every voice note Live Activity that is not this process's recording: one left by a process
    /// that was force quit, crashed or was restarted while recording. Run at launch, each time the app
    /// becomes active and when protected data becomes available (an activity started a moment ago, by a
    /// start in progress, is left alone). Returns how many it ended.
    @discardableResult
    public func endOrphanedActivities(now: Date? = nil) async -> Int {
        await liveActivity.endOrphans(startedBefore: (now ?? self.now()).addingTimeInterval(-Self.orphanGrace))
    }

    /// An activity started less than this long ago may be a start of this process still in progress.
    nonisolated static let orphanGrace: TimeInterval = 10
}
