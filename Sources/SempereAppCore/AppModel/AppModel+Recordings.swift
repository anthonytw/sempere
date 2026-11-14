import Foundation
import Sempere

/// Why a recording was not transcribed: the transcriber's typed failures (the app's `SpeechRecordingTranscriber`
/// throws them; the app words them).
public enum RecordingTranscriptionError: Error, Equatable, Sendable {
    /// The language's on-device model is not installed, and this job may not download it.
    case modelNotDownloaded
}

/// Recordings a crash or a kill left behind (a recording session's folder
/// with a manifest and no session running): saved into their note the next
/// time it is opened (`AppModel.recoverRecordings`).
public enum RecordingRecovery {
    /// `RecordingManifest.fileName` (quick voice notes leave the same manifest).
    public static var manifestName: String { RecordingManifest.fileName }

    /// Folders under `root` whose manifest names `note` and whose recording is not `inUse` (running, or still being
    /// saved or transcribed: `AppModelServices.recordingsInUse`). A manifest that names a vault matches only that vault
    /// (`vault`; one that names none, from an earlier build, matches any): note ids are kept by Make a Copy, so a note id
    /// alone is not unique across the vaults of a device.
    static func pending(for note: UUID, vault: UUID? = nil, root: URL, inUse: Set<UUID>) -> [(URL, RecordingManifest)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> (URL, RecordingManifest)? in
            guard let data = try? BoundedRead.contents(of: dir.appendingPathComponent(manifestName), maxBytes: 1 << 20),
                  let m = try? JSONDecoder().decode(RecordingManifest.self, from: data), m.note == note,
                  vault == nil || m.vault == nil || m.vault == vault, !inUse.contains(m.recording) else { return nil }
            return (dir, m)
        }
    }
}

/// Playback and transcription of the open notes' recordings
/// (docs/attachments.md §9, §13). Audio is played from the model's
/// `BlobCache` (verified files), released with `discard` so its plaintext is
/// deleted once nothing plays or reads it, as are transcripts'; transcripts are written as a blob
/// of the note, then one `setRecording(transcript)` delta through the
/// browser's write path (`commit(_:building:)`), so a job finishes even if
/// the note is closed meanwhile, and an open editor takes the result. A recording being made is
/// `NoteEditor+RecordingSession` (the microphone is the app's `AudioCaptureBackend`); once one is saved, the model transcribes it and hands its
/// files back (`services.finishRecordingSave`).
extension AppModelCore {
    /// Hooks an editor's recordings up to the model: taps on linked ink play, a recording made in it is transcribed
    /// once saved (when that setting is on, then `services.finishRecordingSave`), and recordings a crash left behind
    /// for this note are saved into it. Every editor the model opens, for the library window or a note window, gets it.
    func configureRecordings(_ editor: Editor) {
        editor.audioFiles = services.audioFiles
        editor.onPlayRequest = { [weak self, weak editor] recording, time in
            guard let self, let editor else { return }
            Task { await self.play(recording, in: editor, from: time) }
        }
        let finish = services.finishRecordingSave
        editor.onRecordingSaved = { [weak self, weak editor] recording, file, folder in
            guard let self, let editor, self.transcribesSavedRecordings else {
                finish(recording.id, folder)
                return
            }
            let note = editor.noteID, meta = editor.meta
            Task {
                await self.transcribeSaved(recording, file: file, note: note, meta: meta)
                finish(recording.id, folder)   // the plaintext audio
            }
        }
        Task { await recoverRecordings(into: editor) }
    }

    /// Whether a recording just saved is transcribed at once ("Transcribe Recordings on This Device", and a
    /// transcriber).
    var transcribesSavedRecordings: Bool {
        TranscriptionSettings.isEnabled(services.settings) && transcriber != nil
    }

    /// Transcribes a recording made in `note` (its `meta` as the editor had it) and just saved from `file`
    /// (`transcribesSavedRecordings`). Takes no editor, so none is held for the whole transcription.
    func transcribeSaved(_ recording: Recording, file: URL, note: UUID, meta: NoteMeta?) async {
        await transcribe(recording, note: note, file: file, meta: meta, automatic: true)
    }

    // MARK: - Playback

    /// Plays recording `id` of the editor's note, or pauses it while it plays
    /// (the button on its card, format.md §8.2.9).
    public func toggleRecording(_ id: UUID, in editor: Editor) {
        if let player = editor.player, player.recording?.id == id {
            player.toggle()
            return
        }
        guard let recording = editor.recording(id) else { return }
        Task { await play(recording, in: editor) }
    }

    /// Plays `recording` of the editor's note, from `time` when given.
    public func play(_ given: Recording, in editor: Editor, from time: Double? = nil, start: Bool = true) async {
        // The note's current copy: a caller's may predate a rename or a transcript.
        let recording = editor.recording(given.id) ?? given
        let player = editor.player ?? makePlayer(for: editor)
        if player.recording?.id != recording.id {
            guard let cache = attachmentCache() else { return }
            do {
                let url = try await cache.acquire(note: editor.noteID, ref: recording.blob)
                do { try player.load(recording, file: url) } catch {
                    await cache.release(note: editor.noteID, ref: recording.blob, discard: true)
                    throw error
                }
            } catch {
                alert = .notice(.recordingUnplayable(services.describeError(error)))
                return
            }
            if recording.transcript != nil {
                let note = editor.noteID
                Task { [weak player] in
                    let t = await self.loadTranscript(recording, note: note)
                    if player?.recording?.id == recording.id { player?.transcript = t }
                }
            }
        }
        if let time { player.seek(to: time) }
        if start { player.play() }
    }

    private func makePlayer(for editor: Editor) -> RecordingPlayer {
        let player = RecordingPlayer(backend: playbackBackend())
        let cache = attachmentCache(), note = editor.noteID
        player.onUnload = { [weak editor] recording in
            editor?.clearPlaybackHighlight()
            Task { await cache?.release(note: note, ref: recording.blob, discard: true) }
        }
        player.onPosition = { [weak editor] recording, position in
            editor?.updatePlaybackHighlight(recording, at: position)
        }
        editor.player = player
        return player
    }

    /// The transcript of `recording`, verified (format.md §8.3.2: it must
    /// name this recording); nil when it cannot be read.
    public func loadTranscript(_ recording: Recording, note: UUID) async -> Transcript? {
        guard let ref = recording.transcript else { return nil }
        return await loadTranscript(ref: ref, recording: recording.id, note: note)
    }

    /// The transcript blob `ref` of recording `recording` in `note`, verified and decoded; nil when it
    /// cannot be read or names another recording. Also the transcript search's reader.
    public func loadTranscript(ref: BlobRef, recording: UUID, note: UUID) async -> Transcript? {
        guard let cache = attachmentCache() else { return nil }
        guard let url = try? await cache.acquire(note: note, ref: ref) else { return nil }
        defer { Task { await cache.release(note: note, ref: ref, discard: true) } }
        let decoded = await Task.detached(priority: .userInitiated) { () -> Transcript? in
            guard let data = try? BoundedRead.contents(of: url, maxBytes: Transcript.maxSize) else { return nil }
            return try? Transcript.decode(data)
        }.value
        return decoded?.recording == recording ? decoded : nil
    }

    // MARK: - Transcription

    /// Transcribes a recording of the editor's note now (the Transcribe
    /// button; works whatever the automatic setting says).
    public func transcribe(_ recording: Recording, in editor: Editor) async {
        guard let cache = attachmentCache() else { return }
        let note = editor.noteID
        do {
            let url = try await cache.acquire(note: note, ref: recording.blob)
            await transcribe(recording, note: note, file: url, meta: editor.meta, automatic: false)
            await cache.release(note: note, ref: recording.blob, discard: true)
        } catch {
            alert = .notice(.recordingUnreadable(services.describeError(error)))
        }
    }

    /// Transcribes the audio in `file` (recording `recording` of `note`) on
    /// this device and stores the transcript: the blob, then one delta. The
    /// note's language when it has one, else the device's. An `automatic` job (not the Transcribe button) never
    /// downloads the language model: without it, it says where to get it.
    public func transcribe(_ recording: Recording, note: UUID, file: URL, meta: NoteMeta?, automatic: Bool) async {
        guard let transcriber, !transcribing.contains(recording.id) else { return }
        let gen = generation
        transcribing.insert(recording.id)
        defer { transcribing.remove(recording.id) }
        do {
            let language = meta.flatMap(TranscriptionLanguage.noteLanguage(of:))
            let transcript = try await transcriber.transcribe(file: file, recording: recording.id, noteLanguage: language,
                                                              allowModelDownload: !automatic)
            try ensureCurrent(gen)
            let ref = try await storeTranscript(transcript, note: note)
            try ensureCurrent(gen)
            for e in [editor].compactMap({ $0 }) + Array(windowEditors.values) where e.noteID == note {
                e.adoptTranscript(ref, for: recording.id)
                if e.player?.recording?.id == recording.id { e.player?.transcript = transcript }
            }
        } catch is CancellationError {
        } catch RecordingTranscriptionError.modelNotDownloaded {
            // Once per launch: an inbox of several voice notes would otherwise bring the alert once each.
            if gen == generation, !modelMissingReported {
                modelMissingReported = true
                alert = .notice(.transcriptionModelMissing)
            }
        } catch {
            if gen == generation { alert = .notice(.recordingNotTranscribed(services.describeError(error))) }
        }
    }

    /// Writes `transcript` as a blob of `note`, then the delta that sets it
    /// on its recording (checked against the note on disk at write time).
    func storeTranscript(_ transcript: Transcript, note: UUID) async throws -> BlobRef {
        guard let vault, let clock = try? deviceClockForWriting() else { throw ModelError.noVaultOpen }
        try requireWritableVault()   // format.md §7.3
        let content = try transcript.encoded()
        let ref = BlobRef(content: content, type: BlobRef.transcriptType)
        if let prepare = blobWritePreparer(note: note) { try await prepare(ref) }
        let writer = NoteWriter(vault: vault, noteID: note, clock: clock, nextSeq: 1)
        let stored = try await writer.addBlob(content, type: BlobRef.transcriptType)
        let recording = transcript.recording
        // iCloud: a transcription can take minutes; the note's revisions must be local before the delta is written.
        try await downloadNote(note)
        try await commit(note) { state in
            guard let state else { return [] }
            return (try? NoteOps.setTranscript(stored, content: content, for: recording, in: state)) ?? []
        }
        return stored
    }

    // MARK: - Recovery

    /// Saves recordings that a crash or kill left in the recordings folder
    /// for this note (their finished segments) into it, titled "Recovered
    /// recording", then deletes their files. One recovery per note at a time (`recoveringNotes`): a call while one
    /// runs for the same note does nothing.
    func recoverRecordings(into editor: Editor) async {
        let note = editor.noteID
        guard !recoveringNotes.contains(note) else { return }
        let pending = RecordingRecovery.pending(for: note, vault: vault?.vaultId, root: recordingRoot, inUse: services.recordingsInUse())
        guard !pending.isEmpty, editor.canEditItems else { return }
        recoveringNotes.insert(note)
        defer { recoveringNotes.remove(note) }
        let files = services.audioFiles
        for (folder, manifest) in pending {
            var readable: [URL] = []
            for segment in manifest.segments.map({ folder.appendingPathComponent($0) })
            where FileManager.default.fileExists(atPath: segment.path) {
                if await files.classify(segment) == .audio { readable.append(segment) }
            }
            guard !readable.isEmpty else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            let out = folder.appendingPathComponent("recovered.m4a")
            do {
                try? FileManager.default.removeItem(at: out)
                try await files.merge(readable, into: out)
                // A recording of that id may already be in the note (saved, then the files were not deleted).
                if editor.recording(manifest.recording) == nil {
                    try await editor.addRecording(file: out, started: manifest.started ?? Date(), id: manifest.recording,
                                                  title: "Recovered recording")   // stored in the vault: stays English
                }
                try? FileManager.default.removeItem(at: folder)
            } catch {
                Host.Canvas.recordingFailed(.recover(services.describeError(error)), in: editor)
            }
        }
    }
}
