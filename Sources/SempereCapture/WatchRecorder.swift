import Foundation
import Sempere
import SempereCaptureShared

// The Apple Watch's voice note: a small start, stop and sweep state machine over the recorder protocols (docs/design/1.1-watch.md
// §3.5), with no UI and no Apple framework (the watch app implements `CaptureAudio`/`CaptureRecorder`/`CaptureRecording`
// over AVFoundation). It does not reuse `QuickCapture`, which is built around Live Activities, intents and a delivery the
// watch does not do. A stop concatenates the segments (ADTS), remuxes them to MPEG-4 (`ADTSToMP4`), seals with the
// provisioned `CaptureProfile` (`CaptureWriter.seal`), writes the sealed file to the `WatchOutbox` and only then deletes the
// plaintext folder: audio that was not sealed is never deleted (`CaptureSegments.plan`). It writes `VoiceNoteStatus` for the
// watch's widgets.

/// Why a watch voice note did not start or could not be saved. Worded by the watch app.
public enum WatchRecorderError: Error, Equatable, Sendable {
    /// No provisioned profile ("Set up Quick Voice Notes in Sempere on your iPhone").
    case notSetUp
    case microphoneDenied
    case alreadyRecording
    case notRecording
    /// "Open Sempere on your iPhone to send saved notes".
    case outboxFull
    case lowStorage
    /// The audio session was refused (the system's text, for a diagnostics line).
    case sessionRefused(String)
    case cannotStart(String)
    /// Not a byte of audio was recorded (the folder is deleted).
    case nothingRecorded
    /// A complete segment does not decode (the folder is kept).
    case segmentUndecodable(String)
    /// Bytes of which nothing decodes (the folder is kept).
    case noReadableAudio
    /// Sealing or writing the outbox failed (the folder is kept).
    case sealFailed(String)
}

/// One note that was sealed into the outbox.
public struct WatchSavedNote: Equatable, Sendable {
    public var id: UUID
    public var vault: UUID
    public var vaultName: String
    /// Seconds of audio.
    public var duration: Double
    /// The note stopped because it reached the limit.
    public var reachedLimit: Bool
    /// It was a recording a crash, a quit or a restart cut off, sealed by the sweep ("Interrupted voice note saved").
    public var recovered: Bool
}

@MainActor
public final class WatchRecorder {
    public enum Phase: Equatable, Sendable {
        case idle, recording, paused, saving
    }

    /// Mono AAC-LC, 24 kHz, 32 kbit/s: about 240 KB a minute, set for speech (the phone's is 48 kHz and 64 kbit/s).
    public static let format = RecordingFormat(codec: .aac, bitRate: 32_000, sampleRate: 24_000, channels: 1)
    /// A note longer than this stops, seals and says so (an hour is 14 MB).
    public static let defaultMaxDuration: TimeInterval = 3600

    private let audio: any CaptureAudio
    private let outbox: WatchOutbox
    private let profile: @MainActor () -> WatchProfilePayload?
    private let root: URL
    private let statusStore: VoiceNoteStatusStore?
    private let freeBytes: @MainActor () -> Int64?
    private let timeZone: TimeZone
    public var now: @MainActor () -> Date
    public var maxDuration: TimeInterval

    private var recorder: (any CaptureRecorder)?
    private var session: (any CaptureRecording)?
    private var starting = false
    private var saving = false
    /// What the last stop by the system (not by `stop()`) produced.
    public private(set) var lastSystemStop: Result<WatchSavedNote, WatchRecorderError>?
    public private(set) var lastSaved: WatchSavedNote?

    /// - Parameters:
    ///   - profile: the provisioned profile, nil when none.
    ///   - root: where recording folders go (`Application Support/SempereWatch/Capture`).
    ///   - freeBytes: the device's free space, nil when unknown.
    public init(audio: any CaptureAudio, outbox: WatchOutbox, profile: @escaping @MainActor () -> WatchProfilePayload?, root: URL,
                statusStore: VoiceNoteStatusStore? = nil, freeBytes: @escaping @MainActor () -> Int64? = { nil },
                timeZone: TimeZone = .current, maxDuration: TimeInterval = WatchRecorder.defaultMaxDuration,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.audio = audio
        self.outbox = outbox
        self.profile = profile
        self.root = root
        self.statusStore = statusStore
        self.freeBytes = freeBytes
        self.timeZone = timeZone
        self.maxDuration = maxDuration
        self.now = now
    }

    // MARK: State

    public var phase: Phase {
        if saving { return .saving }
        guard let session, session.isActive else { return .idle }
        return session.isPaused ? .paused : .recording
    }

    public var isRecording: Bool { phase == .recording || phase == .paused }

    /// Seconds of audio recorded so far (pauses are not audio).
    public var elapsed: Double { session.map { $0.timeline.audioLength(at: now()) } ?? 0 }

    /// The folder of the recording in progress.
    public var activeFolder: URL? { session?.folder }

    /// What the widgets show, and writes it (the watch App Group's `VoiceNoteStatusStore`).
    public var status: VoiceNoteStatus {
        let at = now()
        var begun: Date?
        var pausedAt: Date?
        if let session, session.isActive {
            let length = session.timeline.audioLength(at: at)
            begun = at.addingTimeInterval(-length)
            if session.isPaused { pausedAt = at }
        }
        return VoiceNoteStatus.make(setUp: profile() != nil, activitiesEnabled: true, recording: isRecording, saving: saving,
                                    started: begun, paused: pausedAt)
    }

    /// Writes `status` for the widgets; true when it changed (the app reloads them then). Call it after the platform tells of
    /// an interruption or its end: the pause shows through `phase`.
    @discardableResult
    public func publishStatus() -> Bool {
        guard let statusStore else { return false }
        return (try? statusStore.write(status)) ?? false
    }

    // MARK: Start

    /// Starts recording. The outbox's caps and the device's free space are checked first; then the microphone, the audio
    /// session (never mixable: nothing plays on the watch) and the recorder.
    public func start() async throws {
        guard !isRecording, !saving, !starting else { throw WatchRecorderError.alreadyRecording }
        guard profile() != nil else { throw WatchRecorderError.notSetUp }
        do { try outbox.canStartRecording(freeBytes: freeBytes()) } catch let e as WatchOutboxError {
            throw e == .lowStorage ? WatchRecorderError.lowStorage : WatchRecorderError.outboxFull
        }
        starting = true
        defer { starting = false }
        guard await audio.requestMicrophone() else { throw WatchRecorderError.microphoneDenied }
        let capture = audio.makeRecorder()
        do { try await capture.activateSession(mixable: false) } catch {
            throw WatchRecorderError.sessionRefused("\(error)")
        }
        let s = capture.makeRecording(format: Self.format, root: root, segmentExtension: CaptureSegments.segmentExtension)
        s.onStoppedBySystem = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            Task { @MainActor in self.lastSystemStop = await self.finishCatching(s) }
        }
        do { try s.start() } catch {
            capture.deactivate()
            s.discardFiles()
            throw WatchRecorderError.cannotStart("\(error)")
        }
        recorder = capture
        session = s
        publishStatus()
    }

    // MARK: Stop

    /// Stops and seals the recording into the outbox. The note is saved when this returns, before any hand-off.
    @discardableResult
    public func stop() async throws -> WatchSavedNote {
        guard let s = session, s.isActive else { throw WatchRecorderError.notRecording }
        return try await finish(s, reachedLimit: false)
    }

    /// Stops at the limit: called by the app's timer (and after a wake). Returns the note when it stopped one.
    @discardableResult
    public func checkLimit() async -> WatchSavedNote? {
        guard let s = session, s.isActive, s.timeline.audioLength(at: now()) >= maxDuration else { return nil }
        do { return try await finish(s, reachedLimit: true) } catch { return nil }
    }

    private func finishCatching(_ s: any CaptureRecording) async -> Result<WatchSavedNote, WatchRecorderError> {
        do { return .success(try await finish(s, reachedLimit: false)) } catch let e as WatchRecorderError { return .failure(e) } catch {
            return .failure(.sealFailed("\(error)"))
        }
    }

    private func finish(_ s: any CaptureRecording, reachedLimit: Bool) async throws -> WatchSavedNote {
        guard session === s, !saving else { throw WatchRecorderError.notRecording }
        saving = true
        let began = s.timeline.started
        let capture = recorder
        s.stop()
        publishStatus()
        defer {
            saving = false
            session = nil
            recorder = nil
            capture?.deactivate()
            publishStatus()
        }
        guard let p = profile() else { throw WatchRecorderError.notSetUp }   // the folder waits for the next sweep
        let note = try seal(folder: s.folder, id: s.id, listed: s.segments, finished: nil, started: began ?? now(), profile: p,
                            reachedLimit: reachedLimit, recovered: false)
        lastSaved = note
        return note
    }

    // MARK: Sweep

    /// Seals what recordings a crash, a quit or a restart left in `root` (at launch and when the app becomes active):
    /// `CaptureSegments.Leftover`'s rules, a folder that cannot be sealed stays. Returns the notes sealed.
    @discardableResult
    public func sweep() async -> [WatchSavedNote] {
        guard !saving, !starting else { return [] }
        guard let p = profile() else { return [] }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        var out: [WatchSavedNote] = []
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard folder != activeFolder, folder.standardizedFileURL != activeFolder?.standardizedFileURL,
                  let leftover = CaptureSegments.Leftover(folder: folder) else { continue }
            let id = leftover.id ?? UUID()
            do {
                let note = try seal(folder: folder, id: id, listed: leftover.segments, finished: leftover.finished,
                                    started: leftover.started ?? now(), profile: p, reachedLimit: false, recovered: true)
                out.append(note)
            } catch {
                continue   // nothing recorded was deleted by `seal`; the others wait
            }
        }
        if let last = out.last { lastSaved = last }
        return out
    }

    // MARK: Sealing

    /// "Watch voice note 2026-11-09 14:32" (vault text stays English, CLAUDE.md "Localization").
    public nonisolated static func title(_ started: Date, timeZone: TimeZone = .current) -> String {
        let base = CaptureWriter.defaultTitle(started, timeZone: timeZone)
        let prefix = "Voice note "
        return "Watch voice note " + (base.hasPrefix(prefix) ? String(base.dropFirst(prefix.count)) : base)
    }

    private func seal(folder: URL, id: UUID, listed: [URL], finished: Int?, started: Date, profile: WatchProfilePayload,
                      reachedLimit: Bool, recovered: Bool) throws -> WatchSavedNote {
        let files = CaptureSegments.files(listed: listed, in: folder)
        var held: [(url: URL, audio: CaptureSegments.Audio)] = []
        var data: [URL: Data] = [:]
        for url in files {
            let bytes = (try? BoundedRead.contents(of: url, maxBytes: ADTSToMP4.maxInputBytes + 1)) ?? Data()
            data[url] = bytes
            held.append((url, ADTSToMP4.audio(in: bytes)))
        }
        let segments: [URL]
        switch CaptureSegments.plan(held: held, listed: listed, finished: finished) {
        case .nothingRecorded:
            try? FileManager.default.removeItem(at: folder)
            throw WatchRecorderError.nothingRecorded
        case .completeSegmentUndecodable(let name): throw WatchRecorderError.segmentUndecodable(name)
        case .noReadableAudio: throw WatchRecorderError.noReadableAudio
        case .seal(let urls): segments = urls
        }
        let sealed: SealedCapture
        let info: ADTSToMP4.Info
        do {
            // A cut-off last frame is what a crash leaves; anything else in the middle fails and the folder stays.
            let (mp4, i) = try ADTSToMP4.remux(segments.compactMap { data[$0] }, tail: .dropPartial)
            info = i
            sealed = try CaptureWriter(profile: profile.profile).seal(audio: mp4, type: "audio/mp4", started: started,
                                                                     info: i.audioInfo, title: Self.title(started, timeZone: timeZone),
                                                                     id: id)
            try outbox.add(sealed, vault: profile.profile.vaultId)
        } catch {
            throw WatchRecorderError.sealFailed("\(error)")
        }
        try? FileManager.default.removeItem(at: folder)
        return WatchSavedNote(id: id, vault: profile.profile.vaultId, vaultName: profile.vaultName,
                              duration: info.duration, reachedLimit: reachedLimit, recovered: recovered)
    }
}
