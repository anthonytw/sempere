import Foundation
import Sempere

/// Sync when the app leaves the screen (the app's `BackgroundSync`, docs/design/device-first-sync.md §4.2): runs going
/// or asked for finish under background time (`backgroundTasks`); afterwards scheduled tasks (`syncScheduler`) run
/// every vault's targets if the system grants them.
extension AppModelCore {
    /// The app left the screen: every synced vault's last edits go up under background time, and the next
    /// background task is asked for.
    public func enterBackground() {
        // A synced copy tries to send the last edits in the seconds iPadOS leaves the app;
        // a run cut off by the suspension is retried when the app comes back.
        syncSessions.forEach { $0.demand() }
        syncCoordinator.setInBackground(true)   // closed vaults' periodic runs pause meanwhile
        finishTargetRunsInBackground()
        saveSummaryCacheIfDue(force: true)   // the app may not come back
        scheduleBackgroundRefresh()
    }

    /// The app is on screen again: background work ends.
    public func enterForeground() {
        endTargetsBackgroundTime()
        syncCoordinator.setInBackground(false)
        syncCoordinator.demandAll()   // every synced vault runs when the app comes back
    }

    /// Asks for a background refresh while any vault has a sync target (every vault and target, design
    /// §4.2); a processing task too while a target has changes to upload.
    func scheduleBackgroundRefresh() {
        let sessions = syncCoordinator.sessions.values
        guard !sessions.isEmpty else { return }
        syncScheduler.schedule(.refresh)
        if sessions.contains(where: { $0.unconfirmed > 0 }) { syncScheduler.schedule(processingRequest) }
    }

    /// The processing task to ask for: it requires the network only while a WebDAV target has uploads waiting
    /// (offline audit A-P3).
    var processingRequest: BackgroundSyncRequest {
        .processing(needsNetwork: syncCoordinator.sessions.values.contains { $0.kind == .webdav && $0.unconfirmed > 0 })
    }

    // MARK: - Every vault's targets (P8)

    /// The app left the screen with target runs going or asked for (the last edits, a voice note): they finish
    /// under background time (`beginBackgroundTask`), then it ends. When the system takes the time back first, a
    /// processing task is asked for.
    func finishTargetRunsInBackground() {
        let coordinator = syncCoordinator
        guard !coordinator.sessions.isEmpty, targetsBackgroundToken == nil else { return }
        guard let token = backgroundTasks.begin(name: "Sempere sync", expired: { [weak self] in
            guard let self else { return }
            coordinator.cancelAllRuns()   // runs going stop between files, saving their state
            self.targetsBackgroundWait?.cancel()
            self.endTargetsBackgroundTime()
            self.syncScheduler.schedule(self.processingRequest)
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

    /// A scheduled task (`BackgroundSync`): every vault's targets through the coordinator: a refresh shares
    /// its time out (`SyncCoordinator.runBackgroundRefresh`), a processing task runs full passes. The system ending
    /// the task cancels this, which stops the runs between files. The next task is asked for at the end.
    public func runBackgroundTask(_ kind: BackgroundSyncRequest) async {
        let coordinator = syncCoordinator
        if await coordinator.waitUntilStarted() {
            let cancel = SyncRunCancel(), all = coordinator.runCancel
            await withTaskCancellationHandler {
                switch kind {
                case .refresh: await coordinator.runBackgroundRefresh(cancel: cancel)
                case .processing: await coordinator.runBackgroundProcessing(cancel: cancel)
                }
            } onCancel: {
                // Every run going stops, foreground ones included (review of #74, B2).
                cancel.cancel()
                all.cancel()
            }
            coordinator.renewRunCancel(ifSet: all)
        }
        scheduleBackgroundRefresh()
    }

    /// Starts watching the network for the WebDAV targets (once, at launch: `services.makeReachability`; none
    /// headless): coming back, they run soon.
    public func startReachability() {
        guard reachability == nil, let monitor = services.makeReachability() else { return }
        reachability = monitor
        monitor.start { [weak self] reachable in self?.syncCoordinator.networkChanged(reachable: reachable) }
    }
}
