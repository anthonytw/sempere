import Foundation

/// A folder named by a bookmark, as it resolved.
public struct ResolvedBookmark: Sendable, Equatable {
    /// Where the folder is now.
    public var url: URL
    /// The bookmark still resolves but should be made again (the folder moved or was renamed).
    public var isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

/// Why a bookmark did not resolve.
public enum FolderBookmarkError: Error, Equatable, Sendable {
    /// The bytes are not a bookmark this store made, or the folder they name is gone.
    case unresolvable
}

/// Folders kept across launches by bookmark, and the access scope a picked folder needs: in the app,
/// security-scoped bookmarks (`SecurityScopedBookmarks`, `options: []`: no `.withSecurityScope` on iOS or
/// Catalyst, CLAUDE.md); `PathBookmarks` (a plain path, no scope) in tests and the CLI.
public protocol FolderBookmarks: Sendable {
    /// A bookmark of `folder`.
    func bookmark(for folder: URL) throws -> Data
    /// The folder `bookmark` names. `mounting`: may mount a share the bookmark names (false for scheduled work,
    /// which must not try to mount an absent share). Throws `FolderBookmarkError.unresolvable` or the system's error.
    func resolve(_ bookmark: Data, mounting: Bool) throws -> ResolvedBookmark
    /// Starts using `url`'s security scope; true when there was one to start (then `stopAccessing` it later).
    func startAccessing(_ url: URL) -> Bool
    /// Ends a scope `startAccessing` started.
    func stopAccessing(_ url: URL)
}

extension FolderBookmarks {
    /// `resolve(_:mounting:)`, mounting allowed.
    public func resolve(_ bookmark: Data) throws -> ResolvedBookmark { try resolve(bookmark, mounting: true) }

    /// Runs `body` with `url`'s scope held (when it has one).
    public func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = startAccessing(url)
        defer { if scoped { stopAccessing(url) } }
        return try body()
    }
}

/// `FolderBookmarks` without the system's bookmarks: a bookmark is the folder's absolute path, no folder has a
/// scope (tests, the CLI, Linux). A path bookmark is never stale; one whose folder is gone does not resolve.
public struct PathBookmarks: FolderBookmarks {
    private static let prefix = "sempere-path-bookmark:"

    public init() {}

    public func bookmark(for folder: URL) throws -> Data {
        Data((Self.prefix + folder.standardizedFileURL.path).utf8)
    }

    public func resolve(_ bookmark: Data, mounting: Bool) throws -> ResolvedBookmark {
        guard let text = String(data: bookmark, encoding: .utf8), text.hasPrefix(Self.prefix) else {
            throw FolderBookmarkError.unresolvable
        }
        let path = String(text.dropFirst(Self.prefix.count))
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FolderBookmarkError.unresolvable
        }
        return ResolvedBookmark(url: URL(fileURLWithPath: path, isDirectory: true), isStale: false)
    }

    public func startAccessing(_ url: URL) -> Bool { false }
    public func stopAccessing(_ url: URL) {}
}
