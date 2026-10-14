import Foundation
import Sempere
import SempereSpeech

/// Transcribes a recording's audio file on device.
protocol RecordingTranscribing: Sendable {
    func transcribe(file: URL, recording: UUID, noteLanguage: String?) async throws -> Transcript
}

/// The Speech framework, on device only (`SpeechTranscription`):
/// SpeechTranscriber, else SFSpeechRecognizer with on-device recognition required.
/// The language chosen in Settings wins over the note's.
struct SpeechRecordingTranscriber: RecordingTranscribing {
    func transcribe(file: URL, recording: UUID, noteLanguage: String?) async throws -> Transcript {
        let options = SpeechTranscription.Options(language: TranscriptionPreference.language(), noteLanguage: noteLanguage)
        return try await SpeechTranscription.transcribe(file: file, recording: recording, options: options)
    }
}

/// Playback and transcription of the open notes' recordings
/// (docs/attachments.md §9, §13). Audio is played from the model's
/// `BlobCache` (verified files), released with `discard` so its plaintext is
/// deleted once nothing plays or reads it, as are transcripts'; transcripts are written as a blob
/// of the note, then one `setRecording(transcript)` delta through the
/// browser's write path (`commit(_:building:)`), so a job finishes even if
/// the note is closed meanwhile, and an open editor takes the result.
extension AppModel {
    /// Hooks an editor's recordings up to the model: saved recordings are
    /// transcribed when that setting is on, taps on linked ink play, and
    /// recordings a crash left behind for this note are saved into it.
    func configureRecordings(_ editor: NoteEditor) {
        editor.onRecordingSaved = { [weak self, weak editor] recording, file, folder in
            guard let self, let editor, TranscriptionPreference.isOn(), self.transcriber != nil else {
                try? FileManager.default.removeItem(at: folder)
                RecordingSession.busy.remove(recording.id)
                return
            }
            let note = editor.noteID, meta = editor.meta
            Task {
                await self.transcribe(recording, note: note, file: file, meta: meta)
                try? FileManager.default.removeItem(at: folder)   // the plaintext audio
                RecordingSession.busy.remove(recording.id)
            }
        }
        editor.onPlayRequest = { [weak self, weak editor] recording, time in
            guard let self, let editor else { return }
            Task { await self.play(recording, in: editor, from: time) }
        }
        Task { await recoverRecordings(into: editor) }
    }

    // MARK: - Playback

    /// Plays recording `id` of the editor's note, or pauses it while it plays
    /// (the button on its card, format.md §8.2.9).
    func toggleRecording(_ id: UUID, in editor: NoteEditor) {
        if let player = editor.player, player.recording?.id == id {
            player.toggle()
            return
        }
        guard let recording = editor.recording(id) else { return }
        Task { await play(recording, in: editor) }
    }

    /// Plays `recording` of the editor's note, from `time` when given.
    func play(_ given: Recording, in editor: NoteEditor, from time: Double? = nil, start: Bool = true) async {
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
                let detail = "\(error)"
                errorMessage = String(localized: "Could not play the recording: \(detail)")
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

    private func makePlayer(for editor: NoteEditor) -> RecordingPlayer {
        let player = RecordingPlayer(backend: playbackBackend?())
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
    func loadTranscript(_ recording: Recording, note: UUID) async -> Transcript? {
        guard let ref = recording.transcript else { return nil }
        return await loadTranscript(ref: ref, recording: recording.id, note: note)
    }

    /// The transcript blob `ref` of recording `recording` in `note`, verified and decoded; nil when it
    /// cannot be read or names another recording. Also the transcript search's reader.
    func loadTranscript(ref: BlobRef, recording: UUID, note: UUID) async -> Transcript? {
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
    func transcribe(_ recording: Recording, in editor: NoteEditor) async {
        guard let cache = attachmentCache() else { return }
        let note = editor.noteID
        do {
            let url = try await cache.acquire(note: note, ref: recording.blob)
            await transcribe(recording, note: note, file: url, meta: editor.meta)
            await cache.release(note: note, ref: recording.blob, discard: true)
        } catch {
            let detail = "\(error)"
            errorMessage = String(localized: "Could not read the recording: \(detail)")
        }
    }

    /// Transcribes the audio in `file` (recording `recording` of `note`) on
    /// this device and stores the transcript: the blob, then one delta. The
    /// note's language when it has one, else the device's.
    func transcribe(_ recording: Recording, note: UUID, file: URL, meta: NoteMeta?) async {
        guard let transcriber, !transcribing.contains(recording.id) else { return }
        let gen = generation
        transcribing.insert(recording.id)
        defer { transcribing.remove(recording.id) }
        do {
            let language = meta.flatMap(TranscriptionLanguage.noteLanguage(of:))
            let transcript = try await transcriber.transcribe(file: file, recording: recording.id, noteLanguage: language)
            try ensureCurrent(gen)
            let ref = try await storeTranscript(transcript, note: note)
            try ensureCurrent(gen)
            for e in [editor].compactMap({ $0 }) + Array(windowEditors.values) where e.noteID == note {
                e.adoptTranscript(ref, for: recording.id)
                if e.player?.recording?.id == recording.id { e.player?.transcript = transcript }
            }
        } catch is CancellationError {
        } catch {
            let detail = "\(error)"
            if gen == generation { errorMessage = String(localized: "Could not transcribe the recording: \(detail)") }
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
        let writer = NoteWriter(vault: vault, noteID: note, clock: clock, nextSeq: 1, coordinated: isCloudVault)
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
    /// recording", then deletes their files.
    func recoverRecordings(into editor: NoteEditor) async {
        let pending = RecordingRecovery.pending(for: editor.noteID, root: recordingRoot)
        guard !pending.isEmpty, editor.canEditItems else { return }
        for (folder, manifest) in pending {
            let segments = manifest.segments.map { folder.appendingPathComponent($0) }
            let readable = await RecordingAssembly.readable(segments)
            guard !readable.isEmpty else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            let out = folder.appendingPathComponent("recovered.m4a")
            do {
                try await RecordingAssembly.merge(readable, into: out)
                // A recording of that id may already be in the note (saved, then the files were not deleted).
                if editor.recording(manifest.recording) == nil {
                    try await editor.addRecording(file: out, started: manifest.started ?? Date(), id: manifest.recording,
                                                  title: "Recovered recording")   // stored in the vault: stays English
                }
                try? FileManager.default.removeItem(at: folder)
            } catch {
                let detail = "\(error)"
                editor.recordingError = String(localized: "A recording interrupted by the app closing could not be recovered: \(detail)")
            }
        }
    }
}
