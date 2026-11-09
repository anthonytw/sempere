import Foundation
import Sempere

// Setting expectations (maintainer task, 2026-10-09): the "About Your Key"
// notice, the quick tour and the About screen. This file is the logic only; the
// app has the wording (`Expectations+Text.swift`) and the views
// (`ExpectationsViews.swift`). Wording rule: describe the design and its
// limits, never promise an outcome.

/// What this device remembers about the notices it showed: whether the quick
/// tour was seen, and which (vault, key) pairs the key notice was
/// acknowledged for. Per device (the app's `UserDefaults`), never in the vault.
public struct OnboardingMemory: Sendable {
    /// `UserDefaults` key: the tour version last seen (0 = never).
    static let tourSeenKey = "Sempere.quickTourSeen"
    /// `UserDefaults` key: digests of the (vault, key) pairs whose notice was acknowledged.
    static let keyNoticeKey = "Sempere.keyNoticeAcknowledged"
    /// Bumped when the tour changes enough to be shown again.
    static let tourVersion = 1
    /// At most this many acknowledgements are kept (the oldest go first).
    static let keyNoticeLimit = 64

    var defaults: any KeyValueStore

    public init(defaults: any KeyValueStore) { self.defaults = defaults }

    public var tourSeen: Bool { defaults.integer(forKey: Self.tourSeenKey) >= Self.tourVersion }

    public func markTourSeen() {
        defaults.set(Self.tourVersion, forKey: Self.tourSeenKey)
    }

    /// The stored form of a (vault, key) pair: a digest, so the preferences
    /// hold neither the vault id nor the public key. `recipient` is nil when
    /// the vault was unlocked without a key this device holds.
    static func keyNoticeToken(vault: UUID, recipient: String?) -> String {
        let text = vault.uuidString.lowercased() + "\n" + (recipient ?? "")
        return String(FileDigest.sha256(Data(text.utf8)).prefix(32))
    }

    func keyNoticeAcknowledged(vault: UUID, recipient: String?) -> Bool {
        acknowledged.contains(Self.keyNoticeToken(vault: vault, recipient: recipient))
    }

    public func acknowledgeKeyNotice(vault: UUID, recipient: String?) {
        let token = Self.keyNoticeToken(vault: vault, recipient: recipient)
        var list = acknowledged.filter { $0 != token }
        list.append(token)
        defaults.set(Array(list.suffix(Self.keyNoticeLimit)), forKey: Self.keyNoticeKey)
    }

    private var acknowledged: [String] { defaults.object(forKey: Self.keyNoticeKey) as? [String] ?? [] }
}

/// What to show by itself once a vault is unlocked: the key notice the first
/// time a vault is unlocked with a key on this device (that includes a vault
/// just created), then the quick tour once per device. Never on every launch.
public enum OnboardingStep: Equatable, Sendable {
    case keyNotice
    case tour
}

public enum OnboardingPolicy {
    /// The next notice to show by itself, or nil.
    /// - Parameters:
    ///   - unlocked: a vault is unlocked and nothing else holds the screen
    ///     (unlock sheet, remember-key offer, the new-vault sheet).
    ///   - vault: the unlocked vault's id.
    ///   - recipient: the public key of the key it was unlocked with.
    public static func next(unlocked: Bool, vault: UUID?, recipient: String?, memory: OnboardingMemory,
                            automatic: Bool) -> OnboardingStep? {
        guard automatic, unlocked, let vault else { return nil }
        if !memory.keyNoticeAcknowledged(vault: vault, recipient: recipient) { return .keyNotice }
        if !memory.tourSeen { return .tour }
        return nil
    }
}

/// One page of the quick tour. The app gives it its symbol, title and two short lines (`TourPage.title`).
public struct TourPage: Identifiable, Equatable, Sendable {
    /// What a page is about, in the tour's order.
    public enum Topic: String, CaseIterable, Sendable {
        case expectations, writing, page, find, storage, export
    }

    public var topic: Topic
    /// Stable id (UI tests, accessibility identifiers).
    public var id: String { topic.rawValue }
    /// The page offers "About Your Key".
    public var offersKeyNotice: Bool
    /// Worded for the Mac (the writing page mentions mouse and trackpad smoothing).
    public var isMac: Bool

    init(topic: Topic, offersKeyNotice: Bool = false, isMac: Bool = false) {
        self.topic = topic
        self.offersKeyNotice = offersKeyNotice
        self.isMac = isMac
    }
}

/// The quick tour (shown once per device, then from About and Help ▸ Quick
/// Tour). Every claim in its wording is about what `main` does today: check a page
/// when a feature changes.
public enum QuickTour {
    public static func pages(isMac: Bool) -> [TourPage] {
        TourPage.Topic.allCases.map { TourPage(topic: $0, offersKeyNotice: $0 == .expectations, isMac: isMac) }
    }
}

/// The About screen's facts that are not views: version and build, and the
/// bundled texts.
public enum AboutInfo {
    /// "1.2 (34)": the marketing version and the build number.
    public static func versionText(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }

    /// Text files bundled with the app (`project.pbxproj`: the repository's
    /// `LICENSE`, `LICENSE-EXCEPTION` and `docs/appstore/privacy-policy.md`; `ThirdPartyNotices.txt` in the app folder).
    public enum Document: String, CaseIterable, Identifiable, Sendable {
        case license = "LICENSE"
        case exception = "LICENSE-EXCEPTION"
        case thirdParty = "ThirdPartyNotices.txt"
        /// The privacy policy as published (offline audit A-P6: readable without a network).
        case privacyPolicy = "privacy-policy.md"

        public var id: String { rawValue }
    }

    /// At most this many bytes are read from a bundled text (the GPL is 35 KB).
    static let maxDocumentBytes = 1 << 20

    /// A bundled text, or nil when the bundle does not have it.
    public static func text(of document: Document, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: document.rawValue, withExtension: nil),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxDocumentBytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The privacy policy's paragraphs for the app (Markdown, as published), without the note to maintainers about
    /// where the policy is published and kept in step (it names a script and App Store Connect).
    public static func privacyPolicyParagraphs(_ text: String) -> [String] {
        paragraphs(text).filter { !$0.hasPrefix("This page is the Privacy Policy URL") }
    }

    /// A Markdown list paragraph's items (`- ` lines, indented lines continuing the item before), joined into one
    /// line each; nil when the paragraph is not a list.
    public static func listItems(_ paragraph: String) -> [String]? {
        let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, first.hasPrefix("- ") else { return nil }
        var items: [String] = []
        for line in lines {
            if line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)))
            } else if !items.isEmpty {
                items[items.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return items
    }

    /// The text cut into paragraphs (blank-line separated), so a long license
    /// is laid out lazily.
    public static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }
}
