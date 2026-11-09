import Foundation
import Sempere
import SempereRender
import SempereSync

/// What an `AppModelCore` needs from the front end that runs it: its canvas type, the platform services the moved
/// code takes (`AppModelServices`), and, until wave 5b part 3 moves the rest of the family, the state and the steps
/// of the extensions still in the app (docs/design/thin-app.md "Wave 5b, part 2").
///
/// The app's host is `AppHost` (`Apps/Sempere/SempereApp/AppModel+Host.swift`), whose `AppModel` is
/// `AppModelCore<AppHost>`; the package's tests use a host with no-op steps on `TestCanvas`. Every step is a
/// requirement without a default, so a host that forgets one does not compile.
public protocol AppModelHost: Sendable {
    /// The editor's canvas (`NoteEditorModel<Canvas>`).
    associatedtype Canvas: NoteCanvas
    /// The state of the extensions still in the app: properties whose types are the app's (part 3 moves them into
    /// the class with their code). Made once per model.
    associatedtype State: AnyObject

    /// The model's app-side state (`AppModelCore.appState`).
    @MainActor static func makeState() -> State
    /// The platform services the model starts with (the app's: `UserDefaults.standard`, the Keychain, the network;
    /// tests: memory versions). Tests replace single services on the model afterwards, as before.
    @MainActor static func makeServices() -> AppModelServices

    // MARK: Steps of the extensions still in the app (wave 5b part 3)

    /// At the start of `close()`, once settings sync stopped: the app-side state of the vault (drags) is forgotten.
    /// The core's `close()` itself cancels a running backup, inbox adoption and import, and forgets the last import's
    /// report, the drag-out exports and the export requests.
    @MainActor static func willClose(_ model: AppModelCore<Self>)
    /// The open editors changed ("Keep Screen On" follows them).
    @MainActor static func editorsChanged(_ model: AppModelCore<Self>)
    /// An editor opened for the library window is about to be shown: what happens to recordings made in it once
    /// saved (the microphone half is the app's).
    @MainActor static func prepareEditor(_ editor: NoteEditorModel<Canvas>, of note: UUID, in model: AppModelCore<Self>)
    /// What the detail pane says for a note whose read failed before it was shown.
    @MainActor static func unreadableText(_ editor: NoteEditorModel<Canvas>) -> String
    /// The note windows' editors (Mac): close them all, open one, reopen one.
    @MainActor static func closeWindowEditors(_ model: AppModelCore<Self>) async
    @MainActor static func openWindowNote(_ id: UUID, in model: AppModelCore<Self>) async throws
    @MainActor static func reopenWindowNote(_ id: UUID, in model: AppModelCore<Self>) async
}

/// The platform services the moved `AppModel` code takes (docs/design/thin-app.md "The platform protocols"). Each
/// has a version for tests and the CLI (`headless`).
///
/// One rule for how the model reads them: a service tests replace on a model after it is made is copied into a model
/// property at init and read from there (`transcriber`, `playbackBackend`, `recordingRoot`, `iCloudHooks`, the WebDAV
/// remote and passwords, `quickCapture`, `ownerAuthenticator`, and `settings` as `deviceMemory`); every other one is read from `services` when used (`perf`, `settings`,
/// `bookmarks`, `platform`, `makeRenderCache`, `recordingsInUse`, `audioFiles`, `settingsStorage`,
/// `makePageRecognizer`, `files`, `exportRendering`, `pdfTextExtractor`, `attachmentPreparation`), and a test passes
/// its own at init.
public struct AppModelServices {
    /// Timing and log lines (`AppPerfSink` in the app).
    public var perf: any PerfSink
    /// Device settings (`UserDefaults.standard` in the app).
    public var settings: any KeyValueStore
    /// Security-scoped bookmarks of folder targets (`SecurityScopedBookmarks` in the app).
    public var bookmarks: any FolderBookmarks
    /// The device (`AppPlatform`).
    public var platform: any PlatformServices
    /// The WebDAV server calls (`LiveWebDAVRemote`) and passwords (the Keychain).
    public var webdavRemote: any WebDAVRemote
    public var webdavPasswords: any WebDAVPasswordStore
    /// The iCloud calls for copying a vault in, and for a sync folder pick (`CloudVault.Hooks.live`).
    public var iCloudHooks: CloudVault.Hooks
    /// Transcribes recordings on device (`SpeechRecordingTranscriber`); nil: none.
    public var transcriber: (any RecordingTranscribing)?
    /// The `app` the model's revisions carry (format.md §5.1: `NoteWriter.appName`, `sempere-ios/<version>`).
    public var appName: String
    /// Makes the open vault's cache of drawn attachments under a root (nil: memory only): the app's `RenderCache`
    /// (CoreGraphics pictures); headless, a store of plain bytes.
    public var makeRenderCache: @MainActor (_ root: URL?, _ vault: Vault) -> any RenderCaching
    /// What plays recordings (`AVAudioPlaybackBackend`; headless, `SilentPlaybackBackend`).
    public var makePlaybackBackend: @MainActor () -> any AudioPlaybackBackend
    /// Where recordings in progress keep their files (`RecordingSession.root`); nil: a folder of the model's own.
    public var recordingRoot: URL?
    /// The recordings whose files are in use (running, being saved or transcribed): recovery leaves them alone.
    public var recordingsInUse: @MainActor () -> Set<UUID>
    /// What a recording's segment files hold, and their merge (`AVCaptureAudioFiles`; headless, bytes).
    public var audioFiles: any CaptureAudioFiles
    /// Quick voice notes (the app's `QuickCapture.shared`; headless, a capture that records nothing, its folders in
    /// the model's own scratch folder, which it is given).
    public var makeQuickCapture: @MainActor (_ scratch: URL) -> QuickCapture
    /// Where this device keeps the shared settings that are not the model's (`SettingsSyncBridge`; the app's
    /// `AppSettingsStorage`, `UserDefaults` through the settings' own types; headless, `StoredSettingsSyncStorage`).
    public var settingsStorage: any SettingsSyncStorage
    /// Reads handwriting when recognition is turned on (`setHandwritingRecognition`; the app's Vision recognizer;
    /// headless, none).
    public var makePageRecognizer: @MainActor () -> (any PageRecognizing)?
    /// Asks for the device owner before a list change that needs them at the device (Add Device, Replace Recovery Kit,
    /// a passphrase copy: design §6.5): the app's Face ID, Touch ID or passcode check; headless, none can be asked,
    /// and every check fails (`OwnerCheckUnavailable`).
    public var ownerAuthenticator: any OwnerAuthenticator
    /// Coordinated reads of a folder a provider may touch while it is read (a copy-in, a restore from iCloud Drive):
    /// the app's `SystemFileCoordinator` (`NSFileCoordinator`); headless, none (`UncoordinatedFiles`).
    public var files: any FileCoordinating
    /// What exports draw with beyond the note itself (`RenderOptions`' PDF page rasterizer, image decoder and text
    /// shaper: the app's PDFKit, ImageIO and CoreText); headless, none (PDF pages and images are placeholders, text is
    /// left out as the CLI does without fonts).
    public var exportRendering: RenderOptions
    /// Reads the text of PDF pages for search in an import (`--pdf-text`): the app's PDFKit; headless, none.
    public var pdfTextExtractor: (any PDFTextExtracting)?
    /// Turns picked images, PDFs and clips into what is stored, and tells a PDF the system opened the app with by its
    /// type: the app's PDFKit and Core Graphics, ImageIO, AVFoundation and `UTType`; headless, the package's own
    /// (`PortableAttachmentPreparation`, as the CLI on Linux).
    public var attachmentPreparation: any AttachmentPreparing

    public init(perf: any PerfSink, settings: any KeyValueStore, bookmarks: any FolderBookmarks,
                platform: any PlatformServices, webdavRemote: any WebDAVRemote, webdavPasswords: any WebDAVPasswordStore,
                iCloudHooks: CloudVault.Hooks, transcriber: (any RecordingTranscribing)?, appName: String,
                makeRenderCache: @escaping @MainActor (_ root: URL?, _ vault: Vault) -> any RenderCaching = AppModelServices.dataRenderCache,
                makePlaybackBackend: @escaping @MainActor () -> any AudioPlaybackBackend = { SilentPlaybackBackend() },
                recordingRoot: URL? = nil, recordingsInUse: @escaping @MainActor () -> Set<UUID> = { [] },
                audioFiles: any CaptureAudioFiles = ByteCaptureAudioFiles(),
                makeQuickCapture: @escaping @MainActor (_ scratch: URL) -> QuickCapture = AppModelServices.scratchQuickCapture,
                settingsStorage: any SettingsSyncStorage = StoredSettingsSyncStorage(),
                makePageRecognizer: @escaping @MainActor () -> (any PageRecognizing)? = { nil },
                ownerAuthenticator: any OwnerAuthenticator = NoOwnerCheck(),
                files: any FileCoordinating = UncoordinatedFiles(),
                exportRendering: RenderOptions = RenderOptions(), pdfTextExtractor: (any PDFTextExtracting)? = nil,
                attachmentPreparation: any AttachmentPreparing = PortableAttachmentPreparation()) {
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
        self.makeQuickCapture = makeQuickCapture
        self.settingsStorage = settingsStorage
        self.makePageRecognizer = makePageRecognizer
        self.ownerAuthenticator = ownerAuthenticator
        self.files = files
        self.exportRendering = exportRendering
        self.pdfTextExtractor = pdfTextExtractor
        self.attachmentPreparation = attachmentPreparation
    }

    /// A quick capture that records nothing (`QuickCapture`'s defaults), its folders under `scratch`.
    @MainActor public static func scratchQuickCapture(_ scratch: URL) -> QuickCapture {
        QuickCapture(root: scratch.appendingPathComponent("QuickCapture", isDirectory: true),
                     queueRoot: scratch.appendingPathComponent("CaptureQueue", isDirectory: true))
    }

    /// A render cache of plain bytes (`DataPictureCodec`), for tests and front ends that draw nothing.
    @MainActor public static func dataRenderCache(root: URL?, vault: Vault) -> any RenderCaching {
        RenderStore<DataPictureCodec>(root: root, vault: vault, capBytes: RenderStore<DataPictureCodec>.defaultCapBytes,
                                      salt: "", memoryWarning: nil)
    }

    /// Memory versions: settings in memory, plain paths for bookmarks, an iPad with no haptics, no server, passwords
    /// in memory, no iCloud, no transcriber, the package's own attachment preparation.
    public static func headless(settings: any KeyValueStore = MemoryKeyValueStore(),
                                webdavRemote: any WebDAVRemote = OfflineWebDAVRemote()) -> AppModelServices {
        AppModelServices(perf: NoPerfSink(), settings: settings, bookmarks: PathBookmarks(), platform: HeadlessPlatform(),
                         webdavRemote: webdavRemote, webdavPasswords: MemoryWebDAVPasswordStore(),
                         iCloudHooks: CloudVault.Hooks(isUbiquitous: { _ in false }, state: { _ in .current },
                                                       request: { _ in }),
                         transcriber: nil, appName: "sempere-app-core")
    }
}

extension DeviceClock {
    /// `Application Support/Sempere/device.json` in the app's container
    /// (on iPad and in the Catalyst sandbox that is per installation).
    public static var defaultURL: URL { AppSupport.sempere.appendingPathComponent("device.json") }
}
