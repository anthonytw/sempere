import AVFoundation
import Foundation
import Observation
import Sempere

/// What plays a recording's audio file: `AVAudioPlayer` in the app, a fake in tests.
@MainActor
protocol AudioPlaybackBackend: AnyObject {
    func load(_ url: URL) throws -> Double
    func play()
    func pause()
    func seek(to seconds: Double)
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    func unload()
}

@MainActor
final class AVAudioPlaybackBackend: AudioPlaybackBackend {
    private var player: AVAudioPlayer?

    func load(_ url: URL) throws -> Double {
        let session = AVAudioSession.sharedInstance()
        // While a recording runs the session stays `.playAndRecord`.
        if RecordingSession.active?.isActive != true {
            try? session.setCategory(.playback, mode: .spokenAudio)
        }
        try? session.setActive(true)
        let p = try AVAudioPlayer(contentsOf: url)
        p.prepareToPlay()
        player = p
        return p.duration
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
    func seek(to seconds: Double) { player?.currentTime = max(0, seconds) }
    var currentTime: Double { player?.currentTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    func unload() {
        player?.stop()
        player = nil
        if RecordingSession.active?.isActive != true {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Plays one of a note's recordings (docs/attachments.md §9): play, pause,
/// seek, and the position, refreshed ten times a second while playing, which
/// drives the stroke highlights and the transcript's read-back word. The
/// audio comes from the model's `BlobCache` (a verified temporary file);
/// the file is released when another recording is loaded or playback stops.
@MainActor
@Observable
final class RecordingPlayer {
    private(set) var recording: Recording?
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// The transcript of the loaded recording, once read.
    var transcript: Transcript?

    @ObservationIgnored private let backend: AudioPlaybackBackend
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Called with every new position (the editor's stroke highlights).
    @ObservationIgnored var onPosition: ((Recording, Double) -> Void)?
    /// Called when a loaded file is no longer used (`BlobCache.release`).
    @ObservationIgnored var onUnload: ((Recording) -> Void)?

    init(backend: AudioPlaybackBackend? = nil) {
        self.backend = backend ?? AVAudioPlaybackBackend()
    }

    /// Loads `recording` from its (verified, local) audio file.
    func load(_ recording: Recording, file: URL) throws {
        unloadCurrent()
        duration = try backend.load(file)
        self.recording = recording
        position = 0
        transcript = nil
    }

    func play() {
        guard recording != nil else { return }
        backend.play()
        isPlaying = backend.isPlaying
        startTicker()
    }

    func pause() {
        backend.pause()
        isPlaying = false
        update()
        ticker?.cancel()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// Moves to `seconds` (clamped to the recording).
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        backend.seek(to: min(max(0, seconds), duration))
        update()
    }

    /// Stops and unloads.
    func stop() {
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

    func update() {
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
                self?.update()
            }
        }
    }
}
