import Foundation
import Sempere

/// How a note's title is shown, without the words: the trimmed title, nil when nothing is left. The app words the
/// empty case ("Untitled", `NoteTitle.display` in `NoteCanvasView.swift`).
public enum NoteTitle {
    public static func trimmed(_ title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// What a search result's snippet says: its text, or the app's marker when the match is inside an equation (the
/// source is not quoted). The marker is the app's words (`SearchSnippetText.equationMarker`).
public enum SearchSnippetText {
    public static func display(_ snippet: NoteSearchHit.Snippet, equationMarker: String) -> String {
        snippet.isEquation ? equationMarker : snippet.text
    }
}

/// How many pages of a note Recognize All read, for the row's "Read 2 of 5 pages" (the app words it).
public enum RecognitionPagesRead: Equatable, Sendable {
    /// Every page: `read` of them (a note's page count is the number read).
    case all(read: Int)
    case some(read: Int, of: Int)

    public init(read: Int, of pages: Int) {
        self = read >= pages ? .all(read: read) : .some(read: read, of: pages)
    }
}

/// One thing the line under "Recently Recognized" says, in the order it says them.
public enum RecognitionDetail: Equatable, Sendable {
    /// The run is still going.
    case running
    /// This many notes could not be read.
    case failed(Int)
    /// The run was stopped early.
    case stopped
}

extension RecognitionResults {
    /// What the line under the headline says: what is still going on, or what went wrong (empty: nothing).
    public func detailParts(running: Bool) -> [RecognitionDetail] {
        var parts: [RecognitionDetail] = []
        if running { parts.append(.running) }
        if failed > 0 { parts.append(.failed(failed)) }
        if stopped { parts.append(.stopped) }
        return parts
    }
}
