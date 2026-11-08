import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import Testing

/// What the coordinator's and the sessions' tests share: fake runs, a clock and polling.
enum Sync {
    static func ref(_ kind: SyncTargetKind = .webdav, vault: UUID = UUID()) -> SyncTargetRef {
        var t = kind == .webdav ? SyncTarget.webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V")
            : SyncTarget.folder(URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"), bookmark: nil, subfolder: nil)
        t.joined = true
        return SyncTargetRef(vaultID: vault, vaultName: "V", target: t)
    }

    /// A coordinator over `refs` whose runs log themselves and, when `hang`, use their whole bound on `log`'s
    /// clock. `unconfirmed` gives each target's count of local changes. Started as after a background launch.
    @MainActor
    static func coordinator(_ refs: [SyncTargetRef], log: RunLog, hang: Bool = false, failing: Set<UUID> = [],
                            unconfirmed: @escaping @Sendable (UUID) -> Int = { _ in 1 }) async -> SyncCoordinator {
        let coordinator = SyncCoordinator(targets: { refs }, makeSession: { ref in
            let s = SyncSession(locationID: ref.id, vaultID: ref.vaultID, name: ref.vaultName, lastSuccess: nil,
                                run: { request in
                                    log.record(ref.id, request)
                                    if hang { log.advance(request.maxDuration ?? 60) }
                                    if failing.contains(ref.id) {
                                        throw WebDAVError.http(method: "PROPFIND", path: "", status: 503)
                                    }
                                    return SyncReport()
                                }, countUnconfirmed: { unconfirmed(ref.id) })
            s.kind = ref.target.kind
            return s
        })
        var tried: [String: Double] = [:]
        coordinator.loadTried = { tried }
        coordinator.saveTried = { tried = $0 }
        coordinator.clock = { log.now }
        coordinator.tick = .milliseconds(10)
        coordinator.setInBackground(true)
        coordinator.start()
        _ = await waitUntil { coordinator.sessions.count == refs.count }
        // The sessions' first recount (a fixed sleep lost to a loaded machine: the candidates were empty).
        _ = await waitUntil { refs.allSatisfy { coordinator.sessions[$0.id]?.unconfirmed == unconfirmed($0.id) } }
        return coordinator
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes.
    @MainActor
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// What the fake runs saw, in order (thread-safe: runs are `@Sendable`).
    final class RunLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(target: UUID, maxDuration: TimeInterval?, cancellable: Bool)] = []
        private var time = Date(timeIntervalSince1970: 1_000_000)

        func record(_ target: UUID, _ request: SyncRunRequest) {
            lock.lock(); defer { lock.unlock() }
            entries.append((target, request.maxDuration, !request.cancels.isEmpty))
        }
        var targets: [UUID] { lock.lock(); defer { lock.unlock() }; return entries.map(\.target) }
        var bounds: [TimeInterval?] { lock.lock(); defer { lock.unlock() }; return entries.map(\.maxDuration) }
        var allCancellable: Bool { lock.lock(); defer { lock.unlock() }; return entries.allSatisfy(\.cancellable) }
        /// The fake clock: a run that hangs uses its whole bound.
        var now: Date { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ t: TimeInterval) { lock.lock(); time += t; lock.unlock() }
    }

    /// A thread-safe count.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        /// Adds `d`; returns the new value.
        func add(_ d: Int) -> Int { lock.lock(); defer { lock.unlock() }; n += d; return n }
        func raise(to x: Int) { lock.lock(); n = max(n, x); lock.unlock() }
    }

    /// A thread-safe flag.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return on }
            set { lock.lock(); on = newValue; lock.unlock() }
        }
    }

    /// The app's Keychain refusing the password before the device's first unlock (`WebDAVPasswordError.locked`).
    struct Locked: DeviceUnlockWaiting {
        var waitsForDeviceUnlock: Bool { true }
    }
}

/// The coordinator (`SyncCoordinator`, CLAUDE.md "Sync targets"): a session per (vault, target), every vault open or
/// not; at most `maxConcurrentRuns` runs at once with one slot kept for the open vault; closed vaults' pace paused in
/// the background; background tasks' shared budget, fairness and cancellation; reachability. Sessions run fakes.
@MainActor
struct SyncCoordinatorTests {
    /// One vault's failing target never delays or fails another's, and background runs leave the open
    /// vault's slot free (at most `maxConcurrentRuns - 1` of them at once).
    /// CLAUDE.md "Sync targets": a session per (vault, target) for every vault, open or not (a closed vault's WebDAV
    /// target only once its first download made the copy); only the open vault's runs are two-way, and only once it
    /// was unlocked here; every other run uploads only. Closing the vault makes its runs upload-only again.
    @Test func onlyTheOpenUnlockedVaultSyncsTwoWay() async throws {
        final class Modes: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [UUID: [SyncRunMode]] = [:]
            func add(_ id: UUID, _ m: SyncRunMode) { lock.lock(); seen[id, default: []].append(m); lock.unlock() }
            func of(_ id: UUID) -> [SyncRunMode] { lock.lock(); defer { lock.unlock() }; return seen[id] ?? [] }
        }
        let modes = Modes()
        let openVault = UUID()
        let open = [Sync.ref(vault: openVault), Sync.ref(.folder, vault: openVault)], closed = Sync.ref(.folder)
        var unjoined = SyncTarget.webdav("https://dav.example.org/new/", user: nil, name: "N")
        unjoined.joined = false
        let downloading = SyncTargetRef(vaultID: UUID(), vaultName: "N", target: unjoined)
        let all = open + [closed, downloading]
        let coordinator = SyncCoordinator(targets: { all }, makeSession: { ref in
            let s = SyncSession(locationID: ref.id, vaultID: ref.vaultID, name: ref.vaultName, lastSuccess: nil,
                                run: { request in modes.add(ref.id, request.mode); return SyncReport() }, countUnconfirmed: { 0 })
            s.kind = ref.target.kind
            s.runsAutomatically = false
            return s
        })
        coordinator.tick = .milliseconds(10)
        // Before `start` (tests, a launch converting old copies): only the open vault's targets have sessions.
        _ = coordinator.attachOpen(openVault)
        #expect(Set(coordinator.sessions.keys) == Set(open.map(\.id)))
        coordinator.start()
        #expect(Set(coordinator.sessions.keys) == Set((open + [closed]).map(\.id)), "every vault's, open or not")
        #expect(coordinator.sessions[downloading.id] == nil, "a WebDAV copy not downloaded yet has nothing to sync")
        for s in coordinator.sessions.values { _ = await s.syncNow() }
        #expect(open.allSatisfy { modes.of($0.id) == [.uploadOnly] }, "open but locked: upload-only")
        #expect(modes.of(closed.id) == [.uploadOnly])

        coordinator.openVaultUnlocked()
        for s in coordinator.sessions.values { _ = await s.syncNow() }
        #expect(open.allSatisfy { modes.of($0.id).last == .twoWay }, "the open vault, unlocked here: two-way")
        #expect(modes.of(closed.id).last == .uploadOnly, "a vault nobody unlocked only uploads")
        #expect(coordinator.sessions(of: openVault).allSatisfy { $0.isOpenVault && $0.twoWay })

        let running = coordinator.detachOpen()
        #expect(running.isEmpty)
        #expect(coordinator.sessions.count == 3, "a closed vault keeps syncing")
        for s in coordinator.sessions.values { _ = await s.syncNow() }
        #expect(open.allSatisfy { modes.of($0.id).last == .uploadOnly }, "closed again: upload-only")
        for r in all { _ = coordinator.stop(r.id) }
    }

    @Test func vaultsAreIsolatedAndTheBudgetHolds() async throws {
        let inFlight = Sync.Counter(), most = Sync.Counter()
        func location() -> SyncTargetRef {
            var t = SyncTarget.webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V")
            t.joined = true
            return SyncTargetRef(vaultID: UUID(), vaultName: "V", target: t)
        }
        let failing = location(), fine = [location(), location(), location()]
        let all = [failing] + fine
        let coordinator = SyncCoordinator(targets: { all }, makeSession: { loc in
            SyncSession(locationID: loc.id, vaultID: loc.vaultID, name: loc.vaultName, lastSuccess: nil, run: { _ in
                most.raise(to: inFlight.add(1))
                defer { _ = inFlight.add(-1) }
                try await Task.sleep(for: .milliseconds(50))
                if loc.id == failing.id { throw WebDAVError.http(method: "PROPFIND", path: "", status: 503) }
                return SyncReport()
            }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        coordinator.start()
        #expect(coordinator.sessions.count == 4)
        #expect(await Sync.waitUntil(timeout: .seconds(5)) { fine.allSatisfy { coordinator.sessions[$0.id]?.lastSuccess != nil } })
        #expect(coordinator.sessions[failing.id]?.lastSuccess == nil)
        #expect(coordinator.sessions[failing.id]?.needsAttention == true)
        #expect(most.value <= coordinator.maxConcurrentRuns - 1)
        for l in all { _ = coordinator.stop(l.id) }
        #expect(coordinator.sessions.isEmpty)
    }

    /// Review of #70, F2 (its probe): two closed vaults whose runs take long held both slots, and the open
    /// vault's Sync Now waited for them. One slot is the open vault's.
    @Test func theOpenVaultIsNeverStarvedBySlowBackgroundRuns() async throws {
        func location() -> SyncTargetRef {
            SyncTargetRef(vaultID: UUID(), vaultName: "V",
                          target: .webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V"))
        }
        let slow = [location(), location()], open = location()
        let slowIDs = Set(slow.map(\.id))
        let inFlight = Sync.Counter(), released = Sync.Counter()
        let coordinator = SyncCoordinator(targets: { slow + [open] }, makeSession: { loc in
            SyncSession(locationID: loc.id, vaultID: loc.vaultID, name: loc.vaultName, lastSuccess: nil, run: { _ in
                _ = inFlight.add(1)
                defer { _ = inFlight.add(-1) }
                // A slow upload of a closed vault, until the test releases it.
                if slowIDs.contains(loc.id) { while released.value == 0 { try await Task.sleep(for: .milliseconds(10)) } }
                return SyncReport()
            }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        // Every wait here is positive: a starved open run waits until the test releases the slow ones, which
        // it does only after the wait, so the bound only has to outlast a loaded runner (a 3 s one did not, on orin).
        for l in slow { coordinator.session(for: l) }
        #expect(await Sync.waitUntil(timeout: .seconds(30)) { inFlight.value >= 1 })
        let session = try #require(coordinator.attachOpen(open.vaultID).first)
        session.vaultUnlocked()
        let finished = Sync.Counter()
        Task { _ = await session.syncNow(); _ = finished.add(1) }
        #expect(await Sync.waitUntil(timeout: .seconds(30)) { finished.value == 1 }, "the open vault's run waited behind background runs")
        #expect(coordinator.runsGoing <= coordinator.maxConcurrentRuns)
        _ = released.add(1)
        for l in slow + [open] { _ = coordinator.stop(l.id) }
    }

    /// Re-check of #70: a run queued as a background one before its vault was opened kept background
    /// priority, so the unlock's run and Sync Now waited behind another closed vault's slow upload.
    /// Priority is asked again when slots are handed out, and opening the vault hands them out.
    @Test func aRunQueuedBeforeItsVaultOpenedTakesTheOpenVaultsSlot() async throws {
        func location() -> SyncTargetRef {
            SyncTargetRef(vaultID: UUID(), vaultName: "V",
                          target: .webdav("https://dav.example.org/\(UUID().uuidString)/", user: nil, name: "V"))
        }
        let blocked = location(), queued = location()
        let released = Sync.Counter()
        let coordinator = SyncCoordinator(targets: { [blocked, queued] }, makeSession: { loc in
            SyncSession(locationID: loc.id, vaultID: loc.vaultID, name: loc.vaultName, lastSuccess: nil, run: { _ in
                if loc.id == blocked.id {
                    // A slow upload of a closed vault, until the test releases it.
                    while released.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
                }
                return SyncReport()
            }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        let slow = try #require(coordinator.session(for: blocked))
        #expect(await Sync.waitUntil { slow.isSyncing })
        let waiting = try #require(coordinator.session(for: queued))
        try await Task.sleep(for: .milliseconds(100))   // kept: a negative check, nothing to wait on
        #expect(waiting.lastSuccess == nil, "queued behind the background slot")
        let open = try #require(coordinator.attachOpen(queued.vaultID).first)
        open.vaultUnlocked()
        let finished = Sync.Counter()
        Task { _ = await open.syncNow(); _ = finished.add(1) }
        #expect(await Sync.waitUntil(timeout: .seconds(30)) { finished.value == 1 }, "the open vault's runs wait for no background run")
        _ = released.add(1)
        for l in [blocked, queued] { _ = coordinator.stop(l.id) }
    }

    /// Review of #72: in the background, closed vaults' periodic runs pause, but a write into one (a voice
    /// note) still runs; the open vault's sessions keep their pace; back in the foreground all run again.
    @Test func closedVaultsPauseTheirPaceInTheBackground() async throws {
        let runs = Sync.Counter()
        let closed = SyncTargetRef(vaultID: UUID(), vaultName: "Closed",
                                   target: { var t = SyncTarget.webdav("https://dav.example.org/c/", user: nil, name: "C"); t.joined = true; return t }())
        let coordinator = SyncCoordinator(targets: { [closed] }, makeSession: { l in
            SyncSession(locationID: l.id, vaultID: l.vaultID, name: l.vaultName, lastSuccess: nil,
                        run: { _ in _ = runs.add(1); return SyncReport() }, countUnconfirmed: { 0 })
        })
        coordinator.tick = .milliseconds(10)
        coordinator.configure = { $0.idleInterval = 0.05; $0.maxIdleInterval = 0.05; $0.arrivingInterval = 0.05; $0.writeDelay = 0.01 }
        coordinator.start()
        #expect(await Sync.waitUntil { runs.value >= 2 }, "the idle pace runs")
        coordinator.setInBackground(true)
        try await Task.sleep(for: .milliseconds(100))   // a run already going ends
        let paused = runs.value
        try await Task.sleep(for: .milliseconds(300))   // kept: a negative check, nothing to wait on
        #expect(runs.value == paused, "no periodic run in the background")
        coordinator.sessions[closed.id]?.noteWrite()
        #expect(await Sync.waitUntil { runs.value > paused }, "a write still runs")
        coordinator.setInBackground(false)
        let after = runs.value
        #expect(await Sync.waitUntil { runs.value > after + 1 }, "the pace is back")
        _ = coordinator.stop(closed.id)
    }

    /// The reviewer's Q4: a voice note delivered into a closed vault's copy asks its session for a run
    /// soon (a write), not at the idle pace.
    @Test func aCaptureIntoAClosedVaultAsksForARun() async throws {
        let vault = UUID()
        var target = SyncTarget.webdav("https://dav.example.org/x/", user: nil, name: "V")
        target.joined = true
        let loc = SyncTargetRef(vaultID: vault, vaultName: "V", target: target)
        let delivered = Notification.Name("SyncCoordinatorTests.delivered.\(UUID().uuidString)")
        let coordinator = SyncCoordinator(targets: { [loc] }, makeSession: { l in
            SyncSession(locationID: l.id, vaultID: l.vaultID, name: l.vaultName, lastSuccess: nil,
                        run: { _ in SyncReport() }, countUnconfirmed: { 0 })
        }, deliveries: delivered)
        coordinator.tick = .seconds(60)   // the loop does not run meanwhile
        let session = try #require(coordinator.session(for: loc))
        // The run at the start goes first: it would take the write with it (it does on Linux, where it often starts
        // after the post).
        #expect(await Sync.waitUntil { session.lastSuccess != nil && !session.isSyncing })
        #expect(session.schedule.pendingWrite == nil)
        NotificationCenter.default.post(name: delivered, object: nil, userInfo: ["vault": vault])
        #expect(await Sync.waitUntil { session.schedule.pendingWrite != nil })
        _ = coordinator.stop(loc.id)
    }

    @Test func aRefreshRunsEveryVaultWithWorkOnceEachBounded() async throws {
        let log = Sync.RunLog()
        let busy = [Sync.ref(), Sync.ref(.folder), Sync.ref()], idle = Sync.ref()
        let idleID = idle.id
        let coordinator = await Sync.coordinator(busy + [idle], log: log, unconfirmed: { $0 == idleID ? 0 : 1 })
        #expect(log.targets.isEmpty, "a background launch starts no run before the task's budget")
        let ran = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(Set(ran) == Set(busy.map(\.id)), "a closed vault with nothing to upload is left out")
        #expect(log.targets == ran)
        #expect(log.allCancellable)
        for bound in log.bounds {
            let b = try #require(bound)
            #expect(b >= BackgroundBudget.minimumRun && b <= BackgroundBudget.refreshTime)
        }
        for r in busy + [idle] { _ = coordinator.stop(r.id) }
    }

    /// Ten vaults whose servers hang (each run uses its whole bound): one task runs five, the next task the
    /// other five, so no vault starves; each run's bound is its share of the budget.
    @Test func hungServersAreBoundedAndNoVaultStarves() async throws {
        let log = Sync.RunLog()
        let refs = (0..<10).map { _ in Sync.ref() }
        let coordinator = await Sync.coordinator(refs, log: log, hang: true)
        let first = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(first.count == 5)
        #expect(log.bounds.allSatisfy { $0 == BackgroundBudget.minimumRun })
        let second = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(Set(first + second) == Set(refs.map(\.id)))
        for r in refs { _ = coordinator.stop(r.id) }
    }

    @Test func expiryStopsBetweenRuns() async throws {
        let log = Sync.RunLog()
        let refs = (0..<3).map { _ in Sync.ref() }
        let coordinator = await Sync.coordinator(refs, log: log)
        let cancel = SyncRunCancel()
        cancel.cancel()
        #expect(await coordinator.runBackgroundRefresh(cancel: cancel).isEmpty)
        await coordinator.runBackgroundProcessing(cancel: cancel)
        #expect(log.targets.isEmpty)
        for r in refs { _ = coordinator.stop(r.id) }
    }

    @Test func processingRunsFullPassesUntilNothingChanges() async throws {
        let log = Sync.RunLog()
        let refs = [Sync.ref(), Sync.ref(.folder)]
        let coordinator = await Sync.coordinator(refs, log: log)
        await coordinator.runBackgroundProcessing(cancel: SyncRunCancel())
        #expect(log.targets.count == 2, "one pass: it changed nothing")
        #expect(log.bounds.allSatisfy { $0 == nil }, "full runs, at the default bounds")
        for r in refs { _ = coordinator.stop(r.id) }
    }

    /// Design §4: "network reachable: run, cancel the backoff", for every target (offline audit P12: folder
    /// targets too), once the path has held for the debounce; without a path WebDAV targets wait and say offline
    /// (P11), folder targets do not.
    @Test func theNetworkComingBackRetriesEveryTargetOnceItHolds() async throws {
        let log = Sync.RunLog()
        let dav = Sync.ref(), folder = Sync.ref(.folder)
        let coordinator = await Sync.coordinator([dav, folder], log: log)
        coordinator.networkDebounce = .milliseconds(200)
        let davSession = try #require(coordinator.sessions[dav.id])
        let folderSession = try #require(coordinator.sessions[folder.id])
        for s in [davSession, folderSession] {
            s.runsAutomatically = false
            s.schedule.started(at: Date())
            s.schedule.finished(at: Date(), success: false)
        }
        coordinator.networkChanged(reachable: true)   // the first report: nothing changed
        try await Task.sleep(for: .milliseconds(300))   // kept: a negative check, nothing to wait on
        #expect(davSession.schedule.failures == 1 && !davSession.schedule.demanded)
        coordinator.networkChanged(reachable: false)
        #expect(davSession.status.kind == .offline && !davSession.needsAttention)
        #expect(folderSession.status.kind != .offline, "a folder needs no network")
        // A flapping network: back for less than the debounce, then gone again, asks for nothing.
        coordinator.networkChanged(reachable: true)
        coordinator.networkChanged(reachable: false)
        try await Task.sleep(for: .milliseconds(300))   // kept: a negative check, nothing to wait on
        #expect(!davSession.schedule.demanded && !folderSession.schedule.demanded)
        coordinator.networkChanged(reachable: true)
        #expect(davSession.status.kind == .offline, "still offline until the path has held (review of #91, S2)")
        #expect(!davSession.schedule.demanded, "not before the path has held")
        #expect(await Sync.waitUntil { davSession.schedule.demanded && folderSession.schedule.demanded })
        #expect(davSession.status.kind != .offline)
        #expect(davSession.schedule.failures == 0 && folderSession.schedule.failures == 0)
        for r in [dav, folder] { _ = coordinator.stop(r.id) }
    }

    /// Offline audit P11: without a network path, a WebDAV target's scheduled runs do not start (a write or a
    /// demand waits), while a folder target's still run; Sync Now still runs.
    @Test func noNetworkPathHoldsWebDAVRunsOnly() async throws {
        let log = Sync.RunLog()
        let dav = Sync.ref(), folder = Sync.ref(.folder)
        let coordinator = await Sync.coordinator([dav, folder], log: log, unconfirmed: { _ in 0 })
        coordinator.setInBackground(false)
        coordinator.networkChanged(reachable: false)
        let davSession = try #require(coordinator.sessions[dav.id])
        let folderSession = try #require(coordinator.sessions[folder.id])
        let before = log.targets.count
        davSession.demand()
        folderSession.demand()
        #expect(await Sync.waitUntil { log.targets.dropFirst(before).contains(folder.id) })
        try await Task.sleep(for: .milliseconds(200))   // kept: a negative check, nothing to wait on
        #expect(!log.targets.dropFirst(before).contains(dav.id), "no run without a path")
        #expect(davSession.schedule.demanded, "the demand waits for the network")
        _ = await davSession.syncNow()
        #expect(log.targets.dropFirst(before).contains(dav.id), "Sync Now still tries")
        for r in [dav, folder] { _ = coordinator.stop(r.id) }
    }

    /// Review of #91, S2: a blip of the network starts no WebDAV run, even one already due (a write waiting since
    /// the path went away): the session stays offline until the path has held.
    @Test func aNetworkBlipStartsNoDueWebDAVRun() async throws {
        let log = Sync.RunLog()
        let dav = Sync.ref()
        let coordinator = await Sync.coordinator([dav], log: log, unconfirmed: { _ in 0 })
        coordinator.networkDebounce = .seconds(30)
        coordinator.setInBackground(false)
        coordinator.networkChanged(reachable: true)
        coordinator.networkChanged(reachable: false)
        let session = try #require(coordinator.sessions[dav.id])
        let before = log.targets.count
        session.noteWrite()   // due after its write delay
        session.schedule.writeDelay = 0
        coordinator.networkChanged(reachable: true)   // back, but not for long yet
        try await Task.sleep(for: .milliseconds(400))   // kept: a negative check, nothing to wait on
        #expect(log.targets.count == before, "no run during the debounce")
        _ = coordinator.stop(dav.id)
    }

    /// Review of #74, B2: a background task never waits for a foreground run without a bound; the task's
    /// expiry stops that run too (the coordinator's app-wide flag).
    @Test func aTaskSkipsAForegroundRunAndExpiryStopsIt() async throws {
        let busy = Sync.ref(), other = Sync.ref()
        let started = Sync.Counter(), stopped = Sync.Counter()
        let coordinator = SyncCoordinator(targets: { [busy, other] }, makeSession: { ref in
            SyncSession(locationID: ref.id, vaultID: ref.vaultID, name: ref.vaultName, lastSuccess: nil,
                        run: { request in
                            guard ref.id == busy.id else { return SyncReport() }
                            _ = started.add(1)
                            var options = SyncOptions(deviceLabel: "t")
                            request.apply(to: &options)
                            // No bound: runs until a cancel flag is set (polled between "files").
                            while options.isCancelled?() != true { try await Task.sleep(for: .milliseconds(10)) }
                            _ = stopped.add(1)
                            return SyncReport()
                        }, countUnconfirmed: { 1 })
        })
        coordinator.maxConcurrentRuns = 3
        var tried: [String: Double] = [:]
        coordinator.loadTried = { tried }
        coordinator.saveTried = { tried = $0 }
        coordinator.tick = .milliseconds(10)
        coordinator.setInBackground(true)
        coordinator.start()
        let session = try #require(coordinator.sessions[busy.id])
        session.runsAutomatically = false
        coordinator.sessions[other.id]?.runsAutomatically = false
        let foreground = Task { await session.syncNow() }
        #expect(await Sync.waitUntil { started.value == 1 })
        let clock = ContinuousClock.now
        let ran = await coordinator.runBackgroundRefresh(cancel: SyncRunCancel())
        #expect(ran == [other.id], "the busy session is skipped")
        #expect(ContinuousClock.now - clock < .seconds(2), "the task did not wait for the foreground run")
        #expect(stopped.value == 0)
        coordinator.cancelAllRuns()   // the task's expiry
        _ = await foreground.value
        #expect(stopped.value == 1, "the foreground run stopped between files")
        for r in [busy, other] { _ = coordinator.stop(r.id) }
    }
}

/// One (vault, target) pair's session (`SyncSession`) and its status (`SyncStatus`): two-way only while the vault is
/// unlocked here, upload-only otherwise; the loop's pace; what a run's outcome makes of the status. Runs are fakes.
@MainActor
struct SyncSessionTests {
    /// Only an upload error of the provider is a problem; a summary's other states are not.
    @Test func onlyAProvidersUploadErrorIsAProblem() async throws {
        let session = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                                  run: { _ in SyncReport() }, countUnconfirmed: { 0 })
        session.kind = .folder
        let failed = ProviderUploads.State.failed(code: 4355, domain: NSCocoaErrorDomain, message: "full")
        session.providerSummary = { ProviderUploads.Summary(count: 1, error: failed) }
        session.vaultUnlocked()
        _ = await session.syncNow()
        #expect(session.status.kind == .providerFailed(failed) && session.needsAttention)
        session.providerSummary = { ProviderUploads.Summary(count: 1, error: .waiting) }
        _ = await session.syncNow()
        #expect(session.providerError == nil)
        #expect(session.status.kind == .waitingForProvider(1) && !session.needsAttention)
        session.stop()
    }

    @Test func statusKinds() {
        var s = SyncStatus(syncing: false, problems: [], unconfirmed: 0, arriving: 0, twoWay: true, lastSuccess: nil)
        #expect(s.kind == .synced)
        s.unconfirmed = 3
        #expect(s.kind == .pending(3))
        s.problems = [.offline]
        #expect(s.kind == .offline && !s.needsAttention)
        s.problems = [.unauthorized]
        #expect(s.needsAttention)
        s = SyncStatus(syncing: false, problems: [], unconfirmed: 0, arriving: 0, twoWay: false, lastSuccess: nil)
        #expect(s.kind == .waitingForUnlock && !s.needsAttention)
    }

    /// Review of #91, S1: a write made while a Sync Now runs is synced after its write delay once that run ends,
    /// not after the loop's longest sleep.
    @Test func aWriteDuringSyncNowRunsSoonAfterIt() async throws {
        let runs = Sync.Counter()
        let s = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                            run: { _ in
                                _ = runs.add(1)
                                try await Task.sleep(for: .milliseconds(400))
                                return SyncReport()
                            }, countUnconfirmed: { 0 })
        s.tick = .milliseconds(20)
        s.maxSleep = .seconds(30)
        s.schedule.writeDelay = 0.05
        s.start()
        #expect(await Sync.waitUntil { runs.value >= 1 && !s.isSyncing })   // the first run at the start
        // Counted before Sync Now: nothing else is due for minutes. Counting after it raced the follow-up run, which
        // the run's end wakes the loop for and which could start (and count) before the test resumed; the wait then
        // looked for a third run that never came.
        let before = runs.value
        let sync = Task { await s.syncNow() }
        #expect(await Sync.waitUntil { s.isSyncing })
        s.noteWrite()
        _ = await sync.value
        #expect(runs.value >= before + 1, "Sync Now ran")
        #expect(await Sync.waitUntil(timeout: .seconds(3)) { runs.value >= before + 2 }, "the write was synced soon after Sync Now")
        s.stop()
    }

    /// Offline audit P11: the session loop sleeps until its next run instead of ticking every second, and a write
    /// wakes it.
    @Test func theLoopSleepsUntilTheNextRun() async throws {
        let s = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                            run: { _ in SyncReport() }, countUnconfirmed: { 0 })
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.now = { t0 }
        s.schedule.started(at: t0)
        s.schedule.finished(at: t0, success: true)
        #expect(s.sleepDuration() == .seconds(60), "idle: at most a minute, not a second")
        s.schedule.noteWrite(at: t0)
        #expect(s.sleepDuration() == .seconds(s.schedule.writeDelay), "a write is due after its delay")
        s.periodicPaused = true
        s.runsAutomatically = false
        #expect(s.sleepDuration() == .seconds(60), "nothing may run: the longest sleep")
    }

    /// Review of #74, B1: before the device's first unlock the Keychain refuses the password; the session
    /// waits for the unlock, with no problem shown and no backoff.
    @Test func aLockedDeviceIsWaitingNotAProblem() async throws {
        let ref = Sync.ref()
        let locked = Sync.Flag(true)
        let session = SyncSession(locationID: ref.id, vaultID: ref.vaultID, name: "V", lastSuccess: nil,
                                  run: { _ in
                                      if locked.value { throw Sync.Locked() }
                                      return SyncReport()
                                  }, countUnconfirmed: { 0 })
        _ = await session.syncNow()
        #expect(session.waitingForDeviceUnlock)
        #expect(session.problems.isEmpty && session.failure == nil && !session.needsAttention)
        #expect(session.schedule.failures == 0, "no backoff")
        #expect(session.status.kind == .waitingForUnlock)
        locked.value = false
        _ = await session.syncNow()
        #expect(!session.waitingForDeviceUnlock)
        #expect(session.lastSuccess != nil)
    }

    /// Review of #90, N1: the path monitor's return reaches the engine, so a provider's late file is not counted as
    /// stalled for the time the device had no network (offline audit P5).
    @Test func theNetworksReturnReachesTheRun() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Date?] = []
            func add(_ d: Date?) { lock.lock(); values.append(d); lock.unlock() }
            var all: [Date?] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let seen = Seen()
        let session = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                                  run: { request in
                                      var o = SyncOptions()
                                      request.apply(to: &o)
                                      seen.add(o.networkReturned)
                                      return SyncReport()
                                  }, countUnconfirmed: { 0 })
        let back = Date(timeIntervalSince1970: 1_900_000_000)
        session.now = { back }
        session.vaultUnlocked()
        _ = await session.syncNow()
        session.networkChanged(reachable: false)
        session.networkChanged(reachable: true)
        _ = await session.syncNow()
        #expect(seen.all.first == .some(nil), "never away: nothing to leave out")
        #expect(seen.all.last == .some(back))
        session.stop()
    }

    @Test func aFolderInICloudNeverSaysSyncedWhileUploadsWait() async throws {
        let session = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                                  run: { _ in SyncReport() }, countUnconfirmed: { 0 })
        session.kind = .folder
        session.uploadsViaICloud = true
        session.providerSummary = { ProviderUploads.Summary(count: 3) }
        session.vaultUnlocked()
        _ = await session.syncNow()
        #expect(session.status.kind == .waitingForProvider(3))
        #expect(!session.status.lastSuccessIsSync, "the bar shows the run as written to the folder")
        #expect(!session.needsAttention, "waiting is not a problem")
        session.providerSummary = { ProviderUploads.Summary() }
        _ = await session.syncNow()
        #expect(session.status.kind == .synced)
        session.stop()
    }
}
