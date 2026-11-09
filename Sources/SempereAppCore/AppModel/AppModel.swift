import Age
import Foundation
import Observation
import Sempere
import SempereImport
import SempereRender
import SempereSync
import SempereWebDAV

/// How the note list is ordered (the field; "Favorites at Top" is `AppModel.favoritesFirst`).
/// The order itself is the package's `NoteOrder`, which `sempere notes list --sort` uses too. The picker's label is
/// the app's (`NoteSort.title`, `AppModel+Text.swift`).
public enum NoteSort: String, CaseIterable, Identifiable, Sendable {
    case modified = "Date Modified"
    case created = "Date Created"
    case title = "Title"

    public var id: String { rawValue }

    /// The package's key for this order.
    public var key: NoteOrder.Key {
        switch self {
        case .modified: return .modified
        case .created: return .created
        case .title: return .title
        }
    }
}

/// The note list's order on this device (`UserDefaults`): kept by the list's
/// view (`NoteListView`), which hands it to the model, so tests start from the
/// model's defaults.
public enum NoteSortPreference {
    public static let sortKey = "Sempere.noteSort"
    public static let favoritesFirstKey = "Sempere.noteSortFavoritesFirst"
}

/// What the sidebar has selected; filters the note list.
public enum SidebarItem: Hashable, Sendable {
    case allNotes
    case notebook(String)
    case tag(String)
    case deleted
    /// Notes marked as favorites (`meta.favorite`, format.md §5.4).
    case favorites
    /// The notes the last "Recognize All Notes" run changed (`AppModel.recognitionResults`).
    case recentlyRecognized
}

/// Where the open vault is (`AppModel.phase`).
public enum AppModelPhase: Equatable, Sendable {
    /// No vault chosen.
    case noVault
    /// A vault is open by name only; notes need a key.
    case locked
    /// Notes are readable.
    case unlocked
}

/// Errors the shell reports to the user (`AppModel.ModelError`); worded by the app (`AppModel+Text.swift`).
public enum AppModelError: Error, Equatable, Sendable {
    case noVaultOpen
    case notAnIdentity
    case noStoredKeys
    case passphraseMatchesNoKey
    /// None of the given keys is listed in `vault.json`: this device has not joined the vault.
    case notJoined
    case noteNotFound
    /// A note of a partial copy (a join) not downloaded yet, its server unknown.
    case noteNotDownloaded
    /// The same, from the WebDAV server (host) of a partial copy.
    case noteNotDownloadedFromServer(String)
    /// An edit over many notes while some are still downloading (a join), its server unknown.
    case notesStillDownloading
    /// The same, from the WebDAV server (host) of a partial copy.
    case notesStillDownloadingFromServer(String)
    /// The open note's pending canvas changes could not be saved first (the editor's `saveFailure`).
    case unsavedChanges(String)
    /// A notebook dropped into itself or a notebook inside it.
    case invalidNotebookMove
    /// Delete Notebook on a notebook a note is still in.
    case notebookNotEmpty
    /// A new notebook's name is longer than a notebook record allows.
    case notebookNameTooLong

    /// A note not downloaded yet: a fetch may bring it.
    public var isNotDownloaded: Bool {
        switch self {
        case .noteNotDownloaded, .noteNotDownloadedFromServer: return true
        default: return false
        }
    }
}

/// Window-level state: the open vault, its note summaries and the current selection. Vault I/O runs off the main
/// actor; results land here. The app's `AppModel` is `AppModelCore<AppHost>` (docs/design/thin-app.md "Wave 5b,
/// part 2"): the host supplies the canvas, the platform services and, until part 3, the state and steps of the
/// extensions still in the app (`AppModelHost`).
@MainActor
@Observable
public final class AppModelCore<Host: AppModelHost> {
    public typealias Phase = AppModelPhase
    public typealias ModelError = AppModelError
    /// The editor of a note on this host's canvas.
    public typealias Editor = NoteEditorModel<Host.Canvas>

    public private(set) var phase: Phase = .noVault
    /// The open vault's folder.
    public private(set) var vaultURL: URL?
    /// The open vault was handed to the app from outside (AirDrop, Files, another
    /// app: `handleOpened`), not opened in it.
    public private(set) var vaultOpenedExternally = false
    /// Every note in the vault, deleted ones included, sorted by title
    /// (`byTitle`). Passes change it in batches (`queueListUpdate`).
    public var notes: [NoteSummary] = [] {
        didSet {
            listVersion &+= 1
            updateSearch(changed: listChangeIDs)
        }
    }
    /// While `applyListChanges` assigns `notes`: the ids it may have changed, so
    /// that an open search re-tests only those (`updateSearch(changed:)`).
    @ObservationIgnored public var listChangeIDs: Set<UUID>?
    /// Bumped on every change of `notes` (and of `declaredNotebooks`); keys the derived lists (`derived`).
    public private(set) var listVersion = 0
    /// Empty notebooks kept by notebook records (format.md §14), canonical paths
    /// (`refreshNotebookRecords`). The sidebar shows them with the notes' notebooks.
    public var declaredNotebooks: [String] = [] {
        didSet { if declaredNotebooks != oldValue { listVersion &+= 1 } }
    }
    /// The record file names `declaredNotebooks` was read from: a pass that
    /// lists the same names reads nothing.
    @ObservationIgnored public var notebookRecordNamesRead: [String]?
    /// `visibleNotes`, `tags` and `notebookTree`, computed once per change.
    @ObservationIgnored public var derived = DerivedLists()
    /// True while vault I/O is in flight.
    public private(set) var isBusy = false
    /// The last error, as a sentence for an alert; cleared by the view.
    public var errorMessage: String?
    /// Reading note summaries (opening or refreshing the vault), for the
    /// list's "Opening vault: N of M"; nil when no read is running.
    public var loading: NoteLoading?
    /// True once a listing of the open vault has completed (the list is
    /// then what the vault holds, not a partial or cached view).
    public var listLoaded = false
    /// Why the last listing failed, shown in an empty list (cleared by the next one).
    public var loadFailure: String?
    /// Notes whose summary in `notes` was read (or confirmed from the cache)
    /// in this session. A summary shown from an earlier launch's cache, or a
    /// placeholder, is not: edits that decide from a summary re-read the
    /// note first, and a notebook rename waits until every note is verified.
    public var verifiedNoteIDs: Set<UUID> = []
    /// Bumped per note by `refresh` (an edit's own re-read): a listing batch
    /// read before it must not merge its older summary over the newer one.
    public var summaryEpochs: [UUID: Int] = [:]
    /// The newest summary-cache save (`saveSummaryCache`).
    @ObservationIgnored public var summaryCacheSave: Task<Void, Never>?

    /// The sidebar row shown. Choosing another one scopes a running search to
    /// it (TestFlight build 6: the title changed but the results stayed those
    /// of All Notes); the query is kept.
    public var sidebarSelection: SidebarItem? = .allNotes {
        didSet {
            if sidebarSelection != oldValue, searchScope != .list { searchScope = .list }
            updateSearch()
        }
    }
    public var selectedNoteID: UUID?
    /// The search field's text. `visibleNotes` filters by title with it; the
    /// note list shows `searchResults` (`AppModel+Search`) while it is not empty.
    public var searchText = "" { didSet { updateSearch() } }
    public var searchScope = SearchScope.list { didSet { updateSearch() } }
    /// Notes matching `searchText` (title, notebook, tag, recognized handwriting), best first.
    public var searchResults: [NoteSearchHit] = []
    /// True from a change of the query until its results are in.
    public var isSearching = false
    /// Also search the transcripts of recordings (`AppModel+TranscriptSearch`; per device, off by default).
    public var searchTranscripts: Bool
    /// Transcript segments matching `searchText` while `searchTranscripts` is on.
    public var transcriptHits: [TranscriptSearchHit] = []
    /// Transcripts the last transcript search could not read.
    public var transcriptSearchProblems = 0
    @ObservationIgnored public let transcriptCache = TranscriptSearchCache()
    /// The recording to show once its note is open (a tapped transcript hit).
    public var pendingRecordingJump: RecordingJump?
    /// The page to show once the note is open (a tapped search hit).
    public var pendingJump: PageJump?
    @ObservationIgnored public var searchTask: Task<Void, Never>?
    /// Lowercased page text kept between searches (`NoteSearchIndex`).
    @ObservationIgnored public let searchIndex = NoteSearchIndex()
    /// What `searchResults` answer, and the notes changed since (`updateSearch(changed:)`);
    /// nil while no search has completed for the current query, scope and selection.
    @ObservationIgnored public var completedSearch: CompletedSearch?
    /// The title of a note created at a date with no title typed, as Settings
    /// → New Notes says (`NewNoteSettings`; "" for Blank: the note stays
    /// untitled). Tests replace it.
    @ObservationIgnored public var defaultTitle: (Date) -> String
    /// Pause after typing before the search runs.
    @ObservationIgnored public var searchDebounce = Duration.milliseconds(200)
    /// Reads handwriting on pages as they change and when notes open; nil = off.
    public var recognizer: (any PageRecognizing)? {
        didSet {
            editor?.recognizer = recognizer
            for window in windowEditors.values { window.recognizer = recognizer }
        }
    }
    /// Transcribes recordings on device (`AppModel+Recordings`); tests inject a fake.
    @ObservationIgnored public var transcriber: (any RecordingTranscribing)?
    /// Makes the players' audio backends (`services.makePlaybackBackend`; tests pass fakes).
    @ObservationIgnored public var playbackBackend: @MainActor () -> any AudioPlaybackBackend
    /// Where recordings in progress keep their files (`services.recordingRoot`; tests pass their own).
    @ObservationIgnored public var recordingRoot: URL
    /// Notes whose left recordings `recoverRecordings` is saving now: one recovery per note at a time (a library
    /// editor and a note window's editor of the same note would otherwise merge and store the same folder at once).
    @ObservationIgnored public var recoveringNotes: Set<UUID> = []
    /// Recordings being transcribed now, by id.
    public var transcribing: Set<UUID> = []
    /// Quick voice notes (`AppModel+Inbox`; `services.makeQuickCapture`, the app's `QuickCapture.shared`); tests pass
    /// their own.
    @ObservationIgnored public var quickCapture: QuickCapture
    /// Voice notes adopted from the inbox in this session (for the UI).
    public var capturesAdopted = 0
    /// Why the last inbox adoption failed, if it did.
    public var inboxProblem: String?
    /// Inbox files that failed to read, so they are not decrypted again at
    /// every unlock (format.md §11.3, security review 2026-10, C5); next to
    /// the device state.
    public let inboxBackoff: InboxBackoff
    @ObservationIgnored public var inboxAdoption: Task<Void, Never>?
    /// A trigger arrived while an adoption ran: it looks again before it ends (`startInboxAdoption`).
    @ObservationIgnored public var inboxAdoptionAgain = false
    /// Quick capture delivered a file into a vault's inbox (`installInboxDeliveryObserver`).
    @ObservationIgnored public var inboxDeliveryObserver: (any NSObjectProtocol)?
    /// Progress of "Recognize All Notes" (`AppModel+Search`).
    public var recognitionProgress: RecognitionProgress?
    /// What the last "Recognize All Notes" run changed, kept (also after it
    /// ends) until the next run starts; the "Recently Recognized" filter lists it.
    public var recognitionResults: RecognitionResults?
    /// What this device remembers of the open vault between launches: the
    /// recent searches (`RecentActivity`, `AppModel+Activity`). "Recently
    /// Recognized" is in the vault (`meta.recognized`, shared by every device).
    public var activity = RecentActivity()
    /// Where `activity` is kept (a folder per vault secret inside it).
    @ObservationIgnored public var activityRoot: URL
    /// The clock "Recently Recognized" is measured with (tests move it).
    @ObservationIgnored public var activityNow: () -> Date = { Date() }
    /// Bumped when "Recently Recognized" changes by the clock alone (a run
    /// leaves the 7-day window, `recentlyRecognizedNextChange`), so what
    /// reads it is drawn again.
    public var activityClockTick = 0
    /// The unused-attachments index (`AppModel+AttachmentIndex`, docs/attachments.md §4):
    /// the entries read or updated this session, by note.
    @ObservationIgnored public var attachmentIndex: [UUID: AttachmentIndexEntry] = [:]
    /// Bumped whenever `attachmentIndex` changes, so Settings re-derives its numbers.
    public var attachmentIndexVersion = 0
    /// Notes waiting for their index update (latest current-state hashes, if known).
    @ObservationIgnored public var attachmentIndexQueue: [UUID: Set<String>?] = [:]
    /// How many notes are queued or being indexed (Settings shows progress).
    public var attachmentIndexPending = 0
    /// The task working through `attachmentIndexQueue`, owned by the model.
    @ObservationIgnored public var attachmentIndexTask: Task<Void, Never>?
    /// True once every stored entry of the open vault was read (`loadAttachmentIndex`).
    @ObservationIgnored public var attachmentIndexLoaded = false
    /// The open vault's sealed index files, made on first use.
    @ObservationIgnored public var attachmentIndexStoreCache: AttachmentIndexStore?
    /// Where the index is kept (a folder per vault secret inside it): the app's
    /// Application Support; without one (tests) a folder of this model alone.
    @ObservationIgnored public var attachmentIndexRoot: URL
    /// Waited before working through queued updates, so an editor's burst of
    /// autosaves is indexed once. Tests set zero.
    @ObservationIgnored public var attachmentIndexDelay: Duration = .seconds(2)
    /// The clock the 30-day window is measured with (tests move it).
    @ObservationIgnored public var attachmentNow: () -> Date = { Date() }
    /// Test seam: what an index update reads (a counting wrapper of the vault).
    @ObservationIgnored public var attachmentIndexSource: (@Sendable (Vault) -> any AttachmentIndexSource)?
    /// How long `landedDrop` stays set (tests shorten it).
    @ObservationIgnored public var landedDropDuration: Duration = .seconds(1.6)
    @ObservationIgnored public var recognitionTask: Task<Void, Never>?
    /// Pause after the last stroke change before the open note's pages are recognized.
    public let recognitionDelay: Duration
    /// True while the note list ticks several notes (to export them); the
    /// open note (`selectedNoteID`) is untouched meanwhile.
    public var isSelectingNotes = false
    /// The ticked notes while `isSelectingNotes`.
    public var multiSelection: Set<UUID> = []
    /// An import from another app is running (`AppModel+Import`).
    public var isImporting = false
    /// How far the running import is (nil when none runs): the window's progress overlay.
    public var importProgress: ImporterProgress?
    /// Stops the running import between notes (`cancelImport`); nil when the importer cannot stop safely.
    public var importCancellation: ImporterCancellation?
    /// What the last import did, until the alert is dismissed (`AppModel+Import`).
    public var importSummary: ImportSummary?
    /// The last import of this vault, for File > Last Import Report (until the vault closes).
    public var lastImportReport: ImportSummary?
    /// The export sheet's request (`AppModel+Export`).
    public var exportRequest: ExportRequest?
    /// The "Export to Folder or Zip…" sheet's request (`AppModel+BulkExport`).
    public var bulkExportRequest: BulkExportRequest?
    /// Where this model's drag-out exports (a note dragged to the Finder) are written; emptied when the vault closes.
    public let exportFolder: URL = NotePDFExport.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    /// Bumped when the vault closes: a drag-out export prepared before it writes nothing.
    public let exportEpoch = ExportEpoch()
    /// PDFs opened from outside the app (Finder's Open With, the share sheet), waiting to be imported as new notes
    /// (`AppModel+OpenedFiles`). The app's state, not the vault's: they wait while a vault is opened or unlocked, and
    /// closing a vault keeps them.
    public var openedPDFs: [OpenedPDF] = []
    public var sortOrder = NoteSort.modified
    /// Favorites at the top of the note list, under any `sortOrder`.
    public var favoritesFirst = false
    /// True while an edit is being written.
    public var isEditing = false
    /// Serializes edits (`commit`).
    public let editGate = EditGate()
    /// Thin old autosaves once a day after a vault's notes are listed
    /// (`thinIfDue`, format.md §5.8.4). The app turns it on; tests leave it
    /// off so nothing is written that they did not ask for.
    public var automaticThinning = false
    /// Notes thinning works on at once (`thinVault`).
    public var thinningConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    /// The last automatic run `thinIfDue` started (tests wait for it).
    @ObservationIgnored public var automaticThinningRun: Task<Void, Never>?
    /// How far a thinning run (or its preview) has got, counted per note;
    /// nil when none is running (`thinVault`).
    public var thinningProgress: ThinningProgress?
    /// "Open Vault…" copying a vault onto this device (`copyIn`), for the progress overlay.
    public var vaultCopy: VaultCopyProgress?
    /// Notes of a partial copy (a join, `AppModel+Join`) not downloaded yet.
    public var pendingNoteIDs: Set<UUID> = []
    /// The pending notes that have no summary yet (listed as placeholders).
    public var placeholderNoteIDs: Set<UUID> = []
    /// Per note shown, the sorted revision file names its summary was made
    /// from: from the index on open, then from every read. A pass reads only
    /// notes whose names on disk differ (`reconcile`).
    @ObservationIgnored public var indexedNames: [UUID: [String]] = [:]
    /// Summary changes waiting for the next list update (`queueListUpdate`).
    @ObservationIgnored public var listUpserts: [UUID: NoteSummary] = [:]
    @ObservationIgnored public var listRemovals: Set<UUID> = []
    @ObservationIgnored public var listFlushTask: Task<Void, Never>?
    @ObservationIgnored public var lastListApply: ContinuousClock.Instant?
    /// The shortest time between two list updates while notes are read.
    public var listUpdateInterval = Duration.milliseconds(250)
    /// How far a join's fill got (`AppModel+Join`), for the list's bar; nil when no partial copy is open.
    public var joinProgress: JoinProgress?
    /// The note `downloadNote` is fetching (a partial copy), for the note pane's wait and its Cancel.
    public var noteDownload: UUID?
    /// Cancels that wait (`cancelNoteDownload`); the fetch itself goes on.
    @ObservationIgnored public var noteDownloadCancel: (() -> Void)?
    @ObservationIgnored public var targetsBackgroundWait: Task<Void, Never>?
    /// The iCloud calls for copying a vault in from iCloud Drive (`copyIn`, a restore); tests replace them.
    @ObservationIgnored public var iCloudHooks: CloudVault.Hooks
    /// The download a sync folder pick asked iCloud for (`requestDownload(of:scope:)`); tests wait for it.
    @ObservationIgnored public var pickedDownloadRequest: Task<Void, Never>?
    /// The last on-demand fetch into the open partial copy (`joinFetch`): the next waits for it.
    @ObservationIgnored public var joinFetchTail: Task<Void, Never>?
    /// The rows of notes not downloaded yet, by note id, from published summaries
    /// (format.md §12): a partial WebDAV copy's from the server's file (`webdavUnlocked`).
    @ObservationIgnored public var publishedRows: [UUID: NoteSummary] = [:]
    /// The published summary files the rows were last read from (name, size, date), so they are
    /// read again only when one changes.
    @ObservationIgnored public var publishedRowsSignature: [String] = []
    /// The WebDAV locations of this device (`AppModel+WebDAV`, docs/io.md
    /// "WebDAV vaults in the app"). The app passes the default store; without
    /// one (tests) a store in a folder of this model alone.
    @ObservationIgnored public var webdavLocations: WebDAVLocationStore

    /// The folder holding this model's default (not injected) scratch locations; nothing is created in it until
    /// one is used, and `deinit` removes it.
    private let ownedScratch: URL

    deinit { try? FileManager.default.removeItem(at: ownedScratch) }
    /// The sync session of the open vault when it is a WebDAV location's local copy (the
    /// coordinator's, two-way while the vault is unlocked); nil for any other vault.
    public var webdav: SyncSession?
    /// The open vault's sync sessions, one per target (folder and WebDAV), in the order they were added
    /// (`AppModel+SyncTargets`); empty for a vault without targets.
    public var syncSessions: [SyncSession] = []
    /// The open vault's `vault.json` changed on disk (a sync took another device's key change) and the
    /// open `Vault` has not been opened again under it yet: its runs only upload (review of #70, F1).
    public var syncVaultStale = false
    /// A previous copy kept at launch (`recoverWebDAVLeftovers`), for its alert; nil when there is none.
    public var webdavLeftover: WebDAVLeftover?
    /// The coordinator once made (tests set their own).
    @ObservationIgnored public var coordinatorStorage: SyncCoordinator?
    /// Every in-app vault's sync sessions (`SyncCoordinator`, made on first use).
    public var syncCoordinator: SyncCoordinator {
        if let coordinatorStorage { return coordinatorStorage }
        let made = SyncCoordinator(targets: { [weak self] in self?.allSyncTargets() ?? [] },
                                   makeSession: { [weak self] ref in self?.makeSession(for: ref) },
                                   deliveries: QuickCapture.deliveredNotification, settings: services.settings,
                                   perf: services.perf)
        made.tick = webdavTick
        coordinatorStorage = made
        return made
    }
    /// The WebDAV vault being downloaded and how far it is, for the overlay; nil when none is.
    public var webdavDownload: WebDAVDownloadStatus?
    /// The Cancel of that download (`cancelWebDAVDownload`).
    @ObservationIgnored public var webdavDownloadCancel: WebDAVCancelFlag?
    /// The server calls (`LiveWebDAVRemote` in the app); tests pass a fake.
    @ObservationIgnored public var webdavRemote: any WebDAVRemote
    /// WebDAV passwords (the Keychain in the app); tests pass `MemoryWebDAVPasswordStore`.
    @ObservationIgnored public var webdavPasswords: any WebDAVPasswordStore
    /// How often a WebDAV session looks at its schedule, and how long after a
    /// write it pushes (`WebDAVPushSchedule.writeDelay`); tests shorten both.
    @ObservationIgnored public var webdavTick = Duration.seconds(1)
    @ObservationIgnored public var webdavWriteDelay: TimeInterval = 10
    /// How long after a write a folder target syncs (`AppModel+SyncTargets`); tests shorten it.
    @ObservationIgnored public var folderWriteDelay: TimeInterval = 2
    /// Longest a folder target's run waits for files a provider is downloading.
    @ObservationIgnored public var folderArrivalWait: TimeInterval = 10
    /// How often Add Device and the join screen look again while they wait (each look syncs); tests shorten it.
    @ObservationIgnored public var joinLookInterval = Duration.seconds(10)
    /// The provider of a folder target's folder; nil detects it (`FolderProviders.detect`). Tests pass
    /// `EvictingFolderProvider`s.
    @ObservationIgnored public var folderProvider: (@Sendable (URL) -> (any FolderProvider)?)?
    /// Whether a provider (iCloud Drive) has uploaded a file a folder target's run wrote (`ProviderUploads`, offline
    /// audit P15); tests pass fakes.
    @ObservationIgnored public var providerUploadCheck: ProviderUploads.Check = ProviderUploads.system
    /// An automatic transcription already said this launch that the language model is missing (offline audit A-P1).
    @ObservationIgnored public var modelMissingReported = false

    /// Listings and downloads at once in a WebDAV download (`SyncOptions.concurrency`).
    @ObservationIgnored public var webdavConcurrency = TransferPool.defaultWidth
    /// The running Back Up Now, Verify Backup or restore (`AppModel+Backup`),
    /// nil when none runs.
    public var backupProgress: BackupProgress?
    /// Cancels the running backup (`cancelBackup`).
    @ObservationIgnored public var backupControl: BackupRunControl?
    /// Per-vault backup folders and results (`services.settings`: `UserDefaults` in the app; tests use a scratch suite).
    @ObservationIgnored public var backupStore: BackupStore
    /// Delivers backup reminders; the app installs `UserNotificationBackupNotifier`.
    @ObservationIgnored public var backupNotifier: any BackupNotifying = NoBackupNotifier()
    /// Settings sync with the open vault (`AppModel+SettingsSync`, docs/settings-sync.md):
    /// this device's state for it, kept per vault in `services.settings`.
    public var settingsSync = SettingsSyncState()
    /// Why settings sync is paused or failed; nil while it works (or is off).
    public var settingsSyncProblem: SettingsSyncProblem?
    /// Turning sync on found settings that differ: the choice to ask for.
    public var settingsSyncPrompt: SettingsSyncPrompt?
    /// Bumped whenever values from the vault were applied, so the Settings
    /// sections that hold copies of their values reload them.
    public var settingsAppliedRevision = 0
    /// Tests: the device type to sync as (nil: this device's).
    @ObservationIgnored public var settingsDeviceTypeOverride: SettingsDeviceType?
    /// How long after the last local change a pass runs.
    @ObservationIgnored public var settingsSyncDebounce: Duration = .seconds(1)
    /// Follows changes to `services.settings` while a vault is open (`startSettingsSync`).
    @ObservationIgnored public var settingsSyncObserver: KeyValueObservation?
    @ObservationIgnored public var settingsSyncScheduled: Task<Void, Never>?
    @ObservationIgnored public var settingsSyncRunning = false
    /// How long a copy-in or restore from iCloud Drive waits without progress, and how often it looks
    /// (`downloadSourceFolder`); tests shorten them.
    public var cloudPollInterval = Duration.seconds(1)
    public var cloudStallTimeout = Duration.seconds(90)
    /// How long opening a note waits for its fetch in a partial copy before it says "not downloaded yet"
    /// (the fetch goes on; opening it again shows it once it is in).
    public var noteFetchTimeout = Duration.seconds(60)
    /// The shortest time between two summary-cache saves while notes arrive.
    public var summaryCacheSaveInterval = Duration.seconds(20)
    @ObservationIgnored public var lastSummaryCacheSave: ContinuousClock.Instant?
    /// Summary-cache saves started (each re-encodes and seals the whole index): check c20 counts them.
    @ObservationIgnored public var summaryCacheSaves = 0
    /// Test seam: awaited before an editor opened from the drawing cache
    /// takes the note it read in the background.
    @ObservationIgnored public var editorLoadHook: (@Sendable () async -> Void)?
    /// Test seam: told how many notes each listing batch read.
    @ObservationIgnored public var onSummaryRead: (@Sendable (Int) -> Void)?
    /// Notes read per published batch, and threads reading them (`AppModel+Loading`).
    public var loadBatchSize = 24
    /// The largest batch `readSummaries` makes when many notes changed.
    public var loadBatchLimit = 96
    public var loadConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    /// Where summaries are cached between launches (`SummaryCache`); nil (the
    /// default, for tests): no cache. The app passes `defaultSummaryCacheDirectory`.
    public let summaryCacheDirectory: URL?
    /// The open vault's summary cache, once unlocked.
    @ObservationIgnored public var summaryCache: SummaryCache?
    /// The load of `summaryCache` in progress (`openSummaryCache`).
    @ObservationIgnored public var summaryCacheOpening: Task<Void, any Error>?
    /// Where page drawings are cached between note opens (`DrawingCache`);
    /// nil (the default, for tests): no cache. The app passes
    /// `DrawingCache.defaultRoot`.
    public let drawingCacheRoot: URL?
    /// The open vault's drawing cache, opened with the first note; deleted
    /// when the vault closes.
    @ObservationIgnored public var drawingCache: DrawingCache?
    /// The listing started by `unlock`, owned by the model so that no view
    /// (an unlock sheet going away) can cancel it.
    @ObservationIgnored public var loadTask: Task<Void, any Error>?
    /// Serializes listings: a reload, the iCloud sync loop and a pull to
    /// refresh never read the same notes at once.
    public let loadGate = EditGate()


    /// Where this install keeps its device id and hybrid clock.
    public let deviceStateURL: URL
    /// Why the selected note could not be opened (`showSelectedNote`).
    public var editorFailure: (id: UUID, message: String)?
    /// The note open on the canvas, if any (`openEditor(for:)`).
    public private(set) var editor: Editor? {
        didSet { Host.editorsChanged(self) }   // "Keep Screen On" counts open notes, whichever scene shows them
    }

    public private(set) var vault: Vault? {
        // Decrypted attachments and copied items belong to the vault (and the
        // secret) they came from.
        didSet { dropAttachments() }
    }
    /// Decrypted attachments of the open vault (`AppModel+Attachments`),
    /// created on first use, deleted whenever `vault` changes or closes.
    @ObservationIgnored public var blobCache: BlobCache?
    /// The open vault's drawn attachments (`attachmentRenders`), made on first use; closed with the vault.
    @ObservationIgnored public var renderCache: (any RenderCaching)?
    /// Items copied for pasting (`ItemClipboard`), within the open vault.
    public let itemClipboard = ItemClipboard()
    /// Where this model's attachment caches go (a folder per vault secret
    /// inside): the app's `BlobCache.folder`, kept across launches; without
    /// one (tests) a folder of this model alone. Tests may set their own.
    @ObservationIgnored public var blobCacheFolder: URL
    /// Whether decrypted attachments are reused by a later launch
    /// (`BlobCache.keepsAcrossLaunches`: not on a Mac). Tests may set it.
    @ObservationIgnored public var blobCacheAcrossLaunches = BlobCache.keepsAcrossLaunches
    /// Where drawn attachments (pictures, PDF page previews) are cached
    /// between note opens and launches (`RenderCache`); nil (the default, for
    /// tests): kept in memory only. The app passes `RenderCache.defaultRoot`.
    public let renderCacheRoot: URL?
    /// Merges of revisions written elsewhere into open editors, by note id
    /// (`AppModel+RemoteMerge`).
    @ObservationIgnored public var remoteMerges: [UUID: Task<Void, Never>] = [:]
    /// Per note, the revision names a merge could not read: not tried again
    /// until the names change.
    @ObservationIgnored public var unreadableMergeNames: [UUID: [String]] = [:]
    /// Editors of note windows (Mac), by note id: one per note, each with its
    /// own canvas (`AppModel+Windows`).
    public var windowEditors: [UUID: Editor] = [:] {
        didSet { Host.editorsChanged(self) }
    }
    /// Notes shown by a window of their own; the library window's detail pane
    /// does not open an editor for them.
    public var windowClaims: Set<UUID> = []
    /// Notes `openEditor` is reading (its editor not assigned yet), with how
    /// many opens are under way: open for thinning (`isNoteOpen`).
    @ObservationIgnored public var openingNoteIDs: [UUID: Int] = [:]
    /// Bumped when the vault's keys changed under the open editors
    /// (`AppModel+Keys`): views reopen their notes.
    public var keyEpoch = 0
    /// True while a recipient change re-encrypts the vault (`AppModel+Keys`):
    /// no editor opens meanwhile, since it would hold the old vault and secret.
    public var isChangingKeys = false
    /// The library window whose detail pane shows `editor` (`WindowUI.id`).
    /// One canvas per editor: a second canvas on the same editor would report
    /// a drawing without the first one's new strokes, which the ledger takes
    /// as erasures.
    public var canvasWindow: UUID?
    /// When a note window last asked for a library window (coalesces the
    /// requests of several restored note windows).
    public var libraryWindowRequested: Date?
    /// Library windows on screen (a note window restored alone opens one).
    public var libraryWindowCount = 0
    /// "New Note" was chosen in the Mac menu-bar item at this time and has not been carried out yet
    /// (`AppModel+MenuBar`).
    public var menuBarNewNoteRequest: Date?
    /// This device's trust records of the vaults' device lists (format.md
    /// §15.10). The app keeps them in Application Support (`defaultTrustDirectory`);
    /// without one (tests) none is kept, and a list that checks under the
    /// vault's key is taken as it is (`ListStatus.Verification.firstUse`).
    public let trust: (any EpochTrustStore)?
    /// This device's write ledger and set-aside store per vault (key-hierarchy design §5.4, §5.8): the app
    /// sets them at launch (`DeviceWriteStores.app`); without them (tests) nothing is recorded and a device
    /// change is not caught up.
    @ObservationIgnored public var writeStores: DeviceWriteStores?
    /// The open vault's `vault.json` did not check at unlock (design §4.3): the
    /// blocking alert (`ListAlert`). Nothing is written to the vault meanwhile.
    public var listAlert: ListAlert?
    /// The Confirm Vault sheet is shown (`needsVaultConfirmation`: the kit's root confirms the vault here).
    public var confirmingVault = false
    /// While this device is joining the open, locked vault (key-hierarchy design §6.2): its key, so the vault's
    /// runs are keyless two-way runs that take home's approval (`SyncOptions.firstPullIdentities`).
    public var joinIdentity: NativeIdentity?
    /// Each target's run before a device change is bounded by this (design §5.2 step 2); tests shorten it.
    @ObservationIgnored public var deviceChangeRunBound: TimeInterval = EpochChangePull.defaultBound
    /// The targets run before a device change (the sheets' "Syncing…" with its Cancel).
    public var isSyncingBeforeChange = false
    /// Set while they run: Cancel skips the rest (`cancelDeviceChangeSync`).
    @ObservationIgnored public var deviceChangeCancel: SyncRunCancel?
    @ObservationIgnored public var deviceChangeWaitCancel: (() -> Void)?
    /// A re-encryption step is going (`advanceReencryption`): the progress sheet and the Devices row bind to it, so a
    /// second one is never queued behind it (review of #89, S7).
    public var isAdvancingReencryption = false
    /// Set while it goes: Cancel stops it between files and steps (`cancelReencryptionStep`).
    @ObservationIgnored public var reencryptCancel: SyncRunCancel?
    /// This device's state as last read off the main actor (`refreshDeviceState`): since when a change it cannot
    /// verify holds its sync back, and the sightings Repair lists.
    public var heldSinceAtOpen: Date?
    /// The clock the device banners judge "more than a day" by; tests set it.
    @ObservationIgnored public var deviceNoticeNow: () -> Date = { Date() }
    /// The sightings Repair lists, as last read off the main actor (`refreshDeviceState`).
    public var sightingRowsState: [SightingRow] = []
    /// A takeover by another device that this device has not acknowledged (key-hierarchy design §6.3): a banner until
    /// dismissed (`AppModel+Devices`).
    public var takeoverAlert: TakeoverAlert?
    /// Where acknowledged takeovers, the names of devices no list holds any more and this device's open join are
    /// remembered per vault (`services.settings`: `UserDefaults` in the app); tests pass their own.
    @ObservationIgnored public var deviceMemory: any KeyValueStore
    /// Asks for the device owner before a list change that needs them at the device (`services.ownerAuthenticator`);
    /// tests replace it.
    @ObservationIgnored public var ownerAuthenticator: any OwnerAuthenticator
    /// The devices whose removal by this device a takeover undid (offline audit P16; `AppModel+DeviceNotices`): the
    /// record the vault's sync runs keep beside its targets' states (`UndoneRemovalsRecord`, from the run that took the
    /// takeover, `SyncOptions.undoneRemovalsURL`). Tests pass fakes.
    @ObservationIgnored public var undoneRemovalsSource: @Sendable (Vault) -> [UndoneRemoval] = UndoneRemoval.recorded
    /// The keys the vault was unlocked with, for opening it again (a WebDAV
    /// copy downloaded again, a backup check).
    public var unlockKeys = UnlockKeys()
    /// The identities the vault was unlocked with.
    public var unlockIdentities: [any AgeIdentity] { unlockKeys.identities }
    private var scopedURL: URL?
    /// The in-app vault store (`VaultLibrary.vaultStore`): the app sets it, so an open store vault
    /// holds a lease (`storeLease`); nil in tests that need none.
    @ObservationIgnored public var vaultStore: VaultStore? {
        didSet {
            // WebDAV targets live in the store's target registry.
            if let vaultStore, vaultStore.root != webdavLocations.store.root {
                webdavLocations = WebDAVLocationStore(store: vaultStore)
            }
        }
    }
    /// The store whose vaults have sync targets: the app's, else (tests) the model's own scratch store.
    public var syncStore: VaultStore { vaultStore ?? webdavLocations.store }
    /// Held while a vault of `vaultStore` is open: removing it from the store is refused meanwhile
    /// (by the app, or `sempere store remove`). Released once the editors' last saves are written, and
    /// on iOS while the app is in the background (`prepareForSuspension`, AppModel+Suspension).
    @ObservationIgnored public var storeLease: VaultStore.Lease?
    /// The open store vault `storeLease` is for: kept while the lease is let go in the background, so it
    /// is taken again when the app comes back (`resumeAfterSuspension`).
    @ObservationIgnored public var storeLeaseVault: UUID?
    /// Whether the store lease is let go while the app is in the background (iOS, where the store is in
    /// the App Group container and a suspended app holding a lock there is killed: 0xdead10cc). Off on a
    /// Mac, which suspends nothing; tests turn it on.
    @ObservationIgnored public var releasesLocksInBackground: Bool
    /// The app is in the background with its locks let go (`prepareForSuspension`).
    @ObservationIgnored public var locksSuspended = false
    @ObservationIgnored public var suspensionWait: Task<Void, Never>?
    /// The app-lifecycle observers (`observeAppLifecycle`).
    @ObservationIgnored public var lifecycleObservers: [any NSObjectProtocol] = []
    /// Bumped by `close()` (and so by every `openVault`): async work started
    /// under an older generation must not publish its result (the vault it
    /// read is gone).
    public private(set) var generation = 0
    /// The save of the editor `close()` dropped; awaited before any note is
    /// opened again, so a reopened note is read after its last delta landed.
    public var closingEditor: Task<Void, Never>?
    /// Per WebDAV location: the push its closed session left running.
    /// Awaited before that copy is synced, replaced or removed again.
    public var stoppingWebDAV: [UUID: Task<Void, Never>] = [:]
    /// This installation's device id and clock, created on first write
    /// access. Every write (canvas autosave and browser edits) ticks this one
    /// clock, so the state file has a single writer.
    private var deviceClock: DeviceClock?
    public let editorDebounce: Duration
    /// Test seam: awaited after each piece of off-main vault work.
    private let afterIO: (@Sendable () async -> Void)?

    /// The platform services this model was made with (`Host.makeServices()` unless given).
    @ObservationIgnored public let services: AppModelServices
    /// The state of the extensions still in the app (`Host.State`, wave 5b part 3).
    @ObservationIgnored public let appState: Host.State

    public init(deviceStateURL: URL = DeviceClock.defaultURL, editorDebounce: Duration = NoteEditorDefaults.debounce,
         recognizer: (any PageRecognizing)? = nil, recognitionDelay: Duration = NoteEditorDefaults.recognitionDelay,
         summaryCacheDirectory: URL? = nil, drawingCacheRoot: URL? = nil,
         blobCacheRoot: URL? = nil, renderCacheRoot: URL? = nil,
         attachmentIndexRoot: URL? = nil,
         automaticThinning: Bool = false,
         trust: (any EpochTrustStore)? = nil,
         backupNotifier: (any BackupNotifying)? = nil,
         webdavLocations: WebDAVLocationStore? = nil,
         services: AppModelServices? = nil,
         afterIO: (@Sendable () async -> Void)? = nil) {
        let services = services ?? Host.makeServices()
        self.services = services
        appState = Host.makeState()
        defaultTitle = { [settings = services.settings] in NewNoteSettings.defaultTitle(settings, now: $0) }
        transcriber = services.transcriber
        playbackBackend = services.makePlaybackBackend
        iCloudHooks = services.iCloudHooks
        webdavRemote = services.webdavRemote
        webdavPasswords = services.webdavPasswords
        deviceMemory = services.settings
        ownerAuthenticator = services.ownerAuthenticator
        backupStore = BackupStore(defaults: services.settings)
        releasesLocksInBackground = !services.platform.isMac
        searchTranscripts = TranscriptSearchPreference.isOn(services.settings)
        self.trust = trust
        // One private scratch folder for every default location below, removed when the model goes away: a model
        // built without explicit roots (tests, previews) would otherwise leave three folders per instance in tmp.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SempereModel-\(UUID().uuidString)", isDirectory: true)
        ownedScratch = scratch
        quickCapture = services.makeQuickCapture(scratch)
        recordingRoot = services.recordingRoot ?? scratch.appendingPathComponent("Recordings", isDirectory: true)
        self.webdavLocations = webdavLocations
            ?? WebDAVLocationStore(store: VaultStore(root: scratch.appendingPathComponent("Vaults", isDirectory: true)))
        self.deviceStateURL = deviceStateURL
        activityRoot = deviceStateURL.deletingLastPathComponent().appendingPathComponent("Activity", isDirectory: true)
        inboxBackoff = InboxBackoff(fileURL: deviceStateURL.deletingLastPathComponent().appendingPathComponent("InboxBackoff.json"))
        self.automaticThinning = automaticThinning
        self.summaryCacheDirectory = summaryCacheDirectory
        self.drawingCacheRoot = drawingCacheRoot
        blobCacheFolder = blobCacheRoot
            ?? scratch.appendingPathComponent("Blobs", isDirectory: true)
        self.renderCacheRoot = renderCacheRoot
        self.attachmentIndexRoot = attachmentIndexRoot
            ?? scratch.appendingPathComponent("AttachmentIndex", isDirectory: true)
        self.editorDebounce = editorDebounce
        self.recognizer = recognizer
        self.recognitionDelay = recognitionDelay
        self.afterIO = afterIO
        if let backupNotifier { self.backupNotifier = backupNotifier }
    }


    // MARK: - Derived

    /// The vault's display name (folder name without `.sempere`).
    public var vaultName: String? {
        vaultURL.map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The notebook hierarchy of live notes and of the empty notebooks records
    /// keep (names are `/`-separated paths, format.md §5.4, §14).
    public var notebookTree: [NotebookNode] {
        let version = listVersion
        if let t = derived.tree, t.version == version { return t.value }
        let tree = NotebookRecords.tree(noteNotebooks: notes.filter { !$0.deleted }.map(\.notebook), declared: declaredNotebooks)
        derived.tree = (version, tree)
        return tree
    }

    /// Every notebook path in use by live notes or declared, parents included, in tree order.
    public var notebooks: [String] {
        NotebookNode.flatten(notebookTree)
    }

    /// Tags in use by live notes, sorted. Tags match case-insensitively
    /// ("Math" and "math" are one); the spelling shown is the first seen.
    public var tags: [String] {
        let version = listVersion
        if let t = derived.tags, t.version == version { return t.value }
        let tags = NoteOps.vaultTags(notes)
        derived.tags = (version, tags)
        return tags
    }

    /// The note list for the current sidebar selection, title search and sort order.
    public var visibleNotes: [NoteSummary] {
        // Recently Recognized depends on the time too (`activityNow`), which no key holds: never cached.
        if sidebarSelection == .recentlyRecognized { return computeVisibleNotes() }
        let key = DerivedLists.VisibleKey(version: listVersion, selection: sidebarSelection, search: searchText,
                                          sort: sortOrder, favoritesFirst: favoritesFirst)
        if let v = derived.visible, v.key == key { return v.value }
        let value = computeVisibleNotes()
        derived.visible = (key, value)
        return value
    }

    private func computeVisibleNotes() -> [NoteSummary] {
        let inSelection = notesInSelection
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? inSelection : inSelection.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return Self.sorted(matching, by: sortOrder, favoritesFirst: favoritesFirst)
    }

    /// The notes the sidebar selection shows, before any search.
    public var notesInSelection: [NoteSummary] {
        switch sidebarSelection ?? .allNotes {
        case .allNotes: return notes.filter { !$0.deleted }
        case .notebook(let n): return notes.filter { !$0.deleted && NotebookPath.name($0.notebook, isWithin: n) }
        case .tag(let t): return notes.filter { !$0.deleted && $0.tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(t) } }
        case .deleted: return notes.filter(\.deleted)
        case .favorites: return notes.filter { !$0.deleted && $0.favorite }
        case .recentlyRecognized:
            return recentlyRecognizedNotes
        }
    }

    public static func sorted(_ list: [NoteSummary], by order: NoteSort, favoritesFirst: Bool = false) -> [NoteSummary] {
        NoteOrder(order.key, favoritesFirst: favoritesFirst).sorted(list)
    }

    public var selectedNote: NoteSummary? {
        selectedNoteID.flatMap { notesByID[$0] }
    }

    // MARK: - Opening and unlocking

    /// Opens the vault at `url` by name only (no key yet). Starts
    /// security-scoped access for URLs from the document picker and keeps
    /// it until the vault is closed. Every vault the app opens is an in-app copy (`VaultStore`; tests and
    /// debug launches open local folders): nothing is fetched first.
    ///
    /// - Parameter scope: the URL whose security scope covers `url` when it is
    ///   not `url` itself (the folder the user picked, when `url` was found
    ///   inside it). Held instead of `url`'s own.
    ///   - external: the URL came from outside the app (`vaultOpenedExternally`).
    public func openVault(at url: URL, accessing scope: URL? = nil, external: Bool = false) async throws {
        close()
        vaultOpenedExternally = external
        let gen = generation
        let holder = scope ?? url
        let bookmarks = services.bookmarks
        let scoped = bookmarks.startAccessing(holder)
        // A vault folder is never a package (`BundleBitRepair`): a copy-in keeps the source's Finder flags.
        BundleBitRepair.clear(url, .openedVault, log: services.perf)
        let interval = services.perf.begin("vault.open")
        do {
            // A sandboxed Mac refuses a folder whose saved permission did not come back.
            #if DEBUG
            NSLog("SempereDebug folderAccess scoped=%d listable=%d", scoped ? 1 : 0,
                  (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil ? 1 : 0)
            #endif
            try FolderAccess.check(url, scoped: scoped)
            let opened = try await offMain { try Vault.open(at: url) }
            try ensureCurrent(gen)
            services.perf.end(interval, "")
            if scoped { scopedURL = holder }
            if let store = vaultStore, let stored = store.entry(containing: url) {
                storeLeaseVault = stored.vaultId
                // Opened in the background (no lock may be held there): taken when the app comes back.
                if !locksSuspended { storeLease = try? store.lease(stored.vaultId) }
            }
            vault = opened
            vaultURL = url
            phase = .locked
            // A store vault's targets: their sessions are the open ones (two-way once unlocked).
            attachSyncTargets(vaultID: opened.vaultId, at: url)
        } catch {
            services.perf.end(interval, "failed")
            if scoped { bookmarks.stopAccessing(holder) }
            throw error
        }
    }

    /// Opens the vault at `url` and unlocks it with `identities` in one step.
    public func openVault(at url: URL, identities: [any AgeIdentity]) async throws {
        try await openVault(at: url)
        try await unlock(with: identities)
    }

    /// Unlocks the open vault with age identities (a listed device's key
    /// without its signing keys, or the recovery key: read-only).
    public func unlock(with identities: [any AgeIdentity], awaitNotes: Bool = true) async throws {
        try await unlock(with: UnlockKeys(identities: identities), awaitNotes: awaitNotes)
    }

    /// Unlocks the open vault as the device `device` (its decryption key and
    /// its signing keys, which home needs for list changes).
    public func unlock(device: DeviceKeys, awaitNotes: Bool = true) async throws {
        try await unlock(with: UnlockKeys(identities: [device.nativeIdentity], signing: device.signing, device: device),
                         awaitNotes: awaitNotes)
    }

    /// Unlocks the open vault and starts listing its notes
    /// (`startLoadingNotes`): cached summaries at once, then the rest as they
    /// are read. The listing belongs to the model, so a caller that goes away
    /// (the unlock sheet) does not stop it.
    ///
    /// `vault.json` is checked against this device's trust record (design
    /// §4.3); a list that does not check leaves the vault readable and
    /// unwritten, with `listAlert` set. Opened with the recovery key, the
    /// vault is read-only (`isRecoveryOpen`).
    ///
    /// - Parameter awaitNotes: wait for the listing (and throw its error)
    ///   before returning. The UI passes false, so the unlock sheet closes as
    ///   soon as the key is accepted; failures then go to `errorMessage`.
    public func unlock(with keys: UnlockKeys, awaitNotes: Bool = true) async throws {
        guard let url = vaultURL else { throw ModelError.noVaultOpen }
        let gen = generation
        let trust = self.trust
        let opened: Vault
        do {
            // The recovery key reads without a trust record (design §4.3 step 4), checked against
            // the root when one came with it (the passphrase copy).
            let stores = writeStores
            opened = try await offMain {
                let id = try stores.map { _ in try Vault.open(at: url).vaultId }
                return try Vault.open(at: url, identities: keys.identities, signing: keys.signing,
                                      trust: keys.root == nil ? trust : nil, root: keys.root,
                                      ledger: id.flatMap { stores?.ledger(for: $0) }, setAside: stores?.setAside)
            }
        } catch VaultError.keyNotListed {
            throw ModelError.notJoined
        }
        try ensureCurrent(gen)
        vault = opened
        unlockKeys = keys
        listAlert = ListAlert(vault: opened)
        phase = .unlocked
        try await didUnlock(awaitNotes: awaitNotes)
    }

    /// The vault opened again after its `vault.json` changed (`syncedVaultFileArrived`): its list is
    /// checked again (`listAlert`), the quick-capture profile follows the list's capture keys, and the
    /// views open their notes again (`keyEpoch`).
    public func adoptReopened(_ next: Vault) {
        guard phase == .unlocked, next.vaultId == vault?.vaultId else { return }
        vault = next
        listAlert = ListAlert(vault: next)
        // The quick-capture profile follows the list's capture keys; takeovers and the device state; settings sync.
        refreshQuickCaptureProfile()
        Task {
            await checkTakeovers()
            await refreshDeviceState()
        }
        scheduleSettingsSync()
        keyEpoch += 1
    }

    /// What every unlock does once the vault is open: lists the notes
    /// (`startLoadingNotes`, then automatic thinning), refreshes the
    /// quick-capture profile, adopts the inbox, reschedules the backup
    /// reminder and syncs settings.
    private func didUnlock(awaitNotes: Bool) async throws {
        // The open store vault's targets run two-way from now on (also those added while it is open).
        syncCoordinator.openVaultUnlocked()
        await webdavUnlocked()   // a partial copy's rows come from the server's summaries: before the listing
        loadActivity()
        startLoadingNotes(reportErrors: !awaitNotes)
        if awaitNotes { try await notesLoaded() }
        // The quick-capture profile, the inbox, takeovers and the device state, the backup reminder, settings sync.
        refreshQuickCaptureProfile()
        installInboxDeliveryObserver()
        startInboxAdoption()
        await checkTakeovers()
        await refreshDeviceState()
        Task { await rescheduleBackupReminder() }
        startSettingsSync()
    }

    /// Unlocks with the text of a key: a device key file (`DeviceKeys`, with
    /// its signing keys), or plain identity text (`AGE-SECRET-KEY-PQ-1…`,
    /// for instance the recovery key, which opens the vault read-only).
    /// Returns the device keys when it was a device key file
    /// (a device key file made with `sempere`; the app's own keys are in `DeviceKeyStore`).
    @discardableResult
    public func unlock(identityText: String, awaitNotes: Bool = true) async throws -> DeviceKeys? {
        if DeviceKeys.isDeviceKeyFile(identityText) {
            let device: DeviceKeys
            do { device = try DeviceKeys.parse(identityText) } catch { throw ModelError.notAnIdentity }
            try await unlock(device: device, awaitNotes: awaitNotes)
            return device
        }
        let identity: NativeIdentity
        do { identity = try IdentityFile.parse(identityText) } catch { throw ModelError.notAnIdentity }
        try await unlock(with: [identity], awaitNotes: awaitNotes)
        return nil
    }

    /// Unlocks with the passphrase of the recovery key's passphrase copy
    /// (`keys/recovery-….key.age`, format.md §15.11): the vault opens
    /// read-only, checked against the root the copy carries.
    public func unlock(passphrase: String, awaitNotes: Bool = true) async throws {
        guard let locked = vault else { throw ModelError.noVaultOpen }
        let gen = generation
        let copy: RecoveryPassphraseCopy = try await offMain { () throws -> RecoveryPassphraseCopy in
            do { return try locked.openPassphraseCopy(passphrase: passphrase) } catch VaultError.passphraseCopyMissing {
                throw ModelError.noStoredKeys
            } catch VaultError.wrongPassphrase {
                throw ModelError.passphraseMatchesNoKey
            }
        }
        try ensureCurrent(gen)
        try await unlock(with: UnlockKeys(identities: [NativeIdentity.mlkem768x25519(copy.identity)], root: copy.root),
                         awaitNotes: awaitNotes)
    }

    /// Re-reads every note summary from disk: summaries whose revision files
    /// have not changed come from the `SummaryCache`, the rest are read in
    /// batches that are published as they finish (`loading` says how far it
    /// got). Before the first listing of a vault the cached summaries are
    /// shown at once. In iCloud Drive, notes whose files are not downloaded
    /// yet are listed as placeholders (or their cached summary) and fill in
    /// as they arrive (`startCloudSync`), instead of the call waiting for all
    /// of them.
    public func reload() async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        let gen = generation
        isBusy = true
        defer { if gen == generation { isBusy = false } }
        do {
            try await openSummaryCache()
            try ensureCurrent(gen)
            _ = vault
            try await listLocalNotes()
            if gen == generation { loadFailure = nil }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if gen == generation { loadFailure = "\(error)" }
            throw error
        }
    }

    // MARK: - Editor

    /// Opens `noteID` on the canvas (nil closes it). The previous note is
    /// saved first. Needs an unlocked vault; the device clock is created on
    /// first use. In iCloud Drive the note is read, and its deltas written,
    /// under file coordination.
    public func openEditor(for noteID: UUID?) async throws {
        guard editor?.noteID != noteID || noteID == nil else { return }
        let gen = generation
        let previous = editor
        editor = nil
        await previous?.close()
        await closingEditor?.value
        try ensureCurrent(gen)
        guard let noteID else { return }
        guard !isChangingKeys else { throw CancellationError() }   // reopened after the change (`keyEpoch`)
        // Open from here on for the automatic thinning, which must not delete what this reads.
        openingNoteIDs[noteID, default: 0] += 1
        defer {
            let left = (openingNoteIDs[noteID] ?? 1) - 1
            openingNoteIDs[noteID] = left > 0 ? left : nil
        }
        let epoch = keyEpoch
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let perf = services.perf
        let interval = perf.begin("note.open")
        let render = perf.begin("note.firstRender")
        var shown = false
        defer {
            if !shown {
                perf.end(interval, "\(noteID.perfShort) not shown")
                perf.end(render, "\(noteID.perfShort) not shown")
            }
        }
        // A partial copy: this note first, before the rest of the fill.
        let download = perf.begin("note.download")
        do { try await downloadNote(noteID) } catch {
            perf.end(download, "\(noteID.perfShort) failed")
            throw error
        }
        perf.end(download, "\(noteID.perfShort)")
        let clock = try deviceClockForWriting()
        let cache = await openDrawingCache()
        let url = vault.url
        // The names say which cached version of the note is current; listing them reads no file.
        let listed = cache == nil ? nil : try? await offMain {
            try VaultEnumeration.listNotes(vault: url, only: [noteID]).first?.names
        }
        let verify = partialNoteVerifier(noteID)
        let opened = try await Editor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               recognizer: recognizer, recognitionDelay: recognitionDelay,
                                               verify: verify, cache: cache,
                                               listedNames: listed, beforeFinishing: editorLoadHook,
                                               redownload: { [weak self] in
                                                   guard let self else { throw CancellationError() }
                                                   try self.ensureCurrent(gen)   // never into another vault
                                                   try await self.downloadNote(noteID)
                                               }, perf: perf)
        await afterIO?()
        guard gen == generation, selectedNoteID == noteID,   // closed, or the selection moved on meanwhile
              editor?.noteID != noteID else {                // a concurrent open won; keep its edits
            opened.cancelLoading()
            try ensureCurrent(gen)
            return
        }
        // A note window took the note meanwhile (one editor per note), or the
        // keys changed under the vault copy this editor was opened with.
        guard !windowClaims.contains(noteID), !isChangingKeys, epoch == keyEpoch else {
            Task { await opened.close() }
            throw CancellationError()
        }
        // The background read of a note opened from the cache failed: show the
        // failure (and Try Again) rather than a partial read-only canvas.
        opened.onLoadFailed = { [weak self, weak opened] message in
            guard let self, let opened, self.editor === opened else { return }
            self.editor = nil
            if self.selectedNoteID == noteID { self.editorFailure = (noteID, message) }
            Task { await opened.close() }
        }
        if opened.loadFailed {   // it failed before the callback was set
            if let stale = editor { editor = nil; Task { await stale.close() } }
            editorFailure = (noteID, Host.unreadableText(opened))
            Task { await opened.close() }
            return
        }
        let stale = editor
        opened.prepareBlobWrite = blobWritePreparer(note: noteID)
        configureRecordings(opened)
        Host.prepareEditor(opened, of: noteID, in: self)   // saved recordings (the microphone half is the app's)
        opened.onRecognized = { [weak self] id in
            guard let self else { return }
            Task { try? await self.refresh([id]) }   // search sees the new text
        }
        perf.end(interval, "\(noteID.perfShort) pages=\(opened.pages.count) fromCache=\(opened.isPreparing)")
        opened.openInterval = render   // ended by the canvas when the ink is on screen
        shown = true
        editor = opened
        applyPendingJump()
        if let stale { Task { await stale.close() } }
    }

    /// Opens the open vault's drawing cache (`DrawingCache`) once.
    public func openDrawingCache() async -> DrawingCache? {
        if let drawingCache { return drawingCache }
        guard let root = drawingCacheRoot, let vault, vault.canRead else { return nil }
        let gen = generation
        let cap = DrawingCache.configuredCapBytes(in: services.settings)
        let cache = try? await offMain(priority: .utility) { try DrawingCache(root: root, vault: vault, capBytes: cap) }
        // A newer session may already use the same folder (the vault closed and
        // reopened meanwhile): drop this instance without deleting anything; the
        // closed session's `close` cleared its cache.
        guard gen == generation else { return nil }
        if drawingCache == nil { drawingCache = cache }
        return drawingCache
    }

    /// Opens the selected note on the canvas for the detail pane, keeping a
    /// failure next to the note (`editorFailure`) instead of a blank canvas.
    public func showSelectedNote() async {
        var id = phase == .unlocked ? selectedNoteID : nil
        if let claimed = id, windowClaims.contains(claimed) { id = nil }   // a window of its own has it
        editorFailure = nil
        do {
            try await openEditor(for: id)
        } catch is CancellationError {
        } catch {
            if let id, selectedNoteID == id { editorFailure = (id, "\(error)") }
        }
    }

    /// Reloads the open editor when it shows `id` (after a browser edit that
    /// changes whether it may be edited, e.g. delete or restore). Pending
    /// canvas changes are saved first.
    public func reopenEditor(ifShowing id: UUID) async throws {
        if windowEditors[id] != nil { await Host.reopenWindowNote(id, in: self) }
        guard editor?.noteID == id else { return }
        try await openEditor(for: nil)
        try await openEditor(for: id)
    }

    public func deviceClockForWriting() throws -> DeviceClock {
        if let deviceClock { return deviceClock }
        // Every delta any `NoteWriter` writes with this clock updates that note's attachment index.
        let clock = try DeviceClock(url: deviceStateURL, app: services.appName, perf: services.perf) { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                self.noteWritten(id)
                self.syncSessions.forEach { $0.noteWrite() }   // every target syncs shortly after a write
            }
        }
        deviceClock = clock
        return clock
    }

    // MARK: - Closing

    /// Forgets the vault (and its keys). Folder access ends once the open
    /// note's pending changes and any edit already being written are saved.
    public func close() {
        generation += 1
        // Settings sync stops and the app-side state of the vault is forgotten (the extensions still in the app, wave 5b
        // part 3); a backup, inbox adoption or import still running is canceled below.
        stopSettingsSync()
        Host.willClose(self)
        takeoverAlert = nil
        sightingRowsState = []
        resetAttachmentIndex()
        stopJoin()
        stopWebDAV()
        cancelRemoteMerges()
        backupControl?.cancel()   // it reads the vault, whose access ends here
        inboxAdoption?.cancel()   // the next vault adopts its own inbox
        inboxAdoption = nil
        inboxAdoptionAgain = false
        if let o = inboxDeliveryObserver { NotificationCenter.default.removeObserver(o) }
        inboxDeliveryObserver = nil
        importCancellation?.cancel()   // a running import stops after its current note
        lastImportReport = nil
        exportEpoch.bump()
        NotePDFExport.purge(in: exportFolder, olderThan: 0)   // plaintext files dragged out of this vault
        exportRequest = nil
        bulkExportRequest = nil
        publishedRows = [:]
        publishedRowsSignature = []
        isBusy = false
        let editor = self.editor
        let windowed = Array(windowEditors.values)
        windowEditors = [:]
        windowClaims = []
        let scoped = scopedURL
        let bookmarks = services.bookmarks
        let lease = storeLease
        storeLease = nil
        storeLeaseVault = nil
        // In the background the lease is being let go anyway: not after the last saves, which may outlast the
        // background time (`prepareForSuspension` awaits only the closing task it saw).
        if locksSuspended { lease?.release() }
        self.editor = nil
        if editor != nil || scoped != nil || !windowed.isEmpty || lease != nil {
            let earlier = closingEditor
            let gate = editGate
            let closing = Task {
                await earlier?.value
                await editor?.close()
                for open in windowed { await open.close() }
                // A browser edit already writing (`commit`) finishes first.
                await gate.acquire()
                gate.release()
                if let scoped { bookmarks.stopAccessing(scoped) }
                lease?.release()
            }
            closingEditor = closing
            // Done: nothing is closing any more (unless a later close took over).
            Task { [weak self] in
                await closing.value
                if self?.closingEditor == closing { self?.closingEditor = nil }
            }
        }
        scopedURL = nil
        loadTask?.cancel()
        loadTask = nil
        listAlert = nil
        loading = nil
        listLoaded = false
        loadFailure = nil
        declaredNotebooks = []
        notebookRecordNamesRead = nil
        verifiedNoteIDs = []
        summaryEpochs = [:]
        indexedNames = [:]
        discardListUpdates()
        // Saves are throttled while notes arrive: what the last passes read is kept.
        saveSummaryCache()
        lastSummaryCacheSave = nil
        summaryCache = nil
        summaryCacheOpening = nil
        // Drawings of this vault's notes do not outlive it on this device.
        drawingCache?.close()
        drawingCache = nil
        // Nor do decrypted attachments and their pictures (`dropAttachments`, when `vault` goes).
        vault = nil
        unlockKeys = UnlockKeys()
        joinIdentity = nil
        heldSinceAtOpen = nil
        vaultURL = nil
        vaultOpenedExternally = false
        notes = []
        searchIndex.removeAll()
        selectedNoteID = nil
        isSelectingNotes = false
        multiSelection = []
        editorFailure = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionProgress = nil
        recognitionResults = nil
        activity = RecentActivity()
        pendingJump = nil
        pendingRecordingJump = nil
        transcriptHits = []
        transcriptCache.removeAll()
        searchText = ""
        sidebarSelection = .allNotes
        phase = .noVault
    }

    /// Runs `body` and records its error for the UI instead of throwing.
    public func report(_ body: () async throws -> Void) async {
        do { try await body() } catch is CancellationError {} catch { errorMessage = "\(error)" }
    }

    /// Throws `CancellationError` when `close()` or another `openVault` ran
    /// since `gen` was taken, so a late result cannot resurrect a closed vault.
    public func ensureCurrent(_ gen: Int) throws {
        guard gen == generation else { throw CancellationError() }
    }

    /// Runs blocking vault work (file I/O, decryption) on a background thread.
    public func offMain<T: Sendable>(priority: TaskPriority = .userInitiated,
                              _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let value = try await Task.detached(priority: priority) { try work() }.value
        await afterIO?()
        return value
    }
}

extension AppModelCore {
    /// The open, locked vault as read again (a joining device's run may have taken home's approval).
    public func replaceLockedVault(_ fresh: Vault) {
        guard phase == .locked, fresh.url == vault?.url else { return }
        vault = fresh
    }
}
