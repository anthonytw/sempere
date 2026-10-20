#if canImport(Darwin)
import Foundation

// MARK: - iCloud Drive and other providers on Apple platforms (docs/io.md "Folder targets in providers")
//
// What `FolderRemote` needs from a provider, with Foundation's Apple-only API
// (compiled out on Linux; `check-portability.sh` allows Foundation). Ported
// from the app's iCloud code, which keeps its own copy until the app reads
// only its working copy (design §7, phase P6):
//
// - classification (`FolderLocation`, moved from `StorageLocation`): iCloud
//   Drive and other apps' File Provider storage are a provider's; their reads
//   and writes are coordinated (`NSFileCoordinator`, as `CloudVault`);
// - for a folder whose items are ubiquitous (iCloud Drive, replicated File
//   Provider extensions): `.<name>.icloud` stand-ins, dataless files
//   (`SF_DATALESS`, or a "not downloaded" downloading status), download
//   requests (`startDownloadingUbiquitousItem`) and download errors (`CloudVault.state`);
// - conflict versions (`NSFileVersion`, as `CloudConflicts.liveConflicts` /
//   `liveResolve`), resolved inside a coordinated write;
// - change hints from an `NSFilePresenter` on the base (as `NotesFolderPresenter`):
//   any process writing with `NSFileCoordinator` (iCloud's daemon, the app) is heard.

/// The provider hooks of a folder on an Apple platform (see above).
public final class UbiquitousFolderHooks: FolderProvider, @unchecked Sendable {
    /// Where the folder is, from its path.
    public let location: FolderLocation
    /// The folder's items report a downloading status (iCloud Drive, replicated providers).
    public let ubiquitous: Bool

    /// `SF_DATALESS` (sys/stat.h): the file's bytes are not on this device.
    static let datalessFlag: UInt32 = 0x4000_0000

    public init(root: URL, location: FolderLocation? = nil, ubiquitous: Bool? = nil) {
        let loc = location ?? FolderLocation.classify(root)
        self.location = loc
        self.ubiquitous = ubiquitous ?? (loc == .iCloudDrive || Self.isUbiquitous(root))
    }

    public var name: String {
        switch location {
        case .iCloudDrive: return "iCloud Drive"
        case .fileProvider(let n?): return n
        case .fileProvider(nil): return "the folder's provider"
        default: return ubiquitous ? "the folder's provider" : "a folder"
        }
    }

    public var managesFiles: Bool { ubiquitous || location.needsCoordination }

    /// True when `url` (or, if it does not exist yet, the nearest folder above it) is ubiquitous.
    static func isUbiquitous(_ url: URL) -> Bool {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        if FileManager.default.isUbiquitousItem(at: u) { return true }
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    public func standInRealName(_ name: String) -> String? {
        ubiquitous ? UbiquitousPlaceholder.realName(of: name) : nil
    }

    public func availability(of url: URL, stat: FolderItemStat) -> RemoteAvailability {
        guard ubiquitous else { return .available }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemDownloadingErrorKey, .ubiquitousItemIsDownloadingKey]
        let dataless = stat.flags & Self.datalessFlag != 0
        guard let values = try? fresh.resourceValues(forKeys: keys) else { return dataless ? .remoteOnly : .available }
        if let error = values.ubiquitousItemDownloadingError { return .failed(error.localizedDescription) }
        guard values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else {
            return dataless ? .remoteOnly : .available
        }
        switch status {
        case .current, .downloaded:
            // A local copy (perhaps not the newest: the provider replaces it when the new one arrives).
            return dataless ? .remoteOnly : .available
        default:
            return values.ubiquitousItemIsDownloading == true ? .downloading : .remoteOnly
        }
    }

    public func requestDownload(_ url: URL) throws {
        guard ubiquitous else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    public func coordinatedRead<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        guard managesFiles else { return try body() }
        var result: Result<T, any Error>?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { _ in
            result = Result { try body() }
        }
        return try Self.finish(result, error, url)
    }

    public func coordinatedWrite<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        guard managesFiles else { return try body() }
        var result: Result<T, any Error>?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
            result = Result { try body() }
        }
        return try Self.finish(result, error, url)
    }

    private static func finish<T>(_ result: Result<T, any Error>?, _ error: NSError?, _ url: URL) throws -> T {
        if let result { return try result.get() }
        throw error ?? CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }

    public func conflictVersions(of url: URL) -> [RemoteVersion] {
        guard managesFiles, FileManager.default.fileExists(atPath: url.path) else { return [] }
        return (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
            RemoteVersion(id: $0.url.path, modified: $0.modificationDate, device: $0.localizedNameOfSavingComputer)
        }
    }

    public func versionFile(of url: URL, id: String) -> URL? {
        guard managesFiles else { return nil }
        return (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).first { $0.url.path == id }?.url
    }

    /// Marks the versions resolved and removes them, in a coordinated write; one
    /// that appeared since (not in `ids`) is left for the next run.
    public func resolveConflicts(of url: URL, ids: Set<String>) throws {
        guard managesFiles, !ids.isEmpty else { return }
        try coordinatedWrite(url) {
            for v in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] where ids.contains(v.url.path) {
                v.isResolved = true
                try v.remove()
            }
        }
    }

    public func changes(below root: URL) -> AsyncStream<RemoteChange>? {
        AsyncStream { continuation in
            let presenter = FolderPresenter(root: root) { continuation.yield($0) }
            NSFileCoordinator.addFilePresenter(presenter)
            continuation.onTermination = { _ in NSFileCoordinator.removeFilePresenter(presenter) }
        }
    }
}

/// An `NSFilePresenter` on a folder target's base: every item a coordinated
/// writer adds, changes, moves or removes below it is reported, as its path
/// below the base (the base itself: `.unknown`). Hints, not a log: a missed
/// one delays a change until the next run, never loses it.
final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let base: [String]
    private let onChange: @Sendable (RemoteChange) -> Void

    init(root: URL, onChange: @escaping @Sendable (RemoteChange) -> Void) {
        let url = root.standardizedFileURL
        presentedItemURL = url
        base = url.resolvingSymlinksInPath().pathComponents
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        self.onChange = onChange
        super.init()
    }

    /// The path of `url` below the base; nil for the base itself or anything outside it.
    static func path(of url: URL, base: [String]) -> [String]? {
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return Array(parts.dropFirst(base.count))
    }

    private func report(_ url: URL) {
        if let p = Self.path(of: url, base: base) { onChange(.paths([p])) } else { onChange(.unknown) }
    }

    func presentedSubitemDidChange(at url: URL) { report(url) }
    func presentedSubitemDidAppear(at url: URL) { report(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        report(oldURL)
        report(newURL)
    }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        report(url)
        completionHandler(nil)
    }
    func presentedItemDidChange() { onChange(.unknown) }
}
#endif
