import Foundation

/// One tap on a widget, the control or a voice note shortcut that reached Sempere, in whichever
/// process it reached (Settings ▸ Quick Voice Notes ▸ Recent Starts, with the starts). Kept
/// because a start log alone said nothing about taps that never started a recording: a tap that
/// went on into the app (setup needed, still saving), a Stop, an intent run without the app's
/// hooks, or a widget tap that opened the app instead of running its intent (docs/quick-capture.md
/// "Recent starts"). Holds no note content, no keys and no vault name.
public struct VoiceNoteTap: Codable, Equatable, Sendable, Identifiable {
    /// What reached Sempere.
    public enum Entry: String, Codable, Sendable {
        /// `VoiceNoteControlIntent`: the Control Center control, the Action button set to it, the widgets' button.
        case controlIntent
        /// `StartVoiceNoteIntent`: Siri, Shortcuts.
        case startIntent
        /// `StopVoiceNoteIntent`: the Live Activity's Stop.
        case stopIntent
        /// A widget tap that opened the app with `VoiceNoteLink.widgetTapURL` instead of running the
        /// widget's intent (the tap missed the button, or iOS opened the app instead).
        case widgetOpenedApp
    }

    /// What the tap was decided to do.
    public enum Decision: String, Codable, Sendable {
        case start
        case stop
        /// Went on into the app at Settings ▸ Quick Voice Notes (not set up, Live Activities off).
        case openSettings
        /// Went on into the app at the banner (still saving).
        case openRecording
        /// The intent ran where the app had not installed its hooks (`VoiceNoteActions`): in the
        /// widget extension, or before the app's launch finished.
        case unavailable
    }

    public var id = UUID()
    public var date: Date
    public var entry: Entry
    /// "app" or "widget extension" (`VoiceNoteTap.processName`).
    public var process: String
    /// The phase the widget or control was drawn with (`VoiceNoteStatus.Phase` raw value).
    public var shown: String?
    /// The app's live phase when the tap was decided.
    public var live: String?
    public var decision: Decision
    /// The intent's `systemContext.currentMode` at the start of `perform()`: whether iOS ran it in
    /// the background or had already brought the app forward.
    public var mode: String?
    /// `UIApplication.State` of the app ("active", "inactive", "background"); nil in the extension.
    public var appState: String?
    /// What failed after the decision (`continueInForeground` refused, a Stop that threw).
    public var error: String?

    public static let maxError = 400

    public init(id: UUID = UUID(), date: Date, entry: Entry, process: String, shown: String? = nil, live: String? = nil,
                decision: Decision, mode: String? = nil, appState: String? = nil, error: String? = nil) {
        self.id = id
        self.date = date
        self.entry = entry
        self.process = process
        self.shown = shown
        self.live = live
        self.decision = decision
        self.mode = mode
        self.appState = appState
        self.error = error
    }

    /// The process this code runs in: an app extension's bundle ends in `.appex`.
    public static var processName: String {
        Bundle.main.bundleURL.pathExtension == "appex" ? "widget extension" : "app"
    }

    /// One line for the unified log and Settings: technical values stay as the system gives them.
    public var summary: String {
        "entry=\(entry.rawValue) process=\(process) shown=\(shown ?? "-") live=\(live ?? "-") decision=\(decision.rawValue) "
            + "mode=\(mode ?? "-") app=\(appState ?? "-")" + (error.map { " error=\($0)" } ?? "")
    }
}

/// The last `capacity` taps, newest first, in one small JSON file in the App Group container, so
/// the widget extension can add to it too (protected until the first unlock after boot; before it,
/// or without an App Group, only the unified log has them: subsystem `io.github.anthonytw.sempere`,
/// category `quick-capture`, every field public, none personal, written through `logLine`).
public struct VoiceNoteTapLog: Sendable {
    /// How bad a log line is (the unified log's levels).
    public enum LogLevel: Sendable { case notice, error }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installedLogLine: (@Sendable (LogLevel, String) -> Void)?

    /// Where the log lines go: the unified log, installed at launch by the app and the widget extension
    /// (`VoiceNoteTapLog.installUnifiedLog`, `Apps/Sempere/SempereShared`); nowhere when nil (tests, Linux).
    public static var logLine: (@Sendable (LogLevel, String) -> Void)? {
        get { lock.withLock { installedLogLine } }
        set { lock.withLock { installedLogLine = newValue } }
    }

    public static let fileName = "VoiceNoteTaps.json"
    public static let capacity = 12
    public static let maxBytes = 64 * 1024

    public let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent(Self.fileName)
    }

    /// The App Group's log, or nil without an App Group (unsigned builds, Mac Catalyst).
    public static var shared: VoiceNoteTapLog? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VoiceNoteStatusStore.appGroup) else {
            return nil
        }
        return VoiceNoteTapLog(directory: dir)
        #else
        return nil
        #endif
    }

    /// The taps kept, newest first; none when the file is missing, protected, too large or not ours.
    public func read() -> [VoiceNoteTap] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(((try? decoder.decode([VoiceNoteTap].self, from: data)) ?? []).prefix(Self.capacity))
    }

    /// Adds `tap` in front and keeps the newest `capacity`. Never throws: a tap that cannot be kept
    /// is still in the unified log.
    public func append(_ tap: VoiceNoteTap) {
        let taps = Array(([tap] + read()).prefix(Self.capacity))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(taps)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
        } catch {
            Self.logLine?(.error, "could not keep the voice note tap: \(String(describing: error))")
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    /// The tap in the unified log (`logLine`), every field public (none is personal).
    public static func log(_ tap: VoiceNoteTap) {
        logLine?(.notice, "voice note tap \(tap.summary)")
    }
}
