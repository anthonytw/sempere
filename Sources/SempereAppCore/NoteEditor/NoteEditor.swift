import Foundation
import Observation
import Sempere

/// One open note being edited: its reconstructed state, a `StrokeLedger`
/// per page, and autosave. Every drawing change updates the ledger at once;
/// after `debounce` without changes (and on `flush()`: page switch,
/// background, close) the net change is written as ONE delta.
///
/// The model half of the app's editor (docs/design/thin-app.md): `Canvas` is the canvas it shows its pages on
/// (the app's `PencilCanvas`, PencilKit), which this module never names. The app's `NoteEditor` is
/// `NoteEditorModel<PencilCanvas>`.
@MainActor
@Observable
public final class NoteEditorModel<Canvas: NoteCanvas> {
    public let noteID: UUID
    /// Pages in display order, as loaded plus pages added here.
    public internal(set) var pages: [Page]
    public internal(set) var meta: NoteMeta
    /// Live page size; an infinite page grows here and is saved with the next delta.
    public internal(set) var pageSize: PageSize
    /// Paper being previewed by the paper picker (not saved); nil when none.
    public internal(set) var previewPaper: Paper?
    /// Index into `pages` of the page on the canvas: in a paged note, the one
    /// the scroll is on (`scrolledToPage`).
    public internal(set) var pageIndex = 0
    /// Bumped when the canvas must bring `pageIndex` into view: a page chosen
    /// (`selectPage`: the strip, the toolbar, a search hit) or added, duplicated
    /// or restored. Scrolling to a page (`scrolledToPage`) does not bump it.
    public internal(set) var pageJump = 0
    /// Why the note cannot be edited, if it cannot (the app words it).
    public internal(set) var readOnly: NoteReadOnly?
    /// True while the note is shown from the drawing cache and its revisions
    /// are still being read (`open(..., cache:)`): pages have no strokes yet
    /// and nothing can be edited.
    public internal(set) var isPreparing = false
    /// True when the editor opened from the drawing cache (`open(..., cache:)`).
    public internal(set) var openedFromCache = false
    /// The background read of an editor opened from the cache failed: it
    /// shows what the cache had, read-only, and never converts or stores.
    public internal(set) var loadFailed = false
    /// Bumped when the canvas must reload the shown page's drawing although
    /// the page stayed the same: the read note differed from the cache, or a
    /// layout switch changed the strokes of a page that keeps its id. A stale
    /// drawing would be diffed against the new page (ink removed or duplicated
    /// by the next stroke).
    public internal(set) var canvasGeneration = 0
    /// The last autosave failure (the error's description); cleared by the next successful save.
    public internal(set) var saveFailure: String?
    /// Deltas written by this editor (for tests and the UI).
    public internal(set) var deltasWritten = 0
    /// Merges that brought another device's changes on screen
    /// (`mergeRevisions`): the canvas shows "Updated from another device".
    public internal(set) var remoteUpdates = 0

    /// The note was opened again because another device changed the vault's keys (the editor before it
    /// was closed): the canvas says "Updated from another device", as after a merge.
    func noteReopenedForRemoteChange() { remoteUpdates += 1 }
    /// When the last of them happened.
    public internal(set) var lastRemoteUpdate: Date?
    /// Canvases showing this note's ink (`attachInkView`).
    @ObservationIgnored var inkViews: [WeakInkView<Canvas>] = []
    /// How long a merge (`mergeRevisions`) waits for a stroke under way
    /// before it gives up; the next listing tries again. Bounded so that a
    /// canvas that never reports the end of a stroke cannot stall merges of
    /// the note for as long as it stays open.
    @ObservationIgnored public var inkWaitLimit = Duration.seconds(30)

    public var isReadOnly: Bool { readOnly != nil || isPreparing }
    public var currentPage: Page? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    /// The words of the search this note was opened from, highlighted on its
    /// pages (`NoteEditor+SearchHighlight.swift`); nil when none is shown.
    public var searchCursor: SearchMatchCursor?
    /// Bumped to ask the canvas to scroll to the current match.
    public var revealToken = 0
    /// The query and starting page to look for once the note is readable
    /// (`highlightSearch(query:page:)` while it is still opening).
    @ObservationIgnored var pendingSearch: (query: String, page: UUID?)?

    /// The pages (of a paged note's stack, each canvas has its own selection) with an item
    /// selected; the Mac menu's item commands are enabled while it is not empty.
    var pagesWithSelectedItem: Set<UUID> = []
    public var hasItemSelection: Bool { !pagesWithSelectedItem.isEmpty }

    /// A canvas reports whether `page` has a selected item (`ItemSelectionController`).
    public func itemSelection(on page: UUID, isSelected: Bool) {
        if isSelected {
            if !pagesWithSelectedItem.contains(page) { pagesWithSelectedItem.insert(page) }
        } else if pagesWithSelectedItem.contains(page) {
            pagesWithSelectedItem.remove(page)
        }
    }

    /// The app's own state for this editor (`NoteCanvas.Glue`).
    @ObservationIgnored public let glue: Canvas.Glue
    /// Where timings go (the app's signposts).
    @ObservationIgnored let perf: any PerfSink
    @ObservationIgnored var ledgers: [UUID: StrokeLedger] = [:]
    /// The drawing each page's canvas showed last, one-to-one with its
    /// ledger's entries: shown again as it is (no conversion) while the
    /// ledger exists.
    @ObservationIgnored var canvasDrawings: [UUID: Canvas.Drawing] = [:]
    /// The ink bounds of the drawing the canvas reported last, measured from
    /// the ledger (`takeMeasuredInk`).
    @ObservationIgnored var measuredInk: (page: UUID, bounds: CGRect)?
    /// The last stroke ids digested per page, and their digest (`strokeDigest`).
    @ObservationIgnored var strokeDigests: [UUID: (ids: [UUID], digest: String)] = [:]
    /// Pages whose drawing is being prepared off the main actor.
    @ObservationIgnored var preparing: [UUID: Task<PreparedInk<Canvas>?, Never>] = [:]
    /// Test seam: awaited off the main actor before a page's drawing is
    /// prepared (`prepareDrawing`), so a test can change the page meanwhile.
    @ObservationIgnored public var prepareHook: (@Sendable () async -> Void)?
    /// Pages whose strokes changed since the note was read.
    @ObservationIgnored var dirtyPages: Set<UUID> = []
    /// `pagesForHighlight`'s last answer and what it was made from (`NoteEditor+SearchHighlight`).
    @ObservationIgnored var highlightCache: (source: [Page], dirty: Set<UUID>, preparing: Bool, result: [Page])?
    /// Pages whose staleness `pagesForHighlight` worked out (test and measurement counter).
    @ObservationIgnored public var highlightPagesChecked = 0
    /// Where page drawings are cached between opens (nil: no cache).
    @ObservationIgnored var drawingCache: DrawingCache?
    /// The note version the editor was read from (`DrawingCache.Key`); nil
    /// when it cannot be cached (unreadable revisions).
    @ObservationIgnored var cacheKey: DrawingCache.Key?
    /// Revisions this editor wrote, by file name.
    @ObservationIgnored var writtenNames: [String] = []
    /// Bumped whenever this editor starts writing a revision (`mergeRevisions`
    /// re-reads when one started during its read).
    @ObservationIgnored var writeEpoch = 0
    /// Test seam: awaited before each revision a save (`writePending`) or a
    /// recognition pass writes, so a test can hold the write in flight.
    @ObservationIgnored public var beforeWrite: (@Sendable () async -> Void)?
    /// Every revision file name the editor's state already holds: those read
    /// (on open and by `mergeRevisions`) and those it wrote. A name listed in
    /// the note's folder that is not here is a revision written elsewhere
    /// (`hasUnmergedRevisions`).
    @ObservationIgnored var knownRevisionNames: Set<String> = []
    /// The revisions the last read decoded, by file name: a merge reads only
    /// the files that are new since (`read(reuse:)`). They share most of
    /// their storage (stroke points) with the note's state.
    @ObservationIgnored var decodedRevisions: [String: Revision] = [:]
    /// The note as the last applied merge reduced it, which `pages` were
    /// taken from: the next merge applies only the revisions that are new
    /// since (`ReducedNote.updated(with:)`) and compares only the pages they
    /// changed. Nil until the first merge (opening reconstructs without it).
    @ObservationIgnored var reduced: ReducedNote?
    /// What the last merge cost (tests and `Perf`).
    @ObservationIgnored var lastMergeWork = MergeWork()
    /// Test seam: false makes every merge reduce the whole note and compare every page, as before `reduced`.
    @ObservationIgnored var incrementalMerges = true
    /// The read that completes an editor opened from the cache.
    @ObservationIgnored var fullLoad: Task<Void, Never>?
    /// Words the errors this editor keeps as text (`readOnly`'s load failure, `saveFailure`, the recognition and
    /// recording failures): the model's `services.describeError`, set when it opens the editor.
    @ObservationIgnored var describeError: ErrorDescriber = plainErrorDescription
    /// Called when that read fails (`failLoading`), with the error: the
    /// model shows the failure instead of a partial, read-only canvas.
    @ObservationIgnored var onLoadFailed: (@MainActor (any Error) -> Void)?
    /// Called once a recording made in this note is saved (by the app's microphone half), with its audio file and
    /// the session folder holding it: the model transcribes it when that setting is on, then hands the folder to
    /// `AppModelServices.finishRecordingSave` (`configureRecordings`). Nil: the recorder deletes the folder itself.
    @ObservationIgnored public var onRecordingSaved: (@MainActor (Recording, URL, URL) -> Void)?
    /// Set when `finishLoading` starts: no more cache hits are handed out
    /// unchecked from then on.
    @ObservationIgnored var finishing = false
    /// `note.firstRender`: from the open until the canvas shows ink (`didShowInk`).
    @ObservationIgnored var openInterval: PerfInterval?
    @ObservationIgnored var committedPageSize: PageSize
    /// Page additions and paper changes not yet written (written before any stroke ops).
    @ObservationIgnored var pendingPageOps: [Op] = []
    @ObservationIgnored var writer: NoteWriter?
    /// This opening of the note (format.md §5.8.2): written on every delta the
    /// editor saves, so a history view starts a new session when the note is
    /// closed and opened again. A new editor is a new session.
    @ObservationIgnored var editingSession = EditingSession.newID()
    @ObservationIgnored let debounce: Duration
    @ObservationIgnored var timer: Task<Void, Never>?
    @ObservationIgnored var chain: Task<Void, Never>?
    /// Set by `close()` once its last save is done: a closed editor takes no
    /// more changes and writes nothing. A window or view may still show it for
    /// a moment, and it holds the vault as it was opened (with the old secret
    /// after a key change), so nothing it holds may reach the vault.
    @ObservationIgnored public internal(set) var isShutDown = false

    // Handwriting recognition (`PageRecognizing`).
    /// Reads pages after strokes change and on open; nil turns recognition off.
    @ObservationIgnored public var recognizer: (any PageRecognizing)? {
        didSet { if recognizer != nil { scheduleRecognition() } }
    }
    /// Called with the note id after a page's recognition was written.
    @ObservationIgnored var onRecognized: (@MainActor (UUID) -> Void)?
    /// Pages whose strokes this editor changed and whose recognition is not
    /// redone yet: it replaces recognition that cannot be checked (an import).
    @ObservationIgnored var touchedPages: Set<UUID> = []
    @ObservationIgnored var recognitionDelay: Duration
    @ObservationIgnored var recognitionTimer: Task<Void, Never>?
    @ObservationIgnored var recognitionBusy = false
    @ObservationIgnored var recognitionAgain = false
    @ObservationIgnored var recognitionWrite: Task<Void, any Error>?
    @ObservationIgnored var isClosed = false
    /// Recognitions written by this editor (for tests and the UI).
    public internal(set) var recognitionsWritten = 0
    /// The last recognition failure; cleared by the next success.
    public internal(set) var recognitionFailure: RecognitionPassFailure?

    /// Set while ink changed by an undo or redo step is shown again: the
    /// canvases keep their undo stacks (`takeInk`, `putInkBack`).
    @ObservationIgnored public internal(set) var reloadKeepsUndo = false

    // Recordings (`NoteEditor+Recordings.swift`, format.md §8.3, docs/attachments.md §9).
    /// The note's recordings in their order (format.md §5.4). Changed only by
    /// `NoteEditor+Recordings` (one delta per change).
    public var recordings: [Recording] = []
    /// "Tap Ink to Play": a tap on a stroke plays the recording from where it
    /// was written; drawing is off meanwhile (like item selection).
    public var listeningToInk = false
    /// Strokes highlighted because playback is at the moment they were written, per page.
    public var playbackHighlight: [UUID: Set<UUID>] = [:]
    /// The strokes playback highlights, indexed (`updatePlaybackHighlight`).
    @ObservationIgnored var playbackIndex: PlaybackIndex?
    /// Recordings being transcribed now.
    var transcribing: Set<UUID> = []
    /// Called to play a recording from a time (a tap on linked ink).
    @ObservationIgnored var onPlayRequest: ((Recording, Double) -> Void)?
    /// Plays the note's recordings (`AppModel.play`); nil until one is played.
    public var player: RecordingPlayer?

    /// Ink closer than this to the bottom of an infinite page grows it.
    public static var growMargin: Double { NoteEditorDefaults.growMargin }
    /// How far below the ink an infinite page grows to.
    public static var growStep: Double { NoteEditorDefaults.growStep }
    /// Default pause before an autosave.
    public static var defaultDebounce: Duration { NoteEditorDefaults.debounce }
    /// Default pause after the last stroke change before pages are recognized.
    static var defaultRecognitionDelay: Duration { NoteEditorDefaults.recognitionDelay }

    init(noteID: UUID, state: NoteState, writer: NoteWriter?, readOnly: NoteReadOnly?,
                debounce: Duration = NoteEditorDefaults.debounce, recognizer: (any PageRecognizing)? = nil,
                recognitionDelay: Duration = NoteEditorDefaults.recognitionDelay, perf: any PerfSink = NoPerfSink()) {
        self.noteID = noteID
        self.pages = state.pages
        self.recordings = state.recordings.sorted(by: Recording.sortsBefore)
        self.meta = state.meta
        self.pageSize = state.meta.pageSize
        self.committedPageSize = state.meta.pageSize
        self.writer = writer
        self.readOnly = writer == nil ? (readOnly ?? .noWriter) : readOnly
        self.debounce = debounce
        self.recognizer = recognizer
        self.recognitionDelay = recognitionDelay
        self.perf = perf
        self.glue = Canvas.makeGlue()
    }

    /// An editor showing a note from the drawing cache's `layout` while
    /// its revisions are read (`isPreparing`).
    init(noteID: UUID, layout: DrawingCache.Layout, debounce: Duration,
         recognizer: (any PageRecognizing)?, recognitionDelay: Duration, perf: any PerfSink) {
        self.noteID = noteID
        self.pages = layout.state.pages
        self.recordings = layout.state.recordings.sorted(by: Recording.sortsBefore)
        self.meta = layout.state.meta
        self.pageSize = layout.state.meta.pageSize
        self.committedPageSize = layout.state.meta.pageSize
        self.writer = nil
        self.readOnly = nil
        self.debounce = debounce
        self.isPreparing = true
        self.openedFromCache = true
        self.recognizer = recognizer
        self.recognitionDelay = recognitionDelay
        self.perf = perf
        self.glue = Canvas.makeGlue()
    }

    /// The cost of one merge, as counted (`lastMergeWork`).
    struct MergeWork: Equatable, Sendable {
        /// Revision files decrypted and decoded by the read.
        var decoded = 0
        /// Revisions reduced: only the new ones, or all of them.
        var reduced = 0
        /// Pages whose content was compared on the main actor.
        var pagesCompared = 0
        /// Strokes visited on the main actor (ledger merges, id comparisons, the shown-state comparison).
        var strokesVisited = 0
        /// Main-actor time of the apply, and of it the time the canvas took to build
        /// the changed pages' drawings (`NoteCanvas.drawing(of:)`, the same either way).
        var applyTime: Duration = .zero
        var drawingTime: Duration = .zero

        init(decoded: Int = 0, reduced: Int = 0) {
            self.decoded = decoded
            self.reduced = reduced
        }
    }

    /// Loads and reconstructs a note off the main actor. A note with
    /// unreadable revisions, or in Recently Deleted, opens read-only.
    /// `coordinated` (a vault in iCloud Drive): the note is read under
    /// `files` (the app's `NSFileCoordinator`, `CloudVault`). `verify`
    /// runs inside that read before and after the note is loaded and throws
    /// to refuse a note not downloaded yet (a partial copy, `AppModel.partialNoteVerifier`).
    ///
    /// With a `cache` and the note's `listedNames` (its revision file names
    /// as just listed), a note whose layout is cached opens at once from the
    /// cache (`isPreparing`) and is read in the background; its pages'
    /// drawings come from the cache too (`prepareDrawing`) and are checked
    /// against what is read before anything can be drawn.
    public static func open(vault: Vault, noteID: UUID, clock: DeviceClock,
                            debounce: Duration = NoteEditorDefaults.debounce,
                            recognizer: (any PageRecognizing)? = nil,
                            recognitionDelay: Duration = NoteEditorDefaults.recognitionDelay,
                            coordinated: Bool = false, files: any FileCoordinating = UncoordinatedFiles(),
                            verify: (@Sendable () throws -> Void)? = nil,
                            cache: DrawingCache? = nil, listedNames: [String]? = nil,
                            beforeFinishing: (@Sendable () async -> Void)? = nil,
                            redownload: (@MainActor @Sendable () async throws -> Void)? = nil,
                            describeError: @escaping ErrorDescriber = plainErrorDescription,
                            perf: any PerfSink = NoPerfSink()) async throws -> NoteEditorModel {
        if let cache, let listedNames, !listedNames.isEmpty {
            let key = DrawingCache.Key(note: noteID, revisions: listedNames)
            let layout = await Task.detached(priority: .userInitiated) {
                perf.measure("note.cache", "layout \(noteID.perfShort)") { cache.layout(key) }
            }.value
            if let layout {
                let editor = NoteEditorModel(noteID: noteID, layout: layout, debounce: debounce, recognizer: recognizer,
                                        recognitionDelay: recognitionDelay, perf: perf)
                editor.describeError = describeError
                editor.drawingCache = cache
                editor.cacheKey = key
                editor.fullLoad = Task { [weak editor] in
                    do {
                        let loaded: NoteLoad
                        do {
                            loaded = try await read(vault: vault, noteID: noteID, device: clock.device,
                                                    coordinated: coordinated, files: files, verify: verify, perf: perf)
                        } catch let error as any NoteNotDownloaded where redownload != nil && error.isNotDownloaded {
                            // A partial copy's note still incomplete (`partialNoteVerifier`): fetched once more.
                            // Not for an editor closed meanwhile (the model may have another vault open).
                            try Task.checkCancellation()
                            try await redownload?()
                            loaded = try await read(vault: vault, noteID: noteID, device: clock.device,
                                                    coordinated: coordinated, files: files, verify: verify, perf: perf)
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
                                    files: files, verify: verify, perf: perf)
        await clock.observe(loaded.readings)
        let reason = readOnly(loaded)
        let session = EditingSession.newID()
        let writer = reason == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: loaded.nextSeq,
                                                session: session) : nil
        let editor = NoteEditorModel(noteID: noteID, state: loaded.state, writer: writer, readOnly: reason,
                                debounce: debounce, recognizer: recognizer, recognitionDelay: recognitionDelay, perf: perf)
        editor.describeError = describeError
        editor.editingSession = session
        editor.knownRevisionNames = Set(loaded.names)
        editor.decodedRevisions = loaded.decoded
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

    /// Reads and reconstructs the note. Revisions in `reuse` (an earlier
    /// read's `decoded`) are not read again: revision files are write-once,
    /// so a merge reads only the files that are new since (`Vault.loadNote(_:reusing:)`).
    /// With `merging` (a merge's read) the note is reduced as a `ReducedNote`:
    /// from the one given, only the revisions new since are applied when that
    /// is exact (`ReducedNote.updated(with:)`); from nil, all of them.
    static func read(vault: Vault, noteID: UUID, device: DeviceID, coordinated: Bool, files: any FileCoordinating,
                     verify: (@Sendable () throws -> Void)?,
                     reuse: [String: Revision] = [:],
                     merging base: ReducedNote?? = nil, perf: any PerfSink) async throws -> NoteLoad {
        try await Task.detached(priority: .userInitiated) {
            let loaded = try perf.measure("note.read", "\(noteID.perfShort) reused=\(reuse.count)") {
                try files.coordinatedRead(coordinated ? vault.url : nil) {
                    try verify?()
                    let loaded = try vault.loadNote(noteID, reusing: reuse)
                    try verify?()
                    return loaded
                }
            }
            let state: NoteState
            var update: ReducedNote.Update?
            if case .some(let base) = base {
                let u = try perf.measure("note.reconstruct", "\(noteID.perfShort) merge") {
                    try ReducedNote.update(base, with: loaded.revisions)
                }
                perf.event("note.reconstruct", "\(noteID.perfShort) reduced=\(u.reduced) of \(loaded.revisions.count)"
                           + (u.changedPages.map { " pages=\($0.count)" } ?? " full"))
                state = u.note.state
                update = u
            } else {
                state = try perf.measure("note.reconstruct", "\(noteID.perfShort) revisions=\(loaded.revisions.count)") {
                    try NoteReducer.reconstruct(loaded.revisions)
                }
            }
            let names = (loaded.revisions.map(\.name.filename) + loaded.failures.keys.map(\.filename)).sorted()
            return NoteLoad(state: state, failures: loaded.failures.count,
                          nextSeq: Vault.nextSeq(from: loaded.revisions, device: device),
                          readings: loaded.revisions.map(\.hlc), names: names, newer: loaded.newer,
                          vaultReadOnly: vault.readOnlyReasons, vaultRecovery: vault.isRecoveryOpen,
                          vaultListProblem: vault.isRecoveryOpen ? nil : vault.listStatus.problem,
                          decoded: Dictionary(loaded.revisions.map { ($0.name.filename, $0) }) { a, _ in a },
                          reduced: update?.note, changedPages: update?.changedPages,
                          decodedCount: loaded.revisions.reduce(0) { $0 + (reuse[$1.name.filename] == nil ? 1 : 0) },
                          reducedCount: update?.reduced ?? loaded.revisions.count)
        }.value
    }

    /// Why the note is read-only because of content a newer version wrote, in
    /// the note or anywhere in the vault (format.md §7.3); nil when none was seen.
    static func newerReason(_ loaded: NoteLoad) -> NoteReadOnly? {
        if let newer = loaded.newer {
            return .newerVersion(summary: newer.summary)
        } else if !loaded.vaultReadOnly.isEmpty {
            return .vault(loaded.vaultReadOnly)
        } else if loaded.vaultRecovery {
            return .recoveryKey
        } else if let problem = loaded.vaultListProblem {
            // Not opened writable only to fail every save with an alert (demovault-mac, build 11).
            return .deviceList(problem)
        }
        return nil
    }

    static func readOnly(_ loaded: NoteLoad) -> NoteReadOnly? {
        // A newer version's content first: it is why other revisions may be unreadable (format.md §7.4).
        if let reason = newerReason(loaded) {
            return reason
        } else if loaded.failures > 0 {
            return .unreadableRevisions(loaded.failures)
        } else if loaded.state.deleted {
            return .deleted
        }
        return nil
    }

    /// The background read of an editor opened from the cache finished:
    /// the real pages replace the layout's, every cached drawing shown so far
    /// is checked against them (kept, with its ledger, when it matches;
    /// reloaded from the strokes when not), and the note becomes editable.
    func finishLoading(_ loaded: NoteLoad, vault: Vault, clock: DeviceClock, coordinated: Bool) async {
        guard isPreparing else { return }
        finishing = true
        let sameVersion = loaded.failures == 0 && cacheKey?.revisions == loaded.names
        let shownPages = canvasDrawings.mapValues { SendableBox($0) }
        let pagesByID = Dictionary(loaded.state.pages.map { ($0.id, $0.strokes) }, uniquingKeysWith: { a, _ in a })
        // Checking and fingerprinting 15 000 strokes is a few milliseconds: off the main actor anyway.
        let checked: [UUID: PreparedInk<Canvas>] = sameVersion ? await Task.detached(priority: .userInitiated) {
            var ok: [UUID: PreparedInk<Canvas>] = [:]
            for (id, box) in shownPages {
                guard let strokes = pagesByID[id], Canvas.matches(box.value, strokes) else { continue }
                ok[id] = PreparedInk(drawing: box.value)
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
        readOnly = Self.readOnly(loaded)
        writer = readOnly == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: loaded.nextSeq,
                                                    session: editingSession) : nil
        cacheKey = loaded.failures == 0 ? DrawingCache.Key(note: noteID, revisions: loaded.names) : nil
        knownRevisionNames = Set(loaded.names)
        decodedRevisions = loaded.decoded
        reduced = nil
        canvasDrawings = [:]
        ledgers = [:]
        for page in pages {
            guard let ready = checked[page.id], let ledger = StrokeLedger(stored: page.strokes, infos: ready.infos) else { continue }
            ledgers[page.id] = ledger
            canvasDrawings[page.id] = ready.drawing
        }
        if Set(shownPages.keys).union(shownNow.keys).contains(where: { canvasDrawings[$0] == nil }) {
            // A cached drawing a canvas shows (the current page's, or another one in the
            // paged stack) was not kept: every canvas shows the real one.
            perf.event("note.cache", "mismatch \(noteID.perfShort)")
            canvasGeneration &+= 1
        }
        isPreparing = false
        applyPendingSearch()
        scheduleRecognition()   // pages that were never read, or changed elsewhere
    }

    /// The background read of an editor opened from the cache failed: the
    /// cached ink stays on screen, read-only, with the reason.
    func failLoading(_ error: any Error) {
        guard isPreparing else { return }
        readOnly = .loadFailed(describeError(error))
        loadFailed = true
        isPreparing = false
        onLoadFailed?(error)
    }

    /// Stops the background read of an editor opened from the cache that
    /// will not be shown (nothing is written; `close` also does this).
    func cancelLoading() {
        fullLoad?.cancel()
    }

    /// Waits until a note opened from the cache has been read (at once otherwise).
    public func loaded() async {
        await fullLoad?.value
    }

    // MARK: - Pages

    /// A ledger for the page's stored strokes (not kept), for its first change.
    func newLedger(_ pageID: UUID) -> StrokeLedger {
        StrokeLedger(stored: pages.first { $0.id == pageID }?.strokes ?? [], info: { Canvas.info(of: Canvas.canvasStroke($0)) })
    }

    /// The drawing to show for a page: its live strokes, one canvas stroke
    /// each. Re-keys the page's ledger to match. Converts on the calling
    /// (main) actor; the canvas uses `readyDrawing` / `prepareDrawing`.
    public func drawing(for pageID: UUID) -> Canvas.Drawing {
        // No ledger before the strokes are read (or when they could not be).
        if isPreparing || loadFailed { return canvasDrawings[pageID] ?? Canvas.emptyDrawing }
        // Converted once; the ledger is fingerprinted from exactly the strokes shown.
        let prepared = PreparedInk<Canvas>(drawing: Canvas.convert(liveStrokes(of: pageID), visible: nil, visibleFirst: nil))
        if ledgers[pageID]?.rebase(infos: prepared.infos) == nil {
            ledgers[pageID] = StrokeLedger(stored: liveStrokes(of: pageID), infos: prepared.infos)
        }
        canvasDrawings[pageID] = prepared.drawing
        return prepared.drawing
    }

    /// The drawing the page's canvas can show right away, without converting
    /// anything: what it showed last (or what the cache gave while the note
    /// is being read). Nil when it must be prepared (`prepareDrawing`).
    public func readyDrawing(for pageID: UUID) -> Canvas.Drawing? {
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
    public func prepareDrawing(for pageID: UUID, visible: CGRect? = nil,
                               partial: (@MainActor @Sendable (Canvas.Drawing) -> Void)? = nil) async -> Canvas.Drawing? {
        if let ready = readyDrawing(for: pageID) { return ready }
        if let task = preparing[pageID] {
            // Joins a conversion under way (a canvas loading the page again). Its first
            // caller checks the result against the page and keeps it only when it still
            // matches (a merge may have changed the page meanwhile): only then is it ready.
            _ = await task.value
            return readyDrawing(for: pageID)
        }
        if isPreparing {
            // Opened from the cache and still being read: this page from the cache if it is there.
            if let cache = drawingCache, let key = cacheKey {
                let noteID = self.noteID, perf = self.perf
                let cached = await Task.detached(priority: .userInitiated) { () -> SendableBox<Canvas.Drawing>? in
                    let interval = perf.begin("note.cache")
                    let data = cache.drawing(key, page: pageID)
                    let drawing = data.flatMap { Canvas.decode($0) }
                    perf.end(interval, "\(drawing == nil ? "miss" : "hit") page \(noteID.perfShort) bytes=\(data?.count ?? 0)")
                    // Fingerprinted once the strokes are read (`finishLoading`), not now.
                    return drawing.map { SendableBox($0) }
                }.value
                if isPreparing, !finishing, let cached {
                    canvasDrawings[pageID] = cached.value
                    return cached.value
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
        let noteID = self.noteID, perf = self.perf
        let hook = prepareHook
        let task = Task.detached(priority: .userInitiated) { () -> PreparedInk<Canvas>? in
            await hook?()
            if let cache, let key {
                let interval = perf.begin("note.cache")
                let hit = cache.drawing(key, page: pageID).flatMap { data -> PreparedInk<Canvas>? in
                    guard let drawing = Canvas.decode(data), Canvas.matches(drawing, strokes) else { return nil }
                    return PreparedInk(drawing: drawing)
                }
                perf.end(interval, "\(hit == nil ? "miss" : "hit") page \(noteID.perfShort) strokes=\(strokes.count)")
                if let hit { return hit }
            }
            let prepared = perf.measure("note.convert", "\(noteID.perfShort) strokes=\(strokes.count)") {
                PreparedInk<Canvas>(drawing: Canvas.convert(strokes, visible: visible, visibleFirst: partial.map { show in
                    { drawing in
                        let box = SendableBox(drawing)
                        Task { @MainActor in show(box.value) }
                    }
                }))
            }
            if let cache, let key {
                // Stored after the page is shown, not before.
                let box = SendableBox(prepared.drawing)
                Task.detached(priority: .utility) {
                    perf.measure("cache.write", "page \(noteID.perfShort)") {
                        cache.store(drawing: Canvas.encode(box.value), for: key, page: pageID)
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
    public func didShowInk(partial: Bool) {
        guard let interval = openInterval else { return }
        openInterval = nil
        perf.end(interval, "\(noteID.perfShort) \(partial ? "visible strokes" : "page") cached=\(isPreparing)")
    }

    /// Live strokes of a page (saved or not). Empty while the note is being
    /// read (`isPreparing`).
    /// No ledger is made for it: a page without one has its stored strokes
    /// live, which is all a new ledger would hold.
    public func liveStrokes(of pageID: UUID) -> [Stroke] {
        guard !isPreparing, !loadFailed else { return [] }
        return ledgers[pageID]?.live ?? pages.first { $0.id == pageID }?.strokes ?? []
    }

    /// Ink changes per page, so page thumbnails can follow them.
    public internal(set) var inkRevisions: [UUID: Int] = [:]
    /// Identifies this editor in cache keys (`inkRevisions` restart at 0 in
    /// every editor, so they alone cannot key a cache that outlives it).
    @ObservationIgnored public let sessionID = UUID()

    /// The strokes a page thumbnail shows: live once the page has been on
    /// the canvas, else as loaded (no ledger is made just for a thumbnail).
    public func thumbnailStrokes(of page: Page) -> [Stroke] {
        ledgers[page.id]?.live ?? page.strokes
    }

    /// The drawing the page's canvas shows, as it is (no conversion), when there is one: what a page thumbnail
    /// draws, else `thumbnailStrokes`.
    public func shownDrawing(of pageID: UUID) -> Canvas.Drawing? {
        guard !isPreparing, !loadFailed, ledgers[pageID] != nil else { return nil }
        return canvasDrawings[pageID]
    }

    /// Shows the page `id` (a search hit); no-op when the note has no such page.
    public func showPage(id: UUID) {
        if let i = pages.firstIndex(where: { $0.id == id }) { selectPage(i) }
    }

    /// Shows another page; pending changes are saved first. In a paged
    /// note the canvas scrolls to it, also when it is already the current
    /// page but scrolled partly out of view.
    public func selectPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        pageJump &+= 1
        guard index != pageIndex else { return }
        pageIndex = index
        Task { await flush() }
    }

    /// Makes page `id` the current one for a search match without a page jump: the paged stack
    /// scrolls to the match itself (`PageStackHost.performReveal`), and a jump to the top of the page
    /// that reached the stack after the reveal scrolled the match back off screen (SwiftUI may hand
    /// the stack the new `revealToken` and the new `pageJump` in two updates). Saves like `selectPage`.
    func showPageOfMatch(id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }), index != pageIndex else { return }
        pageIndex = index
        Task { await flush() }
    }

    /// The paged canvas scrolled so that page `index` is the current one
    /// (`PageStackLayout.currentPage`). Nothing is saved for it: every page
    /// on screen is live, and autosave writes after its pause as usual.
    public func scrolledToPage(_ index: Int) {
        guard pages.indices.contains(index), index != pageIndex else { return }
        pageIndex = index
    }

    /// The paper to draw under `page`: the picker's preview while one is
    /// open, else the page's own paper, else the note's.
    public func displayedPaper(of page: Page) -> Paper {
        previewPaper ?? page.paper ?? meta.paper
    }

    /// Shows `paper` under the canvas without saving it; nil ends the preview.
    public func showPaperPreview(_ paper: Paper?) {
        previewPaper = paper?.validated()
    }

    /// Sets the paper of the current page, or of the whole note (every page),
    /// at once on screen; saved with the next delta (`NoteOps.setPaper`).
    public func setPaper(_ paper: Paper, allPages: Bool) {
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
    public func addPage() {
        insertPage(at: pages.count)
    }

    /// Adds a blank page right after the one on the canvas and shows it.
    public func addPageAfterCurrent() {
        insertPage(at: pages.isEmpty ? 0 : pageIndex + 1)
    }

    /// Adds a blank page at `index` of `pages` and shows it; saved with the
    /// next delta (with the first ink drawn on it, if that comes first).
    public func insertPage(at index: Int) {
        guard !isReadOnly, !isShutDown else { return }
        let edit = NoteOps.addPage(at: index, in: pages)
        guard case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        scheduleSave()
    }

    // MARK: - Page gestures (format.md §5.4.3): each is saved at once, one delta

    /// Whether the note is one infinite page rather than fixed-size pages.
    public var isPageless: Bool { pageSize.infinite }

    /// A page deleted here, kept for undo with its live strokes and position.
    public struct DeletedPage: Equatable {
        var page: Page
        var index: Int
    }

    /// Pages deleted while the note is open, newest last (`undoDeletePage`).
    public internal(set) var deletedPages: [DeletedPage] = []

    /// Moves the page at `from` so it ends up at `to` (indices into `pages`).
    public func movePage(from: Int, to: Int) {
        guard !isReadOnly, !isShutDown, pages.indices.contains(from),
              let edit = NoteOps.movePage(pages[from].id, to: to, in: pages) else { return }
        apply(edit, show: currentPage?.id)
        saveNow()
    }

    /// Whether a page can be deleted: a note keeps at least one page.
    public var canDeletePage: Bool { !isReadOnly && !isShutDown && pages.count > 1 }
    /// A text box on one of this note's canvases is being typed in (`TextBoxEditorController`).
    /// Menu commands whose shortcuts are text-editing keys on a Mac (⌘⌫ Move to Recently
    /// Deleted, ⌥⌘⌫ Delete Page) are off meanwhile (`EditorCommands.fill`).
    public var typingInTextBox = false

    /// Deletes a page (`removePage`; its strokes go with it). Undo with
    /// `undoDeletePage`. The last page is never deleted.
    public func deletePage(_ id: UUID) {
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
    public func undoDeletePage() {
        guard !isReadOnly, !isShutDown, let last = deletedPages.popLast() else { return }
        let edit = NoteOps.restorePage(last.page, at: last.index, in: pages)
        guard case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        saveNow()
    }

    /// Duplicates a page (its ink and paper) right after it and shows the copy.
    public func duplicatePage(_ id: UUID) {
        guard !isReadOnly, !isShutDown, let edit = NoteOps.duplicatePage(id, in: livePages()),
              case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        saveNow()
    }

    /// Switches the note between paged and pageless (format.md §5.4.3): ink
    /// not yet saved is saved first, then the switch is one delta. No ink is
    /// deleted or moved on its sheet; the canvas shows the page that holds
    /// what was on screen (the first after a join).
    public func setLayout(pageless: Bool) async {
        guard !isReadOnly, !isShutDown, pageless != isPageless else { return }
        // Ink drawn while a save is being written is pending again afterwards:
        // save until nothing is, so the switch never takes unsaved ink as saved
        // (a few rounds at most: if ink keeps arriving, the switch is not made).
        var rounds = 0
        repeat {
            await flush()
            guard saveFailure == nil else { return }   // never switch over ink that could not be saved
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
    public var hasPendingChanges: Bool {
        !pendingPageOps.isEmpty || pageSize != committedPageSize
            || pages.contains { page in ledgers[page.id]?.hasPending ?? false }
    }

    /// `pages` with each page's live strokes (saved or not).
    func livePages() -> [Page] {
        pages.map { page in
            var p = page
            if let l = ledgers[page.id] { p.strokes = l.live }
            return p
        }
    }

    /// Takes `edit`'s pages, drops ledgers of pages that are gone and queues
    /// its ops; shows `show` (else the same page, else the nearest).
    func apply(_ edit: PageEdit, show: UUID?) {
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
    public internal(set) var itemRevisions: [UUID: Int] = [:]

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
    public func applyItemEdit(_ edit: ItemEdit) -> Bool {
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
    func saveNow() {
        Task { await flush() }
    }

    // MARK: - Changes from the canvas

    /// The canvas's drawing for `pageID` changed (stroke drawn, erased,
    /// moved, undone, redone). Updates ids now; saves after the pause.
    @discardableResult
    public func drawingDidChange(pageID: UUID, items: [StrokeLedger.Item], inkMaxY: Double?) -> StrokeLedger.Change {
        drawingDidChange(pageID: pageID, inkMaxY: { _ in inkMaxY }) { $0.update(items) }
    }

    /// The canvas's drawing changed: `update` brings the page's ledger (made
    /// when missing) up to it, in place; `inkMaxY` then reads the bottom of
    /// the ink from it.
    func drawingDidChange(pageID: UUID, inkMaxY: (StrokeLedger) -> Double?,
                                  update: (inout StrokeLedger) -> StrokeLedger.Change) -> StrokeLedger.Change {
        guard !isReadOnly, !isShutDown else { return .init() }
        // In place: a copy taken out of the dictionary would copy every entry on write.
        let change = update(&ledgers[pageID, default: newLedger(pageID)])
        if !change.isEmpty {
            inkRevisions[pageID, default: 0] &+= 1
            dirtyPages.insert(pageID)
        }
        if let ledger = ledgers[pageID], let inkMaxY = inkMaxY(ledger) { growPage(toFit: inkMaxY) }
        if !change.isEmpty || pageSize != committedPageSize { scheduleSave() }
        if !change.isEmpty {
            touchedPages.insert(pageID)
            scheduleRecognition()
        }
        return change
    }

    /// The canvas's whole drawing for `pageID` changed, made with `tool`.
    @discardableResult
    public func drawingDidChange(pageID: UUID, drawing: Canvas.Drawing, tool: Canvas.Tool?) -> StrokeLedger.Change {
        measuredInk = nil
        guard !isReadOnly else { return .init() }
        let stamp = recordingStamp
        // The ink's extent from the ledger's fingerprints, not `drawing.bounds`,
        // which measures every stroke again (finding P17).
        var measured: CGRect?
        let change = drawingDidChange(pageID: pageID, inkMaxY: { ledger in
            let b = ledger.inkBounds
            measured = b.map { CGRect(x: $0.minX, y: $0.minY, width: $0.maxX - $0.minX, height: $0.maxY - $0.minY) } ?? .null
            return b?.maxY
        }) {
            Canvas.update(&$0, to: drawing, tool: tool, stamp: stamp)
        }
        if let measured { measuredInk = (pageID, measured) }
        canvasDrawings[pageID] = drawing   // the ledger's entries now fingerprint exactly these strokes
        return change
    }

    /// The bounds of the ink of the drawing just passed to
    /// `drawingDidChange(pageID:drawing:tool:)` for `pageID`, as its ledger
    /// measured them (`CGRect.null` for no ink), once; nil when the ledger
    /// did not take that drawing (read-only, closed) or it was taken already.
    /// Spares the canvas measuring its drawing again (`PKDrawing.bounds` walks every stroke).
    public func takeMeasuredInk(of pageID: UUID) -> CGRect? {
        defer { measuredInk = nil }
        return measuredInk?.page == pageID ? measuredInk?.bounds : nil
    }

    /// Grows an infinite page so ink stays at least `growMargin` above its
    /// bottom. Finite pages never change size; pages never shrink.
    func growPage(toFit inkMaxY: Double) {
        guard pageSize.infinite, inkMaxY.isFinite, inkMaxY > pageSize.height - Self.growMargin else { return }
        pageSize.height = (inkMaxY + Self.growStep).rounded(.up)
    }

    // MARK: - Saving

    func scheduleSave() {
        timer?.cancel()
        let debounce = self.debounce
        timer = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.flush()
        }
    }

    /// Writes everything pending as one delta now (no-op when nothing is).
    /// Saves are serialized; a failure is kept in `saveFailure` and the
    /// changes stay pending for the next save.
    public func flush() async {
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
    public func close() async {
        // Playback ends with the note (its decrypted audio is released, `RecordingPlayer.onUnload`).
        player?.stop()
        // A recording in progress is saved into the note before the last save.
        await Canvas.editorWillClose(self)
        isClosed = true
        fullLoad?.cancel()
        recognitionTimer?.cancel()
        // A recognition write already started finishes; none starts after this.
        _ = await recognitionWrite?.result
        await flush()
        isShutDown = true
        decodedRevisions = [:]
        reduced = nil
        storeForNextOpen()
    }

    /// Stores this version of the note (as read, plus the deltas this editor
    /// wrote) in the drawing cache: its layout, the drawings of pages shown
    /// unchanged as they are, and those of changed pages converted from
    /// their live strokes, in the background. Nothing when the note could
    /// not be cached, a save failed or something is still unsaved; the
    /// version it replaces is dropped from the cache.
    func storeForNextOpen() {
        guard let cache = drawingCache, let base = cacheKey, !isPreparing, readOnly == nil, saveFailure == nil,
              pendingPageOps.isEmpty, pageSize == committedPageSize,
              !pages.contains(where: { page in ledgers[page.id]?.hasPending ?? false })
        else { return }
        let key = DrawingCache.Key(note: noteID, revisions: base.revisions + writtenNames)
        guard key != base else { return }   // nothing written: the cache already has this version
        var state = NoteState(deleted: false, meta: meta, pages: pages)
        state.meta.pageSize = pageSize
        var clean: [UUID: SendableBox<Canvas.Drawing>] = [:]
        var changed: [UUID: [Stroke]] = [:]
        for i in state.pages.indices {
            let id = state.pages[i].id
            if let l = ledgers[id] { state.pages[i].strokes = l.live }
            if dirtyPages.contains(id) {
                changed[id] = state.pages[i].strokes
            } else if let drawing = canvasDrawings[id], ledgers[id] != nil {
                clean[id] = SendableBox(drawing)
            }
        }
        let layout = DrawingCache.Layout(state)
        let old = base, pageIDs = state.pages.map(\.id), noteID = self.noteID, perf = self.perf
        Task.detached(priority: .utility) {
            perf.measure("cache.write", "close \(noteID.perfShort) changed=\(changed.count) clean=\(clean.count)") {
                cache.store(layout, for: key)
                for (id, box) in clean { cache.store(drawing: Canvas.encode(box.value), for: key, page: id) }
                for (id, strokes) in changed {
                    cache.store(drawing: Canvas.encode(Canvas.convert(strokes, visible: nil, visibleFirst: nil)), for: key, page: id)
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

    func writePending() async {
        guard let writer, !isShutDown else { return }
        let pageOps = pendingPageOps
        var ops = pageOps
        // Ledgers commit before the write (see `StrokeLedger.beginSave`) and
        // roll back if it fails.
        var saves: [(UUID, StrokeLedger.Save)] = []
        for page in pages {
            guard let save = ledgers[page.id]?.beginSave(page: page.id) else { continue }
            ops += save.ops
            saves.append((page.id, save))
        }
        let size = pageSize
        if size != committedPageSize { ops.append(.setMeta(.pageSize(size))) }
        guard !ops.isEmpty else { return }
        writeEpoch &+= 1
        await beforeWrite?()
        do {
            let name = try await writer.write(ops)
            writtenNames.append(name.filename)
            knownRevisionNames.insert(name.filename)
        } catch {
            for (id, save) in saves { ledgers[id]?.saveFailed(save) }
            saveFailure = describeError(error)
            return
        }
        pendingPageOps.removeFirst(pageOps.count)
        committedPageSize = size
        deltasWritten += 1
        saveFailure = nil
    }
}

/// What reading a note yields, off the main actor (`NoteEditorModel.read`).
struct NoteLoad: Sendable {
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
    /// The vault was opened with its recovery key: read-only.
    var vaultRecovery = false
    /// The vault's device list does not check on this device (design §4.3): the library refuses every write.
    var vaultListProblem: ListProblem?
    /// The revisions read, by file name, for the next read to reuse.
    var decoded: [String: Revision]
    /// A merge's read: the note reduced (`ReducedNote`), and the pages that
    /// may differ from the `ReducedNote` it was updated from (nil: any).
    var reduced: ReducedNote?
    var changedPages: Set<UUID>?
    /// Revision files this read decrypted and decoded (not reused), and
    /// revisions it reduced.
    var decodedCount = 0
    var reducedCount = 0
}

/// The editor's defaults (`NoteEditor.defaultDebounce` and the others; a generic type has no stored statics).
public enum NoteEditorDefaults {
    /// Ink closer than this to the bottom of an infinite page grows it.
    static let growMargin = 200.0
    /// How far below the ink an infinite page grows to.
    static let growStep = 400.0
    /// Pause before an autosave.
    public static let debounce = Duration.milliseconds(1500)
    /// Pause after the last stroke change before pages are recognized.
    public static let recognitionDelay = Duration.seconds(4)
}
