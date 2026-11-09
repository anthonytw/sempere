import Foundation
import Sempere

// What the sidebar's drags carry and where they land, and the rules (docs/design/thin-app.md "Wave 5b, part 3,
// step 6"). The app gives the payload its types (`UTType`) and item providers, proposes the drop operation and words
// the undo step (`SidebarDrop.swift` in `Apps/Sempere/SempereApp`).

/// What a drag inside the app carries. The app registers it with `.ownProcess` visibility only: ids and paths never
/// go to another app.
public enum DragPayload: Equatable, Sendable {
    case notes([UUID])
    case notebook(String)

    /// The kinds of payload, one item-provider type each in the app.
    public enum Kind: Equatable, Sendable, CaseIterable {
        case notes
        case notebook
    }

    /// Most ids or path bytes decoded from a drop (a hostile provider cannot make us read more).
    public static let maxNotes = 100_000
    public static let maxPathBytes = 4096

    public var kind: Kind {
        switch self {
        case .notes: return .notes
        case .notebook: return .notebook
        }
    }

    /// The bytes the drag carries: the ids as a JSON array of lowercase strings, or the path's UTF-8.
    public var data: Data {
        switch self {
        case .notes(let ids): return (try? JSONEncoder().encode(ids.map { $0.uuidString.lowercased() })) ?? Data()
        case .notebook(let path): return Data(path.utf8)
        }
    }

    /// The payload of `kind` in `data`, nil when it is empty or malformed.
    public static func decode(_ data: Data, kind: Kind) -> DragPayload? {
        switch kind {
        case .notes:
            guard data.count <= maxNotes * 48,   // a quoted uuid and a comma are 40 bytes
                  let names = try? JSONDecoder().decode([String].self, from: data), names.count <= maxNotes else { return nil }
            let ids = names.compactMap { UUID(uuidString: $0) }
            return ids.isEmpty ? nil : .notes(ids)
        case .notebook:
            guard data.count <= maxPathBytes, let path = String(data: data, encoding: .utf8),
                  let canonical = NotebookPath.canonical(path) else { return nil }
            return .notebook(canonical)
        }
    }
}

/// Where a drop lands in the sidebar: a notebook, or the top level (the
/// "All Notes" row).
public enum DropTarget: Hashable, Sendable {
    case topLevel
    case notebook(String)

    /// The target a sidebar row stands for; nil for rows that take no drops
    /// (tags, Recently Deleted, Recently Recognized).
    public init?(_ item: SidebarItem) {
        switch item {
        case .allNotes: self = .topLevel
        case .notebook(let path): self = NotebookPath.canonical(path).map(DropTarget.notebook) ?? .topLevel
        case .tag, .deleted, .favorites, .recentlyRecognized: return nil
        }
    }

    /// The notebook path notes dropped here get; nil: none.
    var path: String? {
        if case .notebook(let p) = self { return NotebookPath.canonical(p) }
        return nil
    }
}

/// The rules of dropping notes and notebooks on the sidebar (pure, tested).
public enum SidebarDrop {
    /// Whether `payload` dropped on `target` would change something and is allowed.
    ///
    /// - Notes: allowed when at least one of them (live ones only; ids not in `notes` are
    ///   ignored, they may not be listed yet) is not in that notebook already.
    /// - A notebook: allowed when it can move there (never into itself or a
    ///   notebook inside it, `NotebookPath.moved`) and is not there already.
    public static func accepts(_ payload: DragPayload, on target: DropTarget, notes: [NoteSummary]) -> Bool {
        switch payload {
        case .notes(let ids):
            let wanted = Set(ids)
            return notes.contains { wanted.contains($0.id) && !$0.deleted && NotebookPath.canonical($0.notebook) != target.path }
        case .notebook(let path):
            guard let moved = NotebookPath.moved(path, into: target.path) else { return false }
            return moved != NotebookPath.canonical(path)
        }
    }
}

/// Where the notes were before a move, to put them back (undo).
public struct NotebookMoveRecord: Equatable, Sendable {
    /// What moved, for the undo step's name (the app words it: `actionName`).
    public enum Moved: Equatable, Sendable {
        /// `count` notes into a notebook.
        case notes(count: Int)
        /// A notebook with everything below it.
        case notebook
    }

    var previous: [UUID: String?]
    public var moved: Moved
    /// The empty notebooks (notebook records, format.md §14) the move renamed, if any.
    public var emptyNotebooks: NotebookPathMove? = nil

    public init(previous: [UUID: String?], moved: Moved, emptyNotebooks: NotebookPathMove? = nil) {
        self.previous = previous
        self.moved = moved
        self.emptyNotebooks = emptyNotebooks
    }
}

/// A notebook path renamed from `from` to `to` (nil: its levels lifted to the top).
public struct NotebookPathMove: Equatable, Sendable {
    var from: String
    var to: String?

    public init(from: String, to: String?) {
        self.from = from
        self.to = to
    }
}

/// A drop that just landed on a sidebar row (`AppModelCore.landedDrop`); each drop is a new value.
public struct LandedDrop: Equatable, Sendable {
    public let target: DropTarget
    let id = UUID()

    init(target: DropTarget) { self.target = target }
}
