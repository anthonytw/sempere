import Foundation
import Sempere
import SempereSync

/// Where the in-app vault store lives (docs/design/device-first-sync.md §2).
enum VaultStoreRoot {
    /// The app's App Group (entitled on iPhone and iPad builds only).
    static let appGroup = "group.io.github.anthonytw.sempere"

    /// The store's folder: `<App Group>/Library/Application Support/Sempere/Vaults` when the App Group
    /// container is there, else `fallback` (the Mac's). The folder
    /// is `completeUntilFirstUserAuthentication` (quick capture writes from the Lock Screen; every file
    /// is age-encrypted anyway).
    static func prepare(appGroup container: URL?, fallback: URL) -> URL {
        guard let container else { return fallback }
        let root = container.appendingPathComponent("Library/Application Support/Sempere/Vaults", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        return root
    }
}


/// Telling a folder whose drive or share is not there now from one that is gone (offline audit A-P2; review of #91, M2),
/// for folder targets and backups. Only a known removable root counts: a folder is on an absent drive when the volume
/// it is on is not mounted (`/Volumes/<name>` on a Mac; `…/LiveFiles/com.apple.filesystems.<daemon>/<name>` on iPadOS
/// and iOS, where USB drives and SMB shares appear) and that volume folder itself is absent. Anything else, a folder
/// and its parent deleted included, is gone: the user chooses it again (review of #72, G5).
///
/// Assumed on iOS, not yet checked on a device: a USB drive or an SMB share opened in Files resolves to a path under
/// `/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/<volume>/` (or `….smbclientd/<share>/`, and
/// for older drivers `….lifs/`), the bookmark records that path, and the app can tell whether the `<volume>` folder
/// exists without its security scope (it lists only mounted volumes). If the app cannot see it, a mounted drive whose
/// bookmark fails reads as unavailable (offline) rather than gone; a deleted folder elsewhere still reads as gone.
enum FolderReach {
    /// The path a bookmark recorded, read without resolving it (no mount, no scope): nil when it holds none.
    static func recordedPath(_ bookmark: Data) -> String? {
        (try? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark))?.path
    }

    /// The removable volume `path` is on, nil when it is on none: the package's rule (`FolderReachability`, shared
    /// with the CLI and `FolderTargetRun`).
    static func removableRoot(of path: String) -> String? { FolderReachability.removableRoot(of: path) }

    /// True when `path` is on a removable volume that is not mounted now: a drive not connected or a share not
    /// mounted, which a later run may find (`FolderReachability.isOnAbsentVolume`).
    static func isOnAbsentDrive(_ path: String, fileManager fm: FileManager = .default) -> Bool {
        FolderReachability.isOnAbsentVolume(path, fileManager: fm)
    }
}

