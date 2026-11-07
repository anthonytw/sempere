import Foundation
import Sempere

/// Downloading a vault folder that lives in iCloud Drive before the app copies it in (Open Vault…, a
/// restore: `AppModel.downloadSourceFolder`). Files iCloud has not downloaded are placeholders that a plain
/// directory listing skips, so every file is requested and awaited first. The app never reads a vault in
/// place (docs/design/device-first-sync.md P7); folder targets in providers go through the sync engine's
/// `FolderRemote` and `UbiquitousFolderHooks` instead.
///
/// The provider calls (`isUbiquitousItem`, `startDownloadingUbiquitousItem`, the ubiquitous resource values)
/// are the app's: `Hooks.live`, `isUbiquitous` and `state(of:)` in its `CloudVault+Live.swift`, with the
/// errors' texts. Here is the download loop over whatever hooks it is given.
public enum CloudVault {
    public enum CloudError: Error, Equatable {
        /// No file finished downloading for `seconds`. (Each case names
        /// where the files come from, `CloudVault.Hooks.source`.)
        case timedOut(CloudProgress, seconds: Int, source: CloudSource = .iCloudDrive)
        /// iCloud (or the WebDAV server) refused or failed to download a file.
        case failed(name: String, reason: String, source: CloudSource = .iCloudDrive)

        /// Where the files come from.
        public var source: CloudSource {
            switch self {
            case .timedOut(_, _, let s), .failed(_, _, let s): return s
            }
        }
    }

    /// The provider calls (the app's `live`), replaceable in tests (the simulator has no iCloud).
    public struct Hooks: Sendable {
        public var isUbiquitous: @Sendable (URL) -> Bool
        public var state: @Sendable (CloudScan.Item) -> CloudItemState
        /// Asks iCloud to download the file.
        public var request: @Sendable (CloudScan.Item) throws -> Void
        /// Where the files come from, for the texts.
        public var source = CloudSource.iCloudDrive

        public init(isUbiquitous: @escaping @Sendable (URL) -> Bool, state: @escaping @Sendable (CloudScan.Item) -> CloudItemState,
                    request: @escaping @Sendable (CloudScan.Item) throws -> Void, source: CloudSource = .iCloudDrive) {
            self.isUbiquitous = isUbiquitous
            self.state = state
            self.request = request
            self.source = source
        }
    }

    /// Which files `download(vault:)` fetches.
    public enum Scope: Sendable {
        /// `vault.json`, the rewrap journal and `keys/`: enough to unlock.
        case essentials
        /// Everything, notes included.
        case everything
    }

    /// Makes the files of the vault at `url` local before they are read: asks
    /// iCloud for each file that is a placeholder or out of date, then waits
    /// for the missing ones, reporting progress (only when something is
    /// missing). Out-of-date files are requested but not waited for.
    ///
    /// Cancel the calling task to stop waiting (throws `CancellationError`).
    ///
    /// - Returns: false at once, touching nothing, when the vault is not in iCloud.
    /// - Throws: `CloudError.timedOut` when no file completes for
    ///   `stallTimeout`, `CloudError.failed` when iCloud reports an error,
    ///   or the listing error when a folder cannot be read.
    public static func download(vault url: URL, scope: Scope = .everything, hooks: Hooks,
                                stallTimeout: Duration = .seconds(90), pollInterval: Duration = .milliseconds(400),
                                progress: @Sendable (CloudProgress) async -> Void) async throws -> Bool {
        guard hooks.isUbiquitous(url) else { return false }
        let items = scope == .essentials ? try CloudScan.essentialItems(inVault: url) : try CloudScan.items(inVault: url)
        try await download(items: items, hooks: hooks, stallTimeout: stallTimeout, pollInterval: pollInterval,
                           progress: progress)
        return true
    }

    /// `download(vault:)` for a given list of files (one note's, say).
    public static func download(items: [CloudScan.Item], hooks: Hooks,
                                stallTimeout: Duration = .seconds(90), pollInterval: Duration = .milliseconds(400),
                                progress: @Sendable (CloudProgress) async -> Void) async throws {
        var pending: [CloudScan.Item] = []
        for item in items {
            let state = hooks.state(item)
            if state == .current || state == .gone { continue }
            try hooks.request(item)
            if state != .stale { pending.append(item) }
        }
        let total = pending.count
        guard total > 0 else { return }
        await progress(CloudProgress(total: total, downloaded: 0, source: hooks.source))
        let clock = ContinuousClock()
        var lastProgress = clock.now
        while !pending.isEmpty {
            try await Task.sleep(for: pollInterval)
            var still: [CloudScan.Item] = []
            for item in pending {
                switch hooks.state(item) {
                case .failed(let reason):
                    throw CloudError.failed(name: item.url.lastPathComponent, reason: reason, source: hooks.source)
                case .missing:
                    still.append(item)
                case .current, .stale, .gone:
                    break
                }
            }
            if still.count < pending.count { lastProgress = clock.now }
            pending = still
            let now = CloudProgress(total: total, downloaded: total - pending.count, source: hooks.source)
            await progress(now)
            if !pending.isEmpty, clock.now - lastProgress > stallTimeout {
                throw CloudError.timedOut(now, seconds: Int(stallTimeout.components.seconds), source: hooks.source)
            }
        }
    }
}
