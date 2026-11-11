import Foundation
import Sempere

/// No lock is held across a suspension (iOS). The vault store lives in the App Group container on an
/// iPhone or iPad (`VaultLibrary.defaultVaultStoreRoot`), and iOS kills an app that is suspended while it
/// holds a file lock there (RunningBoard `0xdead10cc`). An open store vault holds its lease, a shared
/// `flock(2)` on `<store>/.locks/<id>.open` (`VaultStore.lease`), for as long as it is open, so build 8
/// was killed every time it left the screen with a vault open.
///
/// When the app enters the background, the editors' last saves finish under background time
/// (`beginBackgroundTask`), then the lease is let go; when the system takes the time back first, it is let go
/// at once. The vault stays open. When the app comes back the lease is taken again; if the vault was
/// removed meanwhile (the lease is what refuses a removal), the vault closes. The write lock
/// (`VaultFileLock`) is held only for each write, never across one.
///
/// It follows the application, not a scene (`AppLifecycle`): a note window can stay on screen after the library
/// scene left, and the app is suspended only once every scene has. Sync's background time (`enterBackground`)
/// follows the same events.
///
/// A process that was never on screen holds no lease either: TestFlight 1.1 (67) was killed in launches into the
/// background (a WatchConnectivity delivery, a background task) that restored the library scene, which reopened the
/// last vault and leased it. The model starts with its locks let go until the application is first active
/// (`didBecomeActive`, or `willEnterForeground`), because the state read at launch cannot be trusted: SwiftUI's
/// `App.init` runs before `UIApplicationMain`, when `UIApplication.shared` is still nil and its state reads `.active`.
///
/// Every other lock is held only for one piece of work, and never without an assertion of its own: on iOS each
/// `flock` the package takes begins background time first and is let go before that time runs out
/// (`FileLockGuard`, installed by the app). A write the system gives no time for is refused, never left holding a
/// lock while the process is suspended.
extension AppModelCore {
    /// The log category of the lease's warnings (`services.perf`).
    static var suspensionLogCategory: String { "suspension" }

    /// Starts following the app entering and leaving the background (once, at launch), on `lifecycle`
    /// (`services.lifecycle` unless given). Unless the application is active now, nothing may be leased until it
    /// first is: a process started in the background (a background task, an intent, WatchConnectivity) sees no
    /// `didEnterBackground`, and one still launching cannot tell (above).
    public func observeAppLifecycle(_ lifecycle: (any AppLifecycle)? = nil) {
        guard lifecycleObservation == nil else { return }
        let lifecycle = lifecycle ?? services.lifecycle
        if releasesLocksInBackground, lifecycle.isInBackground || !lifecycle.isActive { locksSuspended = true }
        lifecycleObservation = lifecycle.observe { [weak self] event in
            switch event {
            case .didEnterBackground:
                // A sync in flight finishes under background time; then (or when the system takes the time
                // back) scheduled tasks continue it (`BackgroundSync`).
                self?.enterBackground()
                self?.prepareForSuspension()
            case .willEnterForeground:
                self?.resumeAfterSuspension()
                self?.enterForeground()
            case .didBecomeActive:
                // The first activation of a launch (no `willEnterForeground` comes before it): the app is on screen
                // now. After a return from the background the locks were taken back already (`willEnterForeground`).
                guard let self, self.locksSuspended else { return }
                self.resumeAfterSuspension()
                // The launch read the state too early (it reads `.background` until a scene is active).
                self.syncCoordinator.setInBackground(false)
            case .willResignActive:
                break
            }
        }
    }

    /// The app entered the background: the last saves finish under background time, then the store
    /// lease is let go (at once when the system gives no time or takes it back).
    func prepareForSuspension() {
        guard releasesLocksInBackground else { return }
        locksSuspended = true
        guard storeLease != nil || closingEditor != nil else { return }
        guard suspensionToken == nil else { return }   // the wait of an earlier background still runs
        let editors = [editor].compactMap { $0 } + Array(windowEditors.values)
        let closing = closingEditor
        let gate = editGate
        guard let token = backgroundTasks.begin(name: "Sempere save", expired: { [weak self] in
            guard let self else { return }
            self.services.perf.log(.error, Self.suspensionLogCategory,
                                   "background time ran out before the last saves finished; the vault lease is let go now")
            self.suspensionWait?.cancel()
            self.finishSuspension()
        }) else {
            finishSuspension()
            return
        }
        suspensionToken = token
        suspensionWait = Task { [weak self] in
            for editor in editors { await editor.flush() }
            // A vault closing lets its own lease go after its last saves (a close starting later lets it go
            // at once: `close()` while `locksSuspended`).
            await closing?.value
            // A browser edit already writing (`commit`) finishes first.
            await gate.acquire()
            gate.release()
            guard !Task.isCancelled else { return }
            self?.finishSuspension()
        }
    }

    /// Lets the lease go (when the app is still in the background) and ends the background time.
    func finishSuspension() {
        if locksSuspended, let lease = storeLease {
            lease.release()
            storeLease = nil
        }
        suspensionWait = nil
        if let token = suspensionToken { backgroundTasks.end(token) }
        suspensionToken = nil
    }

    /// The app is coming back: the open store vault's lease is taken again.
    func resumeAfterSuspension() {
        guard releasesLocksInBackground else { return }
        let wasSuspended = locksSuspended
        locksSuspended = false
        reacquireStoreLease()
        // Voice notes delivered meanwhile (an intent, the watch) waited for the foreground (`inboxDelivered`), and the
        // open editors' recognition (`holdRecognitionWhileSuspended`).
        if wasSuspended, phase == .unlocked {
            startInboxAdoption()
            for open in [editor].compactMap({ $0 }) + Array(windowEditors.values) { open.scheduleRecognition() }
        }
    }

    /// An editor's recognition waits while the locks are let go (`locksSuspended`): a launch nobody sees (a restored
    /// editor in a launch into the background) writes no revision and leaves no failure banner; the return runs a pass.
    func holdRecognitionWhileSuspended(_ opened: Editor) {
        opened.recognitionHeld = { [weak self] in self?.locksSuspended ?? false }
    }

    /// Takes the open store vault's lease again, now, on the main actor: one try that never waits, so no
    /// lease can be taken after the app went back to the background (a detached wait could, with no
    /// assertion held). Only a removal holds the lock exclusively: when the vault is gone (removed while
    /// it was unleased) it closes; when the lease cannot be taken, the next return tries again.
    func reacquireStoreLease() {
        guard storeLease == nil, !locksSuspended, let id = storeLeaseVault, let store = vaultStore else { return }
        do {
            let lease = try store.lease(id, timeout: 0)
            // Taken: the vault may still have been removed while it was unleased (the lock file stays).
            guard store.entry(id: id) != nil else {
                lease.release()
                closeRemovedVault()
                return
            }
            storeLease = lease
        } catch {
            if store.entry(id: id) == nil {
                closeRemovedVault()
            } else {
                services.perf.log(.error, Self.suspensionLogCategory,
                                  "cannot take the vault lease again: \(LogSafe.describe(error))")
            }
        }
    }

    private func closeRemovedVault() {
        services.perf.log(.error, Self.suspensionLogCategory,
                          "the open vault was removed while the app was in the background; closing it")
        close()
    }
}
