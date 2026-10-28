import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The Finder's "has bundle" flag (`kHasBundle`, 0x2000) on a vault or backup folder (docs/io.md "Vaults are
/// folders").
///
/// A folder whose `com.apple.FinderInfo` extended attribute has that flag set is shown as a package by the Finder,
/// Files and the pickers, and iCloud Drive syncs it as one item, so two devices writing into it make a conflict of
/// the whole vault (TestFlight 1.0.0 lost a note that way). Vaults and backups are plain folders: the flag found on
/// the owner's iCloud vault folders in build 12 (FinderInfo bytes `00 00 00 00 00 00 00 00 20 00 …`) is cleared,
/// and nothing else in the attribute is touched.
public enum FinderBundleBit {
    /// The extended attribute holding the Finder's flags.
    public static let attributeName = "com.apple.FinderInfo"
    /// The Finder flags field: a big-endian `UInt16` at this offset of the 32-byte `FinderInfo` (`FolderInfo.finderFlags`
    /// for a folder, `FileInfo.finderFlags` for a file: the same place).
    static let flagsOffset = 8
    /// `kHasBundle`, in the high byte of the big-endian flags.
    static let hasBundleHighByte: UInt8 = 0x20

    /// What clearing the flag does to an attribute's bytes.
    public enum Change: Equatable, Sendable {
        /// The flag is not set (or the bytes are too short to hold the flags): leave the attribute as it is.
        case unchanged
        /// Write these bytes back: the same, with the flag cleared.
        case rewrite(Data)
        /// Every byte is zero once the flag is cleared: remove the attribute.
        case remove
    }

    /// Whether `info` (a `com.apple.FinderInfo` value) has `kHasBundle` set.
    public static func isSet(in info: Data) -> Bool {
        guard info.count > flagsOffset else { return false }
        return info[info.startIndex + flagsOffset] & hasBundleHighByte != 0
    }

    /// `info` with `kHasBundle` cleared and every other byte kept.
    public static func cleared(_ info: Data) -> Change {
        guard isSet(in: info) else { return .unchanged }
        var bytes = [UInt8](info)
        bytes[flagsOffset] &= ~hasBundleHighByte
        return bytes.allSatisfy { $0 == 0 } ? .remove : .rewrite(Data(bytes))
    }

    /// Clears `kHasBundle` on the folder at `url` when it is set (the caller holds any security scope it needs).
    /// True when it was set and is now cleared; false when it was not set, the attribute cannot be read or written,
    /// or the platform has no Finder flags.
    @discardableResult
    public static func clear(at url: URL) -> Bool {
        #if canImport(Darwin)
        let path = url.path
        // Never through a symbolic link named like a vault: its target may be a real package (review of #123).
        let options = XATTR_NOFOLLOW
        let size = getxattr(path, attributeName, nil, 0, 0, options)
        guard size > 0, size <= 64 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &buffer, size, 0, options)
        guard read == size else { return false }
        switch cleared(Data(buffer)) {
        case .unchanged:
            return false
        case .rewrite(let bytes):
            let written = bytes.withUnsafeBytes { setxattr(path, attributeName, $0.baseAddress, bytes.count, 0, options) }
            return written == 0
        case .remove:
            return removexattr(path, attributeName, options) == 0
        }
        #else
        return false
        #endif
    }

    /// `clear(at:)` on each of `urls` named like a vault or a backup folder (`appliesTo`); the ones it cleared.
    @discardableResult
    public static func clearFolders(_ urls: [URL]) -> [URL] {
        urls.filter { appliesTo($0) && clear(at: $0) }
    }

    /// Whether `url` is named like a vault or a backup folder (`….sempere`, `….sempere-backup`): the folders whose
    /// flag Sempere clears.
    public static func appliesTo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == BackupDestination.vaultExtension || ext == BackupDestination.folderExtension
    }
}
