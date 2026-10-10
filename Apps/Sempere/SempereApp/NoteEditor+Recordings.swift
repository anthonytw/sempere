import Foundation
import Sempere

/// Recordings of the open note (docs/attachments.md §9, §13; format.md
/// §8.3): recording into the note, saving (the audio blob first, then one
/// delta adding the recording and its card on the page being looked at,
/// format.md §8.2.9), renaming and removing, and the ink sync of
/// playback: strokes written while recording carry `rec` (stamped in
/// `StrokeLedger.items(for:tool:stamp:)`), a tap on one plays from there,
/// and playback highlights what was written around the current moment.
extension NoteEditor {
    /// What stamps strokes drawn now with the running recording (nil when none runs).
    var recordingStamp: (@Sendable (Date) -> RecordingLink?)? {
        guard let s = recordingSession, s.isActive else { return nil }
        return s.stamp
    }

    /// The note as the recording features see it (no strokes).
    var recordingState: NoteState {
        NoteState(meta: meta, pages: [], recordings: recordings)
    }

    /// The recording with `id`, if the note has it.
    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    // MARK: - Recording

    /// Starts recording into this note in `format` (the settings' by
    /// default). The caller asked for the microphone first.
    func startRecording(format: RecordingFormat = RecordingPreference.format(), root: URL = RecordingSession.root,
                        backend: AudioCaptureBackend? = nil, center: NotificationCenter = .default) throws {
        guard canEditItems else { throw RecordingError.notEditable }
        guard recordingSession?.isActive != true else { return }
        guard recordings.count < NoteOps.Limits.recordingsPerNote else {
            throw RecordingError.cannotRecord("\(AttachmentOpsError.tooManyRecordings)")
        }
        let s = RecordingSession(noteID: noteID, format: format, root: root, backend: backend, center: center)
        // Stopped without the user (media server reset, no new segment): saved like a Stop.
        s.onStoppedBySystem = { [weak self, weak s] in
            guard let self, let s else { return }
            self.beginSave(s)
        }
        do { try s.start() } catch {
            s.discardFiles()
            throw error
        }
        recordingError = nil
        recordingSession = s
    }

    /// Stops the recording and saves it into the note. Returns the recording
    /// as added (nil when nothing was saved; the reason is in `recordingError`).
    @discardableResult
    func stopRecording() async -> Recording? {
        guard let s = recordingSession, s.isActive else { return nil }
        s.stop()
        return await beginSave(s).value
    }

    /// Starts saving the stopped session `s`; `close` waits for it.
    @discardableResult
    private func beginSave(_ s: RecordingSession) -> Task<Recording?, Never> {
        let task = Task { await self.save(s) }
        recordingSaves.append(Task { _ = await task.value })
        return task
    }

    /// Stops and saves a recording in progress, and waits for saves still
    /// running (`close`).
    func finishRecording() async {
        await stopRecording()
        let saves = recordingSaves
        recordingSaves = []
        for t in saves { await t.value }
    }

    /// The session's audio as one file, stored as a blob, then the recording
    /// added in one delta. The session's files are handed to
    /// `onRecordingSaved` (transcription), else deleted; on failure they stay
    /// for `RecordingRecovery`.
    private func save(_ s: RecordingSession) async -> Recording? {
        let out = s.folder.appendingPathComponent("recording.m4a")
        RecordingSession.busy.insert(s.id)
        do {
            try await RecordingAssembly.merge(await RecordingAssembly.readable(s.segments), into: out)
            let recording = try await addRecording(file: out, started: s.timeline.started ?? Date(), id: s.id, place: true)
            if recordingSession === s { recordingSession = nil }
            if let handOff = onRecordingSaved {
                handOff(recording, out, s.folder)   // deletes the folder and clears `busy` when done
            } else {
                s.discardFiles()
                RecordingSession.busy.remove(s.id)
            }
            return recording
        } catch {
            let detail = "\(error)"
            recordingError = String(localized: "Could not save the recording: \(detail)")
            if recordingSession === s { recordingSession = nil }
            RecordingSession.busy.remove(s.id)   // the files stay for `RecordingRecovery`
            return nil
        }
    }

    /// Adds the audio file `file` as a recording of this note: the blob
    /// first, then one delta (`addRecording`, and with `place` the `audio`
    /// item that shows it on the page being looked at, `audioPlacement`).
    /// Its informational fields come from the file's header (`AudioProbe`).
    @discardableResult
    func addRecording(file: URL, started: Date, id: UUID = UUID(), title: String? = nil,
                      place: Bool = false) async throws -> Recording {
        guard canEditItems else { throw ItemError.notEditable }
        let info = try? await Task.detached(priority: .userInitiated) { try AudioProbe.probe(file: file) }.value
        let ref = try await storeBlob(file: file, type: "audio/mp4")
        let recording = NoteOps.recording(blob: ref, started: started, info: info, title: title, id: id)
        var ops = try NoteOps.addRecording(recording, to: recordings)
        await flush()   // the card goes on the page as it is after the ink still pending
        let placed = place ? audioPlacement(for: recording) : nil
        if let placed { ops += placed.ops }
        try await writeRecordingOps(ops)
        recordings.append(recording)
        recordings.sort(by: Recording.sortsBefore)
        if let placed { showWrittenItems(added: [(placed.page, placed.item)]) }
        return recording
    }

    /// The card that shows `recording` on the page being looked at, inside the
    /// part of it on screen (format.md §8.2.9; `NoteOps.placeRecording`), nil
    /// when the note has no page or the page is full.
    func audioPlacement(for recording: Recording) -> ItemPlacement? {
        guard let page = currentPage ?? pages.first else { return nil }
        let visible = (canvasTarget?.visibleRect(ofPage: page.id) ?? canvasTarget?.visiblePageRect).map { Rect($0) }
        return try? NoteOps.placeRecording(recording.id, recordings: recordings + [recording], on: page, pageSize: pageSize,
                                           visible: visible)
    }

    /// Places `recording` (already in the note) on the page being looked at
    /// ("Place on Page" in the Recordings list): one `addItem`.
    @discardableResult
    func placeRecording(_ id: UUID) -> Item? {
        guard canEditItems, let shown = self.recording(id), let placed = audioPlacement(for: shown),
              let page = pages.first(where: { $0.id == placed.page }),
              let edit = try? NoteOps.addItems([placed.item], to: page), applyItemEdit(edit) else { return nil }
        return placed.item
    }

    /// The `audio` items that show recording `id`, with their pages.
    func audioItems(showing id: UUID) -> [(page: UUID, item: Item)] {
        NoteState(meta: meta, pages: pages, recordings: recordings).audioItems(showing: id)
    }

    /// Renames a recording (one `setRecording(title)`); an empty title clears it.
    func renameRecording(_ id: UUID, to title: String) async {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (recordings[i].title ?? "") != t else { return }
        do {
            try await writeRecordingOps([.setRecording(recordingId: id, change: .title(t.isEmpty ? nil : t))])
            recordings[i].title = t.isEmpty ? nil : t
        } catch {
            let detail = "\(error)"
            recordingError = String(localized: "Could not rename the recording: \(detail)")
        }
    }

    /// Removes a recording and the cards that show it on the pages (one
    /// delta: `NoteOps.removeRecording`; its blob stays until collection, and
    /// history can restore it).
    func removeRecording(_ id: UUID) async {
        guard recordings.contains(where: { $0.id == id }) else { return }
        if player?.recording?.id == id { player?.stop() }
        do {
            await flush()
            let ops = NoteOps.removeRecording(id, in: NoteState(meta: meta, pages: pages, recordings: recordings))
            try await writeRecordingOps(ops)
            recordings.removeAll { $0.id == id }
            var removed: [(page: UUID, item: UUID)] = []
            for case .removeItem(let page, let item) in ops { removed.append((page, item)) }
            showWrittenItems(added: [], removed: removed)
            playbackHighlight = [:]
        } catch {
            let detail = "\(error)"
            recordingError = String(localized: "Could not delete the recording: \(detail)")
        }
    }

    /// Takes a transcript written for this note elsewhere (the model's
    /// transcription job, through `NoteWriter.append`) into the open editor.
    func adoptTranscript(_ ref: BlobRef?, for id: UUID) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].transcript = ref
    }

    /// Writes `ops` as one delta now, after the ink still pending.
    private func writeRecordingOps(_ ops: [Op]) async throws {
        guard canEditItems else { throw ItemError.notEditable }
        await flush()
        guard let writer = attachmentWriter else { throw ItemError.notEditable }
        try await writeDirect(ops, with: writer)
    }

    // MARK: - Playback and ink

    /// Highlights the strokes written in the moments before `position` of
    /// `recording` (on every page), as playback goes on.
    ///
    /// The strokes linked to the recording are indexed by `at` once per ink
    /// change (`PlaybackIndex`), so a tick is two binary searches, and no
    /// page is converted or given a ledger for it. The result is
    /// `RecordingSync.highlighted` of every page's live strokes.
    func updatePlaybackHighlight(_ recording: Recording, at position: Double) {
        let basis = PlaybackIndex.Basis(recording: recording.id, recordings: recordings, pages: pages.map(\.id),
                                        revisions: pages.map { inkRevisions[$0.id] ?? 0 }, ready: !(isPreparing || loadFailed))
        if playbackIndex?.basis != basis {
            playbackIndex = PlaybackIndex(basis: basis, pages: pages.map { ($0.id, liveStrokes(of: $0.id)) },
                                          state: recordingState)
        }
        let next = playbackIndex?.highlighted(at: position) ?? [:]
        if next != playbackHighlight { playbackHighlight = next }
    }

    func clearPlaybackHighlight() {
        if !playbackHighlight.isEmpty { playbackHighlight = [:] }
    }

    /// The highlight boxes of playback on `pageID`.
    func playbackBoxes(onPage pageID: UUID) -> [HighlightBox] {
        guard let ids = playbackHighlight[pageID], !ids.isEmpty else { return [] }
        return liveStrokes(of: pageID).filter { ids.contains($0.id) }.compactMap(RecordingSync.box(of:))
            .map { HighlightBox(box: $0, isCurrent: false, style: .playback) }
    }

    /// Where a tap at page point (`x`, `y`) should play from: the recording
    /// and time of the earliest linked stroke under it, minus the lead-in.
    func seekTarget(pageID: UUID, x: Double, y: Double, tolerance: Double = 12) -> (recording: Recording, time: Double)? {
        let hits = RecordingSync.hit(x: x, y: y, in: liveStrokes(of: pageID), tolerance: tolerance)
        return RecordingSync.seekTarget(for: hits, in: recordingState)
    }

    /// A tap on the canvas in "Tap Ink to Play" mode.
    func inkTapped(pageID: UUID, x: Double, y: Double) {
        guard let target = seekTarget(pageID: pageID, x: x, y: y) else { return }
        onPlayRequest?(target.recording, target.time)
    }
}

/// The strokes of a note linked to one recording, sorted by the moment they
/// were drawn (`RecordingLink.at`), for the playback highlight.
struct PlaybackIndex {
    /// What the index was built from: rebuilt when any of it changes (every
    /// change of a page's ink bumps its `inkRevisions`; a note still being
    /// read has no strokes yet).
    struct Basis: Equatable {
        var recording: UUID
        var recordings: [Recording]
        var pages: [UUID]
        var revisions: [Int]
        var ready: Bool
    }

    let basis: Basis
    /// (at, page, stroke), sorted by `at`; only finite moments (no other can
    /// fall in a window around a finite position).
    private var links: [(at: Double, page: UUID, stroke: UUID)] = []

    init(basis: Basis, pages: [(id: UUID, strokes: [Stroke])], state: NoteState) {
        self.basis = basis
        var resolved: [UUID: Bool] = [:]   // link id -> names this recording
        for (page, strokes) in pages {
            for s in strokes {
                guard let link = s.rec, link.at.isFinite else { continue }
                let ours = resolved[link.id] ?? (state.recording(for: link)?.id == basis.recording)
                resolved[link.id] = ours
                if ours { links.append((link.at, page, s.id)) }
            }
        }
        links.sort { $0.at < $1.at }
    }

    /// `RecordingSync.highlighted` per page: the strokes drawn in the
    /// `window` seconds up to `position`, by page; pages without any left out.
    func highlighted(at position: Double, window: Double = RecordingSync.highlightWindow) -> [UUID: Set<UUID>] {
        guard position.isFinite else { return [:] }
        let from = position - window
        var lo = 0, hi = links.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if links[mid].at < from { lo = mid + 1 } else { hi = mid }
        }
        var result: [UUID: Set<UUID>] = [:]
        var i = lo
        while i < links.count, links[i].at <= position {
            result[links[i].page, default: []].insert(links[i].stroke)
            i += 1
        }
        return result
    }
}
