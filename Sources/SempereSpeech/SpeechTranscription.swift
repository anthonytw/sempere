import Foundation
import Sempere
#if canImport(Speech)
import AVFoundation
import CoreMedia
import Speech
#endif

/// Why a recording could not be transcribed.
public enum SpeechTranscriptionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// This platform has no Speech framework (Linux).
    case unavailable
    /// No on-device recogniser for the language.
    case unsupportedLanguage(String)
    /// Speech recognition is not allowed (Settings ▸ Privacy ▸ Speech Recognition).
    case notAuthorized
    /// The SFSpeechRecognizer fallback needs a usage description (an app's Info.plist).
    case needsUsageDescription
    /// The engine asked for cannot run here (OS too old, device not supported).
    case engineUnavailable(String)
    /// The recogniser failed.
    case failed(String)

    public var description: String {
        switch self {
        case .unavailable:
            return "transcription needs Apple's Speech framework, so it runs only on macOS, iOS and iPadOS (or in the app)"
        case .unsupportedLanguage(let l): return "no on-device speech recogniser for \(l) on this device"
        case .notAuthorized: return "speech recognition is not allowed (System Settings ▸ Privacy & Security ▸ Speech Recognition)"
        case .needsUsageDescription:
            return "the SFSpeechRecognizer fallback needs an app with a speech recognition usage description; "
                + "on macOS 26 and later SpeechTranscriber is used instead"
        case .engineUnavailable(let why): return why
        case .failed(let why): return "transcription failed: \(why)"
        }
    }
}

/// On-device transcription of a recording (docs/attachments.md §13
/// "Transcription"): SpeechAnalyzer with SpeechTranscriber on iOS / macOS 26,
/// else SFSpeechRecognizer with on-device recognition required. Never a
/// server: a language without an on-device model is an error, not a network
/// request. Shared by the app and `sempere transcribe`.
public enum SpeechTranscription {
    /// What to transcribe with.
    public struct Options: Sendable {
        /// An explicit language (BCP 47 or a locale identifier); wins over the note's.
        public var language: String?
        /// The note's language (format.md §5.4 `lang`), when it has one.
        public var noteLanguage: String?
        /// Nil picks the best available engine.
        public var engine: TranscriptionEngine?
        /// Let SpeechTranscriber download its on-device model for the language
        /// (Apple's asset service; the audio never leaves the device).
        public var allowModelDownload: Bool

        public init(language: String? = nil, noteLanguage: String? = nil, engine: TranscriptionEngine? = nil,
                    allowModelDownload: Bool = true) {
            self.language = language; self.noteLanguage = noteLanguage; self.engine = engine
            self.allowModelDownload = allowModelDownload
        }
    }

    /// One engine's status for a language, for `sempere transcribe --check`
    /// and the app's Settings (the availability matrix of task E5).
    public struct EngineStatus: Hashable, Sendable, Codable {
        public var engine: String
        public var available: Bool
        /// The language it would use, when it supports one.
        public var language: String?
        public var detail: String

        public init(engine: String, available: Bool, language: String?, detail: String) {
            self.engine = engine; self.available = available; self.language = language; self.detail = detail
        }
    }

    /// Whether this build can transcribe at all.
    public static var isSupported: Bool {
        #if canImport(Speech)
        return true
        #else
        return false
        #endif
    }

    /// The device's language as a BCP 47 tag.
    public static var deviceLanguage: String { TranscriptionLanguage.tag(Locale.current.identifier) ?? "en-US" }

    /// `apple-<engine>-<major>.<minor>` for this OS.
    static func engineName(_ e: TranscriptionEngine) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return e.name(osMajor: v.majorVersion, osMinor: v.minorVersion)
    }

    /// Transcribes the audio file `file` (any format AVFoundation reads) of
    /// recording `recording` on this device. The result passes format.md
    /// §8.3.2 validation (`TranscriptBuilder`).
    public static func transcribe(file: URL, recording: UUID, options: Options = Options()) async throws -> Transcript {
        #if canImport(Speech)
        let engines: [TranscriptionEngine] = options.engine.map { [$0] } ?? [.speechTranscriber, .sfSpeech]
        var lastError: Error = SpeechTranscriptionError.unavailable
        for engine in engines {
            do {
                switch engine {
                case .speechTranscriber:
                    if #available(macOS 26.0, iOS 26.0, *) {
                        return try await Analyzer.transcribe(file: file, recording: recording, options: options)
                    }
                    throw SpeechTranscriptionError.engineUnavailable("SpeechTranscriber needs iOS or macOS 26")
                case .sfSpeech:
                    return try await Recognizer.transcribe(file: file, recording: recording, options: options)
                }
            } catch let e as SpeechTranscriptionError {
                lastError = e
                // An explicit engine, or permission refused, is final; otherwise try the next one.
                if options.engine != nil || e == .notAuthorized { throw e }
            }
        }
        throw lastError
        #else
        throw SpeechTranscriptionError.unavailable
        #endif
    }

    /// Downloads and installs SpeechTranscriber's on-device model for the options'
    /// language, when it is not installed (Apple's asset service does the download;
    /// the audio is not involved). Returns at once when it is installed. Only
    /// SpeechTranscriber has a downloadable model: the SFSpeechRecognizer fallback
    /// uses the languages the device has.
    ///
    /// - Throws: `SpeechTranscriptionError.engineUnavailable` before iOS / macOS 26 or
    ///   where the engine is not available, `.unsupportedLanguage`, `.failed` when
    ///   the download fails, `.unavailable` without the Speech framework.
    public static func downloadModel(options: Options = Options()) async throws {
        #if canImport(Speech)
        if #available(macOS 26.0, iOS 26.0, *) {
            try await Analyzer.downloadModel(options)
        } else {
            throw SpeechTranscriptionError.engineUnavailable("SpeechTranscriber needs iOS or macOS 26")
        }
        #else
        throw SpeechTranscriptionError.unavailable
        #endif
    }

    /// Which engines can transcribe `options`' language here (nothing is downloaded).
    public static func availability(options: Options = Options()) async -> [EngineStatus] {
        #if canImport(Speech)
        var out: [EngineStatus] = []
        if #available(macOS 26.0, iOS 26.0, *) {
            out.append(await Analyzer.status(options))
        } else {
            out.append(EngineStatus(engine: engineName(.speechTranscriber), available: false, language: nil,
                                    detail: "needs iOS or macOS 26"))
        }
        out.append(Recognizer.status(options))
        return out
        #else
        return TranscriptionEngine.allCases.map {
            EngineStatus(engine: "apple-\($0.rawValue)", available: false, language: nil, detail: "no Speech framework")
        }
        #endif
    }
}

#if canImport(Speech)

// MARK: - SpeechAnalyzer + SpeechTranscriber (iOS / macOS 26)

@available(macOS 26.0, iOS 26.0, *)
enum Analyzer {
    /// The supported locale for the options, or nil.
    static func locale(_ options: SpeechTranscription.Options) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier }
        guard let tag = TranscriptionLanguage.choose(requested: options.language, note: options.noteLanguage,
                                                     device: SpeechTranscription.deviceLanguage, supported: supported)
        else { return nil }
        return Locale(identifier: tag)
    }

    static func status(_ options: SpeechTranscription.Options) async -> SpeechTranscription.EngineStatus {
        let name = SpeechTranscription.engineName(.speechTranscriber)
        guard SpeechTranscriber.isAvailable else {
            return .init(engine: name, available: false, language: nil, detail: "not available on this device")
        }
        guard let locale = await locale(options) else {
            return .init(engine: name, available: false, language: nil, detail: "language not supported")
        }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        let tag = locale.identifier(.bcp47)
        return .init(engine: name, available: true, language: tag,
                     detail: installed.contains(tag) ? "model installed" : "model not installed (downloaded on first use)")
    }

    /// Installs the model for the options' language (nothing when it is installed).
    static func downloadModel(_ options: SpeechTranscription.Options) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechTranscriptionError.engineUnavailable("SpeechTranscriber is not available on this device")
        }
        guard let locale = await locale(options) else {
            let wanted = TranscriptionLanguage.choose(requested: options.language, note: options.noteLanguage,
                                                      device: SpeechTranscription.deviceLanguage) ?? "?"
            throw SpeechTranscriptionError.unsupportedLanguage(wanted)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw SpeechTranscriptionError.failed("could not install the on-device model: \(error.localizedDescription)")
        }
    }

    static func transcribe(file: URL, recording: UUID, options: SpeechTranscription.Options) async throws -> Transcript {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechTranscriptionError.engineUnavailable("SpeechTranscriber is not available on this device")
        }
        guard let locale = await locale(options) else {
            let wanted = TranscriptionLanguage.choose(requested: options.language, note: options.noteLanguage,
                                                      device: SpeechTranscription.deviceLanguage) ?? "?"
            throw SpeechTranscriptionError.unsupportedLanguage(wanted)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                guard options.allowModelDownload else {
                    throw SpeechTranscriptionError.engineUnavailable("the on-device model for \(locale.identifier(.bcp47)) is not installed")
                }
                try await request.downloadAndInstall()
            }
        } catch let e as SpeechTranscriptionError {
            throw e
        } catch {
            throw SpeechTranscriptionError.failed("could not install the on-device model: \(error.localizedDescription)")
        }
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: file) } catch {
            throw SpeechTranscriptionError.failed("cannot read the audio: \(error.localizedDescription)")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () throws -> [Phrase] in
            var phrases: [Phrase] = []
            for try await result in transcriber.results where result.isFinal {
                phrases.append(phrase(text: result.text, range: result.range))
            }
            return phrases
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw SpeechTranscriptionError.failed(error.localizedDescription)
        }
        let phrases: [Phrase]
        do { phrases = try await collect.value } catch { throw SpeechTranscriptionError.failed(error.localizedDescription) }
        let segments = TranscriptBuilder.segments(fromPhrases: phrases.map {
            (text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence, words: $0.words)
        })
        return TranscriptBuilder.transcript(recording: recording, engine: SpeechTranscription.engineName(.speechTranscriber),
                                            language: locale.identifier(.bcp47), segments: segments)
    }

    struct Phrase: Sendable {
        var text: String, start: Double, end: Double, confidence: Double?, words: [RecognizedSpan]
    }

    /// A result's text as a phrase: one word per run with a time range;
    /// runs without one (punctuation) join the word before them.
    static func phrase(text: AttributedString, range: CMTimeRange) -> Phrase {
        var words: [RecognizedSpan] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let r = run.audioTimeRange {
                words.append(RecognizedSpan(text: piece, start: r.start.seconds, end: r.end.seconds,
                                            confidence: run.transcriptionConfidence))
            } else if !words.isEmpty {
                words[words.count - 1].text += piece.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // A run may hold several words (and leading spaces): split it, sharing its time evenly.
        var split: [RecognizedSpan] = []
        for w in words {
            let parts = w.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 1, w.end > w.start else {
                if !parts.isEmpty { split.append(RecognizedSpan(text: parts.joined(), start: w.start, end: w.end, confidence: w.confidence)) }
                continue
            }
            let step = (w.end - w.start) / Double(parts.count)
            for (i, p) in parts.enumerated() {
                split.append(RecognizedSpan(text: p, start: w.start + Double(i) * step, end: w.start + Double(i + 1) * step,
                                            confidence: w.confidence))
            }
        }
        let cs = split.compactMap(\.confidence)
        return Phrase(text: String(text.characters), start: range.start.seconds, end: range.end.seconds,
                      confidence: cs.isEmpty ? nil : cs.reduce(0, +) / Double(cs.count), words: split)
    }
}

// MARK: - SFSpeechRecognizer, on device only

enum Recognizer {
    static func locale(_ options: SpeechTranscription.Options) -> Locale? {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        return TranscriptionLanguage.choose(requested: options.language, note: options.noteLanguage,
                                            device: SpeechTranscription.deviceLanguage, supported: supported)
            .map { Locale(identifier: $0) }
    }

    static func status(_ options: SpeechTranscription.Options) -> SpeechTranscription.EngineStatus {
        let name = SpeechTranscription.engineName(.sfSpeech)
        guard let locale = locale(options), let r = SFSpeechRecognizer(locale: locale) else {
            return .init(engine: name, available: false, language: nil, detail: "language not supported")
        }
        let tag = TranscriptionLanguage.tag(locale.identifier)
        guard r.supportsOnDeviceRecognition else {
            return .init(engine: name, available: false, language: tag, detail: "no on-device model (server recognition is never used)")
        }
        let auth: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: auth = "allowed"
        case .notDetermined: auth = "permission not asked yet"
        default: auth = "permission refused"
        }
        return .init(engine: name, available: true, language: tag, detail: "on device; \(auth)")
    }

    static func authorize() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                throw SpeechTranscriptionError.needsUsageDescription
            }
            let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            guard status == .authorized else { throw SpeechTranscriptionError.notAuthorized }
        default:
            throw SpeechTranscriptionError.notAuthorized
        }
    }

    static func transcribe(file: URL, recording: UUID, options: SpeechTranscription.Options) async throws -> Transcript {
        guard let locale = locale(options), let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechTranscriptionError.unsupportedLanguage(options.language ?? options.noteLanguage ?? SpeechTranscription.deviceLanguage)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechTranscriptionError.unsupportedLanguage(locale.identifier)
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw SpeechTranscriptionError.needsUsageDescription
        }
        try await authorize()
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true   // never a server (DESIGN.md)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let collector = Collector()
        let words: [RecognizedSpan] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                collector.start(c)
                collector.task = recognizer.recognitionTask(with: request, delegate: collector)
            }
        } onCancel: {
            collector.cancel()
        }
        let tag = TranscriptionLanguage.tag(locale.identifier) ?? locale.identifier
        return TranscriptBuilder.transcript(recording: recording, engine: SpeechTranscription.engineName(.sfSpeech),
                                            language: tag, segments: TranscriptBuilder.segments(fromWords: words))
    }

    /// Collects every utterance a URL recognition finishes (a long file has
    /// several) and resumes once when the task ends.
    final class Collector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[RecognizedSpan], Error>?
        private var words: [RecognizedSpan] = []
        var task: SFSpeechRecognitionTask? {
            get { lock.withLock { _task } }
            set { lock.withLock { _task = newValue } }
        }
        private var _task: SFSpeechRecognitionTask?

        func start(_ c: CheckedContinuation<[RecognizedSpan], Error>) { lock.withLock { continuation = c } }

        func cancel() { task?.cancel() }

        private func finish(_ result: Result<[RecognizedSpan], Error>) {
            let c: CheckedContinuation<[RecognizedSpan], Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: result)
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
            let spans = result.bestTranscription.segments.map {
                RecognizedSpan(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration,
                               confidence: $0.confidence > 0 ? Double($0.confidence) : nil)
            }
            lock.withLock {
                // Later utterances never go back in time; a repeat of words already taken is dropped.
                let lastEnd = words.last?.end ?? -1
                words += spans.filter { $0.start >= lastEnd - 0.001 }
                if words.count > TranscriptBuilder.maxWords { words.removeLast(words.count - TranscriptBuilder.maxWords) }
            }
        }

        func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
            let collected = lock.withLock { words }
            if successfully || !collected.isEmpty {
                finish(.success(collected))
            } else if let error = task.error as NSError?, error.domain == "kAFAssistantErrorDomain", error.code == 1110 {
                finish(.success([]))   // no speech in the recording
            } else {
                finish(.failure(SpeechTranscriptionError.failed(task.error?.localizedDescription ?? "the recogniser stopped")))
            }
        }

        func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
            finish(.failure(CancellationError()))
        }
    }
}

#endif
