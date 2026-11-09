import Foundation
import Sempere
import SempereAppCore

/// The words of the new-note layouts (`NewNoteLayout`, in `SempereAppCore`).
extension NewNoteLayout {
    var title: String {
        switch self {
        case .letter: return String(localized: "Pages – Letter", comment: "Layout of new notes: paged or pageless, and the paper size")
        case .a4: return String(localized: "Pages – A4", comment: "Layout of new notes: paged or pageless, and the paper size")
        case .pagelessLetter: return String(localized: "Pageless – Letter width", comment: "Layout of new notes: paged or pageless, and the paper size")
        case .pagelessA4: return String(localized: "Pageless – A4 width", comment: "Layout of new notes: paged or pageless, and the paper size")
        }
    }
}

// The defaults the app stores them in (`UserDefaults.standard`; the library takes any `KeyValueStore`).
extension NewNoteLayout {
    static func load() -> NewNoteLayout { load(from: UserDefaults.standard) }
    static func save(_ layout: NewNoteLayout) { save(layout, to: UserDefaults.standard) }
}

extension PaperPreference {
    static func load() -> Paper { load(from: UserDefaults.standard) }
    static func save(_ paper: Paper) { save(paper, to: UserDefaults.standard) }
}
