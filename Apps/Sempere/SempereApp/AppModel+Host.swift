import Foundation
import Sempere
import SempereAppCore
import SempereRender
import SempereSync
import UIKit

// The app's `AppModel` is the library's `AppModelCore` on this app's host (docs/design/thin-app.md "Wave 5b,
// part 2"): the canvas is PencilKit's (`PencilCanvas`), the services are the platform's, and the extensions still in
// the app (wave 5b part 3) run through `AppHost`'s two steps.

typealias AppModel = SempereAppCore.AppModelCore<AppHost>

/// The app's `AppModelHost`.
enum AppHost: AppModelHost {
    typealias Canvas = PencilCanvas
    typealias State = AppModelAppState

    static func makeState() -> AppModelAppState { AppModelAppState() }

    /// The platform's: signposts and `os.Logger`, `UserDefaults.standard`, security-scoped bookmarks, the device,
    /// the network and the Keychain for WebDAV, iCloud, on-device speech, quick capture, Vision, the owner check,
    /// file coordination, PDFKit, ImageIO and CoreText for exports and imports, and PDFKit, Core Graphics, ImageIO,
    /// AVFoundation and `UTType` for inserts and opened files, `UIApplication`'s lifecycle and background time,
    /// `BGTaskScheduler` and `NWPathMonitor`.
    static func makeServices() -> AppModelServices {
        AppModelServices(perf: AppPerfSink(), settings: UserDefaults.standard, bookmarks: SecurityScopedBookmarks(),
                         platform: AppPlatform(), webdavRemote: LiveWebDAVRemote(),
                         webdavPasswords: KeychainWebDAVPasswordStore(), iCloudHooks: CloudVault.Hooks.live,
                         transcriber: SpeechRecordingTranscriber(), appName: NoteWriter.appName,
                         makeRenderCache: AppModel.makeRenderCache, makePlaybackBackend: { AVAudioPlaybackBackend() },
                         recordingRoot: RecordingSession.root, recordingsInUse: AppModel.recordingsInUse,
                         audioFiles: AVCaptureAudioFiles(), makeQuickCapture: { _ in QuickCapture.shared },
                         settingsStorage: AppSettingsStorage(), makePageRecognizer: { VisionPageRecognizer() },
                         ownerAuthenticator: SystemOwnerAuthenticator(), files: SystemFileCoordinator(),
                         exportRendering: RenderOptions(pdfRasterizer: PDFKitRasterizer(), imageDecoder: ImageIODecoder(),
                                                        shaper: CoreTextShaper()),
                         pdfTextExtractor: PDFKitTextExtractor(), attachmentPreparation: AppAttachmentPreparation(),
                         lifecycle: UIKitAppLifecycle(), backgroundTasks: UIKitBackgroundTasks(),
                         syncScheduler: BGTaskSyncScheduler(), makeReachability: { WebDAVReachability() })
    }

    static func prepareEditor(_ editor: NoteEditor, of note: UUID, in model: AppModel) {
        model.configureRecordingSaves(editor)
    }

    static func unreadableText(_ editor: NoteEditor) -> String {
        editor.readOnlyReason ?? String(localized: "This note could not be read.")
    }
}

/// The state of the `AppModel` extensions still in the app, whose types are the app's. Empty since wave 5b part 3,
/// step 6 moved the drags, the background tasks, the reachability and the idle timer into `AppModelCore`; step 7
/// removes it with `Host.State`.
@MainActor
final class AppModelAppState {}
