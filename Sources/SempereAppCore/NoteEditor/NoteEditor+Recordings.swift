import Foundation
import Sempere

/// Recordings of the open note (docs/attachments.md §9, §13; format.md
/// §8.3): saving one (the audio blob first, then one delta adding the
/// recording and its card on the page being looked at, format.md §8.2.9),
/// renaming and removing, and the ink sync of
/// playback: strokes written while recording carry `rec` (stamped in
/// `NoteCanvas.update`), a tap on one plays from there, and playback
/// highlights what was written around the current moment. Recording itself
/// (the microphone, the session's files) is the app's (`NoteEditor+RecordingSession.swift`).
extension NoteEditorModel {
    /// What stamps strokes drawn now with the running recording (nil when none runs).
    public var recordingStamp: (@Sendable (Date) -> RecordingLink?)? { Canvas.recordingStamp(of: self) }

    /// The note as the recording features see it (no strokes).
    public var recordingState: NoteState {
        NoteState(meta: meta, pages: [], recordings: recordings)
    }

    /// The recording with `id`, if the note has it.
    public func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    /// Adds the audio file `file` as a recording of this note: the blob
    /// first, then one delta (`addRecording`, and with `place` the `audio`
    /// item that shows it on the page being looked at, `audioPlacement`).
    /// Its informational fields come from the file's header (`AudioProbe`).
    @discardableResult
    public func addRecording(file: URL, started: Date, id: UUID = UUID(), title: String? = nil,
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
    public func audioPlacement(for recording: Recording) -> ItemPlacement? {
        guard let page = currentPage ?? pages.first else { return nil }
        let visible = Canvas.visibleRect(ofPage: page.id, in: self).map { Rect($0) }
        // Below the page's items (an earlier card), never on them (`NoteOps.unoccupied`); an infinite page grows to keep it in reach.
        let placed = try? NoteOps.placeRecording(recording.id, recordings: recordings + [recording], on: page, pageSize: pageSize,
                                                 visible: visible)
        if let f = placed?.item.frame { growPage(toFit: f.y + f.h) }
        return placed
    }

    /// Places `recording` (already in the note) on the page being looked at
    /// ("Place on Page" in the Recordings list): one `addItem`.
    @discardableResult
    public func placeRecording(_ id: UUID) -> Item? {
        guard canEditItems, let shown = self.recording(id), let placed = audioPlacement(for: shown),
              let page = pages.first(where: { $0.id == placed.page }),
              let edit = try? NoteOps.addItems([placed.item], to: page), applyItemEdit(edit) else { return nil }
        return placed.item
    }

    /// The `audio` items that show recording `id`, with their pages.
    public func audioItems(showing id: UUID) -> [(page: UUID, item: Item)] {
        NoteState(meta: meta, pages: pages, recordings: recordings).audioItems(showing: id)
    }

    /// Renames a recording (one `setRecording(title)`); an empty title clears it.
    public func renameRecording(_ id: UUID, to title: String) async {
        let ops = NoteOps.renameRecording(id, to: title, in: recordings)
        guard case .setRecording(_, .title(let renamed))? = ops.first else { return }
        do {
            try await writeRecordingOps(ops)
            if let i = recordings.firstIndex(where: { $0.id == id }) { recordings[i].title = renamed }
        } catch {
            Canvas.recordingFailed(.rename("\(error)"), in: self)
        }
    }

    /// Removes a recording and the cards that show it on the pages (one
    /// delta: `NoteOps.removeRecording`; its blob stays until collection, and
    /// history can restore it).
    public func removeRecording(_ id: UUID) async {
        guard recordings.contains(where: { $0.id == id }) else { return }
        if player?.recording?.id == id { player?.stop() }
        Canvas.recordingWillBeRemoved(id, in: self)
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
            Canvas.recordingFailed(.delete("\(error)"), in: self)
        }
    }

    /// Takes a transcript written for this note elsewhere (the model's
    /// transcription job, through `NoteWriter.append`) into the open editor.
    public func adoptTranscript(_ ref: BlobRef?, for id: UUID) {
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
    public func updatePlaybackHighlight(_ recording: Recording, at position: Double) {
        let basis = PlaybackIndex.Basis(recording: recording.id, recordings: recordings, pages: pages.map(\.id),
                                        revisions: pages.map { inkRevisions[$0.id] ?? 0 }, ready: !(isPreparing || loadFailed))
        if playbackIndex?.basis != basis {
            playbackIndex = PlaybackIndex(basis: basis, pages: pages.map { ($0.id, liveStrokes(of: $0.id)) },
                                          state: recordingState)
        }
        let next = playbackIndex?.highlighted(at: position) ?? [:]
        if next != playbackHighlight { playbackHighlight = next }
    }

    public func clearPlaybackHighlight() {
        if !playbackHighlight.isEmpty { playbackHighlight = [:] }
    }

    /// The highlight boxes of playback on `pageID`.
    public func playbackBoxes(onPage pageID: UUID) -> [HighlightBox] {
        guard let ids = playbackHighlight[pageID], !ids.isEmpty else { return [] }
        return liveStrokes(of: pageID).filter { ids.contains($0.id) }.compactMap(RecordingSync.box(of:))
            .map { HighlightBox(box: $0, isCurrent: false, style: .playback) }
    }

    /// Where a tap at page point (`x`, `y`) should play from: the recording
    /// and time of the earliest linked stroke under it, minus the lead-in.
    public func seekTarget(pageID: UUID, x: Double, y: Double, tolerance: Double = 12) -> (recording: Recording, time: Double)? {
        // Only linked strokes can be a target: the others are not measured.
        let hits = RecordingSync.hit(x: x, y: y, in: liveStrokes(of: pageID).filter { $0.rec != nil }, tolerance: tolerance)
        return RecordingSync.seekTarget(for: hits, in: recordingState)
    }

    /// A tap on the canvas in "Tap Ink to Play" mode.
    public func inkTapped(pageID: UUID, x: Double, y: Double) {
        guard let target = seekTarget(pageID: pageID, x: x, y: y) else { return }
        onPlayRequest?(target.recording, target.time)
    }
}

/// The strokes of a note linked to one recording, sorted by the moment they
/// were drawn (`RecordingLink.at`), for the playback highlight.
public struct PlaybackIndex {
    /// What the index was built from: rebuilt when any of it changes (every
    /// change of a page's ink bumps its `inkRevisions`; a note still being
    /// read has no strokes yet).
    public struct Basis: Equatable {
        public var recording: UUID
        public var recordings: [Recording]
        public var pages: [UUID]
        public var revisions: [Int]
        public var ready: Bool

        public init(recording: UUID, recordings: [Recording], pages: [UUID], revisions: [Int], ready: Bool) {
            self.recording = recording
            self.recordings = recordings
            self.pages = pages
            self.revisions = revisions
            self.ready = ready
        }
    }

    public let basis: Basis
    /// (at, page, stroke), sorted by `at`; only finite moments (no other can
    /// fall in a window around a finite position).
    var links: [(at: Double, page: UUID, stroke: UUID)] = []

    public init(basis: Basis, pages: [(id: UUID, strokes: [Stroke])], state: NoteState) {
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
    public func highlighted(at position: Double, window: Double = RecordingSync.highlightWindow) -> [UUID: Set<UUID>] {
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
