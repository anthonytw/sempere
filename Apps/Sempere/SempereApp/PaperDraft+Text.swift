import Foundation
import Sempere
import SempereAppCore

/// The words of the paper picker's parameters and presets (`PaperParameter`, `PaperBackground`: `SempereAppCore`).
extension PaperParameter {
    var title: String {
        switch self {
        case .spacing: return String(localized: "Spacing")
        case .lineWidth: return String(localized: "Line width")
        case .dotRadius: return String(localized: "Dot size")
        case .marginLeft: return String(localized: "Left margin")
        case .marginTop: return String(localized: "Top margin")
        case .cueWidth: return String(localized: "Cue column")
        case .summaryHeight: return String(localized: "Summary area")
        case .staffSpacing: return String(localized: "Staff line spacing")
        case .staffGap: return String(localized: "Space between staves")
        }
    }
}

extension PaperKind {
    /// The kind's name in the interface language (`title` is the library's English name).
    var localizedTitle: String {
        switch self {
        case .blank: return String(localized: "Blank", comment: "Paper kind")
        case .ruled: return String(localized: "Ruled", comment: "Paper kind")
        case .marginRuled: return String(localized: "Ruled with margin", comment: "Paper kind")
        case .grid: return String(localized: "Grid", comment: "Paper kind")
        case .dot: return String(localized: "Dots", comment: "Paper kind")
        case .isoDot: return String(localized: "Isometric dots", comment: "Paper kind")
        case .isoGrid: return String(localized: "Isometric grid", comment: "Paper kind")
        case .cornell: return String(localized: "Cornell", comment: "Paper kind: Cornell notes layout")
        case .staff: return String(localized: "Music staff", comment: "Paper kind")
        }
    }
}

extension PaperBackground {
    var title: String {
        switch self {
        case .white: return String(localized: "White", comment: "Paper color preset")
        case .cream: return String(localized: "Cream", comment: "Paper color preset")
        case .dark: return String(localized: "Dark", comment: "Paper color preset")
        }
    }
}
