import SwiftUI

/// The app entry point. The model, the library (recent vaults) and the
/// remembered keys are app state, shared by every window, so edits from two
/// windows are serialised by one model and never race on the device clock.
///
/// Scenes: the library window (vault, notes, one note on the canvas); on the
/// Mac also a window per note (`NoteWindowView`, restored at launch with the
/// values it was opened with), one key window and one Settings window (⌘,). The iPad opens only the
/// first (multiple scenes are switched on for Mac Catalyst alone in the
/// project's build settings), and the Mac menu bar is attached for Catalyst only.
@main
struct SempereApp: App {
    /// Builds the Mac menu bar without the system's duplicates (`MacMenus`).
    @UIApplicationDelegateAdaptor(SempereAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var library: VaultLibrary
    @State private var keys: RememberedKeys

    init() {
        #if DEBUG
        // A scripted first launch: nothing below may read state from an earlier run.
        DebugLaunch.resetForFreshLaunch()
        #endif
        let library = VaultLibrary()
        let keys = RememberedKeys()
        // A view updated outside its window's environment falls back to these (`AppModelEnvironment`).
        VaultLibrary.current = library
        RememberedKeys.current = keys
        _library = State(initialValue: library)
        _keys = State(initialValue: keys)
        let model = AppModel(recognizer: RecognitionPreference.enabled ? VisionPageRecognizer() : nil,
                             summaryCacheDirectory: AppModel.defaultSummaryCacheDirectory,
                             drawingCacheRoot: AppModel.drawingCacheEnabled ? DrawingCache.defaultRoot : nil,
                             blobCacheRoot: BlobCache.folder,
                             renderCacheRoot: AppModel.drawingCacheEnabled ? RenderCache.defaultRoot : nil,
                             attachmentIndexRoot: AppModel.defaultAttachmentIndexRoot,
                             automaticThinning: true,
                             recipientsTrust: AppModel.defaultRecipientsTrust,
                             backupNotifier: UserNotificationBackupNotifier())
        AppModel.current = model
        _model = State(initialValue: model)
        // Background sync (iOS): the model the scheduled tasks sync (`.backgroundTask` below).
        BackgroundSync.model = model
        // Staged exports are plaintext copies of notes: none survives a launch.
        ExportJob.purgeStale()
        BulkExportRun.purgeStale()
        // A key file staged for the share sheet by a run that quit with the sheet up.
        KeyShareFile.purge()
        // Plaintext PDFs dragged out in an earlier run that quit with a vault
        // open (each model empties only its own folder, when the vault closes).
        NotePDFExport.purge(olderThan: 0)
        // Work copies of imported PDFs (plaintext) left by an import that never finished.
        PDFPreparation.purge()
        // Quick voice notes: Siri, Shortcuts, widgets and Control Center act through the shared instance;
        // a voice note a crash interrupted is sealed (or deleted) now.
        QuickCapture.register()
        Task { await QuickCapture.shared.sweep() }
        // The Mac menu-bar item (an AppKit bundle in PlugIns; inert where it does not exist).
        StatusItemHost.shared.start(model: model)
        // Settings shows what the on-device speech engines can do (task E5).
        TranscriptionPreference.installSettingsHooks()
        // Per-session attachment caches of earlier builds (the app's is in Caches now, `BlobCache.folder`).
        BlobCache.purgeStale()
    }

    var body: some Scene {
        libraryScene
        // Every window gets the whole app environment, and one restored where it
        // does not fit (another build's scene, a note window without its value)
        // shows the library or closes (`SceneRestoration`).
        WindowGroup("Note", id: SceneRestoration.Kind.note.sceneID, for: NoteWindowValue.self) { $value in
            RestoredScene(kind: .note, hasValue: value != nil) {
                if let value { NoteWindowView(value: value) }
            }
            .appEnvironment(model: model, library: library, keys: keys)
        }
        WindowGroup("Settings", id: SceneRestoration.Kind.settings.sceneID) {
            RestoredScene(kind: .settings) { SettingsView(showsDone: false) }
                .appEnvironment(model: model, library: library, keys: keys)
        }
        WindowGroup("Vault Keys", id: SceneRestoration.Kind.keys.sceneID) {
            RestoredScene(kind: .keys) { KeysWindowView() }
                .appEnvironment(model: model, library: library, keys: keys)
        }
    }

    /// The library window. It has the same id in the Catalyst and the iPad
    /// build, so a window either saved is the library in the other.
    @SceneBuilder private var libraryScene: some Scene {
        #if targetEnvironment(macCatalyst)
        WindowGroup("Sempere", id: SceneRestoration.Kind.library.sceneID) { libraryContent }
            // File > Export… is a `MenuCommand` on the Mac (`AppCommands`); the iPad keeps the submenu.
            .commands { AppCommands() }
        #else
        WindowGroup(id: SceneRestoration.Kind.library.sceneID) { libraryContent }
            .commands { ExportMenuCommands(model: model) }
            // Background sync: iOS launches these for the requests `BGTaskSyncScheduler`
            // submits. The Mac schedules nothing.
            .backgroundTask(.appRefresh(BackgroundSync.refreshIdentifier)) { await BackgroundSync.run() }
            .backgroundTask(.processingTask(BackgroundSync.processingIdentifier)) { await BackgroundSync.run() }
        #endif
    }

    private var libraryContent: some View {
        RootView().appEnvironment(model: model, library: library, keys: keys)
    }
}
