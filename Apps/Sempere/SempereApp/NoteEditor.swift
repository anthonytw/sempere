import Foundation
import Sempere
import Observation
import PencilKit

/// One open note being edited: its reconstructed state, a `StrokeLedger`
/// per page, and autosave. Every drawing change updates the ledger at once;
/// after `debounce` without changes (and on `flush()`: page switch,
/// background, close) the net change is written as ONE delta.
@MainActor
@Observable
final class NoteEditor {
    let noteID: UUID
    /// Pages in display order, as loaded plus pages added here.
    private(set) var pages: [Page]
    private(set) var meta: NoteMeta
    /// Live page size; an infinite page grows here and is saved with the next delta.
    private(set) var pageSize: PageSize
    /// Paper being previewed by the paper picker (not saved); nil when none.
    private(set) var previewPaper: Paper?
    /// Index into `pages` of the page on the canvas: in a paged note, the one
    /// the scroll is on (`scrolledToPage`).
    private(set) var pageIndex = 0
    /// Bumped when the canvas must bring `pageIndex` into view: a page chosen
    /// (`selectPage`: the strip, the toolbar, a search hit) or added, duplicated
    /// or restored. Scrolling to a page (`scrolledToPage`) does not bump it.
    private(set) var pageJump = 0
    /// Why the note cannot be edited, if it cannot.
    private(set) var readOnlyReason: String?
    /// True while the note is shown from the drawing cache and its revisions
    /// are still being read (`open(..., cache:)`): pages have no strokes yet
    /// and nothing can be edited.
    private(set) var isPreparing = false
    /// True when the editor opened from the drawing cache (`open(..., cache:)`).
    private(set) var openedFromCache = false
    /// The background read of an editor opened from the cache failed: it
    /// shows what the cache had, read-only, and never converts or stores.
    private(set) var loadFailed = false
    /// Bumped when the canvas must reload the shown page's drawing although
    /// the page stayed the same: the read note differed from the cache, or a
    /// layout switch changed the strokes of a page that keeps its id. A stale
    /// drawing would be diffed against the new page (ink removed or duplicated
    /// by the next stroke).
    private(set) var canvasGeneration = 0
    /// The last autosave failure; cleared by the next successful save.
    private(set) var saveError: String?
    /// Deltas written by this editor (for tests and the UI).
    private(set) var deltasWritten = 0
    /// Merges that brought another device's changes on screen
    /// (`mergeRevisions`): the canvas shows "Updated from another device".
    private(set) var remoteUpdates = 0
    /// When the last of them happened.
    private(set) var lastRemoteUpdate: Date?
    /// Canvases showing this note's ink (`attachInkView`).
    @ObservationIgnored fileprivate var inkViews: [WeakInkView] = []
    /// How long a merge (`mergeRevisions`) waits for a stroke under way
    /// before it gives up; the next listing tries again. Bounded so that a
    /// canvas that never reports the end of a stroke cannot stall merges of
    /// the note for as long as it stays open.
    @ObservationIgnored var inkWaitLimit = Duration.seconds(30)

    var isReadOnly: Bool { readOnlyReason != nil || isPreparing }
    var currentPage: Page? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    /// The words of the search this note was opened from, highlighted on its
    /// pages (`NoteEditor+SearchHighlight.swift`); nil when none is shown.
    var searchCursor: SearchMatchCursor?
    /// Bumped to ask the canvas to scroll to the current match.
    var revealToken = 0
    /// The query and starting page to look for once the note is readable
    /// (`highlightSearch(query:page:)` while it is still opening).
    @ObservationIgnored var pendingSearch: (query: String, page: UUID?)?

    /// The pages (of a paged note's stack, each canvas has its own selection) with an item
    /// selected; the Mac menu's item commands are enabled while it is not empty.
    private(set) var pagesWithSelectedItem: Set<UUID> = []
    var hasItemSelection: Bool { !pagesWithSelectedItem.isEmpty }

    /// A canvas reports whether `page` has a selected item (`ItemSelectionController`).
    func itemSelection(on page: UUID, isSelected: Bool) {
        if isSelected {
            if !pagesWithSelectedItem.contains(page) { pagesWithSelectedItem.insert(page) }
        } else if pagesWithSelectedItem.contains(page) {
            pagesWithSelectedItem.remove(page)
        }
    }

    /// The canvas showing this note, for menu commands (`CanvasCommandTarget`).
    @ObservationIgnored weak var canvasTarget: (any CanvasCommandTarget)?
    @ObservationIgnored private var ledgers: [UUID: StrokeLedger] = [:]
    /// The drawing each page's canvas showed last, one-to-one with its
    /// ledger's entries: shown again as it is (no conversion) while the
    /// ledger exists.
    @ObservationIgnored private var canvasDrawings: [UUID: PKDrawing] = [:]
    /// Pages whose drawing is being prepared off the main actor.
    @ObservationIgnored private var preparing: [UUID: Task<PreparedDrawing?, Never>] = [:]
    /// Pages whose strokes changed since the note was read.
    @ObservationIgnored private(set) var dirtyPages: Set<UUID> = []
    /// Where page drawings are cached between opens (nil: no cache).
    @ObservationIgnored private(set) var drawingCache: DrawingCache?
    /// The note version the editor was read from (`DrawingCache.Key`); nil
    /// when it cannot be cached (unreadable revisions).
    @ObservationIgnored private(set) var cacheKey: DrawingCache.Key?
    /// Revisions this editor wrote, by file name.
    @ObservationIgnored private var writtenNames: [String] = []
    /// Bumped whenever this editor starts writing a revision (`mergeRevisions`
    /// re-reads when one started during its read).
    @ObservationIgnored private var writeEpoch = 0
    /// Every revision file name the editor's state already holds: those read
    /// (on open and by `mergeRevisions`) and those it wrote. A name listed in
    /// the note's folder that is not here is a revision written elsewhere
    /// (`hasUnmergedRevisions`).
    @ObservationIgnored private(set) var knownRevisionNames: Set<String> = []
    /// The read that completes an editor opened from the cache.
    @ObservationIgnored private var fullLoad: Task<Void, Never>?
    /// Called when that read fails (`failLoading`), with the reason: the
    /// model shows the failure instead of a partial, read-only canvas.
    @ObservationIgnored var onLoadFailed: (@MainActor (String) -> Void)?
    /// Set when `finishLoading` starts: no more cache hits are handed out
    /// unchecked from then on.
    @ObservationIgnored private var finishing = false
    /// `note.firstRender`: from the open until the canvas shows ink (`didShowInk`).
    @ObservationIgnored var openInterval: Perf.Interval?
    @ObservationIgnored private var committedPageSize: PageSize
    /// Page additions and paper changes not yet written (written before any stroke ops).
    @ObservationIgnored private var pendingPageOps: [Op] = []
    @ObservationIgnored private var writer: NoteWriter?
    /// This opening of the note (format.md §5.8.2): written on every delta the
    /// editor saves, so a history view starts a new session when the note is
    /// closed and opened again. A new editor is a new session.
    @ObservationIgnored private(set) var editingSession = EditingSession.newID()
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var chain: Task<Void, Never>?
    /// Set by `close()` once its last save is done: a closed editor takes no
    /// more changes and writes nothing. A window or view may still show it for
    /// a moment, and it holds the vault as it was opened (with the old secret
    /// after a key change), so nothing it holds may reach the vault.
    @ObservationIgnored private(set) var isShutDown = false

    // Handwriting recognition (`PageRecognizing`).
    /// Reads pages after strokes change and on open; nil turns recognition off.
    @ObservationIgnored var recognizer: (any PageRecognizing)? {
        didSet { if recognizer != nil { scheduleRecognition() } }
    }
    /// Called with the note id after a page's recognition was written.
    @ObservationIgnored var onRecognized: (@MainActor (UUID) -> Void)?
    /// Pages whose strokes this editor changed and whose recognition is not
    /// redone yet: it replaces recognition that cannot be checked (an import).
    @ObservationIgnored private var touchedPages: Set<UUID> = []
    @ObservationIgnored private var recognitionDelay: Duration
    @ObservationIgnored private var recognitionTimer: Task<Void, Never>?
    @ObservationIgnored private var recognitionBusy = false
    @ObservationIgnored private var recognitionAgain = false
    @ObservationIgnored private var recognitionWrite: Task<Void, any Error>?
    @ObservationIgnored private var isClosed = false
    /// Recognitions written by this editor (for tests and the UI).
    private(set) var recognitionsWritten = 0
    /// The last recognition failure; cleared by the next success.
    private(set) var recognitionError: String?

    // Handwriting → math (`NoteEditor+MathInk.swift`, docs/attachments.md §14 G1 part 2).
    /// "Convert to Math" is picking ink: the canvases draw a lasso instead of ink.
    var mathLassoActive = false
    /// Ink picked for conversion, waiting in the equation sheet.
    var mathConversion: MathConversionRequest?
    /// Why the last lasso picked nothing (shown with the lasso's hint).
    var mathLassoMessage: String?
    /// Set while ink changed by an undo or redo step is shown again: the
    /// canvases keep their undo stacks (`takeInk`, `putInkBack`).
    @ObservationIgnored private(set) var reloadKeepsUndo = false
    /// The undo steps of conversions, held for as long as the editor (the
    /// undo manager does not retain its targets).
    @ObservationIgnored var conversionActions: ItemActions?

    // Recordings (`NoteEditor+Recordings.swift`, format.md §8.3, docs/attachments.md §9).
    /// The note's recordings in their order (format.md §5.4). Changed only by
    /// `NoteEditor+Recordings` (one delta per change).
    var recordings: [Recording] = []
    /// The recording being made into this note, if one is.
    var recordingSession: RecordingSession?
    /// Plays the note's recordings; nil until one is played.
    var player: RecordingPlayer?
    /// "Tap Ink to Play": a tap on a stroke plays the recording from where it
    /// was written; drawing is off meanwhile (like item selection).
    var listeningToInk = false
    /// Strokes highlighted because playback is at the moment they were written, per page.
    var playbackHighlight: [UUID: Set<UUID>] = [:]
    /// Recordings being transcribed now.
    var transcribing: Set<UUID> = []
    /// The last recording, playback or transcription failure.
    var recordingError: String?
    /// Saves of finished recordings still running (`close` waits for them).
    @ObservationIgnored var recordingSaves: [Task<Void, Never>] = []
    /// Called once a recording made here is saved, with its audio file and
    /// the session folder holding it: the model transcribes it (when that
    /// setting is on) and deletes the folder. Nil: the folder is deleted.
    @ObservationIgnored var onRecordingSaved: ((Recording, URL, URL) -> Void)?
    /// Called to play a recording from a time (a tap on linked ink).
    @ObservationIgnored var onPlayRequest: ((Recording, Double) -> Void)?

    /// Ink closer than this to the bottom of an infinite page grows it.
    static let growMargin = 200.0
    /// How far below the ink an infinite page grows to.
    static let growStep = 400.0
    /// Default pause before an autosave.
    static let defaultDebounce = Duration.milliseconds(1500)
    /// Default pause after the last stroke change before pages are recognised.
    static let defaultRecognitionDelay = Duration.seconds(4)

    init(noteID: UUID, state: NoteState, writer: NoteWriter?, readOnlyReason: String?,
         debounce: Duration = NoteEditor.defaultDebounce, recognizer: (any PageRecognizing)? = nil,
         recognitionDelay: Duration = NoteEditor.defaultRecognitionDelay) {
        self.noteID = noteID
        self.pages = state.pages
        self.recordings = state.recordings.sorted(by: Recording.sortsBefore)
        self.meta = state.meta
        self.pageSize = state.meta.pageSize
        self.committedPageSize = state.meta.pageSize
        self.writer = writer
        self.readOnlyReason = writer == nil ? (readOnlyReason ?? String(localized: "This note is read-only.")) : readOnlyReason
        self.debounce = debounce
        self.recognizer = recognizer
        self.recognitionDelay = recognitionDelay
    }

    /// An editor showing a note from the drawing cache's `layout` while
    /// its revisions are read (`isPreparing`).
    private init(noteID: UUID, layout: DrawingCache.Layout, debounce: Duration,
                 recognizer: (any PageRecognizing)?, recognitionDelay: Duration) {
        self.noteID = noteID
        self.pages = layout.state.pages
        self.recordings = layout.state.recordings.sorted(by: Recording.sortsBefore)
        self.meta = layout.state.meta
        self.pageSize = layout.state.meta.pageSize
        self.committedPageSize = layout.state.meta.pageSize
        self.writer = nil
        self.readOnlyReason = nil
        self.debounce = debounce
        self.isPreparing = true
        self.openedFromCache = true
        self.recognizer = recognizer
        self.recognitionDelay = recognitionDelay
    }

    /// What reading a note yields, off the main actor.
    fileprivate struct Loaded: Sendable {
        var state: NoteState
        var failures: Int
        var nextSeq: Int
        var readings: [HLC]
        /// Every revision file name read or failed, sorted.
        var names: [String]
        /// What a newer version wrote in this note (format.md §7.4).
        var newer: NewerContent?
        /// Why the vault is read-only, as of this read (format.md §7.3).
        var vaultReadOnly: ReadOnlyReasons
    }

    /// Loads and reconstructs a note off the main actor. A note with
    /// unreadable revisions, or in Recently Deleted, opens read-only.
    /// `coordinated` (a vault in iCloud Drive): the note is read, and its
    /// deltas written, under `NSFileCoordinator` (`CloudVault`). `verify`
    /// runs inside that read before and after the note is loaded and throws
    /// to refuse a note whose files are not all local (`CloudVault.requireLocal`).
    ///
    /// With a `cache` and the note's `listedNames` (its revision file names
    /// as just listed), a note whose layout is cached opens at once from the
    /// cache (`isPreparing`) and is read in the background; its pages'
    /// drawings come from the cache too (`prepareDrawing`) and are checked
    /// against what is read before anything can be drawn.
    static func open(vault: Vault, noteID: UUID, clock: DeviceClock,
                     debounce: Duration = NoteEditor.defaultDebounce,
                     recognizer: (any PageRecognizing)? = nil,
                     recognitionDelay: Duration = NoteEditor.defaultRecognitionDelay,
                     coordinated: Bool = false,
                     verify: (@Sendable () throws -> Void)? = nil,
                     cache: DrawingCache? = nil, listedNames: [String]? = nil,
                     beforeFinishing: (@Sendable () async -> Void)? = nil,
                     redownload: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> NoteEditor {
        if let cache, let listedNames, !listedNames.isEmpty {
            let key = DrawingCache.Key(note: noteID, revisions: listedNames)
            let layout = await Task.detached(priority: .userInitiated) {
                Perf.measure(.noteCache, "layout \(Perf.short(noteID))") { cache.layout(key) }
            }.value
            if let layout {
                let editor = NoteEditor(noteID: noteID, layout: layout, debounce: debounce, recognizer: recognizer,
                                        recognitionDelay: recognitionDelay)
                editor.drawingCache = cache
                editor.cacheKey = key
                editor.fullLoad = Task { [weak editor] in
                    do {
                        let loaded: Loaded
                        do {
                            loaded = try await read(vault: vault, noteID: noteID, device: clock.device,
                                                    coordinated: coordinated, verify: verify)
                        } catch CloudVault.CloudError.noteNotLocal where redownload != nil {
                            // A file went missing (or a new one was listed) since the download: once more.
                            // Not for an editor closed meanwhile (the model may have another vault open).
                            try Task.checkCancellation()
                            try await redownload?()
                            loaded = try await read(vault: vault, noteID: noteID, device: clock.device,
                                                    coordinated: coordinated, verify: verify)
                        }
                        // The read is detached: cancellation (`close`) is only seen here.
                        try Task.checkCancellation()
                        await clock.observe(loaded.readings)
                        await beforeFinishing?()
                        try Task.checkCancellation()
                        await editor?.finishLoading(loaded, vault: vault, clock: clock, coordinated: coordinated)
                    } catch is CancellationError {
                    } catch {
                        editor?.failLoading(error)
                    }
                }
                return editor
            }
        }
        let loaded = try await read(vault: vault, noteID: noteID, device: clock.device, coordinated: coordinated,
                                    verify: verify)
        await clock.observe(loaded.readings)
        let reason = readOnlyReason(loaded)
        let session = EditingSession.newID()
        let writer = reason == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: loaded.nextSeq,
                                                coordinated: coordinated, session: session) : nil
        let editor = NoteEditor(noteID: noteID, state: loaded.state, writer: writer, readOnlyReason: reason,
                                debounce: debounce, recognizer: recognizer, recognitionDelay: recognitionDelay)
        editor.editingSession = session
        editor.knownRevisionNames = Set(loaded.names)
        if let cache, loaded.failures == 0 {
            let key = DrawingCache.Key(note: noteID, revisions: loaded.names)
            editor.drawingCache = cache
            editor.cacheKey = key
            let layout = DrawingCache.Layout(loaded.state)
            Task.detached(priority: .utility) { cache.store(layout, for: key) }
        }
        editor.scheduleRecognition()   // pages that were never read, or changed elsewhere
        return editor
    }

    private static func read(vault: Vault, noteID: UUID, device: DeviceID, coordinated: Bool,
                             verify: (@Sendable () throws -> Void)?) async throws -> Loaded {
        try await Task.detached(priority: .userInitiated) {
            let loaded = try Perf.measure(.noteRead, "\(Perf.short(noteID))") {
                try CloudVault.coordinatedRead(coordinated ? vault.url : nil) {
                    try verify?()
                    let loaded = try vault.loadNote(noteID)
                    try verify?()
                    return loaded
                }
            }
            let state = try Perf.measure(.noteReconstruct, "\(Perf.short(noteID)) revisions=\(loaded.revisions.count)") {
                try NoteReducer.reconstruct(loaded.revisions)
            }
            let names = (loaded.revisions.map(\.name.filename) + loaded.failures.keys.map(\.filename)).sorted()
            return Loaded(state: state, failures: loaded.failures.count,
                          nextSeq: Vault.nextSeq(from: loaded.revisions, device: device),
                          readings: loaded.revisions.map(\.hlc), names: names, newer: loaded.newer,
                          vaultReadOnly: vault.readOnlyReasons)
        }.value
    }

    /// Why a note in Recently Deleted cannot be edited.
    static let deletedReason = String(localized: "This note is in Recently Deleted.") // compared by value, so one string for the process

    /// Why the note is read-only because of content a newer version wrote, in
    /// the note or anywhere in the vault (format.md §7.3); nil when none was seen.
    private static func newerReason(_ loaded: Loaded) -> String? {
        if let newer = loaded.newer {
            let summary = newer.summary
            return String(localized: "Parts of this note were written by a newer version of Sempere (\(summary)). It is shown as far as this version understands it, read-only: update Sempere to edit it.")
        } else if !loaded.vaultReadOnly.isEmpty {
            return AppModel.readOnlyText(loaded.vaultReadOnly)
        }
        return nil
    }

    private static func readOnlyReason(_ loaded: Loaded) -> String? {
        // A newer version's content first: it is why other revisions may be unreadable (format.md §7.4).
        if let reason = newerReason(loaded) {
            return reason
        } else if loaded.failures > 0 {
            let count = loaded.failures
            return String(localized: "\(count) revisions of this note could not be read, so it opens read-only.")
        } else if loaded.state.deleted {
            return deletedReason
        }
        return nil
    }

    /// The background read of an editor opened from the cache finished:
    /// the real pages replace the layout's, every cached drawing shown so far
    /// is checked against them (kept, with its ledger, when it matches;
    /// reloaded from the strokes when not), and the note becomes editable.
    private func finishLoading(_ loaded: Loaded, vault: Vault, clock: DeviceClock, coordinated: Bool) async {
        guard isPreparing else { return }
        finishing = true
        let sameVersion = loaded.failures == 0 && cacheKey?.revisions == loaded.names
        let shownPages = canvasDrawings.mapValues(SendableDrawing.init)
        let pagesByID = Dictionary(loaded.state.pages.map { ($0.id, $0.strokes) }, uniquingKeysWith: { a, _ in a })
        // Checking and fingerprinting 15 000 strokes is a few milliseconds: off the main actor anyway.
        let checked: [UUID: PreparedDrawing] = sameVersion ? await Task.detached(priority: .userInitiated) {
            var ok: [UUID: PreparedDrawing] = [:]
            for (id, box) in shownPages {
                guard let strokes = pagesByID[id], DrawingPreparation.matches(box.drawing, strokes) else { continue }
                ok[id] = PreparedDrawing(drawing: box.drawing)
            }
            return ok
        }.value : [:]
        guard isPreparing else { return }
        let shown = currentPage?.id
        let shownNow = canvasDrawings   // what the canvas may show now (no hit is handed out after `finishing`)
        pages = loaded.state.pages
        recordings = loaded.state.recordings.sorted(by: Recording.sortsBefore)
        meta = loaded.state.meta
        pageSize = loaded.state.meta.pageSize
        committedPageSize = loaded.state.meta.pageSize
        pageIndex = shown.flatMap { id in pages.firstIndex { $0.id == id } } ?? min(pageIndex, max(pages.count - 1, 0))
        readOnlyReason = Self.readOnlyReason(loaded)
        writer = readOnlyReason == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: loaded.nextSeq,
                                                    coordinated: coordinated, session: editingSession) : nil
        cacheKey = loaded.failures == 0 ? DrawingCache.Key(note: noteID, revisions: loaded.names) : nil
        knownRevisionNames = Set(loaded.names)
        canvasDrawings = [:]
        ledgers = [:]
        for page in pages {
            guard let ready = checked[page.id], let ledger = StrokeLedger(stored: page.strokes, infos: ready.infos) else { continue }
            ledgers[page.id] = ledger
            canvasDrawings[page.id] = ready.drawing
        }
        if let shown, shownPages[shown] != nil || shownNow[shown] != nil, checked[shown] == nil {
            // The cached drawing on screen was not this note's: show the real one.
            Perf.event(.noteCache, "mismatch \(Perf.short(noteID))")
            canvasGeneration &+= 1
        }
        isPreparing = false
        applyPendingSearch()
        scheduleRecognition()   // pages that were never read, or changed elsewhere
    }

    /// The background read of an editor opened from the cache failed: the
    /// cached ink stays on screen, read-only, with the reason.
    private func failLoading(_ error: any Error) {
        guard isPreparing else { return }
        let detail = "\(error)"
        readOnlyReason = String(localized: "This note could not be read: \(detail)")
        loadFailed = true
        isPreparing = false
        onLoadFailed?("\(error)")
    }

    /// Stops the background read of an editor opened from the cache that
    /// will not be shown (nothing is written; `close` also does this).
    func cancelLoading() {
        fullLoad?.cancel()
    }

    /// Waits until a note opened from the cache has been read (at once otherwise).
    func loaded() async {
        await fullLoad?.value
    }

    // MARK: - Pages

    /// The ledger of a page, created from its stored strokes on first use.
    private func ledger(_ pageID: UUID) -> StrokeLedger {
        if let l = ledgers[pageID] { return l }
        let l = newLedger(pageID)
        ledgers[pageID] = l
        return l
    }

    /// A ledger for the page's stored strokes (not kept).
    private func newLedger(_ pageID: UUID) -> StrokeLedger {
        StrokeLedger(stored: pages.first { $0.id == pageID }?.strokes ?? [], info: CanvasStrokeInfo.init(stored:))
    }

    /// The drawing to show for a page: its live strokes, one canvas stroke
    /// each. Re-keys the page's ledger to match. Converts on the calling
    /// (main) actor; the canvas uses `readyDrawing` / `prepareDrawing`.
    func drawing(for pageID: UUID) -> PKDrawing {
        // No ledger before the strokes are read (or when they could not be).
        if isPreparing || loadFailed { return canvasDrawings[pageID] ?? PKDrawing() }
        var l = ledger(pageID)
        l.rebase(info: CanvasStrokeInfo.init(stored:))
        ledgers[pageID] = l
        let drawing = l.drawing
        canvasDrawings[pageID] = drawing
        return drawing
    }

    /// The drawing the page's canvas can show right away, without converting
    /// anything: what it showed last (or what the cache gave while the note
    /// is being read). Nil when it must be prepared (`prepareDrawing`).
    func readyDrawing(for pageID: UUID) -> PKDrawing? {
        guard let drawing = canvasDrawings[pageID], isPreparing || loadFailed || ledgers[pageID] != nil else { return nil }
        return drawing
    }

    /// Prepares the page's drawing off the main actor: from the drawing
    /// cache when it holds this version of the page (checked against the
    /// strokes), else by converting the strokes, those reaching into
    /// `visible` (page points) first, handed to `partial` as soon as they are
    /// converted. A converted page is stored in the cache. The page's ledger
    /// is set up from the result, so nothing is converted again on the main
    /// actor. Nil when the page went away or changed meanwhile.
    func prepareDrawing(for pageID: UUID, visible: CGRect? = nil,
                        partial: (@MainActor @Sendable (PKDrawing) -> Void)? = nil) async -> PKDrawing? {
        if let ready = readyDrawing(for: pageID) { return ready }
        if let task = preparing[pageID] { return await task.value?.drawing }
        if isPreparing {
            // Opened from the cache and still being read: this page from the cache if it is there.
            if let cache = drawingCache, let key = cacheKey {
                let noteID = self.noteID
                let cached = await Task.detached(priority: .userInitiated) { () -> SendableDrawing? in
                    let interval = Perf.begin(.noteCache)
                    let data = cache.drawing(key, page: pageID)
                    let drawing = data.flatMap { try? PKDrawing(data: $0) }
                    Perf.end(interval, "\(drawing == nil ? "miss" : "hit") page \(Perf.short(noteID)) bytes=\(data?.count ?? 0)")
                    // Fingerprinted once the strokes are read (`finishLoading`), not now.
                    return drawing.map(SendableDrawing.init)
                }.value
                if isPreparing, !finishing, let cached {
                    canvasDrawings[pageID] = cached.drawing
                    return cached.drawing
                }
            }
            await fullLoad?.value
            if let ready = readyDrawing(for: pageID) { return ready }
        }
        // A failed read leaves pages without strokes: nothing to convert or store.
        guard !isPreparing, !loadFailed, pages.contains(where: { $0.id == pageID }) else { return nil }
        let strokes = ledgers[pageID]?.live ?? pages.first { $0.id == pageID }?.strokes ?? []
        let ids = strokes.map(\.id)
        let cache = dirtyPages.contains(pageID) ? nil : drawingCache
        let key = cacheKey
        let noteID = self.noteID
        let task = Task.detached(priority: .userInitiated) { () -> PreparedDrawing? in
            if let cache, let key {
                let interval = Perf.begin(.noteCache)
                let hit = cache.drawing(key, page: pageID).flatMap { DrawingPreparation.fromCache($0, strokes: strokes) }
                Perf.end(interval, "\(hit == nil ? "miss" : "hit") page \(Perf.short(noteID)) strokes=\(strokes.count)")
                if let hit { return hit }
            }
            let prepared = Perf.measure(.noteConvert, "\(Perf.short(noteID)) strokes=\(strokes.count)") {
                DrawingPreparation.convert(strokes, visible: visible, visibleFirst: partial.map { show in
                    { drawing in
                        let box = SendableDrawing(drawing)
                        Task { @MainActor in show(box.drawing) }
                    }
                })
            }
            if let cache, let key {
                // Stored after the page is shown, not before.
                let box = SendableDrawing(prepared.drawing)
                Task.detached(priority: .utility) {
                    Perf.measure(.cacheWrite, "page \(Perf.short(noteID))") {
                        cache.store(drawing: box.drawing.dataRepresentation(), for: key, page: pageID)
                    }
                }
            }
            return prepared
        }
        preparing[pageID] = task
        let prepared = await task.value
        preparing[pageID] = nil
        guard let prepared, !isPreparing,
              (ledgers[pageID]?.live ?? pages.first { $0.id == pageID }?.strokes ?? []).map(\.id) == ids else { return nil }
        if var l = ledgers[pageID] {
            guard l.rebase(infos: prepared.infos) else { return nil }
            ledgers[pageID] = l
        } else {
            guard let l = StrokeLedger(stored: strokes, infos: prepared.infos) else { return nil }
            ledgers[pageID] = l
        }
        canvasDrawings[pageID] = prepared.drawing
        return prepared.drawing
    }

    /// The canvas shows ink for the first time since the note was opened:
    /// ends the `note.firstRender` interval.
    func didShowInk(partial: Bool) {
        guard let interval = openInterval else { return }
        openInterval = nil
        Perf.end(interval, "\(Perf.short(noteID)) \(partial ? "visible strokes" : "page") cached=\(isPreparing)")
    }

    /// Live strokes of a page (saved or not). Empty while the note is being
    /// read (`isPreparing`).
    func liveStrokes(of pageID: UUID) -> [Stroke] { isPreparing || loadFailed ? [] : ledger(pageID).live }

    /// Ink changes per page, so page thumbnails can follow them.
    private(set) var inkRevisions: [UUID: Int] = [:]
    /// Identifies this editor in cache keys (`inkRevisions` restart at 0 in
    /// every editor, so they alone cannot key a cache that outlives it).
    @ObservationIgnored let sessionID = UUID()

    /// The strokes a page thumbnail shows: live once the page has been on
    /// the canvas, else as loaded (no ledger is made just for a thumbnail).
    func thumbnailStrokes(of page: Page) -> [Stroke] {
        ledgers[page.id]?.live ?? page.strokes
    }

    /// Shows the page `id` (a search hit); no-op when the note has no such page.
    func showPage(id: UUID) {
        if let i = pages.firstIndex(where: { $0.id == id }) { selectPage(i) }
    }

    /// Shows another page; pending changes are saved first. In a paged
    /// note the canvas scrolls to it, also when it is already the current
    /// page but scrolled partly out of view.
    func selectPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        pageJump &+= 1
        guard index != pageIndex else { return }
        pageIndex = index
        Task { await flush() }
    }

    /// The paged canvas scrolled so that page `index` is the current one
    /// (`PageStackLayout.currentPage`). Nothing is saved for it: every page
    /// on screen is live, and autosave writes after its pause as usual.
    func scrolledToPage(_ index: Int) {
        guard pages.indices.contains(index), index != pageIndex else { return }
        pageIndex = index
    }

    /// The paper to draw under `page`: the picker's preview while one is
    /// open, else the page's own paper, else the note's.
    func displayedPaper(of page: Page) -> Paper {
        previewPaper ?? page.paper ?? meta.paper
    }

    /// Shows `paper` under the canvas without saving it; nil ends the preview.
    func showPaperPreview(_ paper: Paper?) {
        previewPaper = paper?.validated()
    }

    /// Sets the paper of the current page, or of the whole note (every page),
    /// at once on screen; saved with the next delta (`NoteOps.setPaper`).
    func setPaper(_ paper: Paper, allPages: Bool) {
        previewPaper = nil
        guard !isReadOnly, !isShutDown, let page = currentPage else { return }
        let ops = NoteOps.setPaper(paper, scope: allPages ? .allPages : .page(page.id), note: meta, pages: pages)
        guard !ops.isEmpty else { return }
        for op in ops {
            switch op {
            case .setMeta(.paper(let p)): meta.paper = p
            case .setPagePaper(let id, let p):
                if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].paper = p }
            default: break
            }
        }
        pendingPageOps += ops
        scheduleSave()
    }

    /// Appends a blank page and shows it; saved with the next delta.
    func addPage() {
        insertPage(at: pages.count)
    }

    /// Adds a blank page right after the one on the canvas and shows it.
    func addPageAfterCurrent() {
        insertPage(at: pages.isEmpty ? 0 : pageIndex + 1)
    }

    /// Adds a blank page at `index` of `pages` and shows it; saved with the
    /// next delta (with the first ink drawn on it, if that comes first).
    func insertPage(at index: Int) {
        guard !isReadOnly, !isShutDown else { return }
        let edit = NoteOps.addPage(at: index, in: pages)
        guard case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        scheduleSave()
    }

    // MARK: - Page gestures (format.md §5.4.3): each is saved at once, one delta

    /// Whether the note is one infinite page rather than fixed-size pages.
    var isPageless: Bool { pageSize.infinite }

    /// A page deleted here, kept for undo with its live strokes and position.
    struct DeletedPage: Equatable {
        var page: Page
        var index: Int
    }

    /// Pages deleted while the note is open, newest last (`undoDeletePage`).
    private(set) var deletedPages: [DeletedPage] = []

    /// Moves the page at `from` so it ends up at `to` (indices into `pages`).
    func movePage(from: Int, to: Int) {
        guard !isReadOnly, !isShutDown, pages.indices.contains(from),
              let edit = NoteOps.movePage(pages[from].id, to: to, in: pages) else { return }
        apply(edit, show: currentPage?.id)
        saveNow()
    }

    /// Whether a page can be deleted: a note keeps at least one page.
    var canDeletePage: Bool { !isReadOnly && !isShutDown && pages.count > 1 }
    /// A text box on one of this note's canvases is being typed in (`TextBoxEditorController`).
    /// Menu commands whose shortcuts are text-editing keys on a Mac (⌘⌫ Move to Recently
    /// Deleted, ⌥⌘⌫ Delete Page) are off meanwhile (`EditorCommands.fill`).
    var typingInTextBox = false

    /// Deletes a page (`removePage`; its strokes go with it). Undo with
    /// `undoDeletePage`. The last page is never deleted.
    func deletePage(_ id: UUID) {
        guard canDeletePage, let index = pages.firstIndex(where: { $0.id == id }),
              let edit = NoteOps.deletePage(id, in: pages) else { return }
        let gone = livePages()[index]
        let shown = currentPage?.id == id ? nil : currentPage?.id
        apply(edit, show: shown)
        if shown == nil { pageIndex = min(index, max(pages.count - 1, 0)) }
        deletedPages.append(DeletedPage(page: gone, index: index))
        saveNow()
    }

    /// Re-creates the page deleted last, where it was (a new id with
    /// `parent`, its strokes under new ids: format.md §5.2), and shows it.
    func undoDeletePage() {
        guard !isReadOnly, !isShutDown, let last = deletedPages.popLast() else { return }
        let edit = NoteOps.restorePage(last.page, at: last.index, in: pages)
        guard case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        saveNow()
    }

    /// Duplicates a page (its ink and paper) right after it and shows the copy.
    func duplicatePage(_ id: UUID) {
        guard !isReadOnly, !isShutDown, let edit = NoteOps.duplicatePage(id, in: livePages()),
              case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        saveNow()
    }

    /// Switches the note between paged and pageless (format.md §5.4.3): ink
    /// not yet saved is saved first, then the switch is one delta. No ink is
    /// deleted or moved on its sheet; the canvas shows the page that holds
    /// what was on screen (the first after a join).
    func setLayout(pageless: Bool) async {
        guard !isReadOnly, !isShutDown, pageless != isPageless else { return }
        // Ink drawn while a save is being written is pending again afterwards:
        // save until nothing is, so the switch never takes unsaved ink as saved
        // (a few rounds at most: if ink keeps arriving, the switch is not made).
        var rounds = 0
        repeat {
            await flush()
            guard saveError == nil else { return }   // never switch over ink that could not be saved
            rounds += 1
        } while hasPendingChanges && rounds < 4
        guard !hasPendingChanges, !isShutDown, pageless != isPageless else { return }
        let shown = currentPage?.id
        let edit = pageless
            ? NoteOps.makePageless(pages: livePages(), pageSize: pageSize)
            : NoteOps.makePaged(pages: livePages(), pageSize: pageSize)
        guard !edit.ops.isEmpty else { return }
        // Stroke ids changed: ledgers and the drawings shown with them are rebuilt
        // from the new pages (a drawing kept for a page id that stays would be
        // diffed against the new ledger), and every page is stored anew in the cache.
        ledgers = [:]
        canvasDrawings = [:]
        deletedPages = []
        pages = edit.pages
        dirtyPages = Set(pages.map(\.id))
        pageIndex = pages.firstIndex { $0.id == shown } ?? 0
        pageSize = edit.pageSize
        committedPageSize = edit.pageSize   // the switch's own setMeta carries it
        pendingPageOps += edit.ops
        canvasGeneration &+= 1
        for page in pages { inkRevisions[page.id, default: 0] &+= 1 }
        await flush()
    }

    /// Whether anything is waiting to be written (page ops, ink, page size).
    var hasPendingChanges: Bool {
        !pendingPageOps.isEmpty || pageSize != committedPageSize
            || pages.contains { page in ledgers[page.id].map { !$0.pendingOps(page: page.id, live: $0.live).isEmpty } ?? false }
    }

    /// `pages` with each page's live strokes (saved or not).
    private func livePages() -> [Page] {
        pages.map { page in
            var p = page
            if let l = ledgers[page.id] { p.strokes = l.live }
            return p
        }
    }

    /// Takes `edit`'s pages, drops ledgers of pages that are gone and queues
    /// its ops; shows `show` (else the same page, else the nearest).
    private func apply(_ edit: PageEdit, show: UUID?) {
        let keep = Set(edit.pages.map(\.id))
        let had = Set(pages.map(\.id))
        ledgers = ledgers.filter { keep.contains($0.key) }
        canvasDrawings = canvasDrawings.filter { keep.contains($0.key) }   // one-to-one with the ledgers
        dirtyPages.formUnion(keep.subtracting(had))   // new pages: stored in the cache from their strokes
        pages = edit.pages
        if let show, let i = pages.firstIndex(where: { $0.id == show }) {
            pageIndex = i
            pageJump &+= 1
        } else {
            pageIndex = min(pageIndex, max(pages.count - 1, 0))
        }
        pendingPageOps += edit.ops
    }

    // MARK: - Items (format.md §8.2): each gesture is saved at once, one delta

    /// Item changes per page, so the item layer and thumbnails follow them.
    private(set) var itemRevisions: [UUID: Int] = [:]

    /// The writer, for attachment blobs (`NoteEditor+Items`); nil when read-only.
    var attachmentWriter: NoteWriter? { isShutDown ? nil : writer }

    /// iCloud Drive: makes this note's copy of a blob local before the blob is
    /// written or copied into the note (set by the model; nil elsewhere). A
    /// copy iCloud lists but has not downloaded would otherwise not be found,
    /// and a second file written under the same write-once name.
    @ObservationIgnored var prepareBlobWrite: (@Sendable (BlobRef) async throws -> Void)?

    /// Takes an item gesture's page and queues its ops, then saves them as
    /// one delta (with any ink still pending). False when the note cannot
    /// be edited or the page is gone.
    @discardableResult
    func applyItemEdit(_ edit: ItemEdit) -> Bool {
        guard !isReadOnly, !isShutDown, !edit.ops.isEmpty,
              let i = pages.firstIndex(where: { $0.id == edit.page.id }) else { return false }
        pages[i].items = edit.page.items
        itemRevisions[edit.page.id, default: 0] &+= 1
        pendingPageOps += edit.ops
        saveNow()
        return true
    }

    /// Shows item changes a delta written elsewhere already holds (a
    /// recording's card, `NoteEditor+Recordings`): `added` items on their
    /// pages, `removed` item ids gone from theirs. Writes nothing.
    func showWrittenItems(added: [(page: UUID, item: Item)], removed: [(page: UUID, item: UUID)] = []) {
        for (page, item) in added {
            guard let i = pages.firstIndex(where: { $0.id == page }) else { continue }
            pages[i].items.append(item)
            pages[i].items.sort(by: Item.drawsBefore)
            itemRevisions[page, default: 0] &+= 1
        }
        for (page, item) in removed {
            guard let i = pages.firstIndex(where: { $0.id == page }) else { continue }
            pages[i].items.removeAll { $0.id == item }
            itemRevisions[page, default: 0] &+= 1
        }
    }

    /// Takes pages built elsewhere (a PDF's, `NoteEditor+Insert`), shows
    /// `show`, and saves them at once as one delta.
    func applyInsertedPages(_ edit: PageEdit, show: UUID?) {
        guard !isReadOnly, !isShutDown else { return }
        apply(edit, show: show)
        for page in edit.pages where !page.items.isEmpty { itemRevisions[page.id, default: 0] &+= 1 }
        saveNow()
    }

    /// Writes what is pending now rather than after the pause.
    private func saveNow() {
        Task { await flush() }
    }

    // MARK: - Changes from the canvas

    /// The canvas's drawing for `pageID` changed (stroke drawn, erased,
    /// moved, undone, redone). Updates ids now; saves after the pause.
    @discardableResult
    func drawingDidChange(pageID: UUID, items: [StrokeLedger.Item], inkMaxY: Double?) -> StrokeLedger.Change {
        drawingDidChange(pageID: pageID, inkMaxY: inkMaxY) { $0.update(items) }
    }

    /// The canvas's drawing changed: `update` brings the page's ledger (made
    /// when missing) up to it, in place.
    private func drawingDidChange(pageID: UUID, inkMaxY: Double?,
                                  update: (inout StrokeLedger) -> StrokeLedger.Change) -> StrokeLedger.Change {
        guard !isReadOnly, !isShutDown else { return .init() }
        // In place: a copy taken out of the dictionary would copy every entry on write.
        let change = update(&ledgers[pageID, default: newLedger(pageID)])
        if !change.isEmpty {
            inkRevisions[pageID, default: 0] &+= 1
            dirtyPages.insert(pageID)
        }
        if let inkMaxY { growPage(toFit: inkMaxY) }
        if !change.isEmpty || pageSize != committedPageSize { scheduleSave() }
        if !change.isEmpty {
            touchedPages.insert(pageID)
            scheduleRecognition()
        }
        return change
    }

    /// Convenience for the canvas: a whole PencilKit drawing.
    @discardableResult
    func drawingDidChange(pageID: UUID, drawing: PKDrawing, tool: PKTool?) -> StrokeLedger.Change {
        guard !isReadOnly else { return .init() }
        let bounds = drawing.bounds
        let strokes = drawing.strokes
        let stamp = recordingStamp
        let change = drawingDidChange(pageID: pageID, inkMaxY: bounds.isNull ? nil : Double(bounds.maxY)) {
            $0.update(strokes, tool: tool, stamp: stamp)
        }
        canvasDrawings[pageID] = drawing   // the ledger's entries now fingerprint exactly these strokes
        return change
    }

    /// Grows an infinite page so ink stays at least `growMargin` above its
    /// bottom. Finite pages never change size; pages never shrink.
    func growPage(toFit inkMaxY: Double) {
        guard pageSize.infinite, inkMaxY.isFinite, inkMaxY > pageSize.height - Self.growMargin else { return }
        pageSize.height = (inkMaxY + Self.growStep).rounded(.up)
    }

    // MARK: - Saving

    private func scheduleSave() {
        timer?.cancel()
        let debounce = self.debounce
        timer = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.flush()
        }
    }

    /// Writes everything pending as one delta now (no-op when nothing is).
    /// Saves are serialized; a failure is kept in `saveError` and the
    /// changes stay pending for the next save.
    func flush() async {
        timer?.cancel()
        timer = nil
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            await self?.writePending()
        }
        chain = task
        await task.value
    }

    /// Saves what is pending and stops autosaving; afterwards the editor takes
    /// no more changes and writes nothing (`isShutDown`). The pages' drawings
    /// are stored in the drawing cache for the next open (`storeForNextOpen`).
    func close() async {
        // A recording in progress is saved into the note before the last save.
        await finishRecording()
        player?.stop()
        isClosed = true
        fullLoad?.cancel()
        recognitionTimer?.cancel()
        // A recognition write already started finishes; none starts after this.
        _ = await recognitionWrite?.result
        await flush()
        isShutDown = true
        storeForNextOpen()
    }

    /// Stores this version of the note (as read, plus the deltas this editor
    /// wrote) in the drawing cache: its layout, the drawings of pages shown
    /// unchanged as they are, and those of changed pages converted from
    /// their live strokes, in the background. Nothing when the note could
    /// not be cached, a save failed or something is still unsaved; the
    /// version it replaces is dropped from the cache.
    func storeForNextOpen() {
        guard let cache = drawingCache, let base = cacheKey, !isPreparing, readOnlyReason == nil, saveError == nil,
              pendingPageOps.isEmpty, pageSize == committedPageSize,
              !pages.contains(where: { page in ledgers[page.id].map { !$0.pendingOps(page: page.id, live: $0.live).isEmpty } ?? false })
        else { return }
        let key = DrawingCache.Key(note: noteID, revisions: base.revisions + writtenNames)
        guard key != base else { return }   // nothing written: the cache already has this version
        var state = NoteState(deleted: false, meta: meta, pages: pages)
        state.meta.pageSize = pageSize
        var clean: [UUID: SendableDrawing] = [:]
        var changed: [UUID: [Stroke]] = [:]
        for i in state.pages.indices {
            let id = state.pages[i].id
            if let l = ledgers[id] { state.pages[i].strokes = l.live }
            if dirtyPages.contains(id) {
                changed[id] = state.pages[i].strokes
            } else if let drawing = canvasDrawings[id], ledgers[id] != nil {
                clean[id] = SendableDrawing(drawing)
            }
        }
        let layout = DrawingCache.Layout(state)
        let old = base, pageIDs = state.pages.map(\.id), noteID = self.noteID
        Task.detached(priority: .utility) {
            Perf.measure(.cacheWrite, "close \(Perf.short(noteID)) changed=\(changed.count) clean=\(clean.count)") {
                cache.store(layout, for: key)
                for (id, box) in clean { cache.store(drawing: box.drawing.dataRepresentation(), for: key, page: id) }
                for (id, strokes) in changed {
                    cache.store(drawing: DrawingPreparation.convert(strokes).drawing.dataRepresentation(), for: key, page: id)
                }
                cache.remove(old, pages: pageIDs)
            }
        }
    }

    /// Writes `ops` as one delta of their own, after any save in flight
    /// (recording changes, which touch no page).
    func writeDirect(_ ops: [Op], with writer: NoteWriter) async throws {
        let previous = chain
        let task = Task { () async throws -> RevisionName in
            await previous?.value
            self.writeEpoch &+= 1
            return try await writer.write(ops)
        }
        chain = Task { _ = try? await task.value }
        let name = try await task.value
        writtenNames.append(name.filename)
        knownRevisionNames.insert(name.filename)
        deltasWritten += 1
    }

    private func writePending() async {
        guard let writer, !isShutDown else { return }
        let pageOps = pendingPageOps
        var ops = pageOps
        // Ledgers commit before the write (see `StrokeLedger.beginSave`) and
        // roll back if it fails.
        var saves: [(UUID, StrokeLedger.Save)] = []
        for page in pages {
            guard var l = ledgers[page.id], let save = l.beginSave(page: page.id) else { continue }
            ledgers[page.id] = l
            ops += save.ops
            saves.append((page.id, save))
        }
        let size = pageSize
        if size != committedPageSize { ops.append(.setMeta(.pageSize(size))) }
        guard !ops.isEmpty else { return }
        writeEpoch &+= 1
        do {
            let name = try await writer.write(ops)
            writtenNames.append(name.filename)
            knownRevisionNames.insert(name.filename)
        } catch {
            for (id, save) in saves { ledgers[id]?.saveFailed(save) }
            let detail = "\(error)"
            saveError = String(localized: "Could not save: \(detail)")
            return
        }
        pendingPageOps.removeFirst(pageOps.count)
        committedPageSize = size
        deltasWritten += 1
        saveError = nil
    }
}

// MARK: - Revisions written elsewhere

extension NoteEditor {
    /// What `mergeRevisions` did.
    enum RemoteMergeOutcome: Equatable {
        /// The note as read equals what the editor shows (its own revisions, or
        /// changes that cancel out): nothing changed on screen.
        case unchanged
        /// The editor shows the merged note now; `fromOtherDevice` when a
        /// revision of another device was among those taken.
        case merged(fromOtherDevice: Bool)
        /// Nothing was applied: the editor is closed, still being read, or
        /// could not save what it has (`saveError`). The names stay unknown,
        /// so the next listing tries again.
        case skipped
        /// Nothing was applied: a revision of the note could not be read (it
        /// opens read-only when reopened). Tried again once the names change.
        case unreadable
    }

    /// Whether `names` (the note folder's revision files, as just listed) hold
    /// a revision the editor has not read or written.
    func hasUnmergedRevisions(_ names: [String]) -> Bool {
        !isPreparing && !loadFailed && !isShutDown && names.contains { !knownRevisionNames.contains($0) }
    }

    /// Whether the editor can take revisions written elsewhere in place
    /// (`mergeRevisions`): it can save. A read-only editor (Recently Deleted,
    /// unreadable revisions) is reopened instead, it has nothing unsaved.
    var mergesInPlace: Bool { writer != nil && !loadFailed }

    /// True while a canvas showing this note is in the middle of a stroke or
    /// an object-eraser gesture: its drawing must not be replaced then.
    var isInkInUse: Bool { inkViews.contains { $0.view?.isUsingInk == true } }

    /// Brings revisions written elsewhere (another device, or this device's
    /// browser edits) into the open editor without losing anything unsaved.
    ///
    /// Waits until no canvas is mid-stroke (at most `inkWaitLimit`, else
    /// `.skipped`), saves what is pending (so the
    /// read holds this canvas's ink too), reads the note again (the caller
    /// has made every revision local: `downloadNote`), and applies the merged
    /// state (format.md §5.3 decides concurrent edits) as a minimal diff:
    /// per page only strokes that came or went (`StrokeLedger.mergeStored`;
    /// kept canvas strokes are reused, never converted), items, papers,
    /// recognition, page list, meta and recordings. Ink drawn while the note
    /// was being read stays pending, on top. Canvases showing a page whose
    /// ink changed are updated at once (`RemoteInkView`), keeping scroll and
    /// zoom; their undo steps are dropped (an undo recorded before the merge
    /// could put back a drawing without the other device's strokes and
    /// erase them). Pages the merge left alone keep theirs. Nothing is
    /// written for the merge itself.
    func mergeRevisions(vault: Vault, clock: DeviceClock, coordinated: Bool,
                        verify: (@Sendable () throws -> Void)?) async throws -> RemoteMergeOutcome {
        for _ in 0..<4 {
            guard !isShutDown, !isPreparing, !loadFailed, writer != nil else { return .skipped }
            let waitStart = ContinuousClock.now
            while isInkInUse {
                guard ContinuousClock.now - waitStart < inkWaitLimit else { return .skipped }
                try await Task.sleep(for: .milliseconds(100))
                guard !isShutDown else { return .skipped }
            }
            await flush()
            guard saveError == nil, !isShutDown else { return .skipped }   // never merge over ink that is not on disk
            _ = await recognitionWrite?.result
            // The read must hold every write of this editor: a save that starts
            // meanwhile (autosave, a page gesture) is not in it, and its strokes
            // would look removed elsewhere. Then it is read again.
            let epoch = writeEpoch
            let loaded = try await Self.read(vault: vault, noteID: noteID, device: clock.device,
                                             coordinated: coordinated, verify: verify)
            await clock.observe(loaded.readings)
            guard !isShutDown else { return .skipped }
            if let reason = Self.newerReason(loaded) {
                // A newer version wrote to this note (or the vault) meanwhile: from now on this
                // editor writes nothing (format.md §7.3). Its own ink was saved above.
                readOnlyReason = reason
                writer = nil
            }
            guard loaded.failures == 0 else { return .unreadable }
            await writer?.raiseNextSeq(to: loaded.nextSeq)
            guard !isShutDown else { return .skipped }
            // A page or item gesture waiting to be saved, or a stroke under way: save, read again.
            guard writeEpoch == epoch, pendingPageOps.isEmpty, !isInkInUse else { continue }
            return applyMerged(loaded, device: clock.device)
        }
        return .skipped
    }

    /// What the merge compares to tell whether anything on screen changed.
    private struct Shown: Equatable {
        struct ShownPage: Equatable {
            var id: UUID
            var order: String
            var paper: Paper?
            var strokes: [UUID]
            var items: [Item]
        }

        var pages: [ShownPage]
        var meta: NoteMeta
        var recordings: [Recording]
        var deleted: Bool

        /// Bookkeeping that is not shown (stamps, origins) is left out, so the
        /// editor's own edits read back compare equal.
        init(pages: [Page], meta: NoteMeta, recordings: [Recording], deleted: Bool) {
            self.pages = pages.map { page in
                ShownPage(id: page.id, order: page.order, paper: page.paper, strokes: page.strokes.map(\.id),
                          items: page.items.map { item in
                              var item = item
                              item.origin = nil
                              item.clocks = nil
                              return item
                          })
            }
            self.meta = meta
            self.recordings = recordings.map { recording in
                var recording = recording
                recording.origin = nil
                recording.clocks = nil
                return recording
            }
            self.deleted = deleted
        }
    }

    /// Takes the merged note `loaded` (synchronously: no canvas can report a
    /// drawing in between).
    private func applyMerged(_ loaded: Loaded, device: DeviceID) -> RemoteMergeOutcome {
        let state = loaded.state
        var committedMeta = meta
        committedMeta.pageSize = committedPageSize
        let before = Shown(pages: livePages(), meta: committedMeta, recordings: recordings,
                           deleted: readOnlyReason == Self.deletedReason)
        let oldPages = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shownID = currentPage?.id
        let wasPageless = isPageless
        var inkChanged: Set<UUID> = []
        for page in state.pages {
            let old = oldPages[page.id]
            if var l = ledgers[page.id] {
                let previous = canvasDrawings[page.id]
                let merge = l.mergeStored(page.strokes, info: CanvasStrokeInfo.init(stored:))
                if merge.changesCanvas {
                    if let previous, previous.strokes.count == merge.previousCount {
                        canvasDrawings[page.id] = PKDrawing(strokes: merge.sources.map { source -> PKStroke in
                            switch source {
                            case .kept(let i): return previous.strokes[i]
                            case .converted(let s): return StrokeConversion.pkStroke(s)
                            }
                        })
                    } else {
                        // No canvas shows the page (each one hands its drawing over): it is
                        // prepared from the merged strokes when one does (`prepareDrawing`).
                        canvasDrawings[page.id] = nil
                    }
                    inkChanged.insert(page.id)
                }
                ledgers[page.id] = l
            } else if let old, old.strokes.map(\.id) != page.strokes.map(\.id) {
                inkChanged.insert(page.id)
            }
            if inkChanged.contains(page.id) || old == nil { inkRevisions[page.id, default: 0] &+= 1 }
            if old?.items != page.items { itemRevisions[page.id, default: 0] &+= 1 }   // stamps too: cheap redraw
        }
        let keep = Set(state.pages.map(\.id))
        ledgers = ledgers.filter { keep.contains($0.key) }
        canvasDrawings = canvasDrawings.filter { keep.contains($0.key) }
        for (id, task) in preparing where !keep.contains(id) { task.cancel() }
        pages = state.pages
        recordings = state.recordings.sorted(by: Recording.sortsBefore)
        // An infinite page that grew here and is not saved yet keeps its height.
        let grown = pageSize.infinite && state.meta.pageSize.infinite && pageSize != committedPageSize
            && pageSize.height > state.meta.pageSize.height ? pageSize : nil
        meta = state.meta
        committedPageSize = state.meta.pageSize
        pageSize = grown ?? state.meta.pageSize
        if state.deleted {
            readOnlyReason = readOnlyReason ?? Self.deletedReason
        } else if readOnlyReason == Self.deletedReason {
            readOnlyReason = nil
        }
        if let shownID, let i = pages.firstIndex(where: { $0.id == shownID }) {
            pageIndex = i
        } else {
            pageIndex = min(pageIndex, max(pages.count - 1, 0))
        }
        if wasPageless != isPageless { canvasGeneration &+= 1 }
        // The drawing cache's key names every revision the editor now holds.
        let base = Set(cacheKey?.revisions ?? [])
        writtenNames = Array(Set(writtenNames).union(loaded.names.filter { !base.contains($0) }))
        let fromOtherDevice = loaded.names.contains { name in
            !knownRevisionNames.contains(name) && RevisionName(name).map { $0.device != device } ?? false
        }
        knownRevisionNames.formUnion(loaded.names)
        // Canvases showing a page whose ink changed show the merged drawing now.
        for view in inkViews.compactMap(\.view) {
            if let id = view.shownPageID, inkChanged.contains(id) { view.reloadInk(from: self) }
        }
        inkViews.removeAll { $0.view == nil }
        var afterMeta = meta
        afterMeta.pageSize = committedPageSize
        let after = Shown(pages: livePages(), meta: afterMeta, recordings: recordings, deleted: state.deleted)
        scheduleRecognition()   // pages changed elsewhere may need reading again
        guard after != before else { return .unchanged }
        if fromOtherDevice {
            remoteUpdates &+= 1
            lastRemoteUpdate = .now
        }
        return .merged(fromOtherDevice: fromOtherDevice)
    }

    /// Registers a canvas that shows this note's ink (`RemoteInkView`), so a
    /// merge can update it; held weakly.
    func attachInkView(_ view: any RemoteInkView) {
        inkViews.removeAll { $0.view == nil || $0.view === view }
        inkViews.append(WeakInkView(view: view))
    }

    func detachInkView(_ view: any RemoteInkView) {
        inkViews.removeAll { $0.view == nil || $0.view === view }
    }
}

// MARK: - Handwriting recognition

extension NoteEditor {
    /// The page's strokes as of now: the ledger's once the page was shown or
    /// edited, else the stored ones (no ledger is built just to read ids).
    private func currentStrokes(of page: Page) -> [Stroke] {
        ledgers[page.id]?.live ?? page.strokes
    }

    /// Recognises the pages that need it after `recognitionDelay` without
    /// further stroke changes (and once when the note opens).
    func scheduleRecognition() {
        guard recognizer != nil, !isReadOnly, !isClosed else { return }
        recognitionTimer?.cancel()
        let delay = recognitionDelay
        recognitionTimer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.recognizePending()
        }
    }

    /// Saves pending strokes, then reads every page whose recognition is
    /// missing or stale (`RecognitionPolicy`) and writes what it read as one
    /// delta of `setPageRecognition` ops (one per page) for the whole pass.
    /// Reading runs off the main actor; a page whose strokes changed
    /// meanwhile is dropped (the change schedules another pass). The pass
    /// stops, writing nothing, once the editor closes or recognition is
    /// switched off (`recognizer` set to nil).
    func recognizePending() async {
        guard recognizer != nil, !isReadOnly else { return }
        if recognitionBusy { recognitionAgain = true; return }
        recognitionBusy = true
        defer { recognitionBusy = false }
        repeat {
            recognitionAgain = false
            await recognizeOnce()
        } while recognitionAgain && !isClosed
    }

    /// Whether a pass may go on: the editor is open and recognition still on.
    private var recognitionWanted: Bool { !isClosed && recognizer != nil }

    private func recognizeOnce() async {
        guard let recognizer, let writer, !isClosed else { return }
        await flush()
        guard saveError == nil, recognitionWanted else { return }   // never recognise strokes that are not on disk
        var read: [(pageID: UUID, digest: String, recognition: Recognition?)] = []
        var failed = false
        for page in pages {
            guard recognitionWanted else { return }
            let strokes = currentStrokes(of: page)
            let digest = RecognitionBasis.digest(of: strokes.map(\.id))
            guard RecognitionPolicy.needsRecognition(page.recognition, strokeIDs: strokes.map(\.id),
                                                     touched: touchedPages.contains(page.id)) else { continue }
            var result: Recognition?
            if !strokes.isEmpty {
                do {
                    var r = try await recognizer.recognize(strokes: strokes, language: meta.lang)
                    r.basis = digest
                    result = r
                } catch {
                    let detail = "\(error)"
                    recognitionError = String(localized: "Could not read handwriting: \(detail)")
                    failed = true
                    continue
                }
            }
            read.append((page.id, digest, result))
        }
        guard recognitionWanted else { return }
        // Only pages whose strokes are still the ones that were read.
        let current = read.filter { r in
            guard let page = pages.first(where: { $0.id == r.pageID }) else { return false }
            return RecognitionBasis.digest(of: currentStrokes(of: page).map(\.id)) == r.digest
        }
        guard !current.isEmpty else { return }
        let ops = current.map { Op.setPageRecognition(pageId: $0.pageID, recognition: $0.recognition) }
        writeEpoch &+= 1
        let write = Task { try await writer.write(ops) }
        recognitionWrite = Task { _ = try await write.value }
        do {
            // The drawing cache's key names every revision this editor wrote.
            let name = try await write.value.filename
            writtenNames.append(name)
            knownRevisionNames.insert(name)
        } catch {
            let detail = "\(error)"
            recognitionError = String(localized: "Could not save recognized text: \(detail)")
            return
        }
        for r in current {
            if let index = pages.firstIndex(where: { $0.id == r.pageID }) { pages[index].recognition = r.recognition }
            touchedPages.remove(r.pageID)
        }
        recognitionsWritten += current.count
        if !failed { recognitionError = nil }
        onRecognized?(noteID)
    }
}


// MARK: - Ink converted to math (`NoteEditor+MathInk.swift`)

/// Canvas strokes a conversion took off a page, as the ledger held them:
/// what undo puts back. Immutable; held by undo closures (like the eraser's
/// `DrawingBox`), hence `@unchecked Sendable`.
final class ConvertedInk: @unchecked Sendable {
    let page: UUID
    /// The ledger entries removed: fingerprints and stored strokes.
    let entries: [StrokeLedger.Entry]
    /// The canvas strokes they were shown as.
    let canvasStrokes: [PKStroke]

    init(page: UUID, entries: [StrokeLedger.Entry], canvasStrokes: [PKStroke]) {
        self.page = page; self.entries = entries; self.canvasStrokes = canvasStrokes
    }

    /// Every stored stroke taken.
    var strokes: [Stroke] { entries.flatMap(\.strokes) }
}

extension NoteEditor {
    /// The page's ledger and the drawing its canvases show, one canvas stroke
    /// per ledger entry (re-converted from the live strokes when they are not).
    private func alignedInk(_ pageID: UUID) -> (StrokeLedger, PKDrawing)? {
        if ledgers[pageID] == nil || canvasDrawings[pageID]?.strokes.count != ledgers[pageID]?.entries.count {
            _ = drawing(for: pageID)
        }
        guard let l = ledgers[pageID], let shown = canvasDrawings[pageID], shown.strokes.count == l.entries.count else {
            return nil
        }
        return (l, shown)
    }

    /// Takes every canvas stroke holding one of `ids` off page `pageID`, as an
    /// erase would: the ledger retires them, so their `removeStroke` ops go
    /// into the next save (with whatever else is pending: one delta), and the
    /// canvases showing the page show the rest in this main-actor turn
    /// (`RemoteInkView.reloadInk`, which also clears the canvas's own undo
    /// steps). Nil when nothing was taken.
    func takeInk(_ ids: Set<UUID>, from pageID: UUID, keepUndo: Bool = false) -> ConvertedInk? {
        guard !isReadOnly, !isShutDown, !ids.isEmpty, let (ledger, shown) = alignedInk(pageID) else { return nil }
        var l = ledger
        var keep: [StrokeLedger.Item] = []
        var kept: [PKStroke] = []
        var taken: [StrokeLedger.Entry] = []
        var takenCanvas: [PKStroke] = []
        for (i, e) in l.entries.enumerated() {
            if e.strokes.contains(where: { ids.contains($0.id) }) {
                taken.append(e)
                takenCanvas.append(shown.strokes[i])
            } else {
                let strokes = e.strokes
                keep.append(StrokeLedger.Item(info: e.info, make: { strokes }))
                kept.append(shown.strokes[i])
            }
        }
        guard !taken.isEmpty else { return nil }
        let change = l.update(keep)
        ledgers[pageID] = l
        showChangedInk(PKDrawing(strokes: kept), change: change, on: pageID, keepUndo: keepUndo)
        return ConvertedInk(page: pageID, entries: taken, canvasStrokes: takenCanvas)
    }

    /// Puts ink `takeInk` took back on its page, above the rest (undo). The
    /// ledger revives the strokes: their own ids while the removal is not
    /// saved, new ids with `parent` once it is (format.md §5.2). Returns
    /// the ids the strokes have now; nil when the page is gone or the note
    /// cannot be edited.
    @discardableResult
    func putInkBack(_ ink: ConvertedInk, keepUndo: Bool = false) -> [UUID]? {
        let pageID = ink.page
        guard !isReadOnly, !isShutDown, pages.contains(where: { $0.id == pageID }),
              let (ledger, shown) = alignedInk(pageID) else { return nil }
        var l = ledger
        var items = l.entries.map { e -> StrokeLedger.Item in
            let strokes = e.strokes
            return StrokeLedger.Item(info: e.info, make: { strokes })
        }
        for e in ink.entries {
            let strokes = e.strokes
            items.append(StrokeLedger.Item(info: e.info, make: { strokes }))
        }
        let change = l.update(items)
        ledgers[pageID] = l
        let drawing = PKDrawing(strokes: shown.strokes + ink.canvasStrokes)
        showChangedInk(drawing, change: change, on: pageID, keepUndo: keepUndo)
        return l.entries.suffix(ink.entries.count).flatMap(\.strokes).map(\.id)
    }

    /// The page's ink changed outside its canvas: the drawing its canvases
    /// show, saved like a canvas change (dirty, recognised again).
    private func showChangedInk(_ drawing: PKDrawing, change: StrokeLedger.Change, on pageID: UUID, keepUndo: Bool) {
        canvasDrawings[pageID] = drawing
        if !change.isEmpty {
            inkRevisions[pageID, default: 0] &+= 1
            dirtyPages.insert(pageID)
            touchedPages.insert(pageID)
            scheduleRecognition()
        }
        reloadKeepsUndo = keepUndo
        defer { reloadKeepsUndo = false }
        for view in inkViews.compactMap(\.view) where view.shownPageID == pageID { view.reloadInk(from: self) }
        inkViews.removeAll { $0.view == nil }
    }
}
