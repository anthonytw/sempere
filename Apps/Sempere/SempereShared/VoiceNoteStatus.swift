import Foundation

/// What the Lock Screen and Home Screen widgets and the Control Center
/// control show for quick voice notes (docs/quick-capture.md "Surfaces"). The
/// app writes it (`QuickCapture.publishStatus`) into the App Group container
/// after every change, then reloads the widgets and controls; the widget
/// extension only reads it. It says nothing about any note: only whether
/// quick voice notes are set up and whether one is being recorded.
struct VoiceNoteStatus: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// No capture profile on this device: "Enable Quick Voice Notes" is off.
        case notSetUp
        /// Set up, but iOS ends an intent's recording without a Live Activity.
        case liveActivitiesOff
        /// One tap records.
        case ready
        case recording
        /// Stopped; being sealed into the inbox.
        case saving
    }

    var phase: Phase
    /// When the recording started (`recording`, `saving`).
    var started: Date?

    init(phase: Phase, started: Date? = nil) {
        self.phase = phase
        self.started = started
    }

    /// What is shown when no status can be read: before the device's first
    /// unlock (the file is protected until then, and nothing can record before
    /// it anyway: the capture profile is a Keychain item readable only after
    /// it), in a build without the App Group, or before the app first ran. The
    /// plain record button, as before the status existed.
    static let unknown = VoiceNoteStatus(phase: .ready)

    /// The status for the recorder's state. A recording in progress wins over
    /// the setup checks (the profile may be turned off while it records: it
    /// still needs its Stop).
    static func make(setUp: Bool, activitiesEnabled: Bool, recording: Bool, saving: Bool, started: Date?) -> VoiceNoteStatus {
        if recording { return VoiceNoteStatus(phase: .recording, started: started) }
        if saving { return VoiceNoteStatus(phase: .saving, started: started) }
        if !setUp { return VoiceNoteStatus(phase: .notSetUp) }
        if !activitiesEnabled { return VoiceNoteStatus(phase: .liveActivitiesOff) }
        return VoiceNoteStatus(phase: .ready)
    }

    /// What a tap does.
    enum Action: Equatable, Sendable {
        case start
        case stop
        /// Opens the app at `link` (the extension cannot fix the setup itself).
        case open(VoiceNoteLink)
    }

    var action: Action {
        switch phase {
        case .ready: return .start
        case .recording: return .stop
        case .saving: return .open(.recording)
        case .notSetUp, .liveActivitiesOff: return .open(.settings)
        }
    }

    /// What a tap on the control does. Decided from the app's live state, but
    /// a Stop the control still showed for a recording that is gone (its
    /// process died) never starts a new one: it stops, which only ends the
    /// orphaned Live Activity (#106).
    static func controlAction(shown: Phase?, live: VoiceNoteStatus) -> Action {
        if shown == .recording, live.action == .start { return .stop }
        return live.action
    }

    /// The control's and the widgets' label.
    var title: String {
        switch phase {
        case .ready: return String(localized: "Voice Note")
        case .recording: return String(localized: "Stop Voice Note")
        case .saving: return String(localized: "Saving Voice Note")
        case .notSetUp: return String(localized: "Set Up Voice Notes")
        case .liveActivitiesOff: return String(localized: "Live Activities Off")
        }
    }

    /// A second line where there is room (rectangular widget, control subtitle).
    var subtitle: String {
        switch phase {
        case .ready: return String(localized: "Tap to record")
        case .recording: return String(localized: "Recording…", comment: "Widget and control subtitle: a voice note is being recorded")
        case .saving: return String(localized: "Encrypting…")
        case .notSetUp: return String(localized: "Turn on in Sempere")
        case .liveActivitiesOff: return String(localized: "Needed to record")
        }
    }

    /// An SF Symbol (system symbols only: no asset catalog to read, which a
    /// Lock Screen widget may not be able to before the first unlock).
    var symbol: String {
        switch phase {
        case .ready: return "mic.fill"
        case .recording: return "stop.fill"
        case .saving: return "arrow.down.doc.fill"
        case .notSetUp, .liveActivitiesOff: return "mic.slash.fill"
        }
    }

    /// Whether the control shows as "on" (tinted).
    var isActive: Bool { phase == .recording || phase == .saving }

    /// Widget and control kinds, for reloads.
    static let widgetKind = "io.github.anthonytw.sempere.voice-note"
    static let controlKind = "io.github.anthonytw.sempere.voice-note-control"
}

/// Where a tap on a widget, the control or the Live Activity opens the app
/// (`sempere://quick-voice/…`, `CFBundleURLTypes` in SempereInfo.plist).
enum VoiceNoteLink: String, CaseIterable, Equatable, Sendable {
    /// The recording banner (a voice note being recorded or just saved).
    case recording
    /// Settings ▸ Quick Voice Notes.
    case settings

    static let scheme = "sempere"
    static let host = "quick-voice"

    var url: URL {
        // Built from constants: cannot fail.
        URL(string: "\(Self.scheme)://\(Self.host)/\(rawValue)") ?? URL(fileURLWithPath: "/")
    }

    /// What the app does with a URL it is opened with (`RootView.onOpenURL`).
    enum Route: Equatable {
        /// A quick voice link.
        case link(VoiceNoteLink)
        /// Another `sempere:` URL (a link from a newer version, or typed or
        /// sent by anyone): ignored, never opened as a vault.
        case ignore
        /// Anything else: a file (a vault tapped in Files).
        case file
    }

    static func route(_ url: URL) -> Route {
        if let link = VoiceNoteLink(url: url) { return .link(link) }
        return url.scheme?.lowercased() == scheme ? .ignore : .file
    }

    /// The link `url` names, or nil for any other URL (a vault opened from Files).
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let link = VoiceNoteLink(rawValue: path) else { return nil }
        self = link
    }
}

/// How a stopped voice note ended, for the Live Activity's last state and
/// the app's banner ("say where the note went").
enum VoiceNoteResult: String, Codable, Hashable, Sendable {
    /// Sealed into the vault's `inbox/`.
    case savedToInbox
    /// Sealed into this device's queue: the vault folder was out of reach.
    case savedOnDevice
    case failed

    var title: String {
        switch self {
        case .savedToInbox: return String(localized: "Saved to Inbox")
        case .savedOnDevice: return String(localized: "Saved on This Device")
        case .failed: return String(localized: "Not Saved")
        }
    }

    var detail: String {
        switch self {
        case .savedToInbox: return String(localized: "Encrypted. It becomes a note the next time you unlock the vault.")
        case .savedOnDevice: return String(localized: "Encrypted. It moves to the vault's inbox when Sempere can reach the vault.")
        case .failed: return String(localized: "Open Sempere for details.")
        }
    }

    var symbol: String {
        switch self {
        case .savedToInbox, .savedOnDevice: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// How long the Live Activity and the banner keep showing it.
    var shownFor: TimeInterval { self == .failed ? 12 : 5 }
}

/// The status file in the App Group container. Written whole and atomically
/// by the app, read by the widget extension. It is protected until the first
/// unlock after boot (the default class, stated explicitly): before that a
/// read fails and the widgets show `VoiceNoteStatus.unknown`.
struct VoiceNoteStatusStore: Sendable {
    static let appGroup = "group.io.github.anthonytw.sempere"
    static let fileName = "VoiceNoteStatus.json"
    /// Far above any status (a few dozen bytes); a larger file is not ours.
    static let maxBytes = 4096

    let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent(Self.fileName)
    }

    /// The App Group's store, or nil when the build has no App Group (unsigned
    /// builds, a provisioning profile without it).
    static var shared: VoiceNoteStatusStore? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return VoiceNoteStatusStore(directory: dir)
        #else
        return nil
        #endif
    }

    /// The stored status, or nil (missing, protected, too large or not a status).
    func read() -> VoiceNoteStatus? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes else { return nil }
        return try? JSONDecoder().decode(VoiceNoteStatus.self, from: data)
    }

    /// Stores `status`. Returns whether it differs from what was stored (the
    /// caller reloads the widgets only then).
    @discardableResult
    func write(_ status: VoiceNoteStatus) throws -> Bool {
        if read() == status { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(status)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        return true
    }
}
