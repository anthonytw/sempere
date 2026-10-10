import Foundation
import Sempere

/// The iCloud sync when the app leaves the screen (`BackgroundSync`): a sync
/// in flight is finished under background time; afterwards, and when that
/// time runs out, `BGTaskScheduler` tasks continue it if iOS grants them.
extension AppModel {
    /// Whether the sync still has work: notes downloading or listed as
    /// placeholders, or the vault's own files being fetched.
    var syncInFlight: Bool {
        isCloudVault && (!pendingNoteIDs.isEmpty || !placeholderNoteIDs.isEmpty || cloudProgress != nil
                         || cloudSync?.isDownloading == true)
    }

    /// The app left the screen. With a sync in flight the loop keeps running
    /// under a background-time assertion until nothing is pending
    /// (`finishBackgroundSync`) or the time runs out (`backgroundTimeExpired`);
    /// otherwise it pauses at once, as before. Either way a refresh is
    /// scheduled while an iCloud vault is open.
    func enterBackground() {
        // A WebDAV copy tries to push the last edits in the seconds iPadOS leaves the app;
        // a push cut off by the suspension is retried when the app comes back.
        webdav?.demand()
        guard isCloudVault, cloudSyncTask != nil, syncInFlight, backgroundSyncToken == nil else {
            pauseCloudSync()
            scheduleBackgroundRefresh()
            return
        }
        guard let token = backgroundTasks.begin(name: "Sempere iCloud sync", expired: { [weak self] in
            self?.backgroundTimeExpired()
        }) else {
            pauseCloudSync()
            syncScheduler.schedule(.processing)
            return
        }
        Perf.event(.backgroundSync, "continue pending=\(pendingNoteIDs.count)")
        backgroundSyncToken = token
        syncingInBackground = true
        saveSummaryCacheIfDue(force: true)   // the app may not come back
    }

    /// The app is on screen again: background work ends (the caller restarts the loop).
    func enterForeground() {
        syncingInBackground = false
        endBackgroundTime()
        webdav?.demand()   // a WebDAV copy pushes when the app comes back
    }

    /// The loop found nothing pending while finishing in the background: it
    /// pauses, the assertion ends, and a refresh is scheduled.
    func finishBackgroundSync() {
        Perf.event(.backgroundSync, "settled")
        syncingInBackground = false
        pauseCloudSync()
        endBackgroundTime()
        scheduleBackgroundRefresh()
    }

    /// iOS takes the background time back with notes still pending: the loop
    /// pauses and a processing task is asked for to continue.
    func backgroundTimeExpired() {
        Perf.event(.backgroundSync, "expired pending=\(pendingNoteIDs.count)")
        syncingInBackground = false
        pauseCloudSync()
        endBackgroundTime()
        syncScheduler.schedule(.processing)
    }

    /// Asks for a background refresh while an iCloud vault is open.
    func scheduleBackgroundRefresh() {
        guard isCloudVault, vaultURL != nil else { return }
        syncScheduler.schedule(syncInFlight ? .processing : .refresh)
    }

    /// Ends the background-time assertion, if one is held.
    func endBackgroundTime() {
        if let token = backgroundSyncToken { backgroundTasks.end(token) }
        backgroundSyncToken = nil
    }

    /// A scheduled task (`BackgroundSync.handle`): passes of the sync over
    /// every note folder, `cloudPollInterval` apart, until nothing is pending,
    /// the task is cancelled (iOS ends it) or the vault closes. Nothing to do
    /// without an iCloud vault open in this process.
    ///
    /// - Returns: whether the sync settled.
    func runScheduledSync() async -> Bool {
        guard isCloudVault, vaultURL != nil else { return false }
        let gen = generation
        Perf.event(.backgroundSync, "scheduled pending=\(pendingNoteIDs.count)")
        while !Task.isCancelled, gen == generation {
            do {
                if try await reconcile(scope: nil) == 0 {
                    saveSummaryCacheIfDue(force: true)
                    return true
                }
            } catch is CancellationError {
                break
            } catch {
                cloudSync?.problem = "\(error)"
            }
            do { try await Task.sleep(for: cloudPollInterval) } catch { break }
        }
        if gen == generation { saveSummaryCacheIfDue(force: true) }
        return false
    }
}
