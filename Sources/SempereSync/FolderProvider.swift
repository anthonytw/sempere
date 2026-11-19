import Foundation

// MARK: - What holds a folder target (docs/io.md "Folder targets in providers")
//
// `FolderRemote` reads and writes a plain directory with POSIX calls. Where
// that directory is held by a provider (iCloud Drive, another File Provider:
// Dropbox, Proton Drive, OneDrive on a Mac), files may be evicted, folders
// listed before their files, other processes may write at the same time and
// the provider may fork conflict versions. A `FolderProvider` supplies those
// provider-specific answers; the folder transport keeps every rule
// (docs/design/device-first-sync.md §3.3):
//
// - `PlainFolder`: nothing evicted, no coordination (conditional writes then
//   use a lock file), no versions, no change hints. The default on Linux.
// - `UbiquitousFolderHooks` (Darwin only): `NSFileCoordinator`,
//   `startDownloadingUbiquitousItem`, downloading status and dataless files,
//   `NSFileVersion` conflict versions and an `NSFilePresenter` for change
//   hints, for the folders `FolderLocation` classifies as a provider's. The
//   default on Apple platforms (a plain folder there gets only the hints).
// - `EvictingFolderProvider`: a provider simulated on any file system, for
//   tests (placeholders, dataless files, unlisted folders, delayed delivery,
//   conflict versions).

/// What `lstat(2)` says about one item of a folder, as `FolderRemote` and providers use it.
public struct FolderItemStat: Sendable, Hashable {
    public var isDirectory: Bool
    public var isRegularFile: Bool
    public var size: Int64
    /// 512-byte blocks allocated (a dataless file has none).
    public var blocks: Int64
    /// `st_flags` (Darwin: `SF_DATALESS` and others); 0 elsewhere.
    public var flags: UInt32
    public var device: UInt64
    public var inode: UInt64
    public var modifiedNanoseconds: Int64
    public var changedNanoseconds: Int64

    public init(isDirectory: Bool, isRegularFile: Bool, size: Int64, blocks: Int64 = 0, flags: UInt32 = 0,
                device: UInt64 = 0, inode: UInt64 = 0, modifiedNanoseconds: Int64 = 0, changedNanoseconds: Int64 = 0) {
        self.isDirectory = isDirectory; self.isRegularFile = isRegularFile; self.size = size; self.blocks = blocks
        self.flags = flags; self.device = device; self.inode = inode
        self.modifiedNanoseconds = modifiedNanoseconds; self.changedNanoseconds = changedNanoseconds
    }
}

/// The provider-specific half of a folder target (see above). Every method
/// may be called from several threads at once.
public protocol FolderProvider: Sendable {
    /// What holds the folder, for messages ("iCloud Drive", "a folder").
    var name: String { get }
    /// True when a provider manages the folder's files: listings map stand-in
    /// names, files and folders have an availability, a folder that lists no
    /// file yet is "listed before its files", and reads and writes are
    /// coordinated (a plain folder's conditional writes take a lock file instead).
    var managesFiles: Bool { get }
    /// The real name a stand-in listed in a folder stands for (`.<name>.icloud`); nil when `name` is none.
    func standInRealName(_ name: String) -> String?
    /// Whether the item at `url` (a file or folder, as `stat` describes it) can be read now.
    func availability(of url: URL, stat: FolderItemStat) -> RemoteAvailability
    /// Asks the provider to bring the item at `url` here (a file, or a folder's listing).
    func requestDownload(_ url: URL) throws
    /// Runs `body`, a read of the item at `url`, so that the provider sees it (and fetches what it needs).
    func coordinatedRead<T>(_ url: URL, _ body: () throws -> T) throws -> T
    /// Runs `body`, a write of the item at `url`, so that the provider sees it (and uploads it).
    func coordinatedWrite<T>(_ url: URL, _ body: () throws -> T) throws -> T
    /// The other versions the provider keeps of the file at `url` after a conflict.
    func conflictVersions(of url: URL) -> [RemoteVersion]
    /// Where the bytes of the version `id` of the file at `url` can be read; nil when there is no such version.
    func versionFile(of url: URL, id: String) -> URL?
    /// Marks the versions `ids` of the file at `url` resolved and removes them.
    func resolveConflicts(of url: URL, ids: Set<String>) throws
    /// Marks the versions `ids` of the item at `url` (a file or a folder) resolved and keeps them: the system's
    /// version browser still has them (`sempere vault conflicts --merge` without `--remove-versions`).
    func markConflictsResolved(of url: URL, ids: Set<String>) throws
    /// What the provider records about the item at `url` (a vault or sync folder): held as a package, its type, whether
    /// it has unresolved conflict versions. Resource values only, no walk: cheap enough for every run. Nil when the
    /// provider records nothing of the kind (a plain folder, Linux).
    func itemRecord(of url: URL) -> ProviderItemRecord?
    /// Hints that something below `root` changed; nil when the provider cannot give any (poll).
    func changes(below root: URL) -> AsyncStream<RemoteChange>?
}

extension FolderProvider {
    public func standInRealName(_ name: String) -> String? { nil }
    public func availability(of url: URL, stat: FolderItemStat) -> RemoteAvailability { .available }
    public func requestDownload(_ url: URL) throws {}
    public func coordinatedRead<T>(_ url: URL, _ body: () throws -> T) throws -> T { try body() }
    public func coordinatedWrite<T>(_ url: URL, _ body: () throws -> T) throws -> T { try body() }
    public func conflictVersions(of url: URL) -> [RemoteVersion] { [] }
    public func versionFile(of url: URL, id: String) -> URL? { nil }
    public func resolveConflicts(of url: URL, ids: Set<String>) throws {}
    public func markConflictsResolved(of url: URL, ids: Set<String>) throws {}
    public func itemRecord(of url: URL) -> ProviderItemRecord? { nil }
    public func changes(below root: URL) -> AsyncStream<RemoteChange>? { nil }
}

/// What a provider records about one item (`FolderProvider.itemRecord`; docs/io.md "A vault folder held as a package").
///
/// iCloud Drive decides when it first records a folder whether it is a package (its type conformed to
/// `com.apple.package`, or the Finder's `kHasBundle` flag was set) and keeps that record: a package is synced as ONE
/// item, so two devices writing into it make whole-vault conflict versions (`NSFileVersion`), and a file only the
/// losing side had is missing from the folder until it is merged back (`sempere vault conflicts --merge`).
public struct ProviderItemRecord: Codable, Hashable, Sendable {
    /// The provider's `isPackage` for the item; nil when it says nothing.
    public var isPackage: Bool?
    /// The item's content type identifier as the provider reports it (`dyn.…` for a type made up from the extension).
    public var contentType: String?
    /// Whether that type conforms to `com.apple.package`; nil when unknown.
    public var typeIsPackage: Bool?
    /// The Finder's `kHasBundle` flag on the folder (`FinderBundleBit`); nil when it cannot be read.
    public var finderBundleBit: Bool?
    /// The item is in iCloud Drive or another provider that syncs it.
    public var ubiquitous: Bool
    /// The provider's `ubiquitousItemHasUnresolvedConflicts` for the item itself; nil when it says nothing.
    public var hasUnresolvedConflicts: Bool?

    public init(isPackage: Bool? = nil, contentType: String? = nil, typeIsPackage: Bool? = nil, finderBundleBit: Bool? = nil,
                ubiquitous: Bool = false, hasUnresolvedConflicts: Bool? = nil) {
        self.isPackage = isPackage; self.contentType = contentType; self.typeIsPackage = typeIsPackage
        self.finderBundleBit = finderBundleBit; self.ubiquitous = ubiquitous; self.hasUnresolvedConflicts = hasUnresolvedConflicts
    }

    /// The provider syncs the folder as one item: it says so, or its type is a package, or the Finder flag is set.
    public var heldAsPackage: Bool { isPackage == true || typeIsPackage == true || finderBundleBit == true }

    /// Why it is held as a package, for people: the Finder flag (which the app and the CLI clear at each run), or the
    /// provider's own record (which clearing nothing changes: the folder must be made again).
    public var packageCause: PackageCause? {
        guard heldAsPackage else { return nil }
        return finderBundleBit == true ? .finderBundleBit : .providerRecord
    }

    /// See `packageCause`.
    public enum PackageCause: String, Codable, Hashable, Sendable {
        /// `kHasBundle` in `com.apple.FinderInfo`: cleared by `BundleBitRepair` / `clearBundleBits`.
        case finderBundleBit
        /// The provider's (iCloud Drive's) own record of the item, or its type: only a new folder is plain.
        case providerRecord
    }
}

/// A folder no provider manages (a local folder, a USB drive, a network share):
/// every file is here, nothing is coordinated, there are no versions or hints.
public struct PlainFolder: FolderProvider {
    public init() {}
    public var name: String { "a folder" }
    public var managesFiles: Bool { false }
}

/// The provider of a folder, as this platform can tell: on Apple platforms
/// `UbiquitousFolderHooks` (which classify the path), elsewhere `PlainFolder`.
public enum FolderProviders {
    public static func detect(_ root: URL) -> any FolderProvider {
        #if canImport(Darwin)
        return UbiquitousFolderHooks(root: root)
        #else
        return PlainFolder()
        #endif
    }
}

/// iCloud Drive's stand-ins for files it has not downloaded: a hidden
/// `.<name>.icloud` next to where the file would be (the real name may
/// instead be listed as a dataless file). Moved from the app's `CloudPlaceholder`.
public enum UbiquitousPlaceholder {
    public static let suffix = ".icloud"

    /// The real name a stand-in stands for (`.vault.json.icloud` → `vault.json`); nil when `name` is none.
    public static func realName(of name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > 1 + suffix.count else { return nil }
        return String(name.dropFirst().dropLast(suffix.count))
    }

    /// The stand-in name of `name` (`vault.json` → `.vault.json.icloud`).
    public static func standInName(for name: String) -> String { "." + name + suffix }
}

/// Where a folder lives, judged from its path (docs/io.md "Other Files
/// providers"). Pure logic, so it is testable without a provider. Moved from
/// the app's `StorageLocation` (which is now this type).
///
/// Files on a cloud provider may not be on the device until read. iCloud
/// Drive and providers that report their items as ubiquitous (replicated
/// File Provider extensions, which is how the Mac's `~/Library/CloudStorage`
/// providers work) get download requests, dataless detection and coordinated
/// reads and writes. A provider that does not report its items as ubiquitous
/// still materializes a file only for a coordinated read, and sees a write
/// only through a coordinated write: its folder is coordinated too
/// (`needsCoordination`), while the download requests stay off.
public enum FolderLocation: Equatable, Sendable {
    /// This app's own container (Documents, Application Support).
    case appContainer
    /// iCloud Drive (`…/Library/Mobile Documents/…`).
    case iCloudDrive
    /// Another app's File Provider storage: `~/Library/CloudStorage/<Provider>-<account>/`
    /// on a Mac, a shared app-group container or `File Provider Storage` on
    /// iPadOS. `name` is the provider when the path says it (Mac).
    case fileProvider(name: String?)
    /// Anything else (an external drive, a server mounted in Files, a plain folder).
    case other

    /// Classifies `url`. `container` is this app's home (the sandbox).
    public static func classify(_ url: URL, container: String = NSHomeDirectory()) -> FolderLocation {
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
    public var isFileProvider: Bool {
        if case .fileProvider = self { return true }
        return false
    }

    /// Reads and writes go through `NSFileCoordinator` (iCloud Drive and other providers).
    public var needsCoordination: Bool { self == .iCloudDrive || isFileProvider }
}
