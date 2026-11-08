import Foundation
import Observation
import Sempere
import SempereAppCore
import SempereSync
import UIKit

// The app's `AppModel` is the library's `AppModelCore` on this app's host (docs/design/thin-app.md "Wave 5b,
// part 2"): the canvas is PencilKit's (`PencilCanvas`), the services are the platform's, and the extensions still in
// the app (wave 5b part 3) keep their state in `AppModelAppState` and run through `AppHost`'s steps.

typealias AppModel = SempereAppCore.AppModelCore<AppHost>

/// The app's `AppModelHost`.
enum AppHost: AppModelHost {
    typealias Canvas = PencilCanvas
    typealias State = AppModelAppState

    static func makeState() -> AppModelAppState { AppModelAppState() }

    /// The platform's: signposts and `os.Logger`, `UserDefaults.standard`, security-scoped bookmarks, the device,
    /// the network and the Keychain for WebDAV, iCloud, on-device speech, quick capture, Vision, the owner check.
    static func makeServices() -> AppModelServices {
        AppModelServices(perf: AppPerfSink(), settings: UserDefaults.standard, bookmarks: SecurityScopedBookmarks(),
                         platform: AppPlatform(), webdavRemote: LiveWebDAVRemote(),
                         webdavPasswords: KeychainWebDAVPasswordStore(), iCloudHooks: CloudVault.Hooks.live,
                         transcriber: SpeechRecordingTranscriber(), appName: NoteWriter.appName,
                         makeRenderCache: AppModel.makeRenderCache, makePlaybackBackend: { AVAudioPlaybackBackend() },
                         recordingRoot: RecordingSession.root, recordingsInUse: AppModel.recordingsInUse,
                         audioFiles: AVCaptureAudioFiles(), makeQuickCapture: { _ in QuickCapture.shared },
                         settingsStorage: AppSettingsStorage(), makePageRecognizer: { VisionPageRecognizer() },
                         ownerAuthenticator: SystemOwnerAuthenticator())
    }

    static func willClose(_ model: AppModel) {
        model.lastImportReport = nil
        model.exportEpoch.bump()
        NotePDFExport.purge(in: model.exportFolder, olderThan: 0)   // plaintext PDFs dragged out of this vault
        model.exportRequest = nil
        model.bulkExportRequest = nil
        model.draggedPayload = nil
        model.dropTarget = nil
    }

    static func editorsChanged(_ model: AppModel) { model.idleTimer?.update() }

    static func prepareEditor(_ editor: NoteEditor, of note: UUID, in model: AppModel) {
        model.configureRecordingSaves(editor)
    }

    static func unreadableText(_ editor: NoteEditor) -> String {
        editor.readOnlyReason ?? String(localized: "This note could not be read.")
    }

    static func listingFinished(_ model: AppModel) { model.thinIfDue() }
    static func closeWindowEditors(_ model: AppModel) async { await model.closeWindowEditors() }
    static func openWindowNote(_ id: UUID, in model: AppModel) async throws { _ = try await model.openWindowNote(id) }
    static func reopenWindowNote(_ id: UUID, in model: AppModel) async { await model.reopenWindowNote(id) }
}

/// The state of the `AppModel` extensions still in the app, whose types are the app's (wave 5b part 3 moves each
/// into `AppModelCore` with its code). Read through `AppModel`'s forwarding properties below, so no view changed.
@MainActor
@Observable
final class AppModelAppState {
    /// What is being dragged inside the app (set when a drag starts), so the
    /// sidebar can tell whether a row would accept it while the drag is still over it.
    var draggedPayload: DragPayload?

    /// The sidebar row a drag is over that would accept it (highlighted).
    var dropTarget: DropTarget?

    /// The sidebar row a drop just moved notes or a notebook into: flashed for
    /// `landedDropDuration` so it is clear where they went (`move(_:to:undoManager:)`).
    var landedDrop: LandedDrop?

    /// The export sheet's request (`AppModel+Export`).
    var exportRequest: ExportRequest?

    /// PDFs opened from outside the app (Finder's Open With, the share sheet),
    /// waiting to be imported as new notes (`AppModel+OpenedFiles`). App
    /// state, not the vault's: they wait while a vault is opened or unlocked.
    var openedPDFs: [OpenedPDF] = []

    /// What the last import did, until the alert is dismissed.
    var importSummary: ImportSummary?

    /// The report of the last import of this vault, for File > Last Import Report (until the vault closes).
    var lastImportReport: ImportDetails?

    /// The "Export to Folder or Zip…" sheet's request (`AppModel+BulkExport`).
    var bulkExportRequest: BulkExportRequest?

    /// How far a thinning run (or its preview) has got, counted per note;
    /// nil when none is running (`thinVault`).
    var thinningProgress: ThinningProgress?

    /// Background time and scheduled tasks for the sync (`AppModel+Background`); tests pass fakes.
    @ObservationIgnored var backgroundTasks: any BackgroundTaskRunning = UIKitBackgroundTasks()

    @ObservationIgnored var syncScheduler: any BackgroundSyncScheduling = BGTaskSyncScheduler()

    /// The assertion held while sync targets' runs finish off screen (`finishTargetRunsInBackground`), and its wait.
    @ObservationIgnored var targetsBackgroundToken: BackgroundTaskToken?

    /// Watches the network for the WebDAV targets (`startReachability`); nil until started.
    @ObservationIgnored var reachability: WebDAVReachability?

    /// Where this model's PDF exports (drag to Finder) are written; emptied when the vault closes.
    let exportFolder: URL = NotePDFExport.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// Bumped when the vault closes: a drag-out export prepared before it writes nothing.
    let exportEpoch = ExportEpoch()

    /// The assertion held while the last saves finish before the lease is let go, and its wait.
    @ObservationIgnored var suspensionToken: BackgroundTaskToken?

    /// Applies "Keep Screen On" app-wide (`IdleTimerKeeper`); the app sets it, tests need none.
    @ObservationIgnored var idleTimer: IdleTimerKeeper?

    /// "Open Vault…" copying a vault onto this device (`copyIn`), for the progress overlay.
    var vaultCopy: VaultCopyProgress?
}

extension AppModel {
    var draggedPayload: DragPayload? {
        get { appState.draggedPayload }
        set { appState.draggedPayload = newValue }
    }
    var dropTarget: DropTarget? {
        get { appState.dropTarget }
        set { appState.dropTarget = newValue }
    }
    var landedDrop: LandedDrop? {
        get { appState.landedDrop }
        set { appState.landedDrop = newValue }
    }
    var exportRequest: ExportRequest? {
        get { appState.exportRequest }
        set { appState.exportRequest = newValue }
    }
    var openedPDFs: [OpenedPDF] {
        get { appState.openedPDFs }
        set { appState.openedPDFs = newValue }
    }
    var importSummary: ImportSummary? {
        get { appState.importSummary }
        set { appState.importSummary = newValue }
    }
    var lastImportReport: ImportDetails? {
        get { appState.lastImportReport }
        set { appState.lastImportReport = newValue }
    }
    var bulkExportRequest: BulkExportRequest? {
        get { appState.bulkExportRequest }
        set { appState.bulkExportRequest = newValue }
    }
    var thinningProgress: ThinningProgress? {
        get { appState.thinningProgress }
        set { appState.thinningProgress = newValue }
    }
    var backgroundTasks: any BackgroundTaskRunning {
        get { appState.backgroundTasks }
        set { appState.backgroundTasks = newValue }
    }
    var syncScheduler: any BackgroundSyncScheduling {
        get { appState.syncScheduler }
        set { appState.syncScheduler = newValue }
    }
    var targetsBackgroundToken: BackgroundTaskToken? {
        get { appState.targetsBackgroundToken }
        set { appState.targetsBackgroundToken = newValue }
    }
    var reachability: WebDAVReachability? {
        get { appState.reachability }
        set { appState.reachability = newValue }
    }
    var exportFolder: URL { appState.exportFolder }
    var exportEpoch: ExportEpoch { appState.exportEpoch }
    var suspensionToken: BackgroundTaskToken? {
        get { appState.suspensionToken }
        set { appState.suspensionToken = newValue }
    }
    var idleTimer: IdleTimerKeeper? {
        get { appState.idleTimer }
        set { appState.idleTimer = newValue }
    }
    var vaultCopy: VaultCopyProgress? {
        get { appState.vaultCopy }
        set { appState.vaultCopy = newValue }
    }
}
