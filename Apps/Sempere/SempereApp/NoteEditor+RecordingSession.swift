import Foundation
import Sempere
import SempereAppCore

/// Recording into the open note (docs/attachments.md §9, §13; format.md
/// §8.3): the microphone session (`RecordingSession`), and saving what it
/// recorded through the package's `addRecording(file:…place:)` (the audio
/// blob first, then one delta adding the recording and its card). Renaming,
/// removing and the ink sync of playback are the package's
/// (`SempereAppCore/NoteEditor/NoteEditor+Recordings.swift`).
extension NoteEditor {
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
            let detail = AppModel.describe(error)
            recordingError = String(localized: "Could not save the recording: \(detail)")
            if recordingSession === s { recordingSession = nil }
            RecordingSession.busy.remove(s.id)   // the files stay for `RecordingRecovery`
            return nil
        }
    }
}
