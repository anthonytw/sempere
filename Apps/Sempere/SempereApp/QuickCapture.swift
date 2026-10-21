import AVFoundation
import Foundation
import Observation
import Security
import Sempere
import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import WidgetKit
#endif

/// What this device keeps for quick voice notes (docs/quick-capture.md):
/// the vault's capture profile (public recipients and the capture key, never
/// the identity or the vault secret), where the vault is, and whether voice
/// notes are transcribed here.
struct StoredCaptureProfile: Codable, Equatable, Sendable {
    var profile: CaptureProfile
    var vaultName: String
    /// Bookmark of the vault folder (`options: []`, as for recent vaults).
    var bookmark: Data
    /// Transcribe voice notes on this device when they stop.
    var transcribe: Bool
}

/// Where the profile lives: the Keychain in the app, memory in tests.
protocol CaptureProfileStore: Sendable {
    func load() throws -> StoredCaptureProfile?
    func save(_ profile: StoredCaptureProfile) throws
    func delete() throws
}

/// One generic-password item, readable after the device's first unlock and
/// on this device only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`):
/// a voice note can start from the Lock Screen, and the item never leaves the
/// device. No biometry: the capture key cannot read anything (docs/quick-capture.md).
struct KeychainCaptureProfileStore: CaptureProfileStore {
    static let service = "io.github.anthonytw.sempere.quick-capture"
    static let account = "profile"

    enum Failure: Error, Equatable { case status(OSStatus) }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() throws -> StoredCaptureProfile? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure.status(status) }
        return try JSONDecoder().decode(StoredCaptureProfile.self, from: data)
    }

    func save(_ profile: StoredCaptureProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                         kSecAttrLabel as String: "Sempere — quick voice notes"]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }
}

/// `CaptureProfileStore` in memory (tests).
final class MemoryCaptureProfileStore: CaptureProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredCaptureProfile?
    func load() throws -> StoredCaptureProfile? { lock.withLock { value } }
    func save(_ profile: StoredCaptureProfile) throws { lock.withLock { value = profile } }
    func delete() throws { lock.withLock { value = nil } }
}

enum QuickCaptureError: Error, Equatable, CustomStringConvertible, CustomLocalizedStringResourceConvertible {
    case notSetUp
    /// A profile may be stored but could not be read (the Keychain before the
    /// first unlock after a restart, or an item that does not decode).
    case profileUnreadable
    case microphoneDenied
    /// iOS ends a recording started by an intent (widget, Control Center, Action
    /// button) that shows no Live Activity, so none starts while they are off.
    case liveActivitiesOff
    case alreadyRecording
    case notRecording
    /// iOS did not start the recording's Live Activity (`Activity.request` threw) while the app was
    /// not in front: an `AudioRecordingIntent` records in the background only while one shows, so the
    /// recorder is not started there (the intent continues in the app instead).
    case liveActivityRefused(String)
    /// The intent could not continue in the app (`continueInForeground` threw: iOS refused, or the
    /// device was not unlocked) after a refused background start.
    case couldNotOpenApp(String)
    /// The device has not been unlocked since it restarted: the profile (and the folder the audio
    /// would go to) cannot be read until then (docs/quick-capture.md "Threat model").
    case beforeFirstUnlock
    /// The microphone permission read as not granted while the app was not in front (a process
    /// Siri or a widget launched, maybe before the first unlock after a restart, which cannot show
    /// the permission prompt): checked again with the app in front instead of refusing. TestFlight
    /// 1.0.0 (6), iPhone: after a restart Siri said Sempere was not allowed to use the microphone.
    case microphoneUnconfirmed

    var description: String {
        switch self {
        case .notSetUp: return String(localized: "Quick Voice Notes is not set up: open Sempere, unlock the vault and turn it on in Settings.")
        case .profileUnreadable: return String(localized: "Quick Voice Notes could not read its settings on this device. Unlock the device and try again; if it keeps happening, turn Quick Voice Notes off and on again in Settings.")
        case .microphoneDenied: return RecordingError.microphoneDenied.description
        case .liveActivitiesOff: return String(localized: "Live Activities are off for Sempere, and iOS needs one to record a voice note: turn them on in the Settings app ▸ Sempere ▸ Live Activities.")
        case .alreadyRecording: return String(localized: "A voice note is already being recorded.")
        case .notRecording: return String(localized: "No voice note is being recorded.")
        case .liveActivityRefused(let why):
            return String(localized: "iOS did not start the voice note's Live Activity, which it needs to record in the background: \(why)")
        case .couldNotOpenApp(let why):
            return String(localized: "iOS would not record in the background and did not open Sempere to record there: \(why)")
        case .beforeFirstUnlock:
            return String(localized: "Unlock this device once after it restarts: until then Sempere cannot record voice notes.")
        case .microphoneUnconfirmed:
            return String(localized: "Sempere could not confirm it may use the microphone without opening. Open Sempere to record.")
        }
    }

    /// What Siri, Shortcuts and the widgets show when an intent fails.
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: description) }
}

/// Quick voice notes (docs/quick-capture.md): one tap (Siri, Shortcuts, the
/// Action button, a widget, Control Center) records; stopping seals the audio
/// with the capture profile alone (`CaptureWriter`: age-encrypted to the
/// vault's recipients and tagged with the capture key), so neither the vault
/// nor the device needs unlocking and no Face ID is asked. The sealed file goes
/// into the vault's `inbox/` (a coordinated write in iCloud Drive), or into a
/// local queue when the vault folder cannot be reached, moved into the vault
/// later. The plaintext audio exists only in protected temporary files
/// (`QuickCapture.protection`: `completeUntilFirstUserAuthentication`, since a
/// voice note started from the Lock Screen is read back from closed files and
/// sealed before any unlock, which `completeUnlessOpen` forbids) and in
/// memory, and is deleted as soon as the capture (and its
/// transcript, made on device from it) is sealed; leftovers from a crash or
/// a failed seal are sealed at the next launch or activation (`sweep`), and
/// never deleted before their audio is sealed. The app adopts inbox
/// captures as notes once the vault is unlocked (`AppModel+Inbox`).
@MainActor
@Observable
final class QuickCapture {
    static let shared = QuickCapture()

    enum State: Equatable { case idle, starting, recording, saving }

    enum Delivery: Equatable, Sendable { case vault, queued }

    /// What one capture did.
    struct Outcome: Equatable {
        var id: UUID
        var delivery: Delivery?
        var transcribed = false
        var error: String?
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { publishStatus() } }
    }
    /// The recording in progress.
    private(set) var session: RecordingSession?
    /// A `sweep()` is running.
    @ObservationIgnored private var sweeping = false
    /// The last capture's outcome.
    private(set) var lastOutcome: Outcome?
    /// Where the last stopped voice note went, while the app's banner shows it
    /// (cleared after `VoiceNoteResult.shownFor`).
    private(set) var notice: Notice?
    /// A place a widget, the control or the Live Activity asked the app to
    /// show (`sempere://quick-voice/…`, `VoiceNoteControlIntent`); the window
    /// that shows it clears it.
    var pendingLink: VoiceNoteLink?

    /// What the banner says after a stop.
    struct Notice: Equatable {
        var result: VoiceNoteResult
        /// Why it failed (`Outcome.error`).
        var error: String?
        /// Shown instead of `result.title` (a start that failed: nothing was recorded to save).
        var title: String?
        /// Stays until dismissed rather than for `result.shownFor`.
        var persists = false
        var id = UUID()
    }

    /// When the recording in progress started.
    var started: Date? { session?.timeline.started }

    /// Whether the recording in progress is paused (a call, a headset unplugged).
    var isPaused: Bool { session.map { $0.state == .interrupted || $0.state == .paused } ?? false }

    /// When the recording in progress would have started had it never paused:
    /// a timer counting from it shows the audio recorded (`audioLength` while paused).
    func timerStart(at now: Date = Date()) -> Date? {
        guard let s = session, s.timeline.started != nil else { return nil }
        return now.addingTimeInterval(-s.timeline.audioLength(at: now))
    }

    /// Seconds of audio recorded so far.
    func audioLength(at now: Date = Date()) -> Double { session?.timeline.audioLength(at: now) ?? 0 }

    @ObservationIgnored var store: any CaptureProfileStore = KeychainCaptureProfileStore()
    @ObservationIgnored var backend: (@MainActor () -> AudioCaptureBackend)?
    @ObservationIgnored var transcriber: (any RecordingTranscribing)? = SpeechRecordingTranscriber()
    @ObservationIgnored var microphoneAllowed: @MainActor () async -> Bool = { await AVAudioCaptureBackend.requestMicrophone() }
    /// The microphone permission's name, for the start diagnostics.
    @ObservationIgnored var microphonePermission: @MainActor () -> String = { QuickCapture.systemMicrophonePermission() }
    /// Whether protected data can be read (false before the first unlock after a restart; tests set it).
    @ObservationIgnored var protectedDataAvailable: @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    /// How long after its last update the recording's Live Activity counts as stale: the app refreshes
    /// it every `activityHeartbeat` while recording, so an activity whose app died (force quit, crash)
    /// shows "interrupted" and an Open button instead of a Stop that reaches nothing.
    @ObservationIgnored var activityStaleAfter: TimeInterval = 120
    @ObservationIgnored var activityHeartbeat: Duration = .seconds(45)
    /// Interrupted recordings a sweep could not save yet that the banner already reported (once per launch).
    @ObservationIgnored private var reportedKept: Set<UUID> = []
    @ObservationIgnored var center: NotificationCenter = .default
    /// Where recordings in progress are (plaintext, protected, deleted once sealed).
    @ObservationIgnored var root = QuickCapture.defaultRoot
    /// Sealed captures waiting for the vault folder, per vault id.
    @ObservationIgnored var queueRoot = QuickCapture.defaultQueueRoot
    /// The in-app vault store (the app sets it at launch): a voice note for a store vault goes straight into
    /// its in-app inbox, found by vault id, open or not (docs/design/device-first-sync.md §5.3).
    @ObservationIgnored var vaultStore: VaultStore?
    /// Starts a Live Activity while recording (off in tests).
    @ObservationIgnored var showsActivity = true
    /// Where the widgets read `VoiceNoteStatus` (the App Group; nil without one, and in tests unless set).
    @ObservationIgnored var statusStore: VoiceNoteStatusStore? = VoiceNoteStatusStore.shared
    /// Whether Live Activities are allowed for the app (Settings ▸ Sempere).
    @ObservationIgnored var activitiesEnabled: @MainActor () -> Bool = QuickCapture.systemActivitiesEnabled
    /// Reloads the widgets and the control after the status changed.
    @ObservationIgnored var reloadSurfaces: @MainActor () -> Void = QuickCapture.reloadSystemSurfaces
    /// The app's state, for the start diagnostics and the decision to wait (tests set it).
    @ObservationIgnored var applicationState: @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState }
    /// How long a start that continued in the app waits for the app to be active before trying again.
    @ObservationIgnored var foregroundWait: Duration = .seconds(12)
    /// Waits, at most the given time, for the app to become active (`AppActivation.wait`; tests send their own signal).
    @ObservationIgnored var waitUntilActive: @MainActor (Duration) async -> Bool = { timeout in
        await AppActivation.wait(timeout: timeout) { UIApplication.shared.applicationState == .active }
    }
    /// Asks for the Live Activity instead of ActivityKit (tests: a request that fails); nil uses ActivityKit.
    @ObservationIgnored var requestActivity: (@MainActor (Date) throws -> Void)?
    /// The last voice-note starts, kept for Settings (`VoiceNoteStartLog`); memory only until `register()`.
    @ObservationIgnored var startLog = VoiceNoteStartLog(url: nil)
    /// `startLog`'s attempts, newest first, for Settings ▸ Quick Voice Notes ▸ Recent Starts (observed through the log).
    var recentStarts: [VoiceNoteStartAttempt] { startLog.attempts }
    /// The last taps on a widget, the control or a voice note shortcut, from the app and the widget
    /// extension (`VoiceNoteTapLog`), newest first; read again by `refreshTaps()`.
    private(set) var recentTaps: [VoiceNoteTap] = []
    /// Called with the capture id as each seal begins (tests).
    @ObservationIgnored var willSeal: (@MainActor (UUID) -> Void)?
    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Every state sent to the Live Activity (tests; also without one).
    @ObservationIgnored var activityStates: (@MainActor (VoiceNoteAttributes.ContentState) -> Void)?
    @ObservationIgnored private var activity: Activity<VoiceNoteAttributes>?
    /// The last update or end sent to `activity`: each waits for the one before
    /// (an end overtaking the "Saving" update would leave the activity saving).
    @ObservationIgnored private var activityWork: Task<Void, Never>?
    #endif

    /// The Data Protection class of recordings in progress. Not `completeUnlessOpen`: its files
    /// cannot be reopened while the device is locked once closed, and a voice note started from
    /// the Lock Screen is assembled, read and sealed from closed segment files before any unlock.
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    nonisolated static var defaultRoot: URL { AppSupport.folder("QuickCapture") }
    nonisolated static var defaultQueueRoot: URL { AppSupport.folder("CaptureQueue") }

    /// Whether a failed start may work with the app in front: the audio system's refusal, which iOS
    /// can give a background start, and a Live Activity iOS would not start in the background
    /// (`start(_:)` then continues in the app).
    static func worksInForeground(_ error: Error) -> Bool {
        if (error as? RecordingError)?.isCannotRecord == true { return true }
        if case .liveActivityRefused = error as? QuickCaptureError { return true }
        if case .microphoneUnconfirmed = error as? QuickCaptureError { return true }
        return false
    }

    /// The container of quick voice notes' segment files: ADTS, whose every frame stands alone, so
    /// a recording cut off by a force quit, a crash or a restart keeps its audio up to the last frame.
    /// MPEG-4 (`m4a`, what in-note recordings use) is unreadable until the recorder finishes the file:
    /// a voice note interrupted by a restart was lost whole (TestFlight 1.0.0 (6), iPhone).
    nonisolated static let segmentExtension = "aac"

    /// The format quick voice notes record in: the recording settings, but AAC for Apple Lossless
    /// (ADTS carries only AAC; `segmentExtension`).
    nonisolated static func captureFormat(_ preferred: RecordingFormat) -> RecordingFormat {
        preferred.codec == .alac ? .default : preferred
    }

    /// Hooks the intents (Siri, Shortcuts, widgets, Control Center) up to the shared instance.
    /// Also ends Live Activities left by an earlier process (killed, crashed or
    /// rebooted while recording): nothing of theirs is recording any more, and
    /// their Stop button would reach a process that knows nothing of them.
    static func register() {
        QuickCapture.shared.startLog = VoiceNoteStartLog(url: VoiceNoteStartLog.defaultURL)
        VoiceNoteActions.open = { QuickCapture.shared.pendingLink = $0 }
        VoiceNoteActions.status = { QuickCapture.shared.status }
        VoiceNoteActions.appState = { QuickCapture.shared.applicationState().diagnosticName }
        VoiceNoteActions.tapRecorded = { _ in QuickCapture.shared.refreshTaps() }
        QuickCapture.shared.refreshTaps()
        VoiceNoteActions.start = { try await QuickCapture.shared.start($0) }
        VoiceNoteActions.stop = {
            do { _ = try await QuickCapture.shared.stop() } catch QuickCaptureError.notRecording {
                // Stop on an orphaned Live Activity: it is gone now (stop ended it); nothing to report.
            }
        }
        let launched = Date()
        Task { await QuickCapture.shared.endOrphanedActivities() }
        // A status left by a process that died while recording would offer a Stop that stops nothing.
        QuickCapture.shared.publishStatus(forceReload: true)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Task {
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                QuickCapture.shared.publishStatus()
            }
        }
        // `Activity.activities` may not list an earlier process's activity yet at launch: one the
        // system reports later, started before this launch, is an orphan too.
        Task.detached {
            for await a in Activity<VoiceNoteAttributes>.activityUpdates
            where a.id != ownedActivity.value && a.content.state.started < launched {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
        // A launch before the first unlock after a restart (Siri, a widget) can read neither the
        // profile nor an interrupted recording: once the device is unlocked, they are sealed. The app
        // need not come to the front for that.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                QuickCapture.shared.startLog.reload()
                QuickCapture.shared.publishStatus(forceReload: true)
                Task {
                    await QuickCapture.shared.sweep()
                    await QuickCapture.shared.endOrphanedActivities()
                }
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
        return VoiceNoteStatus.make(setUp: isSetUp, activitiesEnabled: activitiesEnabled(),
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
    func publishStatus(forceReload: Bool = false) {
        guard let statusStore else { return }
        do {
            if try statusStore.write(status) || forceReload { reloadSurfaces() }
        } catch {
            // The widgets keep their last status; the next change writes again.
        }
    }

    nonisolated static func systemActivitiesEnabled() -> Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return true
        #endif
    }

    static func reloadSystemSurfaces() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        WidgetCenter.shared.reloadTimelines(ofKind: VoiceNoteStatus.widgetKind)
        ControlCenter.shared.reloadControls(ofKind: VoiceNoteStatus.controlKind)
        #endif
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
    var isSetUp: Bool {
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
    func clearDiagnostics() {
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
    func widgetOpenedApp() -> Task<Void, Never> {
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
    func start() async throws {
        try await start(VoiceNoteStartRequest(source: .app))
    }

    /// Starts a voice note for `request` and keeps what happened in `startLog`.
    ///
    /// An intent's start runs in the background. When iOS refuses it there (the audio system's
    /// `cannotRecord`, or no Live Activity: `worksInForeground`), the intent continues in the app
    /// (`request.continueInApp`), this waits until the app is actually active (`waitUntilActive`, at
    /// most `foregroundWait`: from the Lock Screen that is after the unlock) and tries once more. If
    /// that fails too, the banner says so (`announceStartFailure`) and the error goes to the intent.
    /// The retry runs in a task of its own, so it is not cancelled with the intent's.
    func start(_ request: VoiceNoteStartRequest) async throws {
        var attempt = VoiceNoteStartAttempt(date: Date(), source: request.source, intentMode: request.intentMode,
                                            first: VoiceNoteStartTry(appState: applicationState().diagnosticName))
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
            if foreground.error != nil, applicationState() != .active {
                // iOS would not bring the app forward (or the user did not unlock): nothing to wait for.
                attempt.foreground = foreground
                startLog.append(attempt)
                let error = QuickCaptureError.couldNotOpenApp(foreground.error?.description ?? "")
                announceStartFailure(error)
                throw error
            }
            foreground.becameActive = await waitUntilActive(foregroundWait)
            let waited = clock.now - asked
            foreground.waited = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
            attempt.foreground = foreground
            var retry = VoiceNoteStartTry(appState: applicationState().diagnosticName)
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
        let unlocked = protectedDataAvailable()
        trace.protectedData = unlocked
        do { _ = try storedProfile() } catch QuickCaptureError.profileUnreadable where !unlocked {
            throw QuickCaptureError.beforeFirstUnlock
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if showsActivity, !activitiesEnabled() { throw QuickCaptureError.liveActivitiesOff }
        #endif
        let allowed = await microphoneAllowed()
        trace.microphone = microphonePermission()
        if !allowed {
            // In front the answer is the user's (and the prompt can show); in a process an intent launched
            // in the background it may be neither (TestFlight 1.0.0 (6): Siri after a restart).
            throw applicationState() == .active ? QuickCaptureError.microphoneDenied : QuickCaptureError.microphoneUnconfirmed
        }
        // Nothing records here yet, so any Live Activity still shown is an orphan.
        await Self.endActivities(startedBefore: .distantFuture)
        // The audio session first, while the intent's fake-foreground assertion still holds: iOS ends that
        // assertion the moment the Live Activity begins, and a non-mixable session activated after it is
        // refused ('!int' cannotInterruptOthers; iPhone, iOS 27.0.1, TestFlight 1.0.0 (6), unified log).
        let capture: AudioCaptureBackend = backend?() ?? AVAudioCaptureBackend()
        trace.session = try await activateSession(capture)
        // Read back and sealed on stop, often with the device still locked: `completeUnlessOpen`
        // files cannot be reopened then once closed, so `Self.protection` (readable after the first unlock).
        // ADTS segments (`segmentExtension`): a recording cut off by a restart keeps its audio.
        let s = RecordingSession(noteID: UUID(), format: Self.captureFormat(RecordingPreference.format()), root: root,
                                 protection: Self.protection, segmentExtension: Self.segmentExtension,
                                 backend: capture, center: center)
        // Ended by the system (media services reset, no new segment file): sealed as after Stop.
        s.onStoppedBySystem = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            Task { _ = try? await self.finish(s) }
        }
        // Then the Live Activity, before the recorder. `AudioRecordingIntent`: "you must start a Live Activity
        // when you begin the audio recording … If you don't start a Live Activity, the audio recording stops",
        // and only a `LiveActivityIntent` may start one from the background (`Activity.request`). Its result
        // goes to the start diagnostics; with the app in the background a failed request ends the try here.
        let request = startActivity(started: Date())
        trace.activity = request
        if case .failed(let why) = request, applicationState() != .active {
            // No Live Activity, no background recording (`AudioRecordingIntent`): the app continues in front.
            capture.deactivate()
            throw QuickCaptureError.liveActivityRefused(why.summary)
        }
        do {
            try s.start()
        } catch {
            endActivity(.init(started: Date(), result: .failed, ended: Date()), after: 0)
            capture.deactivate()
            throw error
        }
        session = s
        state = .recording
        started = true
        if let begun = s.timeline.started { updateActivity(.init(started: begun)) }
        followPauses(of: s, paused: false)
        keepActivityFresh(for: s)
    }

    /// Makes the audio session active for a start (`startRecorderOnce`), not mixable; when iOS refuses that
    /// with the app not in front, mixable (it interrupts no one). Returns how, for the diagnostics; throws the
    /// first refusal when both fail (`worksInForeground`: the intent then continues in the app).
    private func activateSession(_ capture: AudioCaptureBackend) async throws -> String {
        do {
            try await capture.activateSession(mixable: false)
            return "not mixable"
        } catch {
            let refused = error
            guard applicationState() != .active else { throw refused }
            do { try await capture.activateSession(mixable: true) } catch { throw refused }
            return "mixable after a refusal (\(VoiceNoteErrorInfo(refused).description))"
        }
    }

    /// Shows on the Live Activity and the widgets when `s` pauses (an
    /// interruption) and resumes: the timer stands still meanwhile, as the audio does.
    private func followPauses(of s: RecordingSession, paused: Bool) {
        withObservationTracking {
            _ = s.state
        } onChange: { [weak self, weak s] in
            Task { @MainActor in
                guard let self, let s, self.session === s, self.state == .recording, s.isActive else { return }
                let pausedNow = self.isPaused
                if pausedNow != paused {
                    let at = Date()
                    let length = s.timeline.audioLength(at: at)
                    self.updateActivity(.init(started: at.addingTimeInterval(-length), paused: pausedNow, ended: pausedNow ? at : nil))
                    self.publishStatus()
                }
                self.followPauses(of: s, paused: pausedNow)
            }
        }
    }

    /// Stops the voice note and seals it (and its transcript, when that is on).
    @discardableResult
    func stop() async throws -> Outcome {
        guard let s = session, s.isActive else {
            // Stop pressed on a Live Activity this process did not start (the app was force quit, crashed or
            // restarted while recording): end it, and save what that recording left (`sweep`).
            if state == .idle {
                await Self.endActivities(startedBefore: .distantFuture)
                await sweep()
            }
            throw QuickCaptureError.notRecording
        }
        s.stop()
        return try await finish(s)
    }

    /// Seals a stopped session (`stop`, or the system ended it).
    private func finish(_ s: RecordingSession) async throws -> Outcome {
        guard session === s, state == .recording else { throw QuickCaptureError.notRecording }
        let started = s.timeline.started ?? Date(), ended = Date()
        // The Live Activity shows the length of the audio, without the pauses.
        let shown = ended.addingTimeInterval(-s.timeline.audioLength(at: ended))
        state = .saving
        updateActivity(.init(started: shown, saving: true, ended: ended))
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
            announce(nil, error: QuickCaptureError.notSetUp.description, started: shown, ended: ended)
            throw QuickCaptureError.notSetUp
        } catch {
            // The profile may still be there: the recording waits for `sweep()`.
            announce(nil, error: "\(QuickCaptureError.profileUnreadable.description) \(Self.keptOnDevice)", started: shown, ended: ended)
            throw QuickCaptureError.profileUnreadable
        }
        let outcome = await seal(segments: s.segments, folder: s.folder, id: s.id, started: started, stored: stored) { [weak self] delivery in
            // Said as soon as the audio is in the inbox (or the queue), not after the transcript.
            self?.announce(delivery, error: nil, started: shown, ended: ended)
        }
        // `delivered` is called exactly when the audio was delivered.
        if outcome.delivery == nil { announce(nil, error: outcome.error, started: shown, ended: ended) }
        lastOutcome = outcome
        return outcome
    }

    /// Where a stopped voice note went: the Live Activity's last state (then
    /// dismissed) and the app's banner. `started` is the activity's (`ContentState.started`).
    private func announce(_ delivery: Delivery?, error: String?, started: Date, ended: Date) {
        let result = Self.result(for: delivery)
        endActivity(.init(started: started, result: result, ended: ended), after: result.shownFor)
        let notice = Notice(result: result, error: result == .failed ? error : nil)
        self.notice = notice
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(result.shownFor))
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
        notice = Notice(result: .failed, error: "\(error)",
                        title: String(localized: "Voice Note Not Recorded", comment: "Banner title: a quick voice note could not start"),
                        persists: true)
    }

    /// Hides the banner's notice (tapped away).
    func dismissNotice() { notice = nil }

    /// "Voice note 7 Oct 2026 at 14:32" in this device's language (the CLI
    /// writes `CaptureWriter.defaultTitle`'s fixed form instead).
    nonisolated static func title(_ started: Date) -> String {
        String(localized: "Voice note \(started.formatted(date: .abbreviated, time: .shortened))",
               comment: "Default title of a quick-capture voice note: its start date and time")
    }

    /// Seals the audio in `segments` as capture `id`, delivers it, transcribes
    /// it on device from the plaintext when the profile says so and delivers
    /// the transcript, then deletes `folder` (the plaintext).
    ///
    /// The folder is deleted only once the sealed audio is in the inbox or
    /// the queue, or when no segment holds any audio (`segmentAudio`: not a
    /// byte, or a finished file of no length): a voice note whose
    /// audio was not sealed into an inbox file is never deleted. Everything
    /// else keeps it for the next seal (`sweep()`, at launch and each time
    /// the app becomes active), and the outcome's error says so
    /// (`keptOnDevice`): a segment that is there but cannot be opened now
    /// (data protection), a finished segment that does not decode, bytes of
    /// which nothing decodes, a seal or a write that fails. Besides
    /// `segments`, every other `segment-NNN.m4a` in `folder` is sealed too
    /// (`segmentFiles`). Of the segments, the first `finished` (all of them
    /// when nil) are complete; only a later one, the segment being written
    /// when the app died, may be undecodable and is then left out
    /// (docs/attachments.md §13: a crash loses at most that segment).
    func seal(segments listed: [URL], finished: Int? = nil, folder: URL, id: UUID, started: Date, stored: StoredCaptureProfile,
              delivered: (@MainActor (Delivery) -> Void)? = nil) async -> Outcome {
        var outcome = Outcome(id: id)
        willSeal?(id)
        let background = BackgroundWork.begin(name: "Seal voice note") {
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
            let segments = Self.segmentFiles(listed: listed, in: folder)
            // Throws for a segment that is there but cannot be opened: its audio is not lost, only out of reach now.
            for url in segments where FileManager.default.fileExists(atPath: url.path) {
                try FileHandle(forReadingFrom: url).close()
            }
            var held: [(url: URL, audio: SegmentAudio)] = []
            for url in segments { held.append((url, await Self.segmentAudio(url))) }
            if held.allSatisfy({ $0.audio == .none }) {
                // Not a byte recorded, or only finished files of no length (stopped, or the app died,
                // before the recorder wrote any audio): nothing to keep.
                keep = false
                throw RecordingError.cannotAssemble("no audio")
            }
            let complete = Set(listed.prefix(max(0, finished ?? listed.count)).map(\.lastPathComponent))
            // A complete segment that does not decode is not skipped: sealing the others and deleting
            // the folder would lose its audio. It waits, as an unreadable one does.
            if let bad = held.first(where: { $0.audio == .undecodable && complete.contains($0.url.lastPathComponent) }) {
                throw RecordingError.cannotAssemble("\(bad.url.lastPathComponent) does not decode")
            }
            // Bytes of which nothing decodes (the app died in the first segment) are kept too.
            let audio = held.filter { $0.audio == .audio }.map(\.url)
            guard !audio.isEmpty else { throw RecordingError.cannotAssemble("no readable audio") }
            let out = folder.appendingPathComponent("capture.m4a")
            try await RecordingAssembly.merge(audio, into: out)
            let (sealed, audioRef) = try await Task.detached(priority: .userInitiated) { () throws -> (SealedCapture, BlobRef) in
                let audio = try BoundedRead.contents(of: out, maxBytes: CaptureFile.maxBytes - (1 << 20))
                return (try writer.seal(audio: audio, started: started, info: try? AudioProbe.probe(audio),
                                        title: QuickCapture.title(started), id: id),
                        BlobRef(content: audio, type: "audio/mp4"))
            }.value
            let delivery = try deliver(sealed, stored)
            keep = false
            outcome.delivery = delivery
            delivered?(delivery)
            if stored.transcribe, let transcriber {
                do {
                    let transcript = try await transcriber.transcribe(file: out, recording: CaptureAdoption.ids(for: id).recording,
                                                                      noteLanguage: nil)
                    _ = try deliver(try writer.seal(transcript: transcript, capture: id, audio: audioRef), stored)
                    outcome.transcribed = true
                } catch {
                    // Transcribed later, once the vault is unlocked (AppModel+Inbox).
                }
            }
        } catch {
            outcome.error = keep ? "\(error) \(Self.keptOnDevice)" : "\(error)"
        }
        return outcome
    }

    /// The segment files of a recording folder, in order: those `listed`
    /// (the session's, or its manifest's), then every other
    /// `segment-NNN.m4a` in `folder` by number. A segment begun just before
    /// the app died may be missing from the manifest (its write failed or had
    /// not happened yet); sealing without it and deleting the folder would
    /// lose its audio.
    nonisolated static func segmentFiles(listed: [URL], in folder: URL) -> [URL] {
        let names = Set(listed.map(\.lastPathComponent))
        let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let extra = present.compactMap { name -> (Int, String)? in
            guard !names.contains(name), let n = segmentNumber(name) else { return nil }
            return (n, name)
        }.sorted { $0.0 < $1.0 }
        return listed + extra.map { folder.appendingPathComponent($0.1) }
    }

    /// The number of a segment file name (`segment-007.aac` or, from build 6 and
    /// earlier, `segment-007.m4a` is 7, as `RecordingSession` names them); nil for any other name.
    nonisolated static func segmentNumber(_ name: String) -> Int? {
        guard name.hasPrefix("segment-"), name.hasSuffix(".m4a") || name.hasSuffix(".aac") else { return nil }
        let digits = name.dropFirst("segment-".count).dropLast(".m4a".count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// What a segment file holds, for `seal`.
    enum SegmentAudio: Equatable {
        /// No byte, or a file AVFoundation reads whose audio track is zero
        /// seconds long (a segment stopped before its first frame): nothing to keep.
        case none
        /// Audio of some length (`RecordingAssembly.readable`).
        case audio
        /// Bytes AVFoundation cannot read as audio (unfinished by a crash, or damaged).
        case undecodable
    }

    /// Classifies the segment at `url`. Only a file AVFoundation positively
    /// reads as an audio track of no length is `.none` with bytes in it:
    /// anything it cannot read is `.undecodable`, which `seal` never deletes.
    nonisolated static func segmentAudio(_ url: URL) async -> SegmentAudio {
        guard byteCount(url) > 0 else { return .none }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.seconds > 0 { return .audio }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return .undecodable }
        for track in tracks {
            guard let range = try? await track.load(.timeRange), range.duration.isValid, range.duration.seconds == 0 else {
                return .undecodable
            }
        }
        return .none
    }

    /// The size of the file at `url` (0 when it is missing).
    nonisolated static func byteCount(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Added to a failed seal's error when the recording was kept.
    nonisolated static var keptOnDevice: String {
        String(localized: "The recording is kept on this device, and Sempere tries again to save it each time it opens.",
               comment: "Added after the reason a voice note could not be saved")
    }

    // MARK: - Delivery

    /// Writes `sealed` into the vault's inbox, or into the local queue when
    /// the vault folder cannot be reached, is not the profile's vault, or is
    /// read-only (a newer format: this version writes nothing into its
    /// `inbox/`, format.md §7.3; security review 2026-10, N2).
    func deliver(_ sealed: SealedCapture, _ stored: StoredCaptureProfile) throws -> Delivery {
        if let url = vaultFolder(stored) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if Self.acceptsCaptures(at: url, vaultId: stored.profile.vaultId) {
                let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
                do {
                    try CaptureWriter.store(sealed, in: inbox)
                    // A synced copy runs soon, open or not (`SyncCoordinator.captureDelivered`).
                    NotificationCenter.default.post(name: Self.deliveredNotification, object: nil,
                                                    userInfo: ["vault": stored.profile.vaultId])
                    return .vault
                } catch {
                    // Not reachable now: queued below.
                }
            }
        }
        try CaptureWriter.store(sealed, in: queueFolder(stored.profile.vaultId))
        return .queued
    }

    /// True when the folder at `url` is vault `vaultId` and this version may
    /// write into its inbox: not one marked as written by a newer version
    /// (its `format` or `features`, format.md §7.3). Checked from `vault.json`
    /// alone, without a key.
    nonisolated static func acceptsCaptures(at url: URL, vaultId: UUID) -> Bool {
        guard let vault = try? Vault.open(at: url) else { return false }
        return vault.vaultId == vaultId && !vault.isReadOnly
    }

    /// Posted (userInfo `vault`: the vault id) when a voice note was written into a vault's inbox.
    nonisolated static let deliveredNotification = Notification.Name("io.github.anthonytw.sempere.captureDelivered")

    func queueFolder(_ vault: UUID) -> URL { queueRoot.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true) }

    /// The folder of the profile's vault: its in-app copy when the store holds it (found by id, so a moved
    /// store or a stale bookmark does not matter), else the folder its bookmark names.
    func vaultFolder(_ stored: StoredCaptureProfile) -> URL? {
        vaultStore?.entry(id: stored.profile.vaultId)?.url ?? Self.resolve(stored.bookmark)
    }

    /// The vault folder a bookmark names (nil when it cannot be resolved).
    nonisolated static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Moves queued captures of `vaultId` into the vault at `vaultURL`
    /// (sealed already: plain file moves). Returns how many moved. Nothing
    /// moves into a read-only vault (format.md §7.3): they stay queued.
    @discardableResult
    func flushQueue(into vaultURL: URL, vaultId: UUID, coordinated: Bool) -> Int {
        guard Self.acceptsCaptures(at: vaultURL, vaultId: vaultId) else { return 0 }
        let dir = queueFolder(vaultId)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { CaptureFile.parse(name: $0) != nil }
        let inbox = vaultURL.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        var moved = 0
        for name in names {
            let file = dir.appendingPathComponent(name)
            guard let kind = CaptureFile.parse(name: name)?.kind,
                  let data = try? BoundedRead.contents(of: file, maxBytes: CaptureFile.maxSealedBytes(kind)) else { continue }
            do {
                try CloudVault.coordinatedWrite(coordinated ? inbox : nil) {
                    try CaptureWriter.store(SealedCapture(name: name, data: data), in: inbox)
                }
                try? FileManager.default.removeItem(at: file)
                moved += 1
            } catch {
                continue
            }
        }
        return moved
    }

    /// Moves queued captures into the stored profile's vault when its folder
    /// can be reached (the app became active). Returns how many moved;
    /// throws `profileUnreadable` when the profile cannot be read now (the
    /// captures stay queued; unlocking the vault moves them too).
    @discardableResult
    func flushStoredQueue() throws -> Int {
        let stored: StoredCaptureProfile
        do { stored = try storedProfile() } catch QuickCaptureError.notSetUp { return 0 }
        guard let url = vaultFolder(stored) else { return 0 }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let moved = flushQueue(into: url, vaultId: stored.profile.vaultId, coordinated: false)
        if moved > 0 {
            NotificationCenter.default.post(name: Self.deliveredNotification, object: nil,
                                            userInfo: ["vault": stored.profile.vaultId])
        }
        return moved
    }

    /// Recordings a crash or a failed seal left in `root`: sealed when the
    /// profile is there (no transcript), and deleted only as `seal` allows,
    /// once their audio is in the inbox or the queue (or they hold no byte of
    /// audio). What cannot be read now is not "nothing to recover": a profile
    /// the Keychain will not hand over (a launch before the first unlock after
    /// a reboot) leaves every folder for later, and a manifest that is there
    /// but cannot be read (data protection) leaves its folder. A folder whose
    /// manifest is missing, too large or does not decode is sealed from its
    /// segment files (`Leftover`). With no profile at all (quick voice notes
    /// were turned off) nothing can seal them, and they are deleted.
    ///
    /// Runs at launch and each time the app becomes active (a profile the
    /// launch could not read may be readable then); one sweep at a time, so
    /// two never seal the same recording into the same file at once.
    func sweep() async {
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
            guard let leftover = Leftover(folder: dir) else { continue }
            guard let id = leftover.id else {
                // Not a folder a session made (its name is not an id) and no manifest names one: deleted
                // only when it holds no audio, else left alone rather than sealed under a made-up id.
                if leftover.segments.allSatisfy({ Self.byteCount($0) == 0 }) { try? fm.removeItem(at: dir) }
                continue
            }
            let outcome = await seal(segments: leftover.segments, finished: leftover.finished, folder: dir, id: id,
                                     started: leftover.started ?? Date(), stored: noTranscript)
            // Said in the app's banner: a voice note a force quit, a crash or a restart cut off is never
            // saved (or kept) without a word.
            if let delivery = outcome.delivery {
                let saved = Notice(result: Self.result(for: delivery), error: nil,
                                   title: String(localized: "Interrupted Voice Note Saved",
                                                 comment: "Banner title: a voice note cut off by a restart or a force quit was saved"))
                notice = saved
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(saved.result.shownFor))
                    if self?.notice?.id == saved.id { self?.notice = nil }
                }
            } else if fm.fileExists(atPath: dir.path), reportedKept.insert(id).inserted {
                notice = Notice(result: .failed, error: outcome.error,
                                title: String(localized: "Interrupted Voice Note Not Saved Yet",
                                              comment: "Banner title: a voice note cut off by a restart is kept on the device for now"),
                                persists: true)
            }
        }
    }

    /// What a recording folder left in `root` holds, from its manifest when
    /// it can be read, else from its files: a session's folder is named by
    /// its recording id, and its segments by number (`segmentFiles`). Without
    /// a manifest every segment but the last counts as complete.
    struct Leftover: Equatable {
        var id: UUID?
        var segments: [URL]
        var finished: Int?
        var started: Date?

        static let maxManifestBytes = 1 << 20

        /// Nil when the manifest is there but cannot be read now.
        init?(folder: URL) {
            let fm = FileManager.default
            let url = folder.appendingPathComponent(RecordingRecovery.manifestName)
            var manifest: RecordingManifest?
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
            if let size, size <= Self.maxManifestBytes {
                guard let data = try? BoundedRead.contents(of: url, maxBytes: Self.maxManifestBytes) else { return nil }
                manifest = try? JSONDecoder().decode(RecordingManifest.self, from: data)
            }
            // Only names a session gives its segments: never a path out of the folder.
            let listed = (manifest?.segments ?? []).filter { QuickCapture.segmentNumber($0) != nil }
                .map { folder.appendingPathComponent($0) }
            segments = QuickCapture.segmentFiles(listed: listed, in: folder)
            if let manifest {
                id = manifest.recording
                finished = min(max(0, manifest.finished), listed.count)
                started = manifest.started
            } else {
                id = UUID(uuidString: folder.lastPathComponent)
                finished = max(0, segments.count - 1)
                started = segments.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.creationDate] as? Date }.min()
            }
        }
    }
    // MARK: - Live Activity

    /// The stale date of a recording's Live Activity content sent now: `activityStaleAfter` from now while it
    /// records (`keepActivityFresh` moves it on), none once it is saving or done.
    private func staleDate(for recording: Bool) -> Date? {
        recording ? Date().addingTimeInterval(activityStaleAfter) : nil
    }

    /// Asks for the recording's Live Activity and says what came of it (the start diagnostics):
    /// the error is kept, never swallowed (TestFlight 1.0.0 (3) and (4) dropped it with `try?`).
    private func startActivity(started: Date) -> VoiceNoteActivityRequest {
        guard showsActivity else { return .notRequested("turned off") }
        if let requestActivity {
            do {
                try requestActivity(started)
                return .started
            } catch {
                return .failed(VoiceNoteErrorInfo(error))
            }
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard activitiesEnabled() else { return .notRequested("Live Activities are off") }
        do {
            // Stale unless the app refreshes it (`keepActivityFresh`): if the app dies, the activity says
            // the recording was interrupted instead of offering a Stop that reaches nothing.
            let a = try Activity.request(attributes: VoiceNoteAttributes(),
                                         content: .init(state: .init(started: started), staleDate: staleDate(for: true)))
            activity = a
            ownedActivity.value = a.id
            return .started
        } catch {
            return .failed(VoiceNoteErrorInfo(error))
        }
        #else
        return .notRequested("no Live Activities on this platform")
        #endif
    }

    /// While `s` records, sends the Live Activity its current state again every `activityHeartbeat`, which
    /// moves its stale date on. When the process dies (force quit, crash), the updates stop and the activity
    /// turns stale within `activityStaleAfter`: the widget then shows "interrupted" and opens the app, whose
    /// launch ends it and saves the recording (`endOrphanedActivities`, `sweep`).
    private func keepActivityFresh(for s: RecordingSession) {
        let beat = activityHeartbeat
        Task { [weak self, weak s] in
            while true {
                try? await Task.sleep(for: beat)
                guard let self, let s, self.session === s, self.state == .recording, s.isActive else { return }
                let at = Date()
                let length = s.timeline.audioLength(at: at)
                let paused = self.isPaused
                self.updateActivity(.init(started: at.addingTimeInterval(-length), paused: paused, ended: paused ? at : nil))
            }
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Shows `state` on the recording's Live Activity (paused, resumed, saving).
    private func updateActivity(_ state: VoiceNoteAttributes.ContentState) {
        activityStates?(state)
        guard let id = activity?.id else { return }
        let previous = activityWork
        let stale = staleDate(for: state.isRecording)
        // `Activity` is not Sendable: reach it by id from a nonisolated task.
        activityWork = Task.detached {
            await previous?.value
            for a in Activity<VoiceNoteAttributes>.activities where a.id == id {
                await a.update(ActivityContent(state: state, staleDate: stale))
            }
        }
    }

    /// Ends the recording's Live Activity on `state` (where the voice note
    /// went), dismissed `seconds` later.
    private func endActivity(_ state: VoiceNoteAttributes.ContentState, after seconds: TimeInterval) {
        activityStates?(state)
        guard let id = activity?.id else { return }
        activity = nil
        let dismissal = Date().addingTimeInterval(seconds)
        let previous = activityWork
        activityWork = Task.detached {
            await previous?.value
            for a in Activity<VoiceNoteAttributes>.activities where a.id == id {
                await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(dismissal))
            }
            if ownedActivity.value == id { ownedActivity.value = nil }
        }
    }
    #else
    private struct ActivityState {
        init(started: Date, paused: Bool = false, saving: Bool? = nil, result: VoiceNoteResult? = nil, ended: Date? = nil) {}
    }
    private func updateActivity(_ state: ActivityState) {}
    private func endActivity(_ state: ActivityState, after seconds: TimeInterval) {}
    #endif

    /// Ends every voice note Live Activity that is not this process's recording: one left by a process
    /// that was force quit, crashed or was restarted while recording. Run at launch, each time the app
    /// becomes active and when protected data becomes available (an activity started a moment ago, by a
    /// start in progress, is left alone). Returns how many it ended.
    @discardableResult
    func endOrphanedActivities(now: Date = Date()) async -> Int {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let recent = now.addingTimeInterval(-Self.orphanGrace)
        return await Task.detached { () -> Int in
            var ended = 0
            for a in Activity<VoiceNoteAttributes>.activities
            where a.id != ownedActivity.value && a.content.state.started < recent {
                await a.end(nil, dismissalPolicy: .immediate)
                ended += 1
            }
            return ended
        }.value
        #else
        return 0
        #endif
    }

    /// An activity started less than this long ago may be a start of this process still in progress.
    nonisolated static let orphanGrace: TimeInterval = 10

    /// Ends every voice note Live Activity that started before `cutoff`.
    nonisolated static func endActivities(startedBefore cutoff: Date) async {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        await Task.detached {
            for a in Activity<VoiceNoteAttributes>.activities where a.content.state.started < cutoff {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            ownedActivity.value = nil
        }.value
        #endif
    }

    /// `AVAudioApplication`'s record permission, named for the diagnostics.
    nonisolated static func systemMicrophonePermission() -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }
}

/// The id of this process's recording's Live Activity (nil when none): every other voice note activity is
/// an orphan (`QuickCapture.endOrphanedActivities`). Read from nonisolated tasks, so behind a lock.
final class OwnedActivityID: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    var value: String? {
        get { lock.withLock { id } }
        set { lock.withLock { id = newValue } }
    }
}

let ownedActivity = OwnedActivityID()

/// A background-time assertion while a voice note is sealed (the app may
/// have been launched by an intent, or sent to the background meanwhile).
@MainActor
final class BackgroundWork {
    private var id = UIBackgroundTaskIdentifier.invalid

    static func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundWork {
        let work = BackgroundWork()
        work.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak work] in
            MainActor.assumeIsolated {
                expired()
                work?.end()
            }
        }
        return work
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
