import Foundation
import Sempere

/// Recording into the open note (docs/attachments.md §9, §13; format.md §8.3): the session
/// (`RecordingSession`) on the app's microphone backend, and saving what it recorded through
/// `addRecording(file:…place:)` (the audio blob first, then one delta adding the recording and its card). Renaming,
/// removing and the ink sync of playback are `NoteEditor+Recordings.swift`.
extension NoteEditorModel {
    // MARK: - Recording

    /// Starts recording into this note in `format` on `backend`, hearing the system through `events` (the caller
    /// asked for the microphone first).
    public func startRecording(format: RecordingFormat,
                               root: URL = RecordingSession.root, backend: AudioCaptureBackend,
                               events: any RecordingSystemEvents) throws {
        guard canEditItems else { throw RecordingError.notEditable }
        guard recordingSession?.isActive != true else { return }
        guard recordings.count < NoteOps.Limits.recordingsPerNote else {
            throw RecordingError.cannotRecord("\(AttachmentOpsError.tooManyRecordings)")
        }
        let s = RecordingSession(noteID: noteID, format: format, root: root, backend: backend, events: events)
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
    public func stopRecording() async -> Recording? {
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
    public func finishRecording() async {
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
            var readable: [URL] = []
            for url in s.segments where FileManager.default.fileExists(atPath: url.path) {
                if await audioFiles.classify(url) == .audio { readable.append(url) }
            }
            try await audioFiles.merge(readable, into: out)
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
            Canvas.recordingFailed(.save(describeError(error)), in: self)
            if recordingSession === s { recordingSession = nil }
            RecordingSession.busy.remove(s.id)   // the files stay for `RecordingRecovery`
            return nil
        }
    }
}
