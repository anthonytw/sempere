import Foundation

/// Where a vault folder lives, judged from its path (docs/io.md, "Other
/// Files providers"). Pure logic, so it is testable without a provider.
///
/// Files on a cloud provider may not be on the device until read. iCloud
/// Drive and providers that report their items as ubiquitous (replicated
/// File Provider extensions, which is how the Mac's `~/Library/CloudStorage`
/// providers work) take the iCloud path (`CloudVault`): download requests,
/// dataless detection and coordinated reads and writes. A provider that does
/// not report its items as ubiquitous still materialises a file only for a
/// coordinated read, and sees a write only through a coordinated write: its
/// vault is coordinated too (`needsCoordination`), while the download
/// requests stay off (there is no downloading status to wait for).
enum StorageLocation: Equatable, Sendable {
    /// This app's own container (Documents, Application Support: "On This
    /// Device" vaults and WebDAV copies).
    case appContainer
    /// iCloud Drive (`…/Library/Mobile Documents/…`).
    case iCloudDrive
    /// Another app's File Provider storage: `~/Library/CloudStorage/<Provider>-<account>/`
    /// on a Mac, a shared app-group container or `File Provider Storage` on
    /// iPadOS. `name` is the provider when the path says it (Mac).
    case fileProvider(name: String?)
    /// Anything else (an external drive, a server mounted in Files).
    case other

    /// Classifies `url`. `container` is this app's home (the sandbox).
    static func classify(_ url: URL, container: String = NSHomeDirectory()) -> StorageLocation {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: container).standardizedFileURL.resolvingSymlinksInPath().path
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains("Mobile Documents") { return .iCloudDrive }
        if let i = parts.firstIndex(of: "CloudStorage"), i > 0, parts[i - 1] == "Library", i + 1 < parts.count {
            let folder = parts[i + 1]
            let name = folder.split(separator: "-", maxSplits: 1).first.map(String.init)
            return .fileProvider(name: name?.isEmpty == false ? name : nil)
        }
        if parts.contains("File Provider Storage") { return .fileProvider(name: nil) }
        // iPadOS keeps other apps' provider files in shared app-group containers.
        if let i = parts.firstIndex(of: "Containers"), i + 2 < parts.count,
           parts[i + 1] == "Shared", parts[i + 2] == "AppGroup" {
            return .fileProvider(name: nil)
        }
        if path == home || path.hasPrefix(home.hasSuffix("/") ? home : home + "/") { return .appContainer }
        return .other
    }

    /// True for another app's provider storage.
    var isFileProvider: Bool {
        if case .fileProvider = self { return true }
        return false
    }

    /// Reads and writes go through `NSFileCoordinator` (iCloud Drive and other providers).
    var needsCoordination: Bool { self == .iCloudDrive || isFileProvider }
}
