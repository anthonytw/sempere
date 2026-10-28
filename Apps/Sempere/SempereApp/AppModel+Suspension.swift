import Foundation
import OSLog
import Sempere
import UIKit

private let suspensionLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "suspension")

/// No lock is held across a suspension (iOS). The vault store lives in the App Group container on an
/// iPhone or iPad (`VaultLibrary.defaultVaultStoreRoot`), and iOS kills an app that is suspended while it
/// holds a file lock there (RunningBoard `0xdead10cc`). An open store vault holds its lease, a shared
/// `flock(2)` on `<store>/.locks/<id>.open` (`VaultStore.lease`), for as long as it is open, so build 8
/// was killed every time it left the screen with a vault open.
///
/// When the app enters the background, the editors' last saves finish under background time
/// (`beginBackgroundTask`), then the lease is let go; when iOS takes the time back first, it is let go
/// at once. The vault stays open. When the app comes back the lease is taken again; if the vault was
/// removed meanwhile (the lease is what refuses a removal), the vault closes. The write lock
/// (`VaultFileLock`) is held only for each write, never across one.
///
/// It follows the application, not a scene: a note window can stay on screen after the library scene
/// left, and the app is suspended only once every scene has. Sync's background time (`enterBackground`)
/// follows the same observers, so a run writing under the vault's write lock always has an assertion.
extension AppModel {
    /// Starts following the app entering and leaving the background (once, at launch). Tests pass their
    /// own notification center and the state to start in.
    ///
    /// - Parameter inBackground: the process starts in the background (a background task or an intent
    ///   launched it): no `didEnterBackground` comes, so nothing may be leased until the app comes forward.
    func observeAppLifecycle(center: NotificationCenter = .default,
                             inBackground: Bool = UIApplication.shared.applicationState == .background) {
        guard lifecycleObservers.isEmpty else { return }
        if releasesLocksInBackground, inBackground { locksSuspended = true }
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A sync in flight finishes under background time; then (or when iOS takes the time
                    // back) scheduled tasks continue it (`BackgroundSync`).
                    self?.enterBackground()
                    self?.prepareForSuspension()
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resumeAfterSuspension()
                    self?.enterForeground()
                }
            },
        ]
    }

    /// The app entered the background: the last saves finish under background time, then the store
    /// lease is let go (at once when iOS gives no time or takes it back).
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
            suspensionLog.warning("background time ran out before the last saves finished; the vault lease is let go now")
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
        locksSuspended = false
        reacquireStoreLease()
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
                suspensionLog.warning("cannot take the vault lease again: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func closeRemovedVault() {
        suspensionLog.warning("the open vault was removed while the app was in the background; closing it")
        close()
    }
}
