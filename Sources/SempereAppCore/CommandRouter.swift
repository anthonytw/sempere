import Foundation

/// A recent vault, as the File > Open Recent menu lists it.
public struct RecentItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the focused window offers the menu bar: its state (for enabling) and
/// what to do for a command. Each window publishes one with
/// `focusedSceneValue(\.commandRouter, …)`; `AppCommands` reads the focused one.
public struct CommandRouter {
    public var context: MenuCommand.Context
    public var recents: [RecentItem] = []
    /// The notes File > Export acts on: the list's selection in a library
    /// window, the window's note in a note window.
    public var exportIDs: [UUID] = []
    /// The window's `WindowUI.id` (the export sheet opens there).
    public var windowID: UUID?
    public var perform: (MenuCommand) -> Void
    public var openRecent: (UUID) -> Void = { _ in }

    public init(context: MenuCommand.Context, recents: [RecentItem] = [], exportIDs: [UUID] = [], windowID: UUID? = nil,
                perform: @escaping (MenuCommand) -> Void, openRecent: @escaping (UUID) -> Void = { _ in }) {
        self.context = context
        self.recents = recents
        self.exportIDs = exportIDs
        self.windowID = windowID
        self.perform = perform
        self.openRecent = openRecent
    }
}
