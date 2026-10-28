import Darwin
import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// TestFlight 1.0.0 (8) was killed (RunningBoard `0xdead10cc`) every time it left the screen with a vault
/// open: the open store vault's lease, a `flock` in the App Group container, was held across the suspension.
/// Leaving the screen must let every lock go once the last saves are written, and coming back takes the
/// lease again (AppModel+Suspension).
@MainActor
struct SuspensionLockTests {
    /// Whether anyone holds vault `id`'s lease: an exclusive `flock` on another descriptor is refused
    /// while a shared one is held (by this process or another).
    static func leaseHeld(_ store: VaultStore, _ id: UUID) -> Bool {
        let path = store.root.appendingPathComponent(".locks").appendingPathComponent(id.uuidString.lowercased() + ".open").path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    /// A store vault open in a model that lets its locks go in the background (as on iOS), with faked
    /// background time and its own notification center.
    static func openStoreVault(launchedInBackground: Bool = false) async throws
        -> (AppModel, VaultLibrary, UUID, FakeBackgroundTasks, NotificationCenter) {
        let library = try BrowserTests.library()
        let model = try VaultStoreAppTests.model()
        model.vaultStore = library.vaultStore
        model.releasesLocksInBackground = true
        let tasks = FakeBackgroundTasks()
        model.backgroundTasks = tasks
        let center = NotificationCenter()
        model.observeAppLifecycle(center: center, inBackground: launchedInBackground)
        let (source, _) = try AppModelTests.fixtureVault()
        try await model.copyIn(picked: source, library: library)
        let id = try #require(library.storedVaults.first).vaultId
        return (model, library, id, tasks, center)
    }

    @Test func leavingTheScreenLetsTheLeaseGoAndComingBackTakesItAgain() async throws {
        let (model, library, id, tasks, center) = try await Self.openStoreVault()
        let store = library.vaultStore
        #expect(Self.leaseHeld(store, id), "an open store vault is leased")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await TS.waitUntil { !Self.leaseHeld(store, id) }, "no lock is held across the suspension")
        #expect(tasks.begun.count == 1, "the last saves finish under background time")
        #expect(await TS.waitUntil { tasks.ended == tasks.begun }, "and the time ends once the lease is let go")
        #expect(model.phase != .noVault, "the vault stays open")

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(await TS.waitUntil { Self.leaseHeld(store, id) }, "the lease is taken again on the way back")

        model.close()
        await model.closingEditor?.value
        #expect(!Self.leaseHeld(store, id))
    }

    /// A save still writing when the app leaves keeps the lease until it ends, unless iOS takes the time back
    /// first: then the lease goes at once.
    @Test func theLeaseWaitsForAWriteUnlessTheTimeRunsOut() async throws {
        let (model, library, id, tasks, center) = try await Self.openStoreVault()
        let store = library.vaultStore
        await model.editGate.acquire()   // a browser edit is writing
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.leaseHeld(store, id), "held while the write finishes")
        tasks.expire()
        #expect(!Self.leaseHeld(store, id), "let go as soon as iOS takes the time back")
        #expect(tasks.ended == tasks.begun)
        model.editGate.release()

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(await TS.waitUntil { Self.leaseHeld(store, id) })
        model.close()
        await model.closingEditor?.value
    }

    /// With no background time at all, nothing is waited for.
    @Test func noBackgroundTimeLetsTheLeaseGoAtOnce() async throws {
        let (model, library, id, tasks, center) = try await Self.openStoreVault()
        tasks.grant = false
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await TS.waitUntil { !Self.leaseHeld(library.vaultStore, id) })
        model.close()
        await model.closingEditor?.value
    }

    /// Another process removed the vault while it was unleased in the background: coming back closes it.
    @Test func aVaultRemovedInTheBackgroundClosesOnTheWayBack() async throws {
        let (model, library, id, _, center) = try await Self.openStoreVault()
        let store = library.vaultStore
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await TS.waitUntil { !Self.leaseHeld(store, id) })
        try store.remove(id)   // refused (`inUse`) while the lease is held
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.phase == .noVault })
        #expect(!Self.leaseHeld(store, id))
    }

    /// Review of #105, finding 1: back to the screen and straight out again (the app switcher). The lease is
    /// taken back at once on return, never by a wait that could end after the app left again with no
    /// assertion held.
    @Test func aQuickReturnAndLeaveHoldsNoLease() async throws {
        let (model, library, id, tasks, center) = try await Self.openStoreVault()
        let store = library.vaultStore
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await TS.waitUntil { !Self.leaseHeld(store, id) && tasks.ended == tasks.begun })
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(Self.leaseHeld(store, id), "taken back in the same turn")
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await TS.waitUntil { !Self.leaseHeld(store, id) && tasks.ended == tasks.begun })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!Self.leaseHeld(store, id), "nothing takes it later")
        model.reacquireStoreLease()
        #expect(!Self.leaseHeld(store, id), "never taken while in the background")
        model.close()
        await model.closingEditor?.value
    }

    /// Review of #105, finding 2: a vault closing while the last saves are awaited lets its lease go at once
    /// (its own saves may outlast the background time), and the closing task is cleared once done.
    @Test func aCloseDuringTheWaitLetsTheLeaseGo() async throws {
        let (model, library, id, tasks, center) = try await Self.openStoreVault()
        let store = library.vaultStore
        await model.editGate.acquire()   // a browser edit is writing
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.leaseHeld(store, id))
        model.close()
        #expect(!Self.leaseHeld(store, id), "let go at once")
        model.editGate.release()
        #expect(await TS.waitUntil { tasks.ended == tasks.begun })
        #expect(await TS.waitUntil { model.closingEditor == nil }, "no closing task lingers")
    }

    /// Review of #105, finding 5: a process launched into the background (a background task, an intent) never
    /// sees `didEnterBackground`; a vault it opens is leased only once the app comes forward.
    @Test func launchedInTheBackgroundLeasesNothingUntilItComesForward() async throws {
        let (model, library, id, _, center) = try await Self.openStoreVault(launchedInBackground: true)
        #expect(!Self.leaseHeld(library.vaultStore, id))
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(Self.leaseHeld(library.vaultStore, id))
        model.close()
        await model.closingEditor?.value
    }

    /// A Mac suspends nothing: the lease stays while the app is hidden (removal stays refused).
    @Test func withoutSuspensionTheLeaseStays() async throws {
        let (model, library, id, tasks, center) = try await Self.openStoreVault()
        model.releasesLocksInBackground = false
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.leaseHeld(library.vaultStore, id))
        #expect(tasks.begun.isEmpty)
        model.close()
        await model.closingEditor?.value
    }
}

/// "The iPad seems to keep the screen on, even when it's not enabled": the idle timer is the app's, applied
/// from the app's state and the stored setting, never left disabled by a scene that went away.
@MainActor
struct IdleTimerKeeperTests {
    final class Box {
        var noteOpen = true
        var active = true
        var applied: [Bool] = []
    }

    static func keeper(_ box: Box, _ defaults: UserDefaults) -> IdleTimerKeeper {
        IdleTimerKeeper(defaults: defaults, noteOpen: { box.noteOpen }, appActive: { box.active },
                        apply: { box.applied.append($0) })
    }

    @Test func offMeansTheTimerRuns() throws {
        let defaults = try #require(TestDefaults.suite("IdleTimerKeeperTests-\(UUID())"))
        let box = Box()
        let keeper = Self.keeper(box, defaults)
        keeper.start(center: NotificationCenter())
        #expect(box.applied == [false], "never set, note open, app active: the screen still locks")
    }

    @Test func followsTheSettingAndTheAppState() throws {
        let defaults = try #require(TestDefaults.suite("IdleTimerKeeperTests-\(UUID())"))
        let box = Box()
        let center = NotificationCenter()
        let keeper = Self.keeper(box, defaults)
        defaults.set(true, forKey: KeepScreenOn.key)
        keeper.start(center: center)
        #expect(keeper.disabled == true)

        // Leaving: the timer comes back on even while the app's state still reads active.
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(keeper.disabled == false)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(keeper.disabled == true)

        // Turned off anywhere (a note window, settings sync) with no library scene around: applied.
        defaults.set(false, forKey: KeepScreenOn.key)
        keeper.update()
        #expect(keeper.disabled == false)
        defaults.set(true, forKey: KeepScreenOn.key)
        box.noteOpen = false
        keeper.update()
        #expect(keeper.disabled == false, "no note open")
        #expect(box.applied == [true, false, true, false])
    }

    /// Review of #105, finding 6: the model tells the keeper when its editors change, whichever scene (if any)
    /// shows them.
    @Test func theModelsEditorsReachTheKeeper() throws {
        let defaults = try #require(TestDefaults.suite("IdleTimerKeeperTests-\(UUID())"))
        defaults.set(true, forKey: KeepScreenOn.key)
        let box = Box()
        let keeper = Self.keeper(box, defaults)
        keeper.start(center: NotificationCenter())
        #expect(keeper.disabled == true)
        let model = AppModel()
        model.idleTimer = keeper
        box.noteOpen = false   // a note window's note went away
        model.windowEditors = [:]
        #expect(keeper.disabled == false)
    }
}
