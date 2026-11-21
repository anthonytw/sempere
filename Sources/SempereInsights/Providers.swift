import Foundation
import Sempere

// MARK: - Providers (docs/design/1.2-note-insights.md §4)
//
// The pipeline never names a framework: generation goes through a `ModelProvider` (Apple's on-device
// `SystemLanguageModel.default` in `SempereInsightsApple`, scripted fakes in tests) and embedding through an
// `EmbeddingProvider` (`NLEmbedding` at a pinned revision, or a hashed bag of words). Model output is untrusted input
// (design §8 (d)): bounded, normalized, fact-checked, never executed and never fed back as instructions.

/// Whether a generation model can run here, and why not.
public enum ModelAvailability: Hashable, Sendable, CustomStringConvertible {
    case available
    /// Apple Intelligence is turned off.
    case disabled
    /// The model is still downloading or preparing.
    case notReady
    /// This device cannot run the model.
    case deviceNotEligible
    /// No such model on this platform or OS (Linux, macOS before 26; D18).
    case unsupported(String)

    public var isAvailable: Bool { self == .available }

    /// The reason word of the device record and `insights status` (`disabled`, `notReady`, `deviceNotEligible`,
    /// `unsupported`); nil when available.
    public var reason: String? {
        switch self {
        case .available: return nil
        case .disabled: return "disabled"
        case .notReady: return "notReady"
        case .deviceNotEligible: return "deviceNotEligible"
        case .unsupported: return "unsupported"
        }
    }

    public var description: String {
        switch self {
        case .available: return "available"
        case .disabled: return "Apple Intelligence is turned off (disabled)"
        case .notReady: return "the on-device model is not ready yet (notReady)"
        case .deviceNotEligible: return "this device cannot run Apple's on-device model (deviceNotEligible)"
        case .unsupported(let why): return why
        }
    }
}

/// Why a provider call failed.
public enum InsightsProviderError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The input did not fit the model's context window (the pipeline halves and retries once).
    case contextOverflow
    case unavailable(ModelAvailability)
    case unsupportedLanguage(String)
    /// The model refused (a guardrail) or produced nothing usable.
    case refused(String)
    case failed(String)

    public var description: String {
        switch self {
        case .contextOverflow: return "the text does not fit the model's context window"
        case .unavailable(let a): return a.description
        case .unsupportedLanguage(let l): return "the model does not support the language \(l)"
        case .refused(let why): return "the model gave no usable answer: \(why)"
        case .failed(let why): return "the model failed: \(why)"
        }
    }
}

/// What the model extracts from one text (or one chunk, or merges from several).
public struct ModelExtraction: Hashable, Sendable {
    public var summary: String
    /// In the model's order (most important first).
    public var keywords: [String]
    public var concepts: [String]

    public init(summary: String, keywords: [String], concepts: [String]) {
        self.summary = summary; self.keywords = keywords; self.concepts = concepts
    }
}

/// A generation model (design §4): its identity, availability, context window and four calls. Every call marks the
/// note text as data, never instructions, and asks for a fixed schema with no tools.
public protocol ModelProvider: Sendable {
    /// `model`, `os`, `prompt`: what makes a generation current (design §3.4).
    var identity: GenerationIdentity { get }
    var availability: ModelAvailability { get }
    /// Context window in tokens (8192 for Apple's on-device model [M]).
    var contextTokens: Int { get }
    /// True when the model supports `language` (a BCP 47 tag; nil: the device's).
    func supports(language: String?) -> Bool
    /// Summary, keywords and concepts of `text`.
    func extract(_ text: String, language: String?) async throws -> ModelExtraction
    /// One extraction from the extractions of a long text's chunks.
    func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction
    /// A paragraph over the member summaries of a notebook or tag (design §4 step 9).
    func summarize(topic: String, summaries: [String], language: String?) async throws -> String
    /// A 2-6 word title for a voice note's transcript (D14).
    func title(transcript: String, language: String?) async throws -> String
    /// `text` (a summary or a title) written in `language` (a BCP 47 tag): unchanged when it already is in it, names and
    /// numbers kept. For the insight language setting (`insights.language`, format.md §16.8): the summary and the title are
    /// first made and fact-checked in the note's own language, then put into the chosen one.
    func translate(_ text: String, to language: String) async throws -> String
    /// A short answer to `question` from `sources` only, each sentence naming the sources it uses (docs/design/1.3-ask.md
    /// §3.1 step 7). Untrusted output: `AskValidator` checks it. The default throws (a provider that cannot answer).
    func answer(question: String, sources: [AskSource], language: String?) async throws -> ModelAnswer
    /// `question` put into `language` (a BCP 47 tag) so it can be matched against notes written in it: translated, never
    /// answered, names, numbers and dates kept as written (docs/design/1.3-ask.md §3.8). The default uses `translate`.
    func translateQuestion(_ question: String, from source: String, to language: String) async throws -> String
    /// Each of `sentences` (an answer written in `source`) put into `language`, one for one and in order, every number,
    /// date, time, code and name kept as written (design §3.8). The default translates each with `translate`.
    func translateSentences(_ sentences: [String], from source: String, to language: String) async throws -> [String]
}

extension ModelProvider {
    /// A provider that cannot translate refuses: a fixed insight language is then not made by this device.
    public func translate(_ text: String, to language: String) async throws -> String {
        throw InsightsProviderError.failed("this model cannot translate")
    }

    public func translateQuestion(_ question: String, from source: String, to language: String) async throws -> String {
        try await translate(question, to: language)
    }

    public func translateSentences(_ sentences: [String], from source: String, to language: String) async throws -> [String] {
        var out: [String] = []
        for s in sentences { out.append(try await translate(s, to: language)) }
        return out
    }
}

/// A sentence embedder at explicit revisions (design §3.8): never "the current" one.
public protocol EmbeddingProvider: Sendable {
    /// `nl-sentence` for NLEmbedding's sentence model.
    var model: String { get }
    /// The revisions this device supports for `language` (empty: the language is not supported).
    func supportedRevisions(language: String) -> [Int]
    /// The vector of `text` at `revision`; nil when the embedder has no vector for it.
    func embed(_ text: String, language: String, revision: Int) throws -> [Float]?
}

extension EmbeddingProvider {
    /// The key of vectors this provider makes for `language` at `revision`, with Sempere's input revision.
    public func key(language: String, revision: Int) -> EmbeddingKey {
        EmbeddingKey(model: model, lang: language, rev: revision, input: EmbeddingInput.revision)
    }

    /// Every language this provider supports among `languages`, with its revisions.
    public func supported(_ languages: [String]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for l in languages { let r = supportedRevisions(language: l); if !r.isEmpty { out[l] = r.sorted() } }
        return out
    }
}

/// The platform this process runs on, for device records (`mac`, `ipad`, `iphone`, `linux`) and the OS version.
public struct InsightsPlatform: Hashable, Sendable {
    public var platform: String
    public var os: String
    public init(platform: String, os: String) { self.platform = platform; self.os = os }

    /// This process's platform and OS version.
    public static var current: InsightsPlatform {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion)"
        #if os(macOS)
        return .init(platform: "mac", os: "macOS \(version)")
        #elseif targetEnvironment(macCatalyst)
        return .init(platform: "mac", os: "macOS \(version)")
        #elseif os(iOS)
        return .init(platform: "ios", os: "iOS \(version)")
        #elseif os(Linux)
        return .init(platform: "linux", os: "Linux")
        #else
        return .init(platform: "other", os: version)
        #endif
    }
}
