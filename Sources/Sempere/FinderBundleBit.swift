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

    /// What `clearReporting(at:)` did.
    public enum ClearResult: Equatable, Sendable {
        /// The flag was not set (or the attribute is absent, or the platform has no Finder flags).
        case notSet
        /// It was set and is now cleared.
        case cleared
        /// It is set and could not be cleared (`errno` of the failing call), or the attribute could not be read.
        case failed(Int32)
    }

    /// Clears `kHasBundle` on the folder at `url` when it is set (the caller holds any security scope it needs).
    /// True when it was set and is now cleared; false when it was not set, the attribute cannot be read or written,
    /// or the platform has no Finder flags.
    @discardableResult
    public static func clear(at url: URL) -> Bool {
        clearReporting(at: url) == .cleared
    }

    /// `clear(at:)`, telling a flag that was not set from one that could not be cleared (logged by `BundleBitRepair`:
    /// a repair that fails silently every run looked like one that never ran).
    public static func clearReporting(at url: URL) -> ClearResult {
        #if canImport(Darwin)
        let path = url.path
        // Never through a symbolic link named like a vault: its target may be a real package (review of #123).
        let options = XATTR_NOFOLLOW
        let size = getxattr(path, attributeName, nil, 0, 0, options)
        if size < 0 { return [ENOATTR, ENOTSUP, ENOENT].contains(errno) ? .notSet : .failed(errno) }
        guard size > 0, size <= 64 else { return .notSet }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &buffer, size, 0, options)
        guard read == size else { return .failed(errno) }
        switch cleared(Data(buffer)) {
        case .unchanged:
            return .notSet
        case .rewrite(let bytes):
            let written = bytes.withUnsafeBytes { setxattr(path, attributeName, $0.baseAddress, bytes.count, 0, options) }
            return written == 0 ? .cleared : .failed(errno)
        case .remove:
            return removexattr(path, attributeName, options) == 0 ? .cleared : .failed(errno)
        }
        #else
        return .notSet
        #endif
    }

    /// Whether the folder at `url` has `kHasBundle` set, read only (`sempere vault conflicts`); nil when the attribute
    /// cannot be read or the platform has no Finder flags. False when the folder has no `com.apple.FinderInfo`.
    public static func isSet(at url: URL) -> Bool? {
        #if canImport(Darwin)
        let path = url.path
        let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 { return errno == ENOATTR ? false : nil }
        guard size <= 64 else { return nil }
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        let read = getxattr(path, attributeName, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read == size else { return nil }
        return isSet(in: Data(buffer.prefix(size)))
        #else
        return nil
        #endif
    }

    /// `clear(at:)` on each of `urls` named like a vault or a backup folder (`appliesTo`); the ones it cleared.
    @discardableResult
    public static func clearFolders(_ urls: [URL]) -> [URL] {
        urls.filter { appliesTo($0) && clear(at: $0) }
    }

    /// Whether `url` is a vault or a backup folder, the folders whose flag Sempere clears: named like one
    /// (`….sempere`, `….sempere-backup`, a plain sync folder `… Sempere Vault`: `BackupDestination.isHolderName`), or
    /// holding a `vault.json` or `backup.json` whatever its name (a folder sync target of any name: the flag makes a
    /// folder without an extension a package too).
    public static func appliesTo(_ url: URL) -> Bool {
        if BackupDestination.isHolderName(url) { return true }
        let fm = FileManager.default
        return BackupDestination.isVault(url, fm) || BackupDestination.isBackup(url, fileManager: fm)
    }
}
