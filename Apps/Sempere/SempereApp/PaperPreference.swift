import Foundation
import Sempere

/// The paper new notes start with, remembered across launches in
/// `UserDefaults` as the paper's format JSON (format.md §5.4.2). The paper
/// picker's "Use as default for new notes" writes it; the new-note sheet reads it.
enum PaperPreference {
    static let defaultsKey = "Sempere.defaultPaper"
    /// Used when nothing valid is stored.
    static var fallback: Paper { .ruled }

    /// The stored default paper (clamped to valid ranges), or `fallback`.
    static func load(from defaults: UserDefaults = .standard) -> Paper {
        guard let data = defaults.data(forKey: defaultsKey),
              let paper = try? InkJSON.decoder().decode(Paper.self, from: data) else { return fallback }
        return paper.validated()
    }

    /// Remembers `paper` (clamped to valid ranges) as the default for new notes.
    static func save(_ paper: Paper, to defaults: UserDefaults = .standard) {
        guard let data = try? InkJSON.encoder().encode(paper.validated()) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
