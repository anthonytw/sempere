import Foundation
import Observation
import Sempere

/// What plays a recording's audio file: `AVAudioPlayer` in the app (`AVAudioPlaybackBackend`), a fake in tests.
@MainActor
public protocol AudioPlaybackBackend: AnyObject {
    func load(_ url: URL) throws -> Double
    func play()
    func pause()
    func seek(to seconds: Double)
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    func unload()
}

/// Plays nothing (the headless services' backend): a file loads as its probed length, and the position is where it
/// was sought to.
@MainActor
public final class SilentPlaybackBackend: AudioPlaybackBackend {
    public private(set) var currentTime: Double = 0
    public private(set) var isPlaying = false

    public init() {}

    public func load(_ url: URL) throws -> Double {
        currentTime = 0
        return (try? AudioProbe.probe(file: url).duration) ?? 0
    }

    public func play() { isPlaying = true }
    public func pause() { isPlaying = false }
    public func seek(to seconds: Double) { currentTime = seconds }
    public func unload() { isPlaying = false; currentTime = 0 }
}

/// Plays one of a note's recordings (docs/attachments.md §9): play, pause,
/// seek, and the position, refreshed ten times a second while playing, which
/// drives the stroke highlights and the transcript's read-back word. The
/// audio comes from the model's `BlobCache` (a verified temporary file);
/// the file is released when another recording is loaded or playback stops.
@MainActor
@Observable
public final class RecordingPlayer {
    public private(set) var recording: Recording?
    public private(set) var position: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isPlaying = false
    /// The transcript of the loaded recording, once read.
    public var transcript: Transcript?

    @ObservationIgnored private let backend: any AudioPlaybackBackend
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Called with every new position (the editor's stroke highlights).
    @ObservationIgnored public var onPosition: ((Recording, Double) -> Void)?
    /// Called when a loaded file is no longer used (`BlobCache.release`).
    @ObservationIgnored public var onUnload: ((Recording) -> Void)?

    public init(backend: any AudioPlaybackBackend) {
        self.backend = backend
    }

    /// Loads `recording` from its (verified, local) audio file.
    public func load(_ recording: Recording, file: URL) throws {
        unloadCurrent()
        duration = try backend.load(file)
        self.recording = recording
        position = 0
        transcript = nil
    }

    public func play() {
        guard recording != nil else { return }
        backend.play()
        isPlaying = backend.isPlaying
        startTicker()
    }

    public func pause() {
        backend.pause()
        isPlaying = false
        update()
        ticker?.cancel()
    }

    public func toggle() { isPlaying ? pause() : play() }

    /// Moves to `seconds` (clamped to the recording).
    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        backend.seek(to: min(max(0, seconds), duration))
        update()
    }

    /// Stops and unloads.
    public func stop() {
        ticker?.cancel()
        unloadCurrent()
        isPlaying = false
    }

    private func unloadCurrent() {
        backend.unload()
        if let r = recording { onUnload?(r) }
        recording = nil
        position = 0
        duration = 0
    }

    public func update() {
        position = backend.currentTime
        let playing = backend.isPlaying
        if isPlaying && !playing { ticker?.cancel() }   // reached the end
        isPlaying = playing
        if let r = recording { onPosition?(r, position) }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }   // the player is gone: so is its ticker
                self.update()
            }
        }
    }
}
