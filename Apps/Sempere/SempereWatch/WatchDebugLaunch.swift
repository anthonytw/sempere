#if DEBUG
import Age
import Foundation
import Sempere
import SempereCapture
import SempereCaptureShared

// Debug builds of the watch app start in a state set by launch environment variables, for scripted simulator runs
// (`SempereWatchUITests`), as `DebugLaunch` does for the iPad. With `xcrun simctl launch` prefix each with `SIMCTL_CHILD_`;
// a UI test passes them in `XCUIApplication.launchEnvironment`. The simulator has no microphone to speak of: the recorder
// is a fake that writes real ADTS frames, so the seal, the outbox and the hand-off run for real; this tests the UI and the
// outbox, not audio (docs/design/1.1-watch.md §5).
//
//   SEMPERE_WATCH_DEBUG=1             use a throwaway folder, an in-memory Keychain, the fake recorder and no WatchConnectivity
//   SEMPERE_WATCH_DEBUG_PROFILE=1     start provisioned (a profile for a vault called "Debug Vault")
//   SEMPERE_WATCH_DEBUG_UNSENT=N      N sealed notes already in the outbox
//   SEMPERE_WATCH_DEBUG_BLOCK=mic|full|storage   why a start is refused (microphone denied, outbox full, low storage)
enum WatchDebugLaunch {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var isActive: Bool { env["SEMPERE_WATCH_DEBUG"] == "1" }

    @MainActor
    static func environment() -> WatchEnvironment? {
        guard isActive else { return nil }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("SempereWatchDebug-\(UUID().uuidString)", isDirectory: true)
        let secrets = MemoryWatchSecretStore()
        let transport = DebugWatchTransport()
        var limits = WatchOutbox.Limits()
        var free: Int64? = nil
        switch env["SEMPERE_WATCH_DEBUG_BLOCK"] {
        case "full": limits.maxFiles = 0
        case "storage": free = 1 << 20
        default: break
        }
        if env["SEMPERE_WATCH_DEBUG_PROFILE"] == "1" { seedProfile(secrets) }
        let audio = FakeWatchAudio()
        audio.microphoneAllowed = env["SEMPERE_WATCH_DEBUG_BLOCK"] != "mic"
        var environment = WatchEnvironment(secrets: secrets, audio: audio, transport: transport, support: support, statusStore: nil,
                                           freeBytes: { free }, haptic: { _ in }, outboxLimits: limits)
        environment.reloadWidgets = {}
        if let n = env["SEMPERE_WATCH_DEBUG_UNSENT"].flatMap({ Int($0) }), n > 0 { seedOutbox(n, in: support, secrets: secrets) }
        return environment
    }

    /// The profile of the debug vault (and of the unit tests' phone).
    static let profile: CaptureProfile = {
        let identity = (try? NativeIdentity.generate(.postQuantum))
        return CaptureProfile(vaultId: UUID(), recipients: [identity?.recipient.string ?? ""], key: Data(repeating: 7, count: 32),
                              device: "0badf00d", notebook: "Inbox", recipient: String(repeating: "a", count: 64), epoch: 1,
                              epochId: Data(repeating: 9, count: 32))
    }()

    static func seedProfile(_ secrets: MemoryWatchSecretStore) {
        let payload = WatchProfilePayload(profile: profile, vaultName: "Debug Vault", seq: 0, issued: Date())
        try? WatchSecrets(store: secrets).save(WatchProfileState(seq: 0, payload: payload))
    }

    /// `n` sealed notes in the outbox, sealed with the debug profile.
    @MainActor
    static func seedOutbox(_ n: Int, in support: URL, secrets: MemoryWatchSecretStore) {
        guard let outbox = try? WatchOutbox(directory: support.appendingPathComponent("Outbox", isDirectory: true)) else { return }
        for i in 0..<n {
            guard let sealed = try? CaptureWriter(profile: profile).seal(audio: Data("debug \(i)".utf8), started: Date(), id: UUID()) else { continue }
            _ = try? outbox.add(sealed, vault: profile.vaultId)
        }
    }
}

/// A transport with no phone: accepts every file and never acknowledges one, so unsent notes stay unsent.
@MainActor
final class DebugWatchTransport: WatchTransport {
    func activate() {}
    func requestProvisioning(recipient: String) {}
    func transfer(file: URL, meta: WatchTransferMeta) -> Bool { true }
    var pendingTransfers: Set<UUID> { [] }
}

/// A microphone that records frames of silence-shaped ADTS (24 kHz, mono, AAC-LC): headers the muxer reads, no real audio.
@MainActor
final class FakeWatchAudio: CaptureAudio {
    var microphoneAllowed = true
    func requestMicrophone() async -> Bool { microphoneAllowed }
    var microphonePermission: String { microphoneAllowed ? "granted" : "denied" }
    var preferredFormat: RecordingFormat { WatchRecorder.format }
    func makeRecorder() -> any CaptureRecorder { FakeWatchRecorder() }
}

@MainActor
final class FakeWatchRecorder: CaptureRecorder {
    func activateSession(mixable: Bool) async throws {}
    func deactivate() {}
    func makeRecording(format: RecordingFormat, root: URL, segmentExtension: String) -> any CaptureRecording {
        FakeWatchRecording(root: root, segmentExtension: segmentExtension)
    }
}

@MainActor
final class FakeWatchRecording: CaptureRecording {
    let id = UUID()
    let folder: URL
    private(set) var segments: [URL] = []
    private(set) var timeline = RecordingTimeline()
    private(set) var isActive = false
    let isPaused = false
    var onStoppedBySystem: (@MainActor () -> Void)?
    private let ext: String

    init(root: URL, segmentExtension: String) {
        folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        ext = segmentExtension
    }

    func start() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        segments = [folder.appendingPathComponent("segment-001.\(ext)")]
        timeline.resume(at: Date())
        isActive = true
        try writeManifest(finished: 0)
        try Data().write(to: segments[0])
    }

    func stop() {
        guard isActive else { return }
        timeline.stop(at: Date())
        isActive = false
        // About 23 frames a second at 24 kHz, at least a few so the note has a duration.
        let frames = max(8, Int(timeline.audioLength(at: Date()) * 23))
        var data = Data()
        for i in 0..<frames { data.append(Self.frame(seed: UInt8(i & 0x3F))) }
        try? data.write(to: segments[0])
        try? writeManifest(finished: 1)
    }

    func discardFiles() { try? FileManager.default.removeItem(at: folder) }

    private func writeManifest(finished: Int) throws {
        let m = RecordingManifest(note: id, recording: id, started: timeline.started, codec: "aac",
                                  segments: segments.map(\.lastPathComponent), finished: finished)
        try JSONEncoder().encode(m).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
    }

    /// One ADTS frame: a 7 byte header (AAC-LC, 24 kHz, mono) and 24 payload bytes.
    static func frame(seed: UInt8) -> Data {
        let length = 7 + 24
        var d = Data([0xFF, 0xF1, UInt8((1 << 6) | (6 << 2)), UInt8(((1 & 3) << 6) | ((length >> 11) & 3)),
                      UInt8((length >> 3) & 0xFF), UInt8(((length & 7) << 5) | 0x1F), 0xFC])
        d.append(contentsOf: (0..<24).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 7) })
        return d
    }
}
#endif
