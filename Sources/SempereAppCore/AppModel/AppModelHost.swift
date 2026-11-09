import Foundation
import Sempere
import SempereRender
import SempereSync

/// What an `AppModelCore` needs from the front end that runs it: its canvas type and the platform services
/// (`AppModelServices`). Since wave 5b part 3, step 7, nothing else: the family is in the library, and what the app still
/// adds (the microphone half of a saved recording) is a service.
///
/// The app's host is `AppHost` (`Apps/Sempere/SempereApp/AppModel+Host.swift`), whose `AppModel` is
/// `AppModelCore<AppHost>`; the package's tests use `TestHost` on `TestCanvas`.
public protocol AppModelHost: Sendable {
    /// The editor's canvas (`NoteEditorModel<Canvas>`).
    associatedtype Canvas: NoteCanvas

    /// The platform services the model starts with (the app's: `UserDefaults.standard`, the Keychain, the network;
    /// tests: memory versions). Tests replace single services on the model afterwards, as before.
    @MainActor static func makeServices() -> AppModelServices
}

/// The platform services the moved `AppModel` code takes (docs/design/thin-app.md "The platform protocols"). Each
/// has a version for tests and the CLI (`headless`).
///
/// One rule for how the model reads them: a service tests replace on a model after it is made is copied into a model
/// property at init and read from there (`transcriber`, `playbackBackend`, `recordingRoot`, `iCloudHooks`, the WebDAV
/// remote and passwords, `quickCapture`, `ownerAuthenticator`, `backgroundTasks`, `syncScheduler`, and `settings` as
/// `deviceMemory`); every other one is read from `services` when used (`perf`, `settings`, `bookmarks`, `platform`,
/// `makeRenderCache`, `recordingsInUse`, `audioFiles`, `finishRecordingSave`, `settingsStorage`, `makePageRecognizer`,
/// `files`, `exportRendering`, `pdfTextExtractor`, `attachmentPreparation`, `lifecycle`, `makeReachability`), and a test
/// passes its own at init (or, for `lifecycle`, to `observeAppLifecycle` and `keepScreenOn`).
public struct AppModelServices {
    /// Timing and log lines (`AppPerfSink` in the app).
    var perf: any PerfSink
    /// Device settings (`UserDefaults.standard` in the app).
    public var settings: any KeyValueStore
    /// Security-scoped bookmarks of folder targets (`SecurityScopedBookmarks` in the app).
    var bookmarks: any FolderBookmarks
    /// The device (`AppPlatform`).
    var platform: any PlatformServices
    /// The WebDAV server calls (`LiveWebDAVRemote`) and passwords (the Keychain).
    var webdavRemote: any WebDAVRemote
    var webdavPasswords: any WebDAVPasswordStore
    /// The iCloud calls for copying a vault in, and for a sync folder pick (`CloudVault.Hooks.live`).
    var iCloudHooks: CloudVault.Hooks
    /// Transcribes recordings on device (`SpeechRecordingTranscriber`); nil: none.
    var transcriber: (any RecordingTranscribing)?
    /// The `app` the model's revisions carry (format.md §5.1: `NoteWriter.appName`, `sempere-ios/<version>`).
    var appName: String
    /// Makes the open vault's cache of drawn attachments under a root (nil: memory only): the app's `RenderCache`
    /// (CoreGraphics pictures); headless, a store of plain bytes.
    var makeRenderCache: @MainActor (_ root: URL?, _ vault: Vault) -> any RenderCaching
    /// What plays recordings (`AVAudioPlaybackBackend`; headless, `SilentPlaybackBackend`).
    var makePlaybackBackend: @MainActor () -> any AudioPlaybackBackend
    /// Where recordings in progress keep their files (`RecordingSession.root`); nil: a folder of the model's own.
    var recordingRoot: URL?
    /// The recordings whose files are in use (running, being saved or transcribed): recovery leaves them alone.
    var recordingsInUse: @MainActor () -> Set<UUID>
    /// What a recording's segment files hold, and their merge (`AVCaptureAudioFiles`; headless, bytes).
    var audioFiles: any CaptureAudioFiles
    /// A recording made in a note is saved and, when that setting is on, transcribed (`onRecordingSaved`, set by the
    /// model on every editor it opens): its session folder, holding the plaintext audio, goes. The app also stops
    /// counting the recording as in use (`RecordingSession.busy`); headless, the folder is deleted.
    var finishRecordingSave: @MainActor (_ recording: UUID, _ folder: URL) -> Void
    /// Quick voice notes (the app's `QuickCapture.shared`; headless, a capture that records nothing, its folders in
    /// the model's own scratch folder, which it is given).
    var makeQuickCapture: @MainActor (_ scratch: URL) -> QuickCapture
    /// Where this device keeps the shared settings that are not the model's (`SettingsSyncBridge`; the app's
    /// `AppSettingsStorage`, `UserDefaults` through the settings' own types; headless, `StoredSettingsSyncStorage`).
    var settingsStorage: any SettingsSyncStorage
    /// Reads handwriting when recognition is turned on (`setHandwritingRecognition`; the app's Vision recognizer;
    /// headless, none).
    var makePageRecognizer: @MainActor () -> (any PageRecognizing)?
    /// Asks for the device owner before a list change that needs them at the device (Add Device, Replace Recovery Kit,
    /// a passphrase copy: design §6.5): the app's Face ID, Touch ID or passcode check; headless, none can be asked,
    /// and every check fails (`OwnerCheckUnavailable`).
    var ownerAuthenticator: any OwnerAuthenticator
    /// Coordinated reads of a folder a provider may touch while it is read (a copy-in, a restore from iCloud Drive):
    /// the app's `SystemFileCoordinator` (`NSFileCoordinator`); headless, none (`UncoordinatedFiles`).
    public var files: any FileCoordinating
    /// What exports draw with beyond the note itself (`RenderOptions`' PDF page rasterizer, image decoder and text
    /// shaper: the app's PDFKit, ImageIO and CoreText); headless, none (PDF pages and images are placeholders, text is
    /// left out as the CLI does without fonts).
    public var exportRendering: RenderOptions
    /// Reads the text of PDF pages for search in an import (`--pdf-text`): the app's PDFKit; headless, the package's
    /// own (`BuiltinPDFTextExtractor`, as the CLI and `PortableAttachmentPreparation`).
    public var pdfTextExtractor: (any PDFTextExtracting)?
    /// Turns picked images, PDFs and clips into what is stored, and tells a PDF the system opened the app with by its
    /// type: the app's PDFKit and Core Graphics, ImageIO, AVFoundation and `UTType`; headless, the package's own
    /// (`PortableAttachmentPreparation`, as the CLI on Linux).
    public var attachmentPreparation: any AttachmentPreparing
    /// The application entering and leaving the background, becoming active and resigning (`observeAppLifecycle`,
    /// "Keep Screen On"): the app's `UIApplication` notifications; headless, `ManualAppLifecycle`.
    public var lifecycle: any AppLifecycle
    /// Background time for the last saves and sync runs when the app leaves the screen (`beginBackgroundTask`);
    /// headless, none is given (`NoBackgroundTasks`).
    public var backgroundTasks: any BackgroundTaskRunning
    /// Scheduled background sync tasks (`BGTaskScheduler`); headless, none (`NoBackgroundSyncScheduler`).
    public var syncScheduler: any BackgroundSyncScheduling
    /// Watches the network for the WebDAV targets (`startReachability`: the app's `NWPathMonitor`); headless, none.
    public var makeReachability: @MainActor () -> (any NetworkReachability)?
    /// Words every error the model (and the editors and the quick capture it opens) turns into text itself: a note
    /// that failed to export, a failed read, the notices' reasons, the editors' save, recognition and recording
    /// failures, a quick voice note's banner. The app's `AppModel.describe`; headless, the error's own description.
    public var describeError: ErrorDescriber

    public init(perf: any PerfSink, settings: any KeyValueStore, bookmarks: any FolderBookmarks,
                platform: any PlatformServices, webdavRemote: any WebDAVRemote, webdavPasswords: any WebDAVPasswordStore,
                iCloudHooks: CloudVault.Hooks, transcriber: (any RecordingTranscribing)?, appName: String,
                makeRenderCache: @escaping @MainActor (_ root: URL?, _ vault: Vault) -> any RenderCaching = AppModelServices.dataRenderCache,
                makePlaybackBackend: @escaping @MainActor () -> any AudioPlaybackBackend = { SilentPlaybackBackend() },
                recordingRoot: URL? = nil, recordingsInUse: @escaping @MainActor () -> Set<UUID> = { [] },
                audioFiles: any CaptureAudioFiles = ByteCaptureAudioFiles(),
                finishRecordingSave: @escaping @MainActor (_ recording: UUID, _ folder: URL) -> Void
                    = AppModelServices.deleteRecordingFolder,
                makeQuickCapture: @escaping @MainActor (_ scratch: URL) -> QuickCapture = AppModelServices.scratchQuickCapture,
                settingsStorage: any SettingsSyncStorage = StoredSettingsSyncStorage(),
                makePageRecognizer: @escaping @MainActor () -> (any PageRecognizing)? = { nil },
                ownerAuthenticator: any OwnerAuthenticator = NoOwnerCheck(),
                files: any FileCoordinating = UncoordinatedFiles(),
                exportRendering: RenderOptions = RenderOptions(), pdfTextExtractor: (any PDFTextExtracting)? = BuiltinPDFTextExtractor(),
                attachmentPreparation: any AttachmentPreparing = PortableAttachmentPreparation(),
                lifecycle: any AppLifecycle = ManualAppLifecycle(), backgroundTasks: any BackgroundTaskRunning = NoBackgroundTasks(),
                syncScheduler: any BackgroundSyncScheduling = NoBackgroundSyncScheduler(),
                makeReachability: @escaping @MainActor () -> (any NetworkReachability)? = { nil },
                describeError: @escaping ErrorDescriber = plainErrorDescription) {
        self.perf = perf
        self.settings = settings
        self.bookmarks = bookmarks
        self.platform = platform
        self.webdavRemote = webdavRemote
        self.webdavPasswords = webdavPasswords
        self.iCloudHooks = iCloudHooks
        self.transcriber = transcriber
        self.appName = appName
        self.makeRenderCache = makeRenderCache
        self.makePlaybackBackend = makePlaybackBackend
        self.recordingRoot = recordingRoot
        self.recordingsInUse = recordingsInUse
        self.audioFiles = audioFiles
        self.finishRecordingSave = finishRecordingSave
        self.makeQuickCapture = makeQuickCapture
        self.settingsStorage = settingsStorage
        self.makePageRecognizer = makePageRecognizer
        self.ownerAuthenticator = ownerAuthenticator
        self.files = files
        self.exportRendering = exportRendering
        self.pdfTextExtractor = pdfTextExtractor
        self.attachmentPreparation = attachmentPreparation
        self.lifecycle = lifecycle
        self.backgroundTasks = backgroundTasks
        self.syncScheduler = syncScheduler
        self.makeReachability = makeReachability
        self.describeError = describeError
    }

    /// A quick capture that records nothing (`QuickCapture`'s defaults), its folders under `scratch`.
    @MainActor public static func scratchQuickCapture(_ scratch: URL) -> QuickCapture {
        QuickCapture(root: scratch.appendingPathComponent("QuickCapture", isDirectory: true),
                     queueRoot: scratch.appendingPathComponent("CaptureQueue", isDirectory: true))
    }

    /// Deletes a saved recording's session folder (the plaintext audio).
    @MainActor public static func deleteRecordingFolder(_ recording: UUID, _ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A render cache of plain bytes (`DataPictureCodec`), for tests and front ends that draw nothing.
    @MainActor public static func dataRenderCache(root: URL?, vault: Vault) -> any RenderCaching {
        RenderStore<DataPictureCodec>(root: root, vault: vault, capBytes: RenderStore<DataPictureCodec>.defaultCapBytes,
                                      salt: "", memoryWarning: nil)
    }

    /// Memory versions: settings in memory, plain paths for bookmarks, an iPad with no haptics, no server, passwords
    /// in memory, no iCloud, no transcriber, the package's own attachment preparation and PDF page text, an app
    /// lifecycle driven by hand, no background time, no scheduled tasks and no network watcher.
    static func headless(settings: any KeyValueStore = MemoryKeyValueStore(),
                                webdavRemote: any WebDAVRemote = OfflineWebDAVRemote(),
                                describeError: @escaping ErrorDescriber = plainErrorDescription) -> AppModelServices {
        AppModelServices(perf: NoPerfSink(), settings: settings, bookmarks: PathBookmarks(), platform: HeadlessPlatform(),
                         webdavRemote: webdavRemote, webdavPasswords: MemoryWebDAVPasswordStore(),
                         iCloudHooks: CloudVault.Hooks(isUbiquitous: { _ in false }, state: { _ in .current },
                                                       request: { _ in }),
                         transcriber: nil, appName: "sempere-app-core", describeError: describeError)
    }
}

extension DeviceClock {
    /// `Application Support/Sempere/device.json` in the app's container
    /// (on iPad and in the Catalyst sandbox that is per installation).
    public static var defaultURL: URL { AppSupport.sempere.appendingPathComponent("device.json") }
}

/// Turns an error into the sentence a user reads (`AppModelServices.describeError`, `QuickCapture.describeError`).
public typealias ErrorDescriber = @Sendable (any Error) -> String

/// An error's own description, for a front end that has no words of its own (tests, previews).
@Sendable public func plainErrorDescription(_ error: any Error) -> String { "\(error)" }
