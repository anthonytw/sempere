import Foundation

/// Where a folder the app or the CLI reaches by its path stands now (offline audit A-P2; review of #91, M2): a sync
/// target's folder or a backup folder whose bookmark no longer resolves (a USB drive unplugged, a share not mounted)
/// is judged by the path it had. Only a known removable root counts: a folder is unavailable when the removable volume
/// it is on is not mounted now (that volume's folder is absent). Anything else that is not there, a folder deleted
/// together with the folder it was in included, is gone: the user chooses it again (review of #72, G5).
public enum FolderReachability: Equatable, Sendable {
    /// The folder is there.
    case reachable
    /// The removable volume it is on is not mounted now (a drive not connected, a share not mounted): a later run
    /// may find it. Shown as offline, not as a problem to fix.
    case unavailable
    /// The folder is not there, and its volume is (or it is on no removable volume): deleted or moved.
    case missing

    /// The state of the folder at `path`.
    public static func of(path: String, fileManager fm: FileManager = .default) -> FolderReachability {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return .reachable }
        return isOnAbsentVolume(path, fileManager: fm) ? .unavailable : .missing
    }

    /// True when `path` is on a removable volume that is not mounted now. A folder about to be created there would
    /// land on the disk the mount point is on.
    ///
    /// `/Volumes/NAME`, LiveFiles and `/media/USER/NAME` folders exist only while their volume is mounted: absent means
    /// not mounted. Under `/mnt` (and for a `/media` folder listed in `/etc/fstab`) a mount point stays as an empty
    /// folder when its volume is away: it is unmounted when it is a mount point of `mountPoints` (default: `/etc/fstab`)
    /// on the same device as its parent. A plain `/mnt` folder that is no mount point is never unavailable (review of
    /// #90, N2).
    public static func isOnAbsentVolume(_ path: String, fileManager fm: FileManager = .default,
                                        mountPoints: Set<String>? = nil) -> Bool {
        guard let root = removableRoot(of: path) else { return false }
        let listed = (mountPoints ?? fstabMountPoints()).contains(root)
        guard fm.fileExists(atPath: root) else {
            // Gone with its volume, except a plain `/mnt` subfolder (no mount point: created when needed).
            return !root.hasPrefix("/mnt/") || listed
        }
        guard listed else { return false }
        // A listed mount point on the same device as its parent: nothing is mounted on it now.
        let parent = (root as NSString).deletingLastPathComponent
        guard let a = (try? fm.attributesOfItem(atPath: root))?[.systemNumber] as? NSNumber,
              let b = (try? fm.attributesOfItem(atPath: parent))?[.systemNumber] as? NSNumber else { return false }
        return a == b
    }

    /// The mount points `/etc/fstab` lists (its second field), empty when it cannot be read.
    public static func fstabMountPoints(_ url: URL = URL(fileURLWithPath: "/etc/fstab")) -> Set<String> {
        guard let data = try? BoundedRead.contents(of: url, maxBytes: 1 << 20) else { return [] }
        var out = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, !fields[0].hasPrefix("#") else { continue }
            // fstab escapes a space in a path as \040.
            out.insert(String(fields[1]).replacingOccurrences(of: "\\040", with: " "))
        }
        return out
    }

    /// The removable volume `path` is on, nil when it is on none (the startup volume, iCloud Drive, a provider's
    /// storage): `/Volumes/NAME` on a Mac; `…/LiveFiles/com.apple.filesystems.D/NAME` on iPadOS and iOS (USB drives
    /// and SMB shares opened in Files; assumed from the layout, see the app's `FolderReach`); `/media/USER/NAME` and
    /// `/mnt/NAME` on Linux.
    public static func removableRoot(of path: String) -> String? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents   // "/", "Volumes", "NAME", …
        guard parts.first == "/" else { return nil }
        if parts.count >= 3, parts[1] == "Volumes" { return "/Volumes/" + parts[2] }
        if parts.count >= 4, parts[1] == "media" { return "/media/\(parts[2])/\(parts[3])" }
        if parts.count >= 3, parts[1] == "mnt" { return "/mnt/" + parts[2] }
        if let i = parts.firstIndex(where: { $0.hasPrefix("com.apple.filesystems.") }), i > 0, parts[i - 1] == "LiveFiles",
           i + 1 < parts.count {
            return NSString.path(withComponents: Array(parts[...(i + 1)]))
        }
        return nil
    }
}
