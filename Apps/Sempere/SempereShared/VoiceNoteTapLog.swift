import Foundation
import os

private let tapLogger = Logger(subsystem: "io.github.anthonytw.sempere", category: "quick-capture")

/// One tap on a widget, the control or a voice note shortcut that reached Sempere, in whichever
/// process it reached (Settings ▸ Quick Voice Notes ▸ Recent Starts, with the starts). Kept
/// because a start log alone said nothing about taps that never started a recording: a tap that
/// went on into the app (setup needed, still saving), a Stop, an intent run without the app's
/// hooks, or a widget tap that opened the app instead of running its intent (docs/quick-capture.md
/// "Recent starts"). Holds no note content, no keys and no vault name.
struct VoiceNoteTap: Codable, Equatable, Sendable, Identifiable {
    /// What reached Sempere.
    enum Entry: String, Codable, Sendable {
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
    enum Decision: String, Codable, Sendable {
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

    var id = UUID()
    var date: Date
    var entry: Entry
    /// "app" or "widget extension" (`VoiceNoteTap.processName`).
    var process: String
    /// The phase the widget or control was drawn with (`VoiceNoteStatus.Phase` raw value).
    var shown: String?
    /// The app's live phase when the tap was decided.
    var live: String?
    var decision: Decision
    /// The intent's `systemContext.currentMode` at the start of `perform()`: whether iOS ran it in
    /// the background or had already brought the app forward.
    var mode: String?
    /// `UIApplication.State` of the app ("active", "inactive", "background"); nil in the extension.
    var appState: String?
    /// What failed after the decision (`continueInForeground` refused, a Stop that threw).
    var error: String?

    static let maxError = 400

    /// The process this code runs in: an app extension's bundle ends in `.appex`.
    static var processName: String {
        Bundle.main.bundleURL.pathExtension == "appex" ? "widget extension" : "app"
    }

    /// One line for the unified log and Settings: technical values stay as the system gives them.
    var summary: String {
        "entry=\(entry.rawValue) process=\(process) shown=\(shown ?? "-") live=\(live ?? "-") decision=\(decision.rawValue) "
            + "mode=\(mode ?? "-") app=\(appState ?? "-")" + (error.map { " error=\($0)" } ?? "")
    }
}

/// The last `capacity` taps, newest first, in one small JSON file in the App Group container, so
/// the widget extension can add to it too (protected until the first unlock after boot; before it,
/// or without an App Group, only the unified log has them: subsystem `io.github.anthonytw.sempere`,
/// category `quick-capture`, every field public, none personal).
struct VoiceNoteTapLog: Sendable {
    static let fileName = "VoiceNoteTaps.json"
    static let capacity = 12
    static let maxBytes = 64 * 1024

    let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent(Self.fileName)
    }

    /// The App Group's log, or nil without an App Group (unsigned builds, Mac Catalyst).
    static var shared: VoiceNoteTapLog? {
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
    func read() -> [VoiceNoteTap] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(((try? decoder.decode([VoiceNoteTap].self, from: data)) ?? []).prefix(Self.capacity))
    }

    /// Adds `tap` in front and keeps the newest `capacity`. Never throws: a tap that cannot be kept
    /// is still in the unified log.
    func append(_ tap: VoiceNoteTap) {
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
            tapLogger.error("could not keep the voice note tap: \(String(describing: error), privacy: .public)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    /// The tap in the unified log, every field public (none is personal).
    static func log(_ tap: VoiceNoteTap) {
        tapLogger.notice("voice note tap \(tap.summary, privacy: .public)")
    }
}
