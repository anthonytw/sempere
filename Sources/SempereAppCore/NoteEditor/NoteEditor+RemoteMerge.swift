import Foundation
import Sempere

// MARK: - Revisions written elsewhere

extension NoteEditorModel {
    /// What `mergeRevisions` did.
    public enum RemoteMergeOutcome: Equatable, Sendable {
        /// The note as read equals what the editor shows (its own revisions, or
        /// changes that cancel out): nothing changed on screen.
        case unchanged
        /// The editor shows the merged note now; `fromOtherDevice` when a
        /// revision of another device was among those taken.
        case merged(fromOtherDevice: Bool)
        /// Nothing was applied: the editor is closed, still being read, or
        /// could not save what it has (`saveFailure`). The names stay unknown,
        /// so the next listing tries again.
        case skipped
        /// Nothing was applied: a revision of the note could not be read (it
        /// opens read-only when reopened). Tried again once the names change.
        case unreadable
    }

    /// Whether `names` (the note folder's revision files, as just listed) hold
    /// a revision the editor has not read or written.
    public func hasUnmergedRevisions(_ names: [String]) -> Bool {
        !isPreparing && !loadFailed && !isShutDown && names.contains { !knownRevisionNames.contains($0) }
    }

    /// Whether the editor can take revisions written elsewhere in place
    /// (`mergeRevisions`): it can save. A read-only editor (Recently Deleted,
    /// unreadable revisions) is reopened instead, it has nothing unsaved.
    var mergesInPlace: Bool { writer != nil && !loadFailed }

    /// True while a canvas showing this note is in the middle of a stroke or
    /// an object-eraser gesture: its drawing must not be replaced then.
    public var isInkInUse: Bool { inkViews.contains { $0.view?.isUsingInk == true } }

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
    public func mergeRevisions(vault: Vault, clock: DeviceClock, coordinated: Bool,
                               files: any FileCoordinating = UncoordinatedFiles(),
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
            guard saveFailure == nil, !isShutDown else { return .skipped }   // never merge over ink that is not on disk
            // The read must hold every write of this editor: a save that starts
            // meanwhile (autosave, a page gesture), also while a recognition write
            // is awaited here, is not in it, and its strokes would look removed
            // elsewhere. Then it is read again.
            let epoch = writeEpoch
            _ = await recognitionWrite?.result
            // `reduced` changes only when a merge is applied, and one merge runs per note at a time.
            let loaded = try await Self.read(vault: vault, noteID: noteID, device: clock.device,
                                             coordinated: coordinated, files: files, verify: verify, reuse: decodedRevisions,
                                             merging: .some(incrementalMerges ? reduced : nil), perf: perf)
            decodedRevisions = loaded.decoded
            await clock.observe(loaded.readings)
            guard !isShutDown else { return .skipped }
            if let reason = Self.newerReason(loaded) {
                // A newer version wrote to this note (or the vault) meanwhile: from now on this
                // editor writes nothing (format.md §7.3). Its own ink was saved above.
                readOnly = reason
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
    struct Shown: Equatable {
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
        /// editor's own edits read back compare equal. Pages not in `only`
        /// (nil: every page) are compared by id, order and paper alone: the
        /// merge leaves their ink and items as they are. `strokes` gives a
        /// page's live strokes; `visited` counts them.
        init(pages: [Page], strokes: (Page) -> [Stroke], only: Set<UUID>?, meta: NoteMeta, recordings: [Recording],
             deleted: Bool, visited: inout Int) {
            var count = 0
            self.pages = pages.map { page in
                guard only?.contains(page.id) ?? true else {
                    return ShownPage(id: page.id, order: page.order, paper: page.paper, strokes: [], items: [])
                }
                let ids = strokes(page).map(\.id)
                count += ids.count
                return ShownPage(id: page.id, order: page.order, paper: page.paper, strokes: ids,
                                 items: page.items.map { item in
                                     var item = item
                                     item.origin = nil
                                     item.clocks = nil
                                     return item
                                 })
            }
            visited += count
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
    func applyMerged(_ loaded: NoteLoad, device: DeviceID) -> RemoteMergeOutcome {
        let start = ContinuousClock.now
        let interval = perf.begin("note.remoteMerge.apply")
        var work = MergeWork(decoded: loaded.decodedCount, reduced: loaded.reducedCount)
        defer {
            work.applyTime = ContinuousClock.now - start
            lastMergeWork = work
            perf.end(interval, "\(noteID.perfShort) pages=\(work.pagesCompared) strokes=\(work.strokesVisited)")
        }
        let state = loaded.state
        // Only pages the new revisions changed are compared, when the read could tell
        // (`ReducedNote`) and the editor shows the note that read started from: the
        // same pages, taken from `reduced` (the editor's own edits are revisions too,
        // so a page it changed is among them).
        let only = loaded.changedPages.flatMap { changed in
            reduced != nil && pages.map(\.id) == state.pages.map(\.id) ? changed : nil
        }
        reduced = loaded.reduced
        var committedMeta = meta
        committedMeta.pageSize = committedPageSize
        let before = Shown(pages: pages, strokes: currentStrokes(of:), only: only, meta: committedMeta,
                           recordings: recordings, deleted: readOnly == .deleted,
                           visited: &work.strokesVisited)
        let oldPages = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shownID = currentPage?.id
        let wasPageless = isPageless
        var inkChanged: Set<UUID> = []
        for page in state.pages {
            let old = oldPages[page.id]
            // A page no new revision changed is the one shown: its ledger and canvas stay as they are.
            if let only, old != nil, !only.contains(page.id) { continue }
            work.pagesCompared += 1
            work.strokesVisited += page.strokes.count
            if var l = ledgers[page.id] {
                let previous = canvasDrawings[page.id]
                // Strokes converted to fingerprint them are the ones shown (converted once).
                var converted: [UUID: Canvas.CanvasStroke] = [:]
                let merge = l.mergeStored(page.strokes, info: { s in
                    let stroke = Canvas.canvasStroke(s)
                    converted[s.id] = stroke
                    return Canvas.info(of: stroke)
                })
                if merge.changesCanvas {
                    let shown = previous.map(Canvas.strokes(of:))
                    if let shown, shown.count == merge.previousCount {
                        let drawingStart = ContinuousClock.now
                        canvasDrawings[page.id] = Canvas.drawing(of: merge.sources.map { source -> Canvas.CanvasStroke in
                            switch source {
                            case .kept(let i): return shown[i]
                            case .converted(let s): return converted[s.id] ?? Canvas.canvasStroke(s)
                            }
                        })
                        work.drawingTime += ContinuousClock.now - drawingStart
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
            readOnly = readOnly ?? .deleted
        } else if readOnly == .deleted {
            readOnly = nil
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
        let after = Shown(pages: pages, strokes: currentStrokes(of:), only: only, meta: afterMeta,
                          recordings: recordings, deleted: state.deleted, visited: &work.strokesVisited)
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
    public func attachInkView(_ view: any RemoteInkView<Canvas>) {
        inkViews.removeAll { $0.view == nil || $0.view === view }
        inkViews.append(WeakInkView(view: view))
    }

    public func detachInkView(_ view: any RemoteInkView<Canvas>) {
        inkViews.removeAll { $0.view == nil || $0.view === view }
    }
}
