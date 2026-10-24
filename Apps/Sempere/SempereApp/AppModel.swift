import Age
import Foundation
import Sempere
import SempereImport
import SempereSync
import SempereWebDAV
import Observation

/// How the note list is ordered (the field; "Favorites at Top" is `AppModel.favoritesFirst`).
/// The order itself is the package's `NoteOrder`, which `sempere notes list --sort` uses too.
enum NoteSort: String, CaseIterable, Identifiable, Sendable {
    case modified = "Date Modified"
    case created = "Date Created"
    case title = "Title"

    var id: String { rawValue }

    /// The picker's label (`rawValue` is not localized).
    var title: String {
        switch self {
        case .modified: return String(localized: "Date Modified", comment: "Note list sort order")
        case .created: return String(localized: "Date Created", comment: "Note list sort order: by creation date, newest first")
        case .title: return String(localized: "Title", comment: "Note list sort order: by title")
        }
    }

    /// The package's key for this order.
    var key: NoteOrder.Key {
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
enum NoteSortPreference {
    static let sortKey = "Sempere.noteSort"
    static let favoritesFirstKey = "Sempere.noteSortFavoritesFirst"
}

/// What the sidebar has selected; filters the note list.
enum SidebarItem: Hashable, Sendable {
    case allNotes
    case notebook(String)
    case tag(String)
    case deleted
    /// Notes marked as favorites (`meta.favorite`, format.md §5.4).
    case favorites
    /// The notes the last "Recognize All Notes" run changed (`AppModel.recognitionResults`).
    case recentlyRecognized
}

/// Window-level state: the open vault, its note summaries and the current
/// selection. Vault I/O runs off the main actor; results land here.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// No vault chosen.
        case noVault
        /// A vault is open by name only; notes need a key.
        case locked
        /// Notes are readable.
        case unlocked
    }

    /// Errors the shell reports to the user.
    enum ModelError: Error, Equatable, CustomStringConvertible {
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
        /// The open note's pending canvas changes could not be saved first.
        case unsavedChanges(String)
        /// A notebook dropped into itself or a notebook inside it.
        case invalidNotebookMove
        /// Delete Notebook on a notebook a note is still in.
        case notebookNotEmpty
        /// A new notebook's name is longer than a notebook record allows.
        case notebookNameTooLong

        /// A note not downloaded yet: a fetch may bring it.
        var isNotDownloaded: Bool {
            switch self {
            case .noteNotDownloaded, .noteNotDownloadedFromServer: return true
            default: return false
            }
        }

        var description: String {
            switch self {
            case .noVaultOpen: return String(localized: "No vault is open.")
            case .notAnIdentity: return String(localized: "That text holds no device key file and no AGE-SECRET-KEY-PQ-1… identity.")
            case .noStoredKeys: return String(localized: "This vault has no passphrase copy of its recovery key.")
            case .passphraseMatchesNoKey: return String(localized: "The passphrase does not open this vault's recovery key copy.")
            case .notJoined:
                return String(localized: "This device has not joined the vault: the key is neither one of its devices' keys nor its recovery key.")
            case .noteNotFound: return String(localized: "That note is no longer in the vault.")
            case .noteNotDownloaded:
                return String(localized: "iCloud Drive has not delivered all of this note's files yet. Try again in a moment.")
            case .noteNotDownloadedFromServer(let server):
                return String(localized: "\(server) has not delivered all of this note's files yet. Try again in a moment.",
                              comment: "%@ is a server's host name")
            case .notesStillDownloadingFromServer(let server):
                return String(localized: "Some notes are still loading or downloading from \(server). Try again once the list has finished loading.",
                              comment: "%@ is a server's host name")
            case .notesStillDownloading:
                return String(localized: "Some notes are still loading or downloading from iCloud Drive. Try again once the list has finished loading.")
            case .invalidNotebookMove: return String(localized: "A notebook cannot be moved into itself or into a notebook inside it.")
            case .notebookNotEmpty: return String(localized: "Only an empty notebook can be deleted. Move or delete its notes first.")
            case .notebookNameTooLong: return String(localized: "That notebook name is too long.")
            case .unsavedChanges(let reason):
                return String(localized: "The note's latest changes could not be saved first, so nothing was restored. \(reason)")
            }
        }
    }

    private(set) var phase: Phase = .noVault
    /// The open vault's folder.
    private(set) var vaultURL: URL?
    /// The open vault was handed to the app from outside (AirDrop, Files, another
    /// app: `handleOpened`), not opened in it: a remembered key without a
    /// location is not offered for it (`RememberedKeys.offersSavedKey`, S16).
    private(set) var vaultOpenedExternally = false
    /// Every note in the vault, deleted ones included, sorted by title
    /// (`byTitle`). Passes change it in batches (`queueListUpdate`).
    var notes: [NoteSummary] = [] {
        didSet {
            listVersion &+= 1
            updateSearch(changed: listChangeIDs)
        }
    }
    /// While `applyListChanges` assigns `notes`: the ids it may have changed, so
    /// that an open search re-tests only those (`updateSearch(changed:)`).
    @ObservationIgnored var listChangeIDs: Set<UUID>?
    /// Bumped on every change of `notes` (and of `declaredNotebooks`); keys the derived lists (`derived`).
    private(set) var listVersion = 0
    /// Empty notebooks kept by notebook records (format.md §14), canonical paths
    /// (`refreshNotebookRecords`). The sidebar shows them with the notes' notebooks.
    var declaredNotebooks: [String] = [] {
        didSet { if declaredNotebooks != oldValue { listVersion &+= 1 } }
    }
    /// The record file names `declaredNotebooks` was read from: a pass that
    /// lists the same names reads nothing.
    @ObservationIgnored var notebookRecordNamesRead: [String]?
    /// `visibleNotes`, `tags` and `notebookTree`, computed once per change.
    @ObservationIgnored var derived = DerivedLists()
    /// True while vault I/O is in flight.
    private(set) var isBusy = false
    /// The last error, as a sentence for an alert; cleared by the view.
    var errorMessage: String?
    /// Reading note summaries (opening or refreshing the vault), for the
    /// list's "Opening vault: N of M"; nil when no read is running.
    var loading: NoteLoading?
    /// True once a listing of the open vault has completed (the list is
    /// then what the vault holds, not a partial or cached view).
    var listLoaded = false
    /// Why the last listing failed, shown in an empty list (cleared by the next one).
    var loadFailure: String?
    /// Notes whose summary in `notes` was read (or confirmed from the cache)
    /// in this session. A summary shown from an earlier launch's cache, or a
    /// placeholder, is not: edits that decide from a summary re-read the
    /// note first, and a notebook rename waits until every note is verified.
    var verifiedNoteIDs: Set<UUID> = []
    /// Bumped per note by `refresh` (an edit's own re-read): a listing batch
    /// read before it must not merge its older summary over the newer one.
    var summaryEpochs: [UUID: Int] = [:]
    /// The newest summary-cache save (`saveSummaryCache`).
    @ObservationIgnored var summaryCacheSave: Task<Void, Never>?

    /// The sidebar row shown. Choosing another one scopes a running search to
    /// it (TestFlight build 6: the title changed but the results stayed those
    /// of All Notes); the query is kept.
    var sidebarSelection: SidebarItem? = .allNotes {
        didSet {
            if sidebarSelection != oldValue, searchScope != .list { searchScope = .list }
            updateSearch()
        }
    }
    var selectedNoteID: UUID?
    /// The search field's text. `visibleNotes` filters by title with it; the
    /// note list shows `searchResults` (`AppModel+Search`) while it is not empty.
    var searchText = "" { didSet { updateSearch() } }
    var searchScope = SearchScope.list { didSet { updateSearch() } }
    /// Notes matching `searchText` (title, notebook, tag, recognized handwriting), best first.
    var searchResults: [NoteSearchHit] = []
    /// True from a change of the query until its results are in.
    var isSearching = false
    /// Also search the transcripts of recordings (`AppModel+TranscriptSearch`; per device, off by default).
    var searchTranscripts = TranscriptSearchPreference.isOn()
    /// Transcript segments matching `searchText` while `searchTranscripts` is on.
    var transcriptHits: [TranscriptSearchHit] = []
    /// Transcripts the last transcript search could not read.
    var transcriptSearchProblems = 0
    @ObservationIgnored let transcriptCache = TranscriptSearchCache()
    /// The recording to show once its note is open (a tapped transcript hit).
    var pendingRecordingJump: RecordingJump?
    /// The page to show once the note is open (a tapped search hit).
    var pendingJump: PageJump?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// Lowercased page text kept between searches (`NoteSearchIndex`).
    @ObservationIgnored let searchIndex = NoteSearchIndex()
    /// What `searchResults` answer, and the notes changed since (`updateSearch(changed:)`);
    /// nil while no search has completed for the current query, scope and selection.
    @ObservationIgnored var completedSearch: CompletedSearch?
    /// The title of a note created at a date with no title typed, as Settings
    /// → New Notes says (`NewNoteSettings`; "" for Blank: the note stays
    /// untitled). Tests replace it.
    @ObservationIgnored var defaultTitle: (Date) -> String = { NewNoteSettings.defaultTitle(now: $0) }
    /// Pause after typing before the search runs.
    @ObservationIgnored var searchDebounce = Duration.milliseconds(200)
    /// Reads handwriting on pages as they change and when notes open; nil = off.
    var recognizer: (any PageRecognizing)? {
        didSet {
            editor?.recognizer = recognizer
            for window in windowEditors.values { window.recognizer = recognizer }
        }
    }
    /// Transcribes recordings on device (`AppModel+Recordings`); tests inject a fake.
    @ObservationIgnored var transcriber: (any RecordingTranscribing)? = SpeechRecordingTranscriber()
    /// Recordings being transcribed now, by id.
    var transcribing: Set<UUID> = []
    /// Makes the players' audio backends; nil: AVFoundation's (tests pass fakes).
    @ObservationIgnored var playbackBackend: (@MainActor () -> AudioPlaybackBackend)?
    /// Where recordings in progress keep their files (tests pass their own).
    @ObservationIgnored var recordingRoot = RecordingSession.root
    /// Quick voice notes (`QuickCapture`, `AppModel+Inbox`); tests pass their own.
    @ObservationIgnored var quickCapture = QuickCapture.shared
    /// Voice notes adopted from the inbox in this session (for the UI).
    var capturesAdopted = 0
    /// Why the last inbox adoption failed, if it did.
    var inboxProblem: String?
    /// Inbox files that failed to read, so they are not decrypted again at
    /// every unlock (format.md §11.3, security review 2026-10, C5); next to
    /// the device state.
    let inboxBackoff: InboxBackoff
    @ObservationIgnored var inboxAdoption: Task<Void, Never>?
    /// Progress of "Recognize All Notes" (`AppModel+Search`).
    var recognitionProgress: RecognitionProgress?
    /// What the last "Recognize All Notes" run changed, kept (also after it
    /// ends) until the next run starts; the "Recently Recognized" filter lists it.
    var recognitionResults: RecognitionResults?
    /// What this device remembers of the open vault between launches: the
    /// recent searches (`RecentActivity`, `AppModel+Activity`). "Recently
    /// Recognized" is in the vault (`meta.recognized`, shared by every device).
    var activity = RecentActivity()
    /// Where `activity` is kept (a folder per vault secret inside it).
    @ObservationIgnored var activityRoot: URL
    /// The clock "Recently Recognized" is measured with (tests move it).
    @ObservationIgnored var activityNow: () -> Date = { Date() }
    /// Bumped when "Recently Recognized" changes by the clock alone (a run
    /// leaves the 7-day window, `recentlyRecognizedNextChange`), so what
    /// reads it is drawn again.
    var activityClockTick = 0
    /// The unused-attachments index (`AppModel+AttachmentIndex`, docs/attachments.md §4):
    /// the entries read or updated this session, by note.
    @ObservationIgnored var attachmentIndex: [UUID: AttachmentIndexEntry] = [:]
    /// Bumped whenever `attachmentIndex` changes, so Settings re-derives its numbers.
    var attachmentIndexVersion = 0
    /// Notes waiting for their index update (latest current-state hashes, if known).
    @ObservationIgnored var attachmentIndexQueue: [UUID: Set<String>?] = [:]
    /// How many notes are queued or being indexed (Settings shows progress).
    var attachmentIndexPending = 0
    /// The task working through `attachmentIndexQueue`, owned by the model.
    @ObservationIgnored var attachmentIndexTask: Task<Void, Never>?
    /// True once every stored entry of the open vault was read (`loadAttachmentIndex`).
    @ObservationIgnored var attachmentIndexLoaded = false
    /// The open vault's sealed index files, made on first use.
    @ObservationIgnored var attachmentIndexStoreCache: AttachmentIndexStore?
    /// Where the index is kept (a folder per vault secret inside it): the app's
    /// Application Support; without one (tests) a folder of this model alone.
    @ObservationIgnored var attachmentIndexRoot: URL
    /// Waited before working through queued updates, so an editor's burst of
    /// autosaves is indexed once. Tests set zero.
    @ObservationIgnored var attachmentIndexDelay: Duration = .seconds(2)
    /// The clock the 30-day window is measured with (tests move it).
    @ObservationIgnored var attachmentNow: () -> Date = { Date() }
    /// Test seam: what an index update reads (a counting wrapper of the vault).
    @ObservationIgnored var attachmentIndexSource: (@Sendable (Vault) -> any AttachmentIndexSource)?
    /// What is being dragged inside the app (set when a drag starts), so the
    /// sidebar can tell whether a row would accept it while the drag is still over it.
    var draggedPayload: DragPayload?
    /// The sidebar row a drag is over that would accept it (highlighted).
    var dropTarget: DropTarget?
    /// The sidebar row a drop just moved notes or a notebook into: flashed for
    /// `landedDropDuration` so it is clear where they went (`move(_:to:undoManager:)`).
    var landedDrop: LandedDrop?
    /// How long `landedDrop` stays set (tests shorten it).
    @ObservationIgnored var landedDropDuration: Duration = .seconds(1.6)
    @ObservationIgnored var recognitionTask: Task<Void, Never>?
    /// Pause after the last stroke change before the open note's pages are recognized.
    let recognitionDelay: Duration
    /// True while the note list ticks several notes (to export them); the
    /// open note (`selectedNoteID`) is untouched meanwhile.
    var isSelectingNotes = false
    /// The ticked notes while `isSelectingNotes`.
    var multiSelection: Set<UUID> = []
    /// The export sheet's request (`AppModel+Export`).
    var exportRequest: ExportRequest?
    /// PDFs opened from outside the app (Finder's Open With, the share sheet),
    /// waiting to be imported as new notes (`AppModel+OpenedFiles`). App
    /// state, not the vault's: they wait while a vault is opened or unlocked.
    var openedPDFs: [OpenedPDF] = []
    /// An import from another app is running (`AppModel+Import`).
    var isImporting = false
    /// What the last import did, until the alert is dismissed.
    var importSummary: ImportSummary?
    /// How far the running import is (nil when none runs): the window's progress overlay.
    var importProgress: ImporterProgress?
    /// Stops the running import between notes (`cancelImport`); nil when the importer cannot stop safely.
    var importCancellation: ImporterCancellation?
    /// The report of the last import of this vault, for File > Last Import Report (until the vault closes).
    var lastImportReport: ImportDetails?
    /// The "Export to Folder or Zip…" sheet's request (`AppModel+BulkExport`).
    var bulkExportRequest: BulkExportRequest?
    var sortOrder = NoteSort.modified
    /// Favorites at the top of the note list, under any `sortOrder`.
    var favoritesFirst = false
    /// True while an edit is being written.
    var isEditing = false
    /// Serializes edits (`commit`).
    let editGate = EditGate()
    /// Thin old autosaves once a day after a vault's notes are listed
    /// (`thinIfDue`, format.md §5.8.4). The app turns it on; tests leave it
    /// off so nothing is written that they did not ask for.
    var automaticThinning = false
    /// How far a thinning run (or its preview) has got, counted per note;
    /// nil when none is running (`thinVault`).
    var thinningProgress: ThinningProgress?
    /// Notes thinning works on at once (`thinVault`).
    var thinningConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    /// Notes of a partial copy (a join, `AppModel+Join`) not downloaded yet.
    var pendingNoteIDs: Set<UUID> = []
    /// The pending notes that have no summary yet (listed as placeholders).
    var placeholderNoteIDs: Set<UUID> = []
    /// Per note shown, the sorted revision file names its summary was made
    /// from: from the index on open, then from every read. A pass reads only
    /// notes whose names on disk differ (`reconcile`).
    @ObservationIgnored var indexedNames: [UUID: [String]] = [:]
    /// Summary changes waiting for the next list update (`queueListUpdate`).
    @ObservationIgnored var listUpserts: [UUID: NoteSummary] = [:]
    @ObservationIgnored var listRemovals: Set<UUID> = []
    @ObservationIgnored var listFlushTask: Task<Void, Never>?
    @ObservationIgnored var lastListApply: ContinuousClock.Instant?
    /// The shortest time between two list updates while notes are read.
    var listUpdateInterval = Duration.milliseconds(250)
    /// How far a join's fill got (`AppModel+Join`), for the list's bar; nil when no partial copy is open.
    var joinProgress: JoinProgress?
    /// The note `downloadNote` is fetching (a partial copy), for the note pane's wait and its Cancel.
    var noteDownload: UUID?
    /// Cancels that wait (`cancelNoteDownload`); the fetch itself goes on.
    @ObservationIgnored var noteDownloadCancel: (() -> Void)?
    /// Background time and scheduled tasks for the sync (`AppModel+Background`); tests pass fakes.
    @ObservationIgnored var backgroundTasks: any BackgroundTaskRunning = UIKitBackgroundTasks()
    @ObservationIgnored var syncScheduler: any BackgroundSyncScheduling = BGTaskSyncScheduler()
    /// The assertion held while sync targets' runs finish off screen (`finishTargetRunsInBackground`), and its wait.
    @ObservationIgnored var targetsBackgroundToken: BackgroundTaskToken?
    @ObservationIgnored var targetsBackgroundWait: Task<Void, Never>?
    /// Watches the network for the WebDAV targets (`startReachability`); nil until started.
    @ObservationIgnored var reachability: WebDAVReachability?
    /// The iCloud calls for copying a vault in from iCloud Drive (`copyIn`, a restore); tests replace them.
    @ObservationIgnored var iCloudHooks = CloudVault.Hooks.live
    /// The last on-demand fetch into the open partial copy (`joinFetch`): the next waits for it.
    @ObservationIgnored var joinFetchTail: Task<Void, Never>?
    /// The rows of notes not downloaded yet, by note id, from published summaries
    /// (format.md §12): a partial WebDAV copy's from the server's file (`webdavUnlocked`).
    @ObservationIgnored var publishedRows: [UUID: NoteSummary] = [:]
    /// The published summary files the rows were last read from (name, size, date), so they are
    /// read again only when one changes.
    @ObservationIgnored var publishedRowsSignature: [String] = []
    /// The WebDAV locations of this device (`AppModel+WebDAV`, docs/io.md
    /// "WebDAV vaults in the app"). The app passes the default store; without
    /// one (tests) a store in a folder of this model alone.
    @ObservationIgnored var webdavLocations: WebDAVLocationStore

    /// The folder holding this model's default (not injected) scratch locations; nothing is created in it until
    /// one is used, and `deinit` removes it.
    private let ownedScratch: URL

    deinit { try? FileManager.default.removeItem(at: ownedScratch) }
    /// The sync session of the open vault when it is a WebDAV location's local copy (the
    /// coordinator's, two-way while the vault is unlocked); nil for any other vault.
    var webdav: SyncSession?
    /// The open vault's sync sessions, one per target (folder and WebDAV), in the order they were added
    /// (`AppModel+SyncTargets`); empty for a vault without targets.
    var syncSessions: [SyncSession] = []
    /// The open vault's `vault.json` changed on disk (a sync took another device's key change) and the
    /// open `Vault` has not been opened again under it yet: its runs only upload (review of #70, F1).
    var syncVaultStale = false
    /// A previous copy kept at launch (`recoverWebDAVLeftovers`), for its alert; nil when there is none.
    var webdavLeftover: WebDAVLeftover?
    /// The coordinator once made (tests set their own).
    @ObservationIgnored var coordinatorStorage: SyncCoordinator?
    /// Every in-app vault's sync sessions (`SyncCoordinator`, made on first use).
    var syncCoordinator: SyncCoordinator {
        if let coordinatorStorage { return coordinatorStorage }
        let made = SyncCoordinator(targets: { [weak self] in self?.allSyncTargets() ?? [] },
                                   makeSession: { [weak self] ref in self?.makeSession(for: ref) })
        made.tick = webdavTick
        coordinatorStorage = made
        return made
    }
    /// The WebDAV vault being downloaded and how far it is, for the overlay; nil when none is.
    var webdavDownload: WebDAVDownloadStatus?
    /// The Cancel of that download (`cancelWebDAVDownload`).
    @ObservationIgnored var webdavDownloadCancel: WebDAVCancelFlag?
    /// The server calls (`LiveWebDAVRemote`); tests pass a fake.
    @ObservationIgnored var webdavRemote: any WebDAVRemote = LiveWebDAVRemote()
    /// WebDAV passwords (the Keychain); tests pass `MemoryWebDAVPasswordStore`.
    @ObservationIgnored var webdavPasswords: any WebDAVPasswordStore = KeychainWebDAVPasswordStore()
    /// How often a WebDAV session looks at its schedule, and how long after a
    /// write it pushes (`WebDAVPushSchedule.writeDelay`); tests shorten both.
    @ObservationIgnored var webdavTick = Duration.seconds(1)
    @ObservationIgnored var webdavWriteDelay: TimeInterval = 10
    /// How long after a write a folder target syncs (`AppModel+SyncTargets`); tests shorten it.
    @ObservationIgnored var folderWriteDelay: TimeInterval = 2
    /// Longest a folder target's run waits for files a provider is downloading.
    @ObservationIgnored var folderArrivalWait: TimeInterval = 10
    /// The provider of a folder target's folder; nil detects it (`FolderProviders.detect`). Tests pass
    /// `EvictingFolderProvider`s.
    @ObservationIgnored var folderProvider: (@Sendable (URL) -> (any FolderProvider)?)?
    /// Listings and downloads at once in a WebDAV download (`SyncOptions.concurrency`).
    @ObservationIgnored var webdavConcurrency = TransferPool.defaultWidth
    /// The running Back Up Now, Verify Backup or restore (`AppModel+Backup`),
    /// nil when none runs.
    var backupProgress: BackupProgress?
    /// Cancels the running backup (`cancelBackup`).
    @ObservationIgnored var backupControl: BackupRunControl?
    /// Per-vault backup folders and results (`UserDefaults`; tests use a scratch suite).
    @ObservationIgnored var backupStore = BackupStore()
    /// Delivers backup reminders; the app installs `UserNotificationBackupNotifier`.
    @ObservationIgnored var backupNotifier: any BackupNotifying = NoBackupNotifier()
    /// Settings sync with the open vault (`AppModel+SettingsSync`, docs/settings-sync.md):
    /// this device's state for it, kept per vault in `settingsDefaults`.
    var settingsSync = SettingsSyncState()
    /// Why settings sync is paused or failed; nil while it works (or is off).
    var settingsSyncProblem: SettingsSyncProblem?
    /// Turning sync on found settings that differ: the choice to ask for.
    var settingsSyncPrompt: SettingsSyncPrompt?
    /// Bumped whenever values from the vault were applied, so the Settings
    /// sections that hold copies of their values reload them.
    var settingsAppliedRevision = 0
    /// Where settings are read and written (tests use a scratch suite).
    @ObservationIgnored var settingsDefaults: UserDefaults = .standard
    /// Tests: the device type to sync as (nil: this device's).
    @ObservationIgnored var settingsDeviceTypeOverride: SettingsDeviceType?
    /// How long after the last local change a pass runs.
    @ObservationIgnored var settingsSyncDebounce: Duration = .seconds(1)
    @ObservationIgnored var settingsSyncObserver: (any NSObjectProtocol)?
    @ObservationIgnored var settingsSyncScheduled: Task<Void, Never>?
    @ObservationIgnored var settingsSyncRunning = false
    /// How long a copy-in or restore from iCloud Drive waits without progress, and how often it looks
    /// (`downloadSourceFolder`); tests shorten them.
    var cloudPollInterval = Duration.seconds(1)
    var cloudStallTimeout = Duration.seconds(90)
    /// How long opening a note waits for its fetch in a partial copy before it says "not downloaded yet"
    /// (the fetch goes on; opening it again shows it once it is in).
    var noteFetchTimeout = Duration.seconds(60)
    /// The shortest time between two summary-cache saves while notes arrive.
    var summaryCacheSaveInterval = Duration.seconds(20)
    @ObservationIgnored var lastSummaryCacheSave: ContinuousClock.Instant?
    /// Summary-cache saves started (each re-encodes and seals the whole index): check c20 counts them.
    @ObservationIgnored var summaryCacheSaves = 0
    /// Test seam: awaited before an editor opened from the drawing cache
    /// takes the note it read in the background.
    @ObservationIgnored var editorLoadHook: (@Sendable () async -> Void)?
    /// Test seam: told how many notes each listing batch read.
    @ObservationIgnored var onSummaryRead: (@Sendable (Int) -> Void)?
    /// Notes read per published batch, and threads reading them (`AppModel+Loading`).
    var loadBatchSize = 24
    /// The largest batch `readSummaries` makes when many notes changed.
    var loadBatchLimit = 96
    var loadConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    /// Where summaries are cached between launches (`SummaryCache`); nil (the
    /// default, for tests): no cache. The app passes `defaultSummaryCacheDirectory`.
    let summaryCacheDirectory: URL?
    /// The open vault's summary cache, once unlocked.
    @ObservationIgnored var summaryCache: SummaryCache?
    /// The load of `summaryCache` in progress (`openSummaryCache`).
    @ObservationIgnored var summaryCacheOpening: Task<Void, any Error>?
    /// Where page drawings are cached between note opens (`DrawingCache`);
    /// nil (the default, for tests): no cache. The app passes
    /// `DrawingCache.defaultRoot`.
    let drawingCacheRoot: URL?
    /// The open vault's drawing cache, opened with the first note; deleted
    /// when the vault closes.
    @ObservationIgnored var drawingCache: DrawingCache?
    /// The listing started by `unlock`, owned by the model so that no view
    /// (an unlock sheet going away) can cancel it.
    @ObservationIgnored var loadTask: Task<Void, any Error>?
    /// Serializes listings: a reload, the iCloud sync loop and a pull to
    /// refresh never read the same notes at once.
    let loadGate = EditGate()


    /// Where this install keeps its device id and hybrid clock.
    let deviceStateURL: URL
    /// Why the selected note could not be opened (`showSelectedNote`).
    var editorFailure: (id: UUID, message: String)?
    /// The note open on the canvas, if any (`openEditor(for:)`).
    private(set) var editor: NoteEditor?

    private(set) var vault: Vault? {
        // Decrypted attachments and copied items belong to the vault (and the
        // secret) they came from.
        didSet { dropAttachments() }
    }
    /// Decrypted attachments of the open vault (`AppModel+Attachments`),
    /// created on first use, deleted whenever `vault` changes or closes.
    @ObservationIgnored var blobCache: BlobCache?
    /// Where this model's attachment caches go (a folder per vault secret
    /// inside): the app's `BlobCache.folder`, kept across launches; without
    /// one (tests) a folder of this model alone. Tests may set their own.
    @ObservationIgnored var blobCacheFolder: URL
    /// Whether decrypted attachments are reused by a later launch
    /// (`BlobCache.keepsAcrossLaunches`: not on a Mac). Tests may set it.
    @ObservationIgnored var blobCacheAcrossLaunches = BlobCache.keepsAcrossLaunches
    /// Where drawn attachments (pictures, PDF page previews) are cached
    /// between note opens and launches (`RenderCache`); nil (the default, for
    /// tests): kept in memory only. The app passes `RenderCache.defaultRoot`.
    let renderCacheRoot: URL?
    /// The open vault's render cache, made on first use; closed with the vault.
    @ObservationIgnored var renderCache: RenderCache?
    /// Items copied for pasting (`ItemClipboard`), within the open vault.
    let itemClipboard = ItemClipboard()
    /// Merges of revisions written elsewhere into open editors, by note id
    /// (`AppModel+RemoteMerge`).
    @ObservationIgnored var remoteMerges: [UUID: Task<Void, Never>] = [:]
    /// Per note, the revision names a merge could not read: not tried again
    /// until the names change.
    @ObservationIgnored var unreadableMergeNames: [UUID: [String]] = [:]
    /// Editors of note windows (Mac), by note id: one per note, each with its
    /// own canvas (`AppModel+Windows`).
    var windowEditors: [UUID: NoteEditor] = [:]
    /// Notes shown by a window of their own; the library window's detail pane
    /// does not open an editor for them.
    var windowClaims: Set<UUID> = []
    /// Notes `openEditor` is reading (its editor not assigned yet), with how
    /// many opens are under way: open for thinning (`isNoteOpen`).
    @ObservationIgnored var openingNoteIDs: [UUID: Int] = [:]
    /// Bumped when the vault's keys changed under the open editors
    /// (`AppModel+Keys`): views reopen their notes.
    var keyEpoch = 0
    /// True while a recipient change re-encrypts the vault (`AppModel+Keys`):
    /// no editor opens meanwhile, since it would hold the old vault and secret.
    var isChangingKeys = false
    /// The library window whose detail pane shows `editor` (`WindowUI.id`).
    /// One canvas per editor: a second canvas on the same editor would report
    /// a drawing without the first one's new strokes, which the ledger takes
    /// as erasures.
    var canvasWindow: UUID?
    /// When a note window last asked for a library window (coalesces the
    /// requests of several restored note windows).
    var libraryWindowRequested: Date?
    /// Where this model's PDF exports (drag to Finder) are written; emptied when the vault closes.
    let exportFolder = NotePDFExport.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    /// Bumped when the vault closes: a drag-out export prepared before it writes nothing.
    let exportEpoch = ExportEpoch()
    /// Library windows on screen (a note window restored alone opens one).
    var libraryWindowCount = 0
    /// "New Note" was chosen in the Mac menu-bar item at this time and has not been carried out yet
    /// (`AppModel+MenuBar`).
    var menuBarNewNoteRequest: Date?
    /// This device's trust records of the vaults' device lists (format.md
    /// §15.10). The app keeps them in Application Support (`defaultTrustDirectory`);
    /// without one (tests) none is kept, and a list that checks under the
    /// vault's key is taken as it is (`ListStatus.Verification.firstUse`).
    let trust: (any EpochTrustStore)?
    /// This device's write ledger and set-aside store per vault (key-hierarchy design §5.4, §5.8): the app
    /// sets them at launch (`DeviceWriteStores.app`); without them (tests) nothing is recorded and a device
    /// change is not caught up.
    @ObservationIgnored var writeStores: DeviceWriteStores?
    /// The open vault's `vault.json` did not check at unlock (design §4.3): the
    /// blocking alert (`ListAlert`). Nothing is written to the vault meanwhile.
    var listAlert: ListAlert?
    /// A takeover by another device that this device has not acknowledged (key-hierarchy design §6.3): a
    /// banner until dismissed (`AppModel+Devices`).
    var takeoverAlert: TakeoverAlert?
    /// Where acknowledged takeovers are remembered (per vault, the epoch); tests pass their own.
    @ObservationIgnored var takeoverDefaults: UserDefaults = .standard
    /// Each target's run before a device change is bounded by this (design §5.2 step 2); tests shorten it.
    @ObservationIgnored var deviceChangeRunBound: TimeInterval = AppModel.defaultDeviceChangeRunBound
    /// Asks for the device owner before a list change that needs them at the device (Replace Recovery Kit, design
    /// §6.5); tests inject a fake.
    @ObservationIgnored var ownerAuthenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()
    /// The targets run before a device change (the sheets' "Syncing…" with its Cancel).
    var isSyncingBeforeChange = false
    /// Set while they run: Cancel skips the rest (`cancelDeviceChangeSync`).
    @ObservationIgnored var deviceChangeCancel: SyncRunCancel?
    @ObservationIgnored var deviceChangeWaitCancel: (() -> Void)?
    /// This device's state as last read off the main actor (`refreshDeviceState`): since when a change it cannot
    /// verify holds its sync back, and the sightings Repair lists.
    var heldSinceAtOpen: Date?
    var sightingRowsState: [SightingRow] = []
    /// The clock the device banners judge "more than a day" by; tests set it.
    @ObservationIgnored var deviceNoticeNow: () -> Date = { Date() }
    /// The keys the vault was unlocked with, for opening it again (a WebDAV
    /// copy downloaded again, a backup check).
    var unlockKeys = UnlockKeys()
    /// The identities the vault was unlocked with.
    var unlockIdentities: [any AgeIdentity] { unlockKeys.identities }
    private var scopedURL: URL?
    /// The in-app vault store (`VaultLibrary.vaultStore`): the app sets it, so an open store vault
    /// holds a lease (`storeLease`); nil in tests that need none.
    @ObservationIgnored var vaultStore: VaultStore? {
        didSet {
            // WebDAV targets live in the store's target registry.
            if let vaultStore, vaultStore.root != webdavLocations.store.root {
                webdavLocations = WebDAVLocationStore(store: vaultStore)
            }
        }
    }
    /// The store whose vaults have sync targets: the app's, else (tests) the model's own scratch store.
    var syncStore: VaultStore { vaultStore ?? webdavLocations.store }
    /// Held while a vault of `vaultStore` is open: removing it from the store is refused meanwhile
    /// (by the app, or `sempere store remove`). Released once the editors' last saves are written.
    @ObservationIgnored private var storeLease: VaultStore.Lease?
    /// "Open Vault…" copying a vault onto this device (`copyIn`), for the progress overlay.
    var vaultCopy: VaultCopyProgress?
    /// Bumped by `close()` (and so by every `openVault`): async work started
    /// under an older generation must not publish its result (the vault it
    /// read is gone).
    private(set) var generation = 0
    /// The save of the editor `close()` dropped; awaited before any note is
    /// opened again, so a reopened note is read after its last delta landed.
    var closingEditor: Task<Void, Never>?
    /// Per WebDAV location: the push its closed session left running.
    /// Awaited before that copy is synced, replaced or removed again.
    var stoppingWebDAV: [UUID: Task<Void, Never>] = [:]
    /// This installation's device id and clock, created on first write
    /// access. Every write (canvas autosave and browser edits) ticks this one
    /// clock, so the state file has a single writer.
    private var deviceClock: DeviceClock?
    let editorDebounce: Duration
    /// Test seam: awaited after each piece of off-main vault work.
    private let afterIO: (@Sendable () async -> Void)?

    init(deviceStateURL: URL = DeviceClock.defaultURL, editorDebounce: Duration = NoteEditor.defaultDebounce,
         recognizer: (any PageRecognizing)? = nil, recognitionDelay: Duration = NoteEditor.defaultRecognitionDelay,
         summaryCacheDirectory: URL? = nil, drawingCacheRoot: URL? = nil,
         blobCacheRoot: URL? = nil, renderCacheRoot: URL? = nil,
         attachmentIndexRoot: URL? = nil,
         automaticThinning: Bool = false,
         trust: (any EpochTrustStore)? = nil,
         backupNotifier: (any BackupNotifying)? = nil,
         webdavLocations: WebDAVLocationStore? = nil,
         afterIO: (@Sendable () async -> Void)? = nil) {
        self.trust = trust
        // One private scratch folder for every default location below, removed when the model goes away: a model
        // built without explicit roots (tests, previews) would otherwise leave three folders per instance in tmp.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SempereModel-\(UUID().uuidString)", isDirectory: true)
        ownedScratch = scratch
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
    var vaultName: String? {
        vaultURL.map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The notebook hierarchy of live notes and of the empty notebooks records
    /// keep (names are `/`-separated paths, format.md §5.4, §14).
    var notebookTree: [NotebookNode] {
        let version = listVersion
        if let t = derived.tree, t.version == version { return t.value }
        let tree = NotebookRecords.tree(noteNotebooks: notes.filter { !$0.deleted }.map(\.notebook), declared: declaredNotebooks)
        derived.tree = (version, tree)
        return tree
    }

    /// Every notebook path in use by live notes or declared, parents included, in tree order.
    var notebooks: [String] {
        NotebookNode.flatten(notebookTree)
    }

    /// Tags in use by live notes, sorted. Tags match case-insensitively
    /// ("Math" and "math" are one); the spelling shown is the first seen.
    var tags: [String] {
        let version = listVersion
        if let t = derived.tags, t.version == version { return t.value }
        let tags = NoteOps.vaultTags(notes)
        derived.tags = (version, tags)
        return tags
    }

    /// The note list for the current sidebar selection, title search and sort order.
    var visibleNotes: [NoteSummary] {
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
    var notesInSelection: [NoteSummary] {
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

    static func sorted(_ list: [NoteSummary], by order: NoteSort, favoritesFirst: Bool = false) -> [NoteSummary] {
        NoteOrder(order.key, favoritesFirst: favoritesFirst).sorted(list)
    }

    var selectedNote: NoteSummary? {
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
    func openVault(at url: URL, accessing scope: URL? = nil, external: Bool = false) async throws {
        close()
        vaultOpenedExternally = external
        let gen = generation
        let holder = scope ?? url
        let scoped = holder.startAccessingSecurityScopedResource()
        let interval = Perf.begin(.vaultOpen)
        do {
            // A sandboxed Mac refuses a folder whose saved permission did not come back.
            #if DEBUG
            NSLog("SempereDebug folderAccess scoped=%d listable=%d", scoped ? 1 : 0,
                  (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil ? 1 : 0)
            #endif
            try FolderAccess.check(url, scoped: scoped)
            let opened = try await offMain { try Vault.open(at: url) }
            try ensureCurrent(gen)
            Perf.end(interval, "")
            if scoped { scopedURL = holder }
            if let store = vaultStore, let stored = store.entry(containing: url) {
                storeLease = try? store.lease(stored.vaultId)
            }
            vault = opened
            vaultURL = url
            phase = .locked
            // A store vault's targets: their sessions are the open ones (two-way once unlocked).
            attachSyncTargets(vaultID: opened.vaultId, at: url)
        } catch {
            Perf.end(interval, "failed")
            if scoped { holder.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Opens the vault at `url` and unlocks it with `identities` in one step.
    func openVault(at url: URL, identities: [any AgeIdentity]) async throws {
        try await openVault(at: url)
        try await unlock(with: identities)
    }

    /// Unlocks the open vault with age identities (a listed device's key
    /// without its signing keys, or the recovery key: read-only).
    func unlock(with identities: [any AgeIdentity], awaitNotes: Bool = true) async throws {
        try await unlock(with: UnlockKeys(identities: identities), awaitNotes: awaitNotes)
    }

    /// Unlocks the open vault as the device `device` (its decryption key and
    /// its signing keys, which home needs for list changes).
    func unlock(device: DeviceKeys, awaitNotes: Bool = true) async throws {
        try await unlock(with: UnlockKeys(identities: [device.nativeIdentity], signing: device.signing), awaitNotes: awaitNotes)
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
    func unlock(with keys: UnlockKeys, awaitNotes: Bool = true) async throws {
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
    func adoptReopened(_ next: Vault) {
        guard phase == .unlocked, next.vaultId == vault?.vaultId else { return }
        vault = next
        listAlert = ListAlert(vault: next)
        refreshQuickCaptureProfile()
        keyEpoch += 1
        Task {
            await checkTakeovers()
            await refreshDeviceState()
        }
        scheduleSettingsSync()
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
        refreshQuickCaptureProfile()
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
    /// (`RememberedKeys` remembers only those).
    @discardableResult
    func unlock(identityText: String, awaitNotes: Bool = true) async throws -> DeviceKeys? {
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
    func unlock(passphrase: String, awaitNotes: Bool = true) async throws {
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
    func reload() async throws {
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
    func openEditor(for noteID: UUID?) async throws {
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
        let interval = Perf.begin(.noteOpen)
        let render = Perf.begin(.noteFirstRender)
        var shown = false
        defer {
            if !shown {
                Perf.end(interval, "\(Perf.short(noteID)) not shown")
                Perf.end(render, "\(Perf.short(noteID)) not shown")
            }
        }
        // A partial copy: this note first, before the rest of the fill.
        let download = Perf.begin(.noteDownload)
        do { try await downloadNote(noteID) } catch {
            Perf.end(download, "\(Perf.short(noteID)) failed")
            throw error
        }
        Perf.end(download, "\(Perf.short(noteID))")
        let clock = try deviceClockForWriting()
        let cache = await openDrawingCache()
        let url = vault.url
        // The names say which cached version of the note is current; listing them reads no file.
        let listed = cache == nil ? nil : try? await offMain {
            try VaultEnumeration.listNotes(vault: url, only: [noteID]).first?.names
        }
        let verify = partialNoteVerifier(noteID)
        let opened = try await NoteEditor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               recognizer: recognizer, recognitionDelay: recognitionDelay,
                                               verify: verify, cache: cache,
                                               listedNames: listed, beforeFinishing: editorLoadHook,
                                               redownload: { [weak self] in
                                                   guard let self else { throw CancellationError() }
                                                   try self.ensureCurrent(gen)   // never into another vault
                                                   try await self.downloadNote(noteID)
                                               })
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
            editorFailure = (noteID, opened.readOnlyReason ?? String(localized: "This note could not be read."))
            Task { await opened.close() }
            return
        }
        let stale = editor
        opened.prepareBlobWrite = blobWritePreparer(note: noteID)
        configureRecordings(opened)
        opened.onRecognized = { [weak self] id in
            guard let self else { return }
            Task { try? await self.refresh([id]) }   // search sees the new text
        }
        Perf.end(interval, "\(Perf.short(noteID)) pages=\(opened.pages.count) fromCache=\(opened.isPreparing)")
        opened.openInterval = render   // ended by the canvas when the ink is on screen
        shown = true
        editor = opened
        applyPendingJump()
        if let stale { Task { await stale.close() } }
    }

    /// Opens the open vault's drawing cache (`DrawingCache`) once.
    func openDrawingCache() async -> DrawingCache? {
        if let drawingCache { return drawingCache }
        guard let root = drawingCacheRoot, let vault, vault.canRead else { return nil }
        let gen = generation
        let cache = try? await offMain(priority: .utility) { try DrawingCache(root: root, vault: vault) }
        // A newer session may already use the same folder (the vault closed and
        // reopened meanwhile): drop this instance without deleting anything; the
        // closed session's `close` cleared its cache.
        guard gen == generation else { return nil }
        if drawingCache == nil { drawingCache = cache }
        return drawingCache
    }

    /// Opens the selected note on the canvas for the detail pane, keeping a
    /// failure next to the note (`editorFailure`) instead of a blank canvas.
    func showSelectedNote() async {
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
    func reopenEditor(ifShowing id: UUID) async throws {
        if windowEditors[id] != nil { await reopenWindowNote(id) }
        guard editor?.noteID == id else { return }
        try await openEditor(for: nil)
        try await openEditor(for: id)
    }

    func deviceClockForWriting() throws -> DeviceClock {
        if let deviceClock { return deviceClock }
        // Every delta any `NoteWriter` writes with this clock updates that note's attachment index.
        let clock = try DeviceClock(url: deviceStateURL) { [weak self] id in
            Task { @MainActor in
                self?.noteWritten(id)
                self?.syncSessions.forEach { $0.noteWrite() }   // every target syncs shortly after a write
            }
        }
        deviceClock = clock
        return clock
    }

    // MARK: - Closing

    /// Forgets the vault (and its keys). Folder access ends once the open
    /// note's pending changes and any edit already being written are saved.
    func close() {
        generation += 1
        stopSettingsSync()
        stopJoin()
        stopWebDAV()
        cancelRemoteMerges()
        backupControl?.cancel()   // it reads the vault, whose access ends here
        inboxAdoption?.cancel()   // the next vault adopts its own inbox
        inboxAdoption = nil
        importCancellation?.cancel()   // a running import stops after its current note
        lastImportReport = nil
        publishedRows = [:]
        publishedRowsSignature = []
        isBusy = false
        let editor = self.editor
        let windowed = Array(windowEditors.values)
        windowEditors = [:]
        windowClaims = []
        let scoped = scopedURL
        let lease = storeLease
        storeLease = nil
        self.editor = nil
        exportEpoch.bump()
        NotePDFExport.purge(in: exportFolder, olderThan: 0)   // plaintext PDFs dragged out of this vault
        if editor != nil || scoped != nil || !windowed.isEmpty || lease != nil {
            let earlier = closingEditor
            let gate = editGate
            closingEditor = Task {
                await earlier?.value
                await editor?.close()
                for open in windowed { await open.close() }
                // A browser edit already writing (`commit`) finishes first.
                await gate.acquire()
                gate.release()
                scoped?.stopAccessingSecurityScopedResource()
                lease?.release()
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
        takeoverAlert = nil
        heldSinceAtOpen = nil
        sightingRowsState = []
        vaultURL = nil
        vaultOpenedExternally = false
        notes = []
        searchIndex.removeAll()
        selectedNoteID = nil
        isSelectingNotes = false
        multiSelection = []
        exportRequest = nil
        bulkExportRequest = nil
        editorFailure = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionProgress = nil
        recognitionResults = nil
        resetAttachmentIndex()
        activity = RecentActivity()
        draggedPayload = nil
        dropTarget = nil
        pendingJump = nil
        pendingRecordingJump = nil
        transcriptHits = []
        transcriptCache.removeAll()
        searchText = ""
        sidebarSelection = .allNotes
        phase = .noVault
    }

    /// Runs `body` and records its error for the UI instead of throwing.
    func report(_ body: () async throws -> Void) async {
        do { try await body() } catch is CancellationError {} catch { errorMessage = "\(error)" }
    }

    /// Throws `CancellationError` when `close()` or another `openVault` ran
    /// since `gen` was taken, so a late result cannot resurrect a closed vault.
    func ensureCurrent(_ gen: Int) throws {
        guard gen == generation else { throw CancellationError() }
    }

    /// Runs blocking vault work (file I/O, decryption) on a background thread.
    func offMain<T: Sendable>(priority: TaskPriority = .userInitiated,
                              _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let value = try await Task.detached(priority: priority) { try work() }.value
        await afterIO?()
        return value
    }
}
