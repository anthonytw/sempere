import Foundation

/// Reading and writing a vault that lives in iCloud Drive (docs/io.md,
/// "iCloud Drive"). Files iCloud has not downloaded are placeholders that a
/// plain directory listing skips, so before reading, every vault file is
/// requested and awaited; reads and writes then go through
/// `NSFileCoordinator` so iCloud sees them. Vaults elsewhere skip all of it.
enum CloudVault {
    enum CloudError: Error, Equatable, CustomStringConvertible {
        /// No file finished downloading for `seconds`. (Each case names
        /// where the files come from, `CloudVault.Hooks.source`.)
        case timedOut(CloudProgress, seconds: Int, source: CloudSource = .iCloudDrive)
        /// iCloud (or the WebDAV server) refused or failed to download a file.
        case failed(name: String, reason: String, source: CloudSource = .iCloudDrive)
        /// A note was about to be read while `missing` of its `total` revision
        /// files were not local (0 of 0: its folder is not listed yet).
        case noteNotLocal(missing: Int, total: Int, source: CloudSource = .iCloudDrive)
        /// An attachment was about to be read while its file was not local.
        case blobNotLocal(name: String, source: CloudSource = .iCloudDrive)

        /// Where the files come from.
        var source: CloudSource {
            switch self {
            case .timedOut(_, _, let s), .failed(_, _, let s), .noteNotLocal(_, _, let s), .blobNotLocal(_, let s): return s
            }
        }

        var description: String {
            if let server = source.serverName { return serverDescription(server) }
            switch self {
            case let .timedOut(progress, seconds, _):
                let wait = String(localized: "\(seconds) seconds", comment: "A number of seconds")
                return String(localized: "iCloud Drive did not deliver the vault's files: \(progress.total - progress.downloaded) of \(progress.total) are still not downloaded after \(wait) without progress. Check that this device is online and signed in to iCloud Drive, then try again.",
                              comment: "The numbers are files not downloaded and all files; %@ is a number of seconds")
            case let .failed(name, reason, _):
                return String(localized: "iCloud Drive could not download “\(name)”: \(reason)",
                              comment: "%1$@ is a file name, %2$@ the reason iCloud gave")
            case let .noteNotLocal(missing, total, _) where total == 0:
                return String(localized: "iCloud Drive has not listed this note's files yet (\(missing) missing). Try again in a moment.",
                              comment: "[not-plural] the number is files missing")
            case let .noteNotLocal(missing, total, _):
                let files = String(localized: "\(total) files", comment: "A number of files")
                return String(localized: "\(missing) of this note's \(files) are not downloaded from iCloud Drive yet, so it was not opened (it would look empty or incomplete). Try again in a moment.",
                              comment: "%@ is a number of files, e.g. “3 of this note's 5 files”")
            case .blobNotLocal:
                return String(localized: "This attachment is not downloaded from iCloud Drive yet. Try again in a moment.")
            }
        }

        /// The same, for a partial WebDAV copy (`CloudSource.server`).
        private func serverDescription(_ server: String) -> String {
            switch self {
            case let .timedOut(progress, seconds, _):
                let wait = String(localized: "\(seconds) seconds", comment: "A number of seconds")
                return String(localized: "\(server) did not deliver the vault's files: \(progress.total - progress.downloaded) of \(progress.total) are still not downloaded after \(wait) without progress. Check that this device is online, then try again.",
                              comment: "First %@ is a server's host name; the numbers are files not downloaded and all files; last %@ is a number of seconds")
            case let .failed(name, reason, _):
                return String(localized: "“\(name)” could not be downloaded from \(server): \(reason)",
                              comment: "%1$@ is a file name, %2$@ a server's host name, %3$@ the reason")
            case .noteNotLocal:
                return String(localized: "This note is not downloaded from \(server) yet, so it was not opened (it would look empty or incomplete). Try again in a moment.",
                              comment: "%@ is a server's host name")
            case .blobNotLocal:
                return String(localized: "This attachment is not downloaded from \(server) yet. Try again in a moment.",
                              comment: "%@ is a server's host name")
            }
        }
    }

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

    /// The iCloud calls, replaceable in tests (the simulator has no iCloud).
    struct Hooks: Sendable {
        var isUbiquitous: @Sendable (URL) -> Bool
        var state: @Sendable (CloudScan.Item) -> CloudItemState
        /// Asks iCloud to download the file.
        var request: @Sendable (CloudScan.Item) throws -> Void
        /// Where the files come from, for the texts (a partial WebDAV copy's fetcher names its server).
        var source = CloudSource.iCloudDrive
        /// The versions iCloud kept of the file or folder at the URL from a conflict
        /// (`NSFileVersion.unresolvedConflictVersionsOfItem`); none outside iCloud.
        var conflicts: @Sendable (URL) -> [CloudConflictVersion] = { _ in [] }
        /// Marks those versions of the item resolved and removes them (after their content was merged).
        var resolve: @Sendable (URL, [CloudConflictVersion]) throws -> Void = { _, _ in }

        static let live = Hooks(isUbiquitous: { CloudVault.isUbiquitous($0) },
                                state: { CloudVault.state(of: $0) },
                                request: { item in
            do { try FileManager.default.startDownloadingUbiquitousItem(at: item.url) } catch {
                throw CloudError.failed(name: item.url.lastPathComponent, reason: error.localizedDescription)
            }
        }, conflicts: { CloudConflicts.liveConflicts(of: $0) },
           resolve: { try CloudConflicts.liveResolve($0, $1) })
    }

    /// Throws `noteNotLocal` unless every revision file of note `id` is
    /// local, listing its folder fresh. Run inside the coordinated read that
    /// loads the note, so a note is never shown from a partial log: plain
    /// reads skip `.icloud` stand-ins, and a folder iCloud has not listed yet
    /// reads as a note without pages.
    static func requireLocal(note id: UUID, vault url: URL, hooks: Hooks) throws {
        let items = try CloudScan.noteItems(inVault: url, id: id)
        let missing = items.filter { !hooks.state($0).isSettled }.count
        if items.isEmpty || missing > 0 {
            throw CloudError.noteNotLocal(missing: missing, total: items.count, source: hooks.source)
        }
    }

    /// Which files `download(vault:)` fetches.
    enum Scope: Sendable {
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
    /// The app fetches `.essentials` first (unlocking needs only those) and
    /// lets `ProgressiveLoad` bring the notes in as they arrive.
    ///
    /// Cancel the calling task to stop waiting (throws `CancellationError`).
    ///
    /// - Returns: false at once, touching nothing, when the vault is not in iCloud.
    /// - Throws: `CloudError.timedOut` when no file completes for
    ///   `stallTimeout`, `CloudError.failed` when iCloud reports an error,
    ///   or the listing error when a folder cannot be read.
    static func download(vault url: URL, scope: Scope = .everything, hooks: Hooks = .live,
                         stallTimeout: Duration = .seconds(90), pollInterval: Duration = .milliseconds(400),
                         progress: @Sendable (CloudProgress) async -> Void) async throws -> Bool {
        guard hooks.isUbiquitous(url) else { return false }
        let items = scope == .essentials ? try CloudScan.essentialItems(inVault: url) : try CloudScan.items(inVault: url)
        try await download(items: items, hooks: hooks, stallTimeout: stallTimeout, pollInterval: pollInterval,
                           progress: progress)
        return true
    }

    /// `download(vault:)` for a given list of files (one note's, say).
    static func download(items: [CloudScan.Item], hooks: Hooks = .live,
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

    /// Runs `body` inside a coordinated read of `url` (nil: no coordination,
    /// for vaults outside iCloud).
    static func coordinatedRead<T>(_ url: URL?, _ body: () throws -> T) throws -> T {
        guard let url else { return try body() }
        var result: Result<T, any Error>?
        var error: NSError?
        let wait = Perf.begin(.reconcileCoordinate)
        var granted = false
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { _ in
            Perf.end(wait, "read")
            granted = true
            result = Result { try body() }
        }
        if !granted { Perf.end(wait, "read refused") }
        return try finish(result, error, url)
    }

    /// Runs `body` inside a coordinated write of `url` (nil: no
    /// coordination), so iCloud uploads what `body` adds there.
    static func coordinatedWrite<T>(_ url: URL?, _ body: () throws -> T) throws -> T {
        guard let url else { return try body() }
        var result: Result<T, any Error>?
        var error: NSError?
        let wait = Perf.begin(.reconcileCoordinate)
        var granted = false
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
            Perf.end(wait, "write")
            granted = true
            result = Result { try body() }
        }
        if !granted { Perf.end(wait, "write refused") }
        return try finish(result, error, url)
    }

    private static func finish<T>(_ result: Result<T, any Error>?, _ error: NSError?, _ url: URL) throws -> T {
        if let result { return try result.get() }
        throw error ?? CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}
