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
        // A synced copy tries to send the last edits in the seconds iPadOS leaves the app;
        // a run cut off by the suspension is retried when the app comes back.
        syncSessions.forEach { $0.demand() }
        syncCoordinator.setInBackground(true)   // closed vaults' periodic runs pause meanwhile
        finishTargetRunsInBackground()
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
        endTargetsBackgroundTime()
        syncCoordinator.setInBackground(false)
        syncCoordinator.demandAll()   // every synced vault runs when the app comes back
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

    /// Asks for a background refresh while an iCloud vault is open in place, or any vault has a sync target
    /// (every vault and target, design §4.2); a processing task too while a target has changes to upload.
    func scheduleBackgroundRefresh() {
        if isCloudVault, vaultURL != nil {
            syncScheduler.schedule(syncInFlight ? .processing : .refresh)
            return
        }
        let sessions = syncCoordinator.sessions.values
        guard !sessions.isEmpty else { return }
        syncScheduler.schedule(.refresh)
        if sessions.contains(where: { $0.unconfirmed > 0 }) { syncScheduler.schedule(.processing) }
    }

    // MARK: - Every vault's targets (P8)

    /// The app left the screen with target runs going or asked for (the last edits, a voice note): they finish
    /// under background time (`beginBackgroundTask`), then it ends. When iOS takes the time back first, a
    /// processing task is asked for.
    func finishTargetRunsInBackground() {
        let coordinator = syncCoordinator
        guard !coordinator.sessions.isEmpty, targetsBackgroundToken == nil else { return }
        guard let token = backgroundTasks.begin(name: "Sempere sync", expired: { [weak self] in
            guard let self else { return }
            self.targetsBackgroundWait?.cancel()
            self.endTargetsBackgroundTime()
            self.syncScheduler.schedule(.processing)
        }) else { return }
        targetsBackgroundToken = token
        targetsBackgroundWait = Task { [weak self] in
            // Let the demands just made start their runs, then wait for every run to end.
            try? await Task.sleep(for: .milliseconds(100))
            await coordinator.waitForRunsToEnd()
            guard !Task.isCancelled else { return }
            self?.endTargetsBackgroundTime()
        }
    }

    /// Ends the targets' background-time assertion, if one is held.
    func endTargetsBackgroundTime() {
        targetsBackgroundWait?.cancel()
        targetsBackgroundWait = nil
        if let token = targetsBackgroundToken { backgroundTasks.end(token) }
        targetsBackgroundToken = nil
    }

    /// A scheduled task (`BackgroundSync`): the in-place iCloud vault's passes first, while one is open
    /// (`runScheduledSync`, until P7), then every vault's targets through the coordinator: a refresh shares its
    /// time out (`SyncCoordinator.runBackgroundRefresh`), a processing task runs full passes. iOS ending the
    /// task cancels this, which stops the runs between files. The next task is asked for at the end.
    func runBackgroundTask(_ kind: BackgroundSyncRequest) async {
        if isCloudVault, vaultURL != nil { _ = await runScheduledSync() }
        let coordinator = syncCoordinator
        if await coordinator.waitUntilStarted() {
            let cancel = SyncRunCancel()
            await withTaskCancellationHandler {
                switch kind {
                case .refresh: await coordinator.runBackgroundRefresh(cancel: cancel)
                case .processing: await coordinator.runBackgroundProcessing(cancel: cancel)
                }
            } onCancel: {
                cancel.cancel()
            }
        }
        scheduleBackgroundRefresh()
    }

    /// Ends the background-time assertion, if one is held.
    func endBackgroundTime() {
        if let token = backgroundSyncToken { backgroundTasks.end(token) }
        backgroundSyncToken = nil
    }

    /// A scheduled task (`BackgroundSync.run`): passes of the sync over
    /// every note folder, `cloudPollInterval` apart, until nothing is pending,
    /// the task is canceled (iOS ends it) or the vault closes. Nothing to do
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

extension AppModel {
    /// Starts watching the network for the WebDAV targets (once, at launch): coming back, they run soon.
    func startReachability() {
        guard reachability == nil else { return }
        let monitor = WebDAVReachability()
        reachability = monitor
        monitor.start { [weak self] reachable in self?.syncCoordinator.networkChanged(reachable: reachable) }
    }
}
