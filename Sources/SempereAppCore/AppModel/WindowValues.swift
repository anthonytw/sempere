import Foundation
import Sempere

// The Mac's windows, as the system saves and restores them (docs/design/thin-app.md "Wave 5b, part 3, step 6").

/// What a window of one note is opened with. It is `Codable`, so SwiftUI saves
/// the windows that were open and opens them again at the next launch (state
/// restoration); the vault is named by its id (`vault.json`), not by a path, so
/// no location is stored.
public struct NoteWindowValue: Codable, Hashable, Sendable {
    /// `WindowGroup` id of the note windows.
    public static let sceneID = "note"
    public var vaultID: UUID
    public var noteID: UUID

    public init(vaultID: UUID, noteID: UUID) {
        self.vaultID = vaultID
        self.noteID = noteID
    }
}

/// The library window's selection, saved with the scene (`@SceneStorage`) and
/// applied once the vault is unlocked again.
///
/// The system keeps scene storage in plaintext (a Mac's Saved Application
/// State), so it never names a notebook or a tag: those are stored as a keyed
/// digest (`digest`, `AppModel.selectionDigest`) that only the unlocked vault
/// resolves (security review 2026-10, S13).
public struct RestorableSelection: Codable, Equatable, Sendable {
    /// `all`, `deleted`, `favorites`, `recognized`, `notebook#<digest>` or
    /// `tag#<digest>`; anything else is All Notes.
    public var sidebar: String
    public var note: UUID?
    /// The vault the selection belongs to.
    public var vault: UUID?

    public static let key = "Sempere.selection"

    /// What `sidebar` names: an item, or a notebook or tag known only by its digest.
    public enum Sidebar: Equatable {
        case item(SidebarItem)
        case notebook(digest: String)
        case tag(digest: String)
    }

    public var sidebarRef: Sidebar {
        if sidebar == "deleted" { return .item(.deleted) }
        if sidebar == "recognized" { return .item(.recentlyRecognized) }
        if sidebar == "favorites" { return .item(.favorites) }
        if sidebar.hasPrefix("notebook#") { return .notebook(digest: String(sidebar.dropFirst("notebook#".count))) }
        if sidebar.hasPrefix("tag#") { return .tag(digest: String(sidebar.dropFirst("tag#".count))) }
        return .item(.allNotes)
    }

    /// The stored form of `item`; a notebook or tag goes through `digest`
    /// (of the canonical path or the tag key, `digestLabel`).
    public static func name(of item: SidebarItem?, digest: (String) -> String) -> String {
        switch item ?? .allNotes {
        case .allNotes: return "all"
        case .recentlyRecognized: return "recognized"
        case .favorites: return "favorites"
        case .deleted: return "deleted"
        case .notebook(let path): return "notebook#" + digest(digestLabel(notebook: path))
        case .tag(let tag): return "tag#" + digest(digestLabel(tag: tag))
        }
    }

    /// What a notebook's or tag's digest is taken of: the same for every
    /// spelling of the same notebook (`NotebookPath.canonical`) or tag (`NoteOps.tagKey`).
    public static func digestLabel(notebook path: String) -> String { "notebook|" + (NotebookPath.canonical(path) ?? "") }
    public static func digestLabel(tag: String) -> String { "tag|" + NoteOps.tagKey(tag) }

    public init(sidebar: SidebarItem?, note: UUID?, vault: UUID?, digest: (String) -> String) {
        self.sidebar = Self.name(of: sidebar, digest: digest)
        self.note = note
        self.vault = vault
    }

    /// Decodes a stored string; anything unreadable is "no selection".
    public init?(stored: String) {
        guard let data = stored.data(using: .utf8),
              let value = try? JSONDecoder().decode(RestorableSelection.self, from: data) else { return nil }
        self = value
    }

    public var stored: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
