import Foundation
import Sempere

// Setting expectations (maintainer task, 2026-10-09): the "About Your Key"
// notice, the quick tour and the About screen. This file is the logic only
// (Foundation and Sempere, typecheckable on Linux like `AppModel`); the views
// are in `ExpectationsViews.swift`. Wording rule: describe the design and its
// limits, never promise an outcome.

/// What this device remembers about the notices it showed: whether the quick
/// tour was seen, and which (vault, key) pairs the key notice was
/// acknowledged for. Per device (`UserDefaults`), never in the vault.
struct OnboardingMemory {
    /// `UserDefaults` key: the tour version last seen (0 = never).
    static let tourSeenKey = "Sempere.quickTourSeen"
    /// `UserDefaults` key: digests of the (vault, key) pairs whose notice was acknowledged.
    static let keyNoticeKey = "Sempere.keyNoticeAcknowledged"
    /// Bumped when the tour changes enough to be shown again.
    static let tourVersion = 1
    /// At most this many acknowledgements are kept (the oldest go first).
    static let keyNoticeLimit = 64

    var defaults: UserDefaults = .standard

    var tourSeen: Bool { defaults.integer(forKey: Self.tourSeenKey) >= Self.tourVersion }

    func markTourSeen() {
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

    func acknowledgeKeyNotice(vault: UUID, recipient: String?) {
        let token = Self.keyNoticeToken(vault: vault, recipient: recipient)
        var list = acknowledged.filter { $0 != token }
        list.append(token)
        defaults.set(Array(list.suffix(Self.keyNoticeLimit)), forKey: Self.keyNoticeKey)
    }

    private var acknowledged: [String] { defaults.stringArray(forKey: Self.keyNoticeKey) ?? [] }
}

/// What to show by itself once a vault is unlocked: the key notice the first
/// time a vault is unlocked with a key on this device (that includes a vault
/// just created), then the quick tour once per device. Never on every launch.
enum OnboardingStep: Equatable {
    case keyNotice
    case tour
}

enum OnboardingPolicy {
    /// The next notice to show by itself, or nil.
    /// - Parameters:
    ///   - unlocked: a vault is unlocked and nothing else holds the screen
    ///     (unlock sheet, remember-key offer, the new-vault sheet).
    ///   - vault: the unlocked vault's id.
    ///   - recipient: the public key of the key it was unlocked with.
    static func next(unlocked: Bool, vault: UUID?, recipient: String?, memory: OnboardingMemory,
                     automatic: Bool) -> OnboardingStep? {
        guard automatic, unlocked, let vault else { return nil }
        if !memory.keyNoticeAcknowledged(vault: vault, recipient: recipient) { return .keyNotice }
        if !memory.tourSeen { return .tour }
        return nil
    }

    /// Whether the notices show by themselves. Debug launches that script the
    /// app (the screenshot, smoke and pseudo-language UI tests, `DebugLaunch`)
    /// skip them unless `SEMPERE_DEBUG_ONBOARDING` is set; release builds always show them.
    static var automatic: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["SEMPERE_DEBUG_ONBOARDING"] != nil { return true }
        let scripted = ["SEMPERE_DEBUG_VAULT", "SEMPERE_DEBUG_RECENT", "SEMPERE_DEMO"].contains { env[$0] != nil }
        // Hosted unit tests run the app too: they never see a notice by themselves.
        let testing = env["XCTestConfigurationFilePath"] != nil
        return !scripted && !testing
        #else
        return true
        #endif
    }
}

/// One page of the quick tour: a symbol, a title and two short lines.
struct TourPage: Identifiable, Equatable {
    /// Stable id (UI tests, accessibility identifiers).
    var id: String
    /// An SF Symbol name.
    var symbol: String
    var title: String
    var lines: [String]
    /// The page offers "About Your Key".
    var offersKeyNotice = false
}

/// The quick tour (shown once per device, then from About and Help ▸ Quick
/// Tour). Every claim here is about what `main` does today: check a page
/// against `docs/ROADMAP.md` when a feature moves.
enum QuickTour {
    static func pages(isMac: Bool) -> [TourPage] {
        [
            TourPage(
                id: "expectations", symbol: "key.horizontal",
                title: String(localized: "Your Notes, Your Key", comment: "Quick tour page 1 title"),
                lines: [
                    String(localized: "Sempere is free software and comes with no warranty. Your key is the only way into your notes.",
                           comment: "Quick tour page 1"),
                    String(localized: "Keep the recovery kit and a backup somewhere safe: if every copy of the key is lost, nobody can open the notes.",
                           comment: "Quick tour page 1"),
                ],
                offersKeyNotice: true),
            TourPage(
                id: "writing", symbol: "pencil.tip",
                title: String(localized: "Write", comment: "Quick tour page 2 title"),
                lines: [
                    String(localized: "Write with Apple Pencil and pick pens, markers and erasers from the palette, on pages or on one long page.",
                           comment: "Quick tour page 2"),
                    isMac
                        ? String(localized: "Import a PDF to write on it. Settings can smooth strokes drawn with a mouse or trackpad.",
                                 comment: "Quick tour page 2, Mac")
                        : String(localized: "Import a PDF to write on it, and add pages as you go.",
                                 comment: "Quick tour page 2, iPad"),
                ]),
            TourPage(
                id: "page", symbol: "photo.on.rectangle.angled",
                title: String(localized: "Everything on the Page", comment: "Quick tour page 3 title"),
                lines: [
                    String(localized: "Add images, PDF pages, videos, equations and text boxes.", comment: "Quick tour page 3"),
                    String(localized: "Record while you write: the ink is linked to the recording, and transcripts are made on this device.",
                           comment: "Quick tour page 3"),
                ]),
            TourPage(
                id: "find", symbol: "magnifyingglass",
                title: String(localized: "Find It Again", comment: "Quick tour page 4 title"),
                lines: [
                    String(localized: "Search looks through titles, handwriting, typed text, the text of PDFs and recording transcripts.", comment: "Quick tour page 4"),
                    String(localized: "Handwriting is recognized on this device; it is not sent anywhere.", comment: "Quick tour page 4"),
                ]),
            TourPage(
                id: "storage", symbol: "lock.icloud",
                title: String(localized: "Your Storage", comment: "Quick tour page 5 title"),
                lines: [
                    String(localized: "A vault is a folder of encrypted files in iCloud Drive or any Files location; the command-line tool can mirror it to WebDAV.",
                           comment: "Quick tour page 5"),
                    String(localized: "Notes are encrypted on your devices. There is no Sempere server: your storage sees encrypted files, their sizes and times.",
                           comment: "Quick tour page 5"),
                ]),
            TourPage(
                id: "export", symbol: "square.and.arrow.up",
                title: String(localized: "Take It With You", comment: "Quick tour page 6 title"),
                lines: [
                    String(localized: "Export notes as PDF, images or Markdown, one at a time or all at once.", comment: "Quick tour page 6"),
                    String(localized: "The free sempere command-line tool for macOS and Linux reads, exports and recovers vaults, without the app.",
                           comment: "Quick tour page 6"),
                ]),
        ]
    }
}

/// The About screen's facts that are not views: version and build, and the
/// bundled texts.
enum AboutInfo {
    /// "1.2 (34)": the marketing version and the build number.
    static func versionText(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }

    /// Text files bundled with the app (`project.pbxproj`: the repository's
    /// `LICENSE` and `LICENSE-EXCEPTION`; `ThirdPartyNotices.txt` in the app folder).
    enum Document: String, CaseIterable, Identifiable {
        case license = "LICENSE"
        case exception = "LICENSE-EXCEPTION"
        case thirdParty = "ThirdPartyNotices.txt"

        var id: String { rawValue }
    }

    /// At most this many bytes are read from a bundled text (the GPL is 35 KB).
    static let maxDocumentBytes = 1 << 20

    /// A bundled text, or nil when the bundle does not have it.
    static func text(of document: Document, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: document.rawValue, withExtension: nil),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxDocumentBytes), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The text cut into paragraphs (blank-line separated), so a long licence
    /// is laid out lazily.
    static func paragraphs(_ text: String) -> [String] {
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
