import Foundation
import Sempere
import SempereAppCore

// The wording and the device glue of the key notice, the quick tour and About (`Expectations.swift` in
// SempereAppCore holds the logic). Wording rule: describe the design and its limits, never promise an outcome.

extension OnboardingMemory {
    /// This device's memory: the app's `UserDefaults`.
    init() { self.init(defaults: UserDefaults.standard) }
}

extension OnboardingPolicy {
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

/// The quick tour's pages in words. Every claim here is about what `main` does today: check a page when a
/// feature changes.
extension TourPage {
    /// An SF Symbol name.
    var symbol: String {
        switch topic {
        case .expectations: return "key.horizontal"
        case .writing: return "pencil.tip"
        case .page: return "photo.on.rectangle.angled"
        case .find: return "magnifyingglass"
        case .storage: return "lock.icloud"
        case .export: return "square.and.arrow.up"
        }
    }

    var title: String {
        switch topic {
        case .expectations: return String(localized: "Your Notes, Your Key", comment: "Quick tour page 1 title")
        case .writing: return String(localized: "Write", comment: "Quick tour page 2 title")
        case .page: return String(localized: "Everything on the Page", comment: "Quick tour page 3 title")
        case .find: return String(localized: "Find It Again", comment: "Quick tour page 4 title")
        case .storage: return String(localized: "Your Storage", comment: "Quick tour page 5 title")
        case .export: return String(localized: "Take It With You", comment: "Quick tour page 6 title")
        }
    }

    /// Two short lines.
    var lines: [String] {
        switch topic {
        case .expectations:
            return [
                String(localized: "Sempere is free software and comes with no warranty. Your key is the only way into your notes.",
                       comment: "Quick tour page 1"),
                String(localized: "Keep the recovery kit and a backup somewhere safe: if every copy of the key is lost, nobody can open the notes.",
                       comment: "Quick tour page 1"),
            ]
        case .writing:
            return [
                String(localized: "Write with Apple Pencil and pick pens, markers and erasers from the palette, on pages or on one long page.",
                       comment: "Quick tour page 2"),
                isMac
                    ? String(localized: "Import a PDF to write on it. Settings can smooth strokes drawn with a mouse or trackpad.",
                             comment: "Quick tour page 2, Mac")
                    : String(localized: "Import a PDF to write on it, and add pages as you go.",
                             comment: "Quick tour page 2, iPad"),
            ]
        case .page:
            return [
                String(localized: "Add images, PDF pages, videos, equations and text boxes.", comment: "Quick tour page 3"),
                String(localized: "Record while you write: the ink is linked to the recording, and transcripts are made on this device.",
                       comment: "Quick tour page 3"),
            ]
        case .find:
            return [
                String(localized: "Search looks through titles, handwriting, typed text, the text of PDFs and recording transcripts.", comment: "Quick tour page 4"),
                String(localized: "Handwriting is recognized on this device; it is not sent anywhere.", comment: "Quick tour page 4"),
            ]
        case .storage:
            return [
                String(localized: "Every vault is a folder of encrypted files kept on this device, so it opens offline. A vault from a WebDAV server stays in sync with the server, both ways.",
                       comment: "Quick tour page 5"),
                String(localized: "Notes are encrypted on your devices. There is no Sempere server: your storage sees encrypted files, their sizes and times.",
                       comment: "Quick tour page 5"),
            ]
        case .export:
            return [
                String(localized: "Export notes as PDF, images or Markdown, one at a time or all at once.", comment: "Quick tour page 6"),
                String(localized: "The free sempere command-line tool for macOS and Linux reads, exports and recovers vaults, without the app.",
                       comment: "Quick tour page 6"),
            ]
        }
    }
}
