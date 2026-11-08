import Foundation
import Observation
import Sempere
import SempereCaptureShared

/// An error as the diagnostics keep it: its Swift type, its `NSError` domain and code, and its
/// text (at most `maxDescription` characters). Never holds note content or keys: the errors it
/// is made from are the recorder's, ActivityKit's and the intent system's.
public struct VoiceNoteErrorInfo: Codable, Equatable, Sendable {
    public var type: String
    public var domain: String
    public var code: Int
    public var description: String

    public static let maxDescription = 400

    public init(type: String, domain: String, code: Int, description: String) {
        self.type = type
        self.domain = domain
        self.code = code
        self.description = String(description.prefix(Self.maxDescription))
    }

    public init(_ error: Error) {
        let ns = error as NSError
        // A Swift error's own text (`RecordingError` carries the audio system's domain and code in it);
        // an Objective-C error's localized text (its `description` repeats the whole user info).
        let text = Swift.type(of: error) is NSError.Type ? ns.localizedDescription : String(describing: error)
        self.init(type: String(reflecting: Swift.type(of: error)), domain: ns.domain, code: ns.code, description: text)
    }

    /// One line: "domain code: description".
    public var summary: String { "\(domain) \(code): \(description)" }
}

/// What asking for the recording's Live Activity did.
public enum VoiceNoteActivityRequest: Codable, Equatable, Sendable {
    /// `Activity.request` returned an activity.
    case started
    /// `Activity.request` threw.
    case failed(VoiceNoteErrorInfo)
    /// Not asked: Live Activities are off, the platform has none (a Mac), or tests turned them off.
    case notRequested(String)
}

/// One try at starting the recorder within a start attempt.
public struct VoiceNoteStartTry: Codable, Equatable, Sendable {
    /// `UIApplication.State` when the try began: "active", "inactive" or "background".
    public var appState: String
    /// Nil when the try ended before the Live Activity was asked for (not set up, no microphone).
    public var activity: VoiceNoteActivityRequest?
    /// The microphone permission as the try read it (`granted`, `denied`, `undetermined`; nil when the try ended before
    /// the microphone was asked: already recording, not set up, an unreadable or suspended profile, Live Activities off).
    public var microphone: String?
    /// Whether protected data was available (false before the first unlock after a restart; nil when the try ended
    /// before it was read: `alreadyRecording` is thrown first).
    public var protectedData: Bool?
    /// How the audio session was made active, before the Live Activity was asked for (`not mixable`,
    /// `mixable after a refusal`); nil when the try did not get that far.
    public var session: String?
    /// Nil when the recorder started.
    public var error: VoiceNoteErrorInfo?

    public init(appState: String, activity: VoiceNoteActivityRequest? = nil, microphone: String? = nil, protectedData: Bool? = nil,
                session: String? = nil, error: VoiceNoteErrorInfo? = nil) {
        self.appState = appState
        self.activity = activity
        self.microphone = microphone
        self.protectedData = protectedData
        self.session = session
        self.error = error
    }
}

/// One voice-note start, kept on this device for Settings ▸ Quick Voice Notes ▸ Recent Starts
/// (no device logs reach the developer). Only where it came from, the app's state, what
/// ActivityKit and the audio system answered, and how it ended: no note content, no keys,
/// no vault name.
public struct VoiceNoteStartAttempt: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Recording, from where it was asked (the background, for an intent).
        case recording
        /// Recording, after the intent continued in the app (the background start was refused).
        case recordingInApp
        case failed
    }

    /// The step after a refused background start: the intent continued in the app.
    public struct Foreground: Codable, Equatable, Sendable {
        /// `continueInForeground` threw (the user did not unlock, or the system refused).
        public var error: VoiceNoteErrorInfo?
        /// Whether the app became active within the wait (`QuickCapture.foregroundWait`).
        public var becameActive = false
        /// Seconds from the request to the app being active (or to the end of the wait).
        public var waited: Double = 0

        public init(error: VoiceNoteErrorInfo? = nil, becameActive: Bool = false, waited: Double = 0) {
            self.error = error
            self.becameActive = becameActive
            self.waited = waited
        }
    }

    public var id = UUID()
    public var date: Date
    public var source: VoiceNoteStartSource
    /// The intent's `systemContext.currentMode` (nil for a start in the app).
    public var intentMode: String?
    public var first: VoiceNoteStartTry
    public var foreground: Foreground?
    /// The start tried again with the app in front.
    public var retry: VoiceNoteStartTry?
    public var outcome: Outcome = .failed

    public init(id: UUID = UUID(), date: Date, source: VoiceNoteStartSource, intentMode: String? = nil, first: VoiceNoteStartTry,
                foreground: Foreground? = nil, retry: VoiceNoteStartTry? = nil, outcome: Outcome = .failed) {
        self.id = id
        self.date = date
        self.source = source
        self.intentMode = intentMode
        self.first = first
        self.foreground = foreground
        self.retry = retry
        self.outcome = outcome
    }

    /// The error that ended the attempt, if it failed.
    public var finalError: VoiceNoteErrorInfo? {
        guard outcome == .failed else { return nil }
        return retry?.error ?? foreground?.error ?? first.error
    }
}

/// The last `capacity` voice-note starts, newest first, in one small JSON file in Application
/// Support (not backed up, protected until the first unlock after boot: an intent may write it
/// with the device locked). `url` nil keeps them in memory (tests). Also written to `perf`'s log
/// (the app's unified log: subsystem `io.github.anthonytw.sempere`, category `quick-capture`), every
/// field public: none is personal.
@MainActor
@Observable
public final class VoiceNoteStartLog {
    public nonisolated static let capacity = 8
    public nonisolated static let maxFileBytes = 64 * 1024
    /// The log category of the lines (`PerfSink.log`).
    public nonisolated static let logCategory = "quick-capture"

    public nonisolated static var defaultURL: URL {
        AppSupport.folder("QuickCaptureDiagnostics").appendingPathComponent("recent-starts.json")
    }

    @ObservationIgnored public let url: URL?
    @ObservationIgnored private let perf: any PerfSink
    public private(set) var attempts: [VoiceNoteStartAttempt] = []

    public init(url: URL?, perf: any PerfSink = NoPerfSink()) {
        self.url = url
        self.perf = perf
        attempts = Self.read(url)
    }

    /// The attempts in `url`; none when it is missing, too large or does not decode.
    public nonisolated static func read(_ url: URL?) -> [VoiceNoteStartAttempt] {
        guard let url, let data = try? BoundedRead.contents(of: url, maxBytes: maxFileBytes) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(((try? decoder.decode([VoiceNoteStartAttempt].self, from: data)) ?? []).prefix(capacity))
    }

    /// Reads the file again and keeps this launch's starts too (protected data became available).
    public func reload() {
        var known = Set(attempts.map(\.id))
        let onDisk = Self.read(url).filter { known.insert($0.id).inserted }
        attempts = Array((attempts + onDisk).sorted { $0.date > $1.date }.prefix(Self.capacity))
    }

    public func append(_ attempt: VoiceNoteStartAttempt) {
        // The file may hold starts this launch could not read (it began before the first unlock after a
        // restart): merged, never overwritten with only this launch's.
        var known = Set(attempts.map(\.id))
        let onDisk = Self.read(url).filter { known.insert($0.id).inserted }
        let merged = (attempts + onDisk).sorted { $0.date > $1.date }
        attempts = Array(([attempt] + merged).prefix(Self.capacity))
        perf.log(.notice, Self.logCategory, Self.logLine(attempt))
        if let url {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                #if canImport(Darwin)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try encoder.encode(attempts).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(attempts).write(to: url, options: .atomic)
                #endif
            } catch {
                // Before the first unlock after boot nothing can be written; the log still has it.
                perf.log(.error, Self.logCategory, "could not keep the voice note start: \(String(describing: error))")
            }
        }
    }

    public func clear() {
        attempts = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// The attempt as one log line, every field public (none is personal).
    public nonisolated static func logLine(_ a: VoiceNoteStartAttempt) -> String {
        let first = describe(a.first)
        let foreground = a.foreground.map { f in
            "continued in app: active=\(f.becameActive) after \(String(format: "%.1f", f.waited)) s" + (f.error.map { ", error \($0.summary)" } ?? "")
        } ?? "-"
        let retry = a.retry.map(describe) ?? "-"
        return "voice note start source=\(a.source.rawValue) mode=\(a.intentMode ?? "-") outcome=\(a.outcome.rawValue) "
            + "first=[\(first)] foreground=[\(foreground)] retry=[\(retry)]"
    }

    public nonisolated static func describe(_ t: VoiceNoteStartTry) -> String {
        let activity: String
        switch t.activity {
        case .started: activity = "started"
        case .failed(let e): activity = "failed \(e.type) \(e.summary)"
        case .notRequested(let why): activity = "not requested (\(why))"
        case nil: activity = "-"
        }
        var extra = ""
        if let m = t.microphone { extra += " mic=\(m)" }
        if let p = t.protectedData { extra += " protectedData=\(p)" }
        if let s = t.session { extra += " session=\(s)" }
        return "app=\(t.appState)\(extra) activity=\(activity) error=\(t.error.map { "\($0.type) \($0.summary)" } ?? "none")"
    }
}
