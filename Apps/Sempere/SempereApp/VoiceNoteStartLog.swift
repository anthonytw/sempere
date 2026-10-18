import Foundation
import Observation
import os
import Sempere
import UIKit

private let startLogger = Logger(subsystem: "io.github.anthonytw.sempere", category: "quick-capture")

/// An error as the diagnostics keep it: its Swift type, its `NSError` domain and code, and its
/// text (at most `maxDescription` characters). Never holds note content or keys: the errors it
/// is made from are the recorder's, ActivityKit's and the intent system's.
struct VoiceNoteErrorInfo: Codable, Equatable, Sendable {
    var type: String
    var domain: String
    var code: Int
    var description: String

    static let maxDescription = 400

    init(type: String, domain: String, code: Int, description: String) {
        self.type = type
        self.domain = domain
        self.code = code
        self.description = String(description.prefix(Self.maxDescription))
    }

    init(_ error: Error) {
        let ns = error as NSError
        // A Swift error's own text (`RecordingError` carries the audio system's domain and code in it);
        // an Objective-C error's localized text (its `description` repeats the whole user info).
        let text = Swift.type(of: error) is NSError.Type ? ns.localizedDescription : String(describing: error)
        self.init(type: String(reflecting: Swift.type(of: error)), domain: ns.domain, code: ns.code, description: text)
    }

    /// One line: "domain code: description".
    var summary: String { "\(domain) \(code): \(description)" }
}

/// What asking for the recording's Live Activity did.
enum VoiceNoteActivityRequest: Codable, Equatable, Sendable {
    /// `Activity.request` returned an activity.
    case started
    /// `Activity.request` threw.
    case failed(VoiceNoteErrorInfo)
    /// Not asked: Live Activities are off, the platform has none (a Mac), or tests turned them off.
    case notRequested(String)
}

/// One try at starting the recorder within a start attempt.
struct VoiceNoteStartTry: Codable, Equatable, Sendable {
    /// `UIApplication.State` when the try began: "active", "inactive" or "background".
    var appState: String
    /// Nil when the try ended before the Live Activity was asked for (not set up, no microphone).
    var activity: VoiceNoteActivityRequest?
    /// Nil when the recorder started.
    var error: VoiceNoteErrorInfo?
}

/// One voice-note start, kept on this device for Settings ▸ Quick Voice Notes ▸ Recent Starts
/// (no device logs reach the developer). Only where it came from, the app's state, what
/// ActivityKit and the audio system answered, and how it ended: no note content, no keys,
/// no vault name.
struct VoiceNoteStartAttempt: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable {
        /// Recording, from where it was asked (the background, for an intent).
        case recording
        /// Recording, after the intent continued in the app (the background start was refused).
        case recordingInApp
        case failed
    }

    /// The step after a refused background start: the intent continued in the app.
    struct Foreground: Codable, Equatable, Sendable {
        /// `continueInForeground` threw (the user did not unlock, or the system refused).
        var error: VoiceNoteErrorInfo?
        /// Whether the app became active within the wait (`QuickCapture.foregroundWait`).
        var becameActive = false
        /// Seconds from the request to the app being active (or to the end of the wait).
        var waited: Double = 0
    }

    var id = UUID()
    var date: Date
    var source: VoiceNoteStartSource
    /// The intent's `systemContext.currentMode` (nil for a start in the app).
    var intentMode: String?
    var first: VoiceNoteStartTry
    var foreground: Foreground?
    /// The start tried again with the app in front.
    var retry: VoiceNoteStartTry?
    var outcome: Outcome = .failed

    /// The error that ended the attempt, if it failed.
    var finalError: VoiceNoteErrorInfo? {
        guard outcome == .failed else { return nil }
        return retry?.error ?? foreground?.error ?? first.error
    }
}

/// The last `capacity` voice-note starts, newest first, in one small JSON file in Application
/// Support (not backed up, protected until the first unlock after boot: an intent may write it
/// with the device locked). `url` nil keeps them in memory (tests). Also written to the unified
/// log (subsystem `io.github.anthonytw.sempere`, category `quick-capture`), every field public:
/// none is personal.
@MainActor
@Observable
final class VoiceNoteStartLog {
    nonisolated static let capacity = 8
    nonisolated static let maxFileBytes = 64 * 1024

    nonisolated static var defaultURL: URL {
        AppSupport.folder("QuickCaptureDiagnostics").appendingPathComponent("recent-starts.json")
    }

    @ObservationIgnored let url: URL?
    private(set) var attempts: [VoiceNoteStartAttempt] = []

    init(url: URL?) {
        self.url = url
        attempts = Self.read(url)
    }

    /// The attempts in `url`; none when it is missing, too large or does not decode.
    nonisolated static func read(_ url: URL?) -> [VoiceNoteStartAttempt] {
        guard let url, let data = try? BoundedRead.contents(of: url, maxBytes: maxFileBytes) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(((try? decoder.decode([VoiceNoteStartAttempt].self, from: data)) ?? []).prefix(capacity))
    }

    func append(_ attempt: VoiceNoteStartAttempt) {
        attempts = Array(([attempt] + attempts).prefix(Self.capacity))
        Self.log(attempt)
        if let url {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try encoder.encode(attempts).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // Before the first unlock after boot nothing can be written; the unified log still has it.
                startLogger.error("could not keep the voice note start: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func clear() {
        attempts = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// The attempt in the unified log, every field public (none is personal).
    nonisolated static func log(_ a: VoiceNoteStartAttempt) {
        let first = describe(a.first)
        let foreground = a.foreground.map { f in
            "continued in app: active=\(f.becameActive) after \(String(format: "%.1f", f.waited)) s" + (f.error.map { ", error \($0.summary)" } ?? "")
        } ?? "-"
        let retry = a.retry.map(describe) ?? "-"
        startLogger.notice("""
            voice note start source=\(a.source.rawValue, privacy: .public) mode=\(a.intentMode ?? "-", privacy: .public) outcome=\(a.outcome.rawValue, privacy: .public) \
            first=[\(first, privacy: .public)] foreground=[\(foreground, privacy: .public)] retry=[\(retry, privacy: .public)]
            """)
    }

    nonisolated static func describe(_ t: VoiceNoteStartTry) -> String {
        let activity: String
        switch t.activity {
        case .started: activity = "started"
        case .failed(let e): activity = "failed \(e.type) \(e.summary)"
        case .notRequested(let why): activity = "not requested (\(why))"
        case nil: activity = "-"
        }
        return "app=\(t.appState) activity=\(activity) error=\(t.error.map { "\($0.type) \($0.summary)" } ?? "none")"
    }
}

extension UIApplication.State {
    /// How the diagnostics name it.
    var diagnosticName: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

/// Waits for the app to become active, at most `timeout`: true when it is active (at once, if it
/// already is), false when the time ran out. On a notification, never polling: the observer is
/// registered before `isActive` is checked, so an activation in between is not missed. Not
/// cancelled with the task that awaits it (an intent's): it ends by the notification or the timeout.
@MainActor
enum AppActivation {
    static func wait(timeout: Duration, center: NotificationCenter = .default,
                     name: Notification.Name = UIApplication.didBecomeActiveNotification,
                     isActive: @MainActor () -> Bool) async -> Bool {
        let gate = Gate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gate.continuation = continuation
            gate.observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { gate.finish(true, center: center) }
            }
            if isActive() {
                gate.finish(true, center: center)
                return
            }
            gate.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.finish(false, center: center)
            }
        }
    }

    /// Resumes the continuation once, and removes the observer and the timer.
    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Bool, Never>?
        var observer: NSObjectProtocol?
        var timer: Task<Void, Never>?

        func finish(_ value: Bool, center: NotificationCenter) {
            guard let c = continuation else { return }
            continuation = nil
            if let observer { center.removeObserver(observer) }
            observer = nil
            timer?.cancel()
            timer = nil
            c.resume(returning: value)
        }
    }
}
