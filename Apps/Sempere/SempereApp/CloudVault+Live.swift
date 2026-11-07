import Foundation
import Sempere
import SempereSync

// The provider half of `CloudVault` (SempereSync): the calls into iCloud Drive, which Linux Foundation does not
// have, the file coordination of a provider's folder, and the texts of its errors and progress.

extension CloudVault {
    /// True when `url` is in iCloud Drive (or another ubiquitous container).
    static func isUbiquitous(_ url: URL) -> Bool {
        if FileManager.default.isUbiquitousItem(at: url) { return true }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// Where one vault file stands, read fresh (resource values are cached per URL).
    static func state(of item: CloudScan.Item) -> CloudItemState {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: item.url.path)
        if !exists {
            return fm.fileExists(atPath: CloudPlaceholder.placeholderURL(for: item.url).path) ? .missing : .gone
        }
        var url = item.url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemDownloadingErrorKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .current }
        if let error = values.ubiquitousItemDownloadingError { return .failed(error.localizedDescription) }
        guard values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return .current }
        switch status {
        case .current: return .current
        case .downloaded: return .stale
        default: return .missing
        }
    }

    /// Runs `body` inside a coordinated read of `url` (nil: no coordination,
    /// for vaults outside iCloud), through `files` (`SystemFileCoordinator`: `NSFileCoordinator`).
    static func coordinatedRead<T>(_ url: URL?, files: any FileCoordinating = SystemFileCoordinator(),
                                   _ body: () throws -> T) throws -> T {
        try files.coordinatedRead(url, body)
    }

    /// Runs `body` inside a coordinated write of `url` (nil: no
    /// coordination), so iCloud uploads what `body` adds there.
    static func coordinatedWrite<T>(_ url: URL?, files: any FileCoordinating = SystemFileCoordinator(),
                                    _ body: () throws -> T) throws -> T {
        try files.coordinatedWrite(url, body)
    }
}

extension CloudVault.Hooks {
    /// iCloud Drive itself.
    static let live = CloudVault.Hooks(isUbiquitous: { CloudVault.isUbiquitous($0) },
                                       state: { CloudVault.state(of: $0) },
                                       request: { item in
        do { try FileManager.default.startDownloadingUbiquitousItem(at: item.url) } catch {
            throw CloudVault.CloudError.failed(name: item.url.lastPathComponent, reason: error.localizedDescription)
        }
    })
}

extension CloudVault.CloudError: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case let .timedOut(progress, seconds, _):
            let wait = String(localized: "\(seconds) seconds", comment: "A number of seconds")
            return String(localized: "iCloud Drive did not deliver the vault's files: \(progress.total - progress.downloaded) of \(progress.total) are still not downloaded after \(wait) without progress. Check that this device is online and signed in to iCloud Drive, then try again.",
                          comment: "The numbers are files not downloaded and all files; %@ is a number of seconds")
        case let .failed(name, reason, _):
            return String(localized: "iCloud Drive could not download “\(name)”: \(reason)",
                          comment: "%1$@ is a file name, %2$@ the reason iCloud gave")
        }
    }
}

extension CloudProgress: @retroactive CustomStringConvertible {
    public var description: String {
        let files = String(localized: "\(total) files", comment: "A number of files")
        if let server = source.serverName {
            return String(localized: "Downloading from \(server)… \(downloaded)/\(files)",
                          comment: "Progress; first %@ is a server's host name, second a number of files, e.g. “3/6 files”")
        }
        return String(localized: "Downloading from iCloud… \(downloaded)/\(files)",
                      comment: "Progress; %@ is a number of files, e.g. “3/6 files”")
    }
}
