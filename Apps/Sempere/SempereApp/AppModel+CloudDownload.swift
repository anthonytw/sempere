import Foundation
import Sempere

/// iCloud Drive has not delivered every note in time (`downloadEverything`).
enum CloudDownloadError: Error, Equatable, CustomStringConvertible {
    case notDownloaded(Int)
    /// The same, from the WebDAV server (host) of a partial copy.
    case notDownloadedFromServer(Int, String)

    var description: String {
        switch self {
        case .notDownloadedFromServer(let n, let server):
            return String(localized: "\(server) has not delivered \(n) notes yet. Every note must be on this device first. Check that it is online and try again.",
                          comment: "%@ is a server's host name, the number a count of notes")
        case .notDownloaded(let n):
            return String(localized: "iCloud Drive has not delivered \(n) notes yet. Every note must be on this device before the vault can be re-encrypted. Check that it is online and try again.")
        }
    }
}

/// Bringing a whole iCloud Drive vault onto this device, before a rewrap or a backup.
extension AppModel {
    /// Waits until every note folder is listed and every revision file is
    /// local (a rewrap must see them all: a file it cannot see would stay
    /// encrypted to the old keys only), requesting the downloads.
    func downloadEverything(_ url: URL, gen: Int, progress: (String) -> Void) async throws {
        let hooks = cloudHooks
        let window = cloudWindow
        let clock = ContinuousClock()
        var lastChange = clock.now
        var lastLocal = -1
        while true {
            let pass = try await offMain { try ProgressiveLoad.pass(vault: url, window: window, hooks: hooks) }
            try ensureCurrent(gen)
            if pass.pending.isEmpty {
                // The rewrap re-tags voice notes waiting in `inbox/` too (format.md
                // §3.3.1): an evicted one it could not see would never be adopted.
                let inbox = try await offMain { try CloudScan.inboxItems(inVault: url) }
                if !inbox.isEmpty {
                    try await CloudVault.download(items: inbox.map(\.item), hooks: hooks, stallTimeout: cloudStallTimeout,
                                                  pollInterval: cloudPollInterval) { _ in }
                    try ensureCurrent(gen)
                }
                return
            }
            if let server = cloudSource.serverName {
                progress(String(localized: "Downloading from \(server): \(pass.ready.count) of \(pass.all.count) notes…",
                                comment: "Progress: %@ is a server's host name, then notes downloaded so far of all notes"))
            } else {
                progress(String(localized: "Downloading from iCloud Drive: \(pass.ready.count) of \(pass.all.count) notes…",
                                comment: "Progress: notes downloaded so far of all notes"))
            }
            if pass.localFiles != lastLocal {
                lastLocal = pass.localFiles
                lastChange = clock.now
            } else if clock.now - lastChange > cloudStallTimeout {
                throw cloudSource.serverName.map { CloudDownloadError.notDownloadedFromServer(pass.pending.count, $0) }
                    ?? .notDownloaded(pass.pending.count)
            }
            try await Task.sleep(for: cloudPollInterval)
            try ensureCurrent(gen)
        }
    }
}
