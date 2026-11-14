import Age
import Foundation
import Observation
import Sempere
import SempereCapture
import SempereCaptureShared
import WatchKit

// The watch app's one screen and what drives it (docs/design/1.1-watch.md §3.5 to §3.7): a profile from the iPhone, a
// recording over `WatchRecorder`, the outbox, and the hand-off. No vault, no vault key and no device key is here. The
// WatchConnectivity side is `WatchTransport` (`WatchConnectivityClient`; nothing in a simulator test).

/// What the watch asks of WatchConnectivity.
@MainActor
protocol WatchTransport: AnyObject {
    func activate()
    /// Whether the session is activated: before that nothing can be queued, and nothing counts as a failed transfer.
    var isActivated: Bool { get }
    /// Asks the phone for the profile (`transferUserInfo`, queued; wakes the phone app in the background), with the counter
    /// the watch holds. False when it could not be queued (the session is not activated yet): the caller asks again.
    func requestProvisioning(recipient: String, seq: Int) -> Bool
    /// Hands a sealed outbox file over (`transferFile`); false when it could not be queued.
    func transfer(file: URL, meta: WatchTransferMeta) -> Bool
    /// Ids whose file transfer the system still holds (so a launch does not queue them twice).
    var pendingTransfers: Set<UUID> { get }
}

/// A transport that does nothing (tests, simulator runs without a phone).
@MainActor
final class NoWatchTransport: WatchTransport {
    private(set) var requests: [String] = []
    private(set) var sent: [WatchTransferMeta] = []
    var accepts = true
    /// A session that is not activated yet queues nothing (tests set it false, then true).
    var activated = true
    private(set) var requestSeqs: [Int] = []
    var isActivated: Bool { activated }
    func activate() {}
    func requestProvisioning(recipient: String, seq: Int) -> Bool {
        guard activated else { return false }
        requests.append(recipient)
        requestSeqs.append(seq)
        return true
    }
    func transfer(file: URL, meta: WatchTransferMeta) -> Bool {
        guard accepts, activated else { return false }
        sent.append(meta)
        return true
    }
    var pendingTransfers: Set<UUID> { [] }
}

/// Why a voice note cannot start now: always shown, never silence.
enum WatchCannotRecord: Equatable {
    case microphoneDenied
    case outboxFull
    case lowStorage
    case failed(String)
}

/// The one screen's states.
enum WatchScreen: Equatable {
    case notSetUp
    case ready
    case recording
    case saving
    case saved(WatchSavedNote)
    case cannotRecord(WatchCannotRecord)
}

/// Everything the model needs from the platform.
struct WatchEnvironment {
    var secrets: any WatchSecretStore
    var audio: any CaptureAudio
    var transport: any WatchTransport
    /// Holds `Capture/` (recordings in progress) and `Outbox/`.
    var support: URL
    var statusStore: VoiceNoteStatusStore?
    var freeBytes: @MainActor () -> Int64? = { WatchStorage.freeBytes() }
    var haptic: @MainActor (WatchHaptic) -> Void = { WatchHaptic.play($0) }
    var reloadWidgets: @MainActor () -> Void = {}
    var outboxLimits = WatchOutbox.Limits()
    var now: @MainActor () -> Date = { Date() }
}

enum WatchHaptic { case start, stop }

enum WatchStorage {
    /// The free space on the watch, or nil when it cannot be read. An `Int64` through `NSNumber`: the watch's `Int` may be 32 bits.
    static func freeBytes() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    static var support: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("SempereWatch", isDirectory: true)
    }
}

extension WatchHaptic {
    @MainActor static func play(_ h: WatchHaptic) {
        WKInterfaceDevice.current().play(h == .start ? .start : .stop)
    }
}

@MainActor
@Observable
final class WatchModel {
    private(set) var screen: WatchScreen = .notSetUp
    /// The vault's name, for "Saving to …".
    private(set) var vaultName: String?
    /// Notes saved on the watch that the iPhone has not acknowledged.
    private(set) var unsent = 0
    /// A line for diagnostics (the system's text of a refusal), never shown as the screen's words.
    private(set) var diagnostics: String?
    /// Seconds recorded, refreshed while recording.
    private(set) var elapsed: Double = 0
    /// When the timer reads zero (audio-adjusted), and whether it stands still (paused).
    private(set) var timerStart: Date?
    private(set) var paused = false
    /// The "Saved" that is up stays until the app goes to the background (the watch face comes back, or the crown is
    /// pressed), with no buttons: the recording was started from a surface (the complication, the Control, Siri), so the
    /// app has done its one job (owner, build 67). watchOS has no supported way for an app to close itself. A recording
    /// that ends while the app is already in the background gets the usual timed Saved.
    private(set) var savedStays = false

    @ObservationIgnored private let env: WatchEnvironment
    @ObservationIgnored private let secrets: WatchSecrets
    @ObservationIgnored let outbox: WatchOutbox
    @ObservationIgnored private(set) var recorder: WatchRecorder!
    @ObservationIgnored private var identity: NativeIdentity?
    @ObservationIgnored private(set) var state: WatchProfileState
    /// The stored state could not be read (the Keychain before the first unlock): the empty state is a stand-in, not "no
    /// profile", so nothing is deleted on its account, and it is read again at activation.
    @ObservationIgnored private(set) var stateUnreadable = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private(set) var savedTask: Task<Void, Never>?
    @ObservationIgnored private var requested = false
    /// The recording in progress was started from a surface (`startFromSurface`).
    @ObservationIgnored private var surfaceStart = false
    /// The app is not in the background (`enteredForeground`/`enteredBackground`, from the scene phase).
    @ObservationIgnored private var inForeground = true
    /// How long "Saved" stays up.
    @ObservationIgnored var savedDuration: Duration = .seconds(2)
    /// How "Saved" waits out `savedDuration`; tests replace it with a timer they fire by hand.
    @ObservationIgnored var savedWait: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    init(environment: WatchEnvironment) throws {
        env = environment
        secrets = WatchSecrets(store: environment.secrets)
        outbox = try WatchOutbox(directory: environment.support.appendingPathComponent("Outbox", isDirectory: true),
                                 limits: environment.outboxLimits, now: { Date() })
        let loaded = try? WatchSecrets(store: environment.secrets).loadState()
        state = loaded ?? WatchProfileState()
        stateUnreadable = loaded == nil
        recorder = WatchRecorder(audio: environment.audio, outbox: outbox, profile: { [weak self] in self?.state.payload },
                                 root: environment.support.appendingPathComponent("Capture", isDirectory: true),
                                 keeper: KeychainRecordingProfileKeeper(store: environment.secrets),
                                 profileReadable: { [weak self] in !(self?.stateUnreadable ?? false) },
                                 statusStore: environment.statusStore, freeBytes: environment.freeBytes)
        recorder.now = environment.now
        vaultName = state.payload?.vaultName
        refreshScreen()
    }

    var isSetUp: Bool { state.payload != nil }

    // MARK: Launch and activation

    /// At launch and whenever the app becomes active: the profile, a sweep of recordings a quit or a crash cut off, the
    /// outbox's hand-off, and the status the widgets show.
    func activate() async {
        env.transport.activate()
        if stateUnreadable, let loaded = try? secrets.loadState() {
            state = loaded
            stateUnreadable = false
            vaultName = state.payload?.vaultName
        }
        _ = try? identityForRequests()
        let swept = await recorder.sweep()
        if let note = swept.last { show(saved: note) }
        flushOutbox(launch: true)
        // With no profile the watch asks on every activation: the phone keeps no request while "Use on Apple Watch" is off,
        // and the transport drops a duplicate that is still outstanding.
        if !isSetUp { requested = false }
        requestProvisioningIfNeeded()
        refreshScreen()
        publish()
    }

    // MARK: Recording

    /// A launch from a surface (`sempere-watch://record`, the intent, Siri): records at once. The app grid's launch does not.
    func startFromSurface() {
        guard !recorder.isRecording else { return }
        Task { await record(fromSurface: true) }
    }

    func record(fromSurface: Bool = false) async {
        savedTask?.cancel()
        do {
            try await recorder.start()
            surfaceStart = fromSurface
            savedStays = false
            env.haptic(.start)
            beginTicking()
            refreshScreen()
        } catch let error as WatchRecorderError {
            fail(error)
        } catch {
            screen = .cannotRecord(.failed("\(error)"))
        }
        publish()
    }

    func stop() async {
        do {
            let note = try await recorder.stop()
            env.haptic(.stop)
            noteSaved(note)
        } catch let error as WatchRecorderError {
            fail(error)
        } catch {
            screen = .cannotRecord(.failed("\(error)"))
        }
        ticker?.cancel()
        publish()
    }

    private func fail(_ error: WatchRecorderError) {
        ticker?.cancel()
        switch error {
        case .notSetUp: screen = .notSetUp
        case .microphoneDenied: screen = .cannotRecord(.microphoneDenied)
        case .outboxFull: screen = .cannotRecord(.outboxFull)
        case .lowStorage: screen = .cannotRecord(.lowStorage)
        case .alreadyRecording, .notRecording: refreshScreen(settle: true)
        case .sessionRefused(let why), .cannotStart(let why), .segmentUndecodable(let why), .sealFailed(let why):
            diagnostics = why
            screen = .cannotRecord(.failed(why))
        case .noReadableAudio:
            screen = .cannotRecord(.failed("no readable audio"))
        case .nothingRecorded:
            refreshScreen(settle: true)   // nothing to say: not a byte was recorded
        }
    }

    private func noteSaved(_ note: WatchSavedNote) {
        show(saved: note, stays: surfaceStart && inForeground)
        surfaceStart = false
        flushOutbox()
    }

    private func show(saved note: WatchSavedNote, stays: Bool = false) {
        screen = .saved(note)
        savedStays = stays
        updateUnsent()
        savedTask?.cancel()
        guard !stays else { return }
        savedTask = Task { [weak self, savedDuration, savedWait] in
            await savedWait(savedDuration)
            guard !Task.isCancelled else { return }
            self?.dismissSaved()
        }
    }

    func dismissSaved() {
        savedStays = false
        if case .saved = screen { refreshScreen(settle: true) }
    }

    /// The app went to the background: a "Saved" kept up for a surface's recording goes, so opening the app later shows
    /// the Ready screen.
    func enteredBackground() {
        inForeground = false
        if savedStays { dismissSaved() }
    }

    func enteredForeground() {
        inForeground = true
    }

    /// Dismisses a "can't record" and goes back to the Ready or Not set up screen.
    func dismissProblem() {
        if case .cannotRecord = screen { refreshScreen(settle: true) }
    }

    private func beginTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Each second while recording: the elapsed time, the 60 minute limit, and a stop by the system (a media server reset,
    /// an interruption that does not resume).
    private func tick() {
        elapsed = recorder.elapsed
        let status = recorder.status
        timerStart = status.started
        paused = status.paused != nil
        Task { [weak self] in
            guard let self else { return }
            if let note = await self.recorder.checkLimit() {
                self.env.haptic(.stop)
                self.noteSaved(note)
                self.ticker?.cancel()
                self.publish()
            } else if !self.recorder.isRecording, case .recording = self.screen {
                self.ticker?.cancel()
                switch self.recorder.lastSystemStop {
                case .success(let note)?: self.env.haptic(.stop); self.noteSaved(note)
                case .failure(let error)?: self.fail(error)
                case nil: self.refreshScreen(settle: true)
                }
                self.publish()
            }
        }
    }

    // MARK: Screen and status

    /// Brings the screen in line with the recorder and the profile. A "Saved" or "Can't record" that is up stays until its
    /// own time or its OK (a launch's sweep, a message from the phone or a reactivation must not wipe the news); `settle`
    /// replaces it.
    func refreshScreen(settle: Bool = false) {
        updateUnsent()
        vaultName = state.payload?.vaultName
        if !settle, recorder.phase == .idle {
            switch screen {
            case .saved, .cannotRecord: return
            default: break
            }
        }
        switch recorder.phase {
        case .recording, .paused: screen = .recording
        case .saving: screen = .saving
        case .idle: screen = isSetUp ? .ready : .notSetUp
        }
    }

    private func updateUnsent() { unsent = outbox.unsentCount }

    /// Writes the status for the widgets and reloads them when it changed.
    private func publish() {
        if recorder.publishStatus() { env.reloadWidgets() }
    }

    // MARK: Provisioning

    private func identityForRequests() throws -> NativeIdentity {
        if let identity { return identity }
        let id = try secrets.identity()
        identity = id
        return id
    }

    /// With no profile the watch asks the phone, once per launch (and again after a Reset).
    /// `requested` is set only when the request was queued: the first one on a cold launch comes before the session is
    /// activated, and `activated()` asks again.
    func requestProvisioningIfNeeded() {
        guard !isSetUp, !requested, let identity = try? identityForRequests() else { return }
        requested = env.transport.requestProvisioning(recipient: identity.recipient.string, seq: state.seq)
    }

    /// A message from the paired iPhone, from the session delegate's callbacks only (never a file, a URL or anything else:
    /// a forged profile would send this watch's audio to a vault someone else holds).
    func receive(_ dictionary: [String: Any]) {
        guard let message = WatchProvisioning.message(dictionary), let identity = try? identityForRequests() else { return }
        var next = state
        do {
            switch try WatchProvisioning.apply(message, identity: identity, to: &next) {
            case .stored, .cleared:
                try secrets.save(next)
                state = next
                stateUnreadable = false   // written: this state is the stored one now
                // A watch the phone cleared asks again by itself; the phone keeps the request only while "Use on Apple
                // Watch" is on (docs/design/1.1-watch.md §3.4), so it asks once more at its next launch after the toggle is on.
                if next.payload == nil { requested = false }
                if next.payload == nil { sweepLeftovers() }
            case .ignored, .notForTheWatch:
                return
            }
        } catch {
            diagnostics = "\(error)"
            return
        }
        refreshScreen()
        publish()
        requestProvisioningIfNeeded()
    }

    /// Seals or deletes what a recording left behind, by the recorder's rules (a recording in progress is left alone).
    private func sweepLeftovers() {
        Task { [weak self] in _ = await self?.recorder.sweep() }
    }

    /// "Reset": deletes the profile and its counter (back to -1, so the phone's next payload is taken) and asks again.
    /// Notes already sealed stay in the outbox and are still sent.
    func reset() {
        state = WatchProfileState()
        // Saved: the stored state is this empty one, so it is readable (and the sweep may delete) again.
        if (try? secrets.save(state)) != nil { stateUnreadable = false }
        // A new provisioning key too: the phone's persisted application context holds the old profile, encrypted to the old
        // key, and nothing can open it any more.
        try? env.secrets.delete(.provisioningKey)
        identity = nil
        requested = false
        // Nothing kept for a recording in progress outlives a Reset; recordings left without a profile are deleted.
        recorder.discardKeptProfiles()
        sweepLeftovers()
        refreshScreen(settle: true)
        publish()
        requestProvisioningIfNeeded()
    }

    // MARK: Hand-off

    /// Hands every outbox file that is due to the system (`launch`: every unsent file, as every launch retries).
    func flushOutbox(launch: Bool = false) {
        // Before the session is activated nothing can be queued: that is not a failed transfer (it would push the retry back).
        guard env.transport.isActivated else { updateUnsent(); return }
        let pending = env.transport.pendingTransfers
        for entry in outbox.due(launch: launch) where !pending.contains(entry.id) {
            if env.transport.transfer(file: outbox.fileURL(entry.id), meta: entry.meta) {
                try? outbox.markTransferring(entry.id)
            } else {
                try? outbox.transferFailed(entry.id)
            }
        }
        updateUnsent()
    }

    /// "Send now".
    func sendNow() { flushOutbox(launch: true) }

    /// The phone's acknowledgement (`acked`) or its list (`have`): the files go.
    func receive(ack: WatchAck) {
        _ = try? outbox.acknowledge(ack)
        updateUnsent()
    }

    /// `didFinish`: a failure keeps the file for a retry after a backoff; a success only says the phone's WatchConnectivity
    /// has it, not that it is in the vault, so nothing is deleted until the ack.
    func transferFinished(id: UUID, failed: Bool) {
        if failed { try? outbox.transferFailed(id) }
        updateUnsent()
    }

    func open(url: URL) {
        if WatchLink.isRecord(url) { startFromSurface() }
    }
}
