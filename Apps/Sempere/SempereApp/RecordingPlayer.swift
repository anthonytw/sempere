import AVFoundation
import Foundation
import Sempere
import SempereAppCore

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
