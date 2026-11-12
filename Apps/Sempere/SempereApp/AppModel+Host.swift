import Foundation
import Sempere
import SempereAppCore
import SempereRender
import SempereSync
import UIKit

// The app's `AppModel` is the library's `AppModelCore` on this app's host (docs/design/thin-app.md "Wave 5b,
// part 2"): the canvas is PencilKit's (`PencilCanvas`) and the services are the platform's. Since wave 5b part 3,
// step 7, that is all the host gives.

typealias AppModel = SempereAppCore.AppModelCore<AppHost>

/// The app's `AppModelHost`.
enum AppHost: AppModelHost {
    typealias Canvas = PencilCanvas

    /// The platform's: signposts and `os.Logger`, `UserDefaults.standard`, security-scoped bookmarks, the device,
    /// the network and the Keychain for WebDAV, iCloud, on-device speech, quick capture, Vision, the owner check,
    /// file coordination, PDFKit, ImageIO and CoreText for exports and imports, and PDFKit, Core Graphics, ImageIO,
    /// AVFoundation and `UTType` for inserts and opened files, `UIApplication`'s lifecycle and background time,
    /// `BGTaskScheduler`, `NWPathMonitor`, and the nearby link of joining (`NWNearbyTransport`).
    static func makeServices() -> AppModelServices {
        AppModelServices(perf: AppPerfSink(), settings: UserDefaults.standard, bookmarks: SecurityScopedBookmarks(),
                         platform: AppPlatform(), webdavRemote: LiveWebDAVRemote(),
                         webdavPasswords: KeychainWebDAVPasswordStore(), iCloudHooks: CloudVault.Hooks.live,
                         transcriber: SpeechRecordingTranscriber(), appName: NoteWriter.appName,
                         makeRenderCache: AppModel.makeRenderCache, makePlaybackBackend: { AVAudioPlaybackBackend() },
                         recordingRoot: RecordingSession.root, recordingsInUse: AppModel.recordingsInUse,
                         audioFiles: AVCaptureAudioFiles(), finishRecordingSave: AppModel.finishRecordingSave,
                         makeQuickCapture: { _ in QuickCapture.shared },
                         settingsStorage: AppSettingsStorage(), makePageRecognizer: { VisionPageRecognizer() },
                         ownerAuthenticator: SystemOwnerAuthenticator(), files: SystemFileCoordinator(),
                         exportRendering: RenderOptions(pdfRasterizer: PDFKitRasterizer(), imageDecoder: ImageIODecoder(),
                                                        shaper: CoreTextShaper()),
                         pdfTextExtractor: PDFKitTextExtractor(), attachmentPreparation: AppAttachmentPreparation(),
                         lifecycle: UIKitAppLifecycle(), backgroundTasks: UIKitBackgroundTasks(),
                         syncScheduler: BGTaskSyncScheduler(), makeReachability: { WebDAVReachability() },
                         nearby: debugNearbyTransport ?? NWNearbyTransport(),
                         describeError: AppModel.describe)
    }

    /// Debug builds: a scripted launch (UI tests, screenshots) keeps the nearby link on loopback, which needs no local
    /// network permission, so the system's prompt never covers the window under test (`DebugLaunch.nearbyLoopback`).
    private static var debugNearbyTransport: NWNearbyTransport? {
        #if DEBUG
        DebugLaunch.nearbyLoopback ? NWNearbyTransport(mode: .loopback) : nil
        #else
        nil
        #endif
    }
}
