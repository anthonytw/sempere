import AVFoundation
import Foundation
import Security
import Sempere
import SempereAppCore
import SempereCaptureShared
import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import WidgetKit
#endif

// The app's half of quick voice notes (docs/quick-capture.md): the shared `QuickCapture` (SempereAppCore, the
// start/stop/sweep state machine) made with the platform's services, and those services: the Keychain profile, the
// recorder (`RecordingSession` on AVFoundation, files protected `completeUntilFirstUserAuthentication`), the
// segments' decoding, the Live Activity (ActivityKit), the app's state and background time (UIKit). `register()` hooks
// it up to the intents and watches what only the platform can tell.

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

extension QuickCapture {
    /// The app's quick capture: the Keychain profile, AVFoundation, ActivityKit, UIKit, the App Group's status
    /// file and the widgets' reload. `register()` hooks it up at launch.
    static let shared = QuickCapture.app()

    /// A quick capture on the app's platform services; tests pass their own store and folders.
    static func app(store: any CaptureProfileStore = KeychainCaptureProfileStore(), root: URL = QuickCapture.defaultRoot,
                    queueRoot: URL = QuickCapture.defaultQueueRoot, statusStore: VoiceNoteStatusStore? = .shared) -> QuickCapture {
        let capture = QuickCapture(store: store, audio: AppCaptureAudio(), audioFiles: AVCaptureAudioFiles(),
                                   transcriber: SpeechRecordingTranscriber(), liveActivity: SystemLiveActivity(),
                                   app: UIKitCaptureApp(), backgroundTime: UIKitBackgroundTime(), bookmarks: SecurityScopedBookmarks(),
                                   files: SystemFileCoordinator(), perf: AppPerfSink(), root: root, queueRoot: queueRoot)
        capture.statusStore = statusStore
        // The app's words for errors even when no `AppModel` exists yet (a start from a widget before any is made).
        capture.describeError = { AppModel.describe($0) }
        capture.noteTitle = { QuickCapture.title($0) }
        capture.reloadSurfaces = { QuickCapture.reloadSystemSurfaces() }
        return capture
    }

    /// The Data Protection class of recordings in progress. Not `completeUnlessOpen`: its files
    /// cannot be reopened while the device is locked once closed, and a voice note started from
    /// the Lock Screen is assembled, read and sealed from closed segment files before any unlock.
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// Hooks the intents (Siri, Shortcuts, widgets, Control Center) up to the shared instance.
    /// Also ends Live Activities left by an earlier process (killed, crashed or
    /// rebooted while recording): nothing of theirs is recording any more, and
    /// their Stop button would reach a process that knows nothing of them.
    static func register() {
        // The taps' unified-log lines, first: an intent may run as soon as the hooks below are in.
        VoiceNoteTapLog.installUnifiedLog()
        let capture = QuickCapture.shared
        capture.startLog = VoiceNoteStartLog(url: VoiceNoteStartLog.defaultURL, perf: AppPerfSink())
        capture.installActions()
        let launched = Date()
        Task { await capture.endOrphanedActivities() }
        // A status left by a process that died while recording would offer a Stop that stops nothing.
        capture.publishStatus(forceReload: true)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Task {
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                capture.publishStatus()
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
                capture.startLog.reload()
                capture.publishStatus(forceReload: true)
                Task {
                    await capture.sweep()
                    await capture.endOrphanedActivities()
                }
            }
        }
    }

    static func reloadSystemSurfaces() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        WidgetCenter.shared.reloadTimelines(ofKind: VoiceNoteStatus.widgetKind)
        ControlCenter.shared.reloadControls(ofKind: VoiceNoteStatus.controlKind)
        #endif
    }
}

// MARK: - The recorder

// `RecordingSession` is the `CaptureRecording` and `RecordingError` the `CaptureStartRefusal` (AudioRecorder.swift).

/// The device's microphone and `RecordingSession` (AVFoundation). Tests give it a fake backend, a permission and
/// their own notification center.
@MainActor
final class AppCaptureAudio: CaptureAudio {
    /// The recorder of one start (`AVAudioCaptureBackend`; tests: `FakeCapture`).
    var backend: @MainActor () -> AudioCaptureBackend = { AVAudioCaptureBackend() }
    var microphoneAllowed: @MainActor () async -> Bool = { await AVAudioCaptureBackend.requestMicrophone() }
    /// The microphone permission's name, for the start diagnostics.
    var permission: @MainActor () -> String = { AppCaptureAudio.systemMicrophonePermission() }
    /// Where the sessions watch the audio session's interruptions.
    var center: NotificationCenter = .default

    func requestMicrophone() async -> Bool { await microphoneAllowed() }
    var microphonePermission: String { permission() }
    var preferredFormat: RecordingFormat { RecordingPreference.format(UserDefaults.standard) }
    func makeRecorder() -> any CaptureRecorder { AppCaptureRecorder(backend: backend(), center: center) }

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

/// One start's `AudioCaptureBackend`, and the `RecordingSession` on it, its files protected
/// `QuickCapture.protection` (readable after the first unlock).
@MainActor
final class AppCaptureRecorder: CaptureRecorder {
    let backend: AudioCaptureBackend
    let center: NotificationCenter

    init(backend: AudioCaptureBackend, center: NotificationCenter) {
        self.backend = backend
        self.center = center
    }

    func activateSession(mixable: Bool) async throws { try await backend.activateSession(mixable: mixable) }
    func deactivate() { backend.deactivate() }

    func makeRecording(format: RecordingFormat, root: URL, segmentExtension: String) -> any CaptureRecording {
        RecordingSession(noteID: UUID(), format: format, root: root, protection: QuickCapture.protection,
                         segmentExtension: segmentExtension, backend: backend, center: center)
    }
}

/// Segment files read and joined with AVFoundation.
struct AVCaptureAudioFiles: CaptureAudioFiles {
    /// Classifies the segment at `url`. Only a file AVFoundation positively
    /// reads as an audio track of no length is `.none` with bytes in it:
    /// anything it cannot read is `.undecodable`, which `seal` never deletes.
    func classify(_ url: URL) async -> CaptureSegments.Audio {
        guard CaptureSegments.byteCount(url) > 0 else { return .none }
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

    func merge(_ segments: [URL], into out: URL) async throws {
        try await RecordingAssembly.merge(segments, into: out)
    }
}

// MARK: - The Live Activity

/// The recording's Live Activity through ActivityKit (iPhone and iPad; none on a Mac).
@MainActor
final class SystemLiveActivity: CaptureLiveActivity {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var activity: Activity<VoiceNoteAttributes>?
    /// The last update or end sent to `activity`: each waits for the one before
    /// (an end overtaking the "Saving" update would leave the activity saving).
    private var activityWork: Task<Void, Never>?

    var isSupported: Bool { true }
    var areEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(_ state: VoiceNoteActivityState, staleDate: Date?) throws {
        let a = try Activity.request(attributes: VoiceNoteAttributes(), content: .init(state: state, staleDate: staleDate))
        activity = a
        ownedActivity.value = a.id
    }

    func update(_ state: VoiceNoteActivityState, staleDate: Date?) {
        guard let id = activity?.id else { return }
        let previous = activityWork
        // `Activity` is not Sendable: reach it by id from a nonisolated task.
        activityWork = Task.detached {
            await previous?.value
            for a in Activity<VoiceNoteAttributes>.activities where a.id == id {
                await a.update(ActivityContent(state: state, staleDate: staleDate))
            }
        }
    }

    func end(_ state: VoiceNoteActivityState, dismissal: Date) {
        guard let id = activity?.id else { return }
        activity = nil
        let previous = activityWork
        activityWork = Task.detached {
            await previous?.value
            for a in Activity<VoiceNoteAttributes>.activities where a.id == id {
                await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(dismissal))
            }
            if ownedActivity.value == id { ownedActivity.value = nil }
        }
    }

    func endAll(startedBefore cutoff: Date) async {
        await Task.detached {
            for a in Activity<VoiceNoteAttributes>.activities where a.content.state.started < cutoff {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            ownedActivity.value = nil
        }.value
    }

    func endOrphans(startedBefore cutoff: Date) async -> Int {
        await Task.detached { () -> Int in
            var ended = 0
            for a in Activity<VoiceNoteAttributes>.activities
            where a.id != ownedActivity.value && a.content.state.started < cutoff {
                await a.end(nil, dismissalPolicy: .immediate)
                ended += 1
            }
            return ended
        }.value
    }
    #else
    var isSupported: Bool { false }
    var areEnabled: Bool { true }
    func request(_ state: VoiceNoteActivityState, staleDate: Date?) throws {}
    func update(_ state: VoiceNoteActivityState, staleDate: Date?) {}
    func end(_ state: VoiceNoteActivityState, dismissal: Date) {}
    func endAll(startedBefore cutoff: Date) async {}
    func endOrphans(startedBefore cutoff: Date) async -> Int { 0 }
    #endif
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

// MARK: - The app's state and background time

/// `UIApplication`'s state, protected data and activation.
@MainActor
final class UIKitCaptureApp: CaptureAppState {
    var activity: CaptureAppActivity { UIApplication.shared.applicationState.captureActivity }
    var protectedDataAvailable: Bool { UIApplication.shared.isProtectedDataAvailable }
    func waitUntilActive(timeout: Duration) async -> Bool {
        await AppActivation.wait(timeout: timeout) { UIApplication.shared.applicationState == .active }
    }
}

/// A background-time assertion while a voice note is sealed (the app may
/// have been launched by an intent, or sent to the background meanwhile).
@MainActor
final class UIKitBackgroundTime: BackgroundTime {
    func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> BackgroundGrant {
        let holder = TaskHolder()
        let grant = BackgroundGrant {
            guard holder.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(holder.id)
            holder.id = .invalid
        }
        holder.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak grant] in
            MainActor.assumeIsolated {
                expired()
                grant?.end()
            }
        }
        return grant
    }

    @MainActor
    private final class TaskHolder {
        var id = UIBackgroundTaskIdentifier.invalid
    }
}
