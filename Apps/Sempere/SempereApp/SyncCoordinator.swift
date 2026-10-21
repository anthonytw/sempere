import Foundation
import Observation
import Sempere
import SempereSync
import SempereWebDAV

/// One sync target of a store vault, as the coordinator schedules it.
struct SyncTargetRef: Hashable, Sendable, Identifiable {
    /// The store vault.
    let vaultID: UUID
    /// The vault's name, for the bars.
    let vaultName: String
    let target: SyncTarget
    /// The session's key: the target's id.
    var id: UUID { target.id }
}

/// Every in-app vault with a sync target keeps syncing, open or not, each isolated from the others
/// (docs/design/device-first-sync.md §4.2, docs/io.md "Sync targets in the app"). One per app; it owns
/// one `SyncSession` per (vault, target): folder targets (iCloud Drive, any folder) and WebDAV targets,
/// any number per vault.
///
/// - The open vault's sessions run two-way while it is unlocked here (`attachOpen`, `openVaultUnlocked`)
///   and hand each run's local changes to the model. Every other vault's sessions run upload-only at the
///   idle pace (`start`): its captures and last edits go up, and what other devices wrote arrives at its
///   next unlock (nothing unverified is placed in a vault nobody unlocked, design §4.1).
/// - Isolation: each session has its own sync state, quarantine, credentials (Keychain item by target
///   id), schedule, backoff and status. A failure (a hung server bounded by the run's limits, a wrong
///   password, a folder that went away, a full disk) marks only its own session.
/// - Budget: at most `maxConcurrentRuns` runs at once across the app, at most one per session. One slot is
///   kept for the open vault: background runs take at most `maxConcurrentRuns - 1`, so slow uploads of
///   closed vaults never hold up the open vault's runs or Sync Now (review of #70, F2). Two targets of one
///   vault take turns on the vault's write lock.
@MainActor
@Observable
final class SyncCoordinator {
    /// The sessions, by target id.
    private(set) var sessions: [UUID: SyncSession] = [:]
    /// The vault open in the model, if any.
    private(set) var openVault: UUID?
    /// Whether every target's session runs (the app at launch); off, only the open vault's do (tests).
    private(set) var runsAll = false
    /// The open vault was unlocked here (its sessions are two-way; targets added later are too).
    @ObservationIgnored private var openUnlocked = false

    /// At most this many runs at once across the app.
    @ObservationIgnored var maxConcurrentRuns = 2
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var waiting: [(priority: @MainActor () -> Bool, resume: CheckedContinuation<Void, Never>)] = []

    /// Builds the session of a target (the model supplies the transport, copy and options).
    @ObservationIgnored var makeSession: @MainActor (SyncTargetRef) -> SyncSession?
    /// The targets there are now, of every store vault.
    @ObservationIgnored var targets: @MainActor () -> [SyncTargetRef]
    /// How often sessions look at their schedules, and their write delay (tests shorten both).
    @ObservationIgnored var tick = Duration.seconds(1)
    @ObservationIgnored var configure: (inout SyncSchedule) -> Void = { _ in }

    init(targets: @escaping @MainActor () -> [SyncTargetRef],
         makeSession: @escaping @MainActor (SyncTargetRef) -> SyncSession?) {
        self.targets = targets
        self.makeSession = makeSession
        // Quick capture writes into a vault's copy from outside the model (`QuickCapture.deliver`).
        captureObserver = NotificationCenter.default.addObserver(forName: QuickCapture.deliveredNotification, object: nil,
                                                                 queue: .main) { [weak self] note in
            guard let id = note.userInfo?["vault"] as? UUID else { return }
            MainActor.assumeIsolated { self?.captureDelivered(vault: id) }
        }
    }

    /// The observer of `QuickCapture.deliveredNotification` (it holds the coordinator weakly; one per app).
    @ObservationIgnored private var captureObserver: (any NSObjectProtocol)?

    // MARK: - Sessions

    /// Starts a session for every target (the app at launch, and after one is added or removed).
    func start() {
        runsAll = true
        refresh()
    }

    /// Makes sessions for new targets (every vault's when `runsAll`, else only the open vault's) and
    /// stops those of removed ones. The model calls it when a target is added or removed. A WebDAV target
    /// whose first download has not finished has no copy to sync yet (`openWebDAV` makes it).
    func refresh() {
        let now = targets()
        let ids = Set(now.map { $0.id })
        for id in sessions.keys where !ids.contains(id) { _ = stop(id) }
        for ref in now where sessions[ref.id] == nil && (runsAll || ref.vaultID == openVault) {
            if ref.target.kind == .webdav, ref.target.joined != true, ref.vaultID != openVault { continue }
            let made = session(for: ref)
            if ref.vaultID == openVault {
                made?.isOpenVault = true
                wakeWaiters()
                if openUnlocked { made?.vaultUnlocked() }
            }
        }
    }

    /// The session of `ref`, made and started if there is none.
    @discardableResult
    func session(for ref: SyncTargetRef) -> SyncSession? {
        if let existing = sessions[ref.id] { return existing }
        guard let made = makeSession(ref) else { return nil }
        made.tick = tick
        configure(&made.schedule)
        made.admit = { [weak self] priority in await self?.admit(priority: priority) }
        made.release = { [weak self] in self?.releaseRun() }
        made.periodicPaused = inBackground && ref.vaultID != openVault
        sessions[ref.id] = made
        made.start()
        return made
    }

    /// The sessions of vault `id`'s targets, in the order the targets were added.
    func sessions(of id: UUID) -> [SyncSession] {
        sessions.values.filter { $0.vaultID == id }.sorted { $0.added < $1.added }
    }

    /// The model opened vault `id`: its targets' sessions are the open ones (made if needed).
    @discardableResult
    func attachOpen(_ id: UUID) -> [SyncSession] {
        openVault = id
        openUnlocked = false
        for ref in targets() where ref.vaultID == id { session(for: ref) }
        let open = sessions(of: id)
        for s in open { s.isOpenVault = true; s.periodicPaused = false }
        wakeWaiters()   // a run of it queued as a background one takes the open vault's slot now
        return open
    }

    /// The open vault was unlocked here: its sessions run two-way from now on, and run now.
    func openVaultUnlocked() {
        guard let openVault else { return }
        openUnlocked = true
        for s in sessions(of: openVault) { s.vaultUnlocked() }
    }

    /// The model closed the open vault: its sessions go back to upload-only (or stop when only the open
    /// vault syncs). Returns the runs still going, which must end before the copy is replaced.
    @discardableResult
    func detachOpen() -> [Task<SyncReport?, Never>] {
        guard let id = openVault else { return [] }
        openVault = nil
        openUnlocked = false
        var running: [Task<SyncReport?, Never>] = []
        for session in sessions(of: id) {
            session.vaultClosed()
            session.isOpenVault = false
            session.periodicPaused = inBackground
            session.onChanges = { _ in }
            if !runsAll {
                if let task = stop(session.locationID) { running.append(task) }
            } else if let task = session.currentRun {
                running.append(task)
            }
        }
        return running
    }

    /// Stops and forgets the session of target `id` (a removed target); returns its run still going.
    @discardableResult
    func stop(_ id: UUID) -> Task<SyncReport?, Never>? {
        guard let session = sessions.removeValue(forKey: id) else { return nil }
        return session.stop()
    }

    /// The app went to the background (or came back): closed vaults' sessions stop their periodic runs
    /// meanwhile; writes into them (a voice note) and demands still run. The open vault's are untouched.
    func setInBackground(_ background: Bool) {
        inBackground = background
        for s in sessions.values { s.periodicPaused = background && !s.isOpenVault }
    }
    @ObservationIgnored private var inBackground = false

    /// Asks every session for a run soon (the app became active, the network came back).
    func demandAll() {
        for s in sessions.values { s.demand() }
    }

    // MARK: - Budget

    /// Background runs may hold at most this many slots; the open vault's may use them all.
    private func fits(priority: Bool) -> Bool {
        active < (priority ? max(maxConcurrentRuns, 1) : max(maxConcurrentRuns - 1, 1))
    }

    /// Takes a slot for a run. `priority` is asked again whenever slots are handed out, so a run queued
    /// before its vault was opened takes the open vault's slot once it is (`attachOpen`).
    private func admit(priority: @escaping @MainActor () -> Bool) async {
        let now = priority()
        if waiting.isEmpty || now, fits(priority: now) {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting.append((priority, c))
        }
    }

    private func releaseRun() {
        active = max(active - 1, 0)
        wakeWaiters()
    }

    /// Hands free slots to waiters that fit now: the open vault's first, then the others in order.
    private func wakeWaiters() {
        for wantPriority in [true, false] {
            var i = 0
            while i < waiting.count {
                let p = waiting[i].priority()
                if p == wantPriority, fits(priority: p) {
                    active += 1
                    waiting.remove(at: i).resume.resume()
                } else {
                    i += 1
                }
            }
        }
    }

    /// The number of runs going now (tests).
    var runsGoing: Int { active }

    // MARK: - Background tasks (docs/design/device-first-sync.md §4.2)

    /// When a background task last ran each target (by target id), so the next starts with the others (no pair
    /// starves, `BackgroundBudget.order`). Kept in `UserDefaults`: iOS often launches the app for one task. Tests
    /// replace both.
    @ObservationIgnored var loadTried: () -> [String: Double] = {
        UserDefaults.standard.dictionary(forKey: SyncCoordinator.triedKey) as? [String: Double] ?? [:]
    }
    @ObservationIgnored var saveTried: ([String: Double]) -> Void = { UserDefaults.standard.set($0, forKey: SyncCoordinator.triedKey) }
    static let triedKey = "Sempere.backgroundSyncTried"
    /// The clock the background budget is measured with (tests pass their own).
    @ObservationIgnored var clock: () -> Date = { Date() }

    /// The pairs a background task runs: every session whose vault has local changes the target has not
    /// confirmed, the open vault's while it is unlocked here (two-way: what other devices wrote arrives), and
    /// any that failed (it retries). A closed vault with nothing to upload is left out: its runs only upload
    /// (nothing unverified is placed in a vault nobody unlocked, design §4.1), so there is nothing to do.
    func backgroundCandidates() -> [BackgroundRunCandidate] {
        let tried = loadTried()
        return sessions.values.compactMap { s in
            guard let vault = s.vaultID, s.unconfirmed > 0 || s.twoWay || !s.problems.isEmpty || s.failure != nil else {
                return nil
            }
            return BackgroundRunCandidate(vaultID: vault, targetID: s.locationID, hasUnconfirmed: s.unconfirmed > 0,
                                          isOpenVault: s.isOpenVault, lastSuccess: s.lastSuccess,
                                          lastTried: tried[s.locationID.uuidString].map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Waits at most `timeout` for `start` (a launch in the background starts the coordinator once old copies
    /// are converted). Returns whether it started.
    func waitUntilStarted(timeout: Duration = .seconds(5)) async -> Bool {
        let end = ContinuousClock.now + timeout
        while !runsAll, ContinuousClock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return runsAll
    }

    /// A `BGAppRefreshTask`: one run per candidate pair, one after another, in `BackgroundBudget.order`; each
    /// bounded by its share of `budget` (at least `BackgroundBudget.minimumRun`). Pairs that do not fit wait
    /// for the next task, which starts with them (`markTried`). A run that fails or hangs (bounded) only marks its own
    /// session. Returns the targets that ran, in order.
    @discardableResult
    func runBackgroundRefresh(budget: TimeInterval = BackgroundBudget.refreshTime, cancel: SyncRunCancel) async -> [UUID] {
        let start = clock()
        let order = BackgroundBudget.order(backgroundCandidates())
        var ran: [UUID] = []
        for (i, candidate) in order.enumerated() {
            if cancel.isSet || Task.isCancelled { break }
            let remaining = budget - clock().timeIntervalSince(start)
            guard let bound = BackgroundBudget.runTime(remaining: remaining, runsLeft: order.count - i) else { break }
            guard let session = sessions[candidate.targetID] else { continue }
            markTried(candidate.targetID)
            _ = await session.runInBackground(maxDuration: bound, cancel: cancel)
            ran.append(candidate.targetID)
        }
        Perf.event(.backgroundSync, "refresh ran=\(ran.count) of=\(order.count)")
        return ran
    }

    /// A `BGProcessingTask`: full passes over every candidate pair in the same order, until a pass changes
    /// nothing, `maxPasses` passes ran, or iOS takes the time back (`cancel`: runs stop between files).
    func runBackgroundProcessing(cancel: SyncRunCancel, maxPasses: Int = 3) async {
        for _ in 0..<maxPasses {
            var changed = false
            for candidate in BackgroundBudget.order(backgroundCandidates()) {
                if cancel.isSet || Task.isCancelled { return }
                guard let session = sessions[candidate.targetID] else { continue }
                markTried(candidate.targetID)
                changed = await session.runInBackground(maxDuration: nil, cancel: cancel).changed || changed
            }
            if !changed { return }
        }
    }

    /// Records that a background task runs target `id` now (dropping targets that are gone).
    private func markTried(_ id: UUID) {
        let current = Set(sessions.keys.map(\.uuidString))
        var tried = loadTried().filter { current.contains($0.key) }
        tried[id.uuidString] = clock().timeIntervalSince1970
        saveTried(tried)
    }

    /// True while a run goes or one was asked for and has not started.
    var hasWorkInFlight: Bool {
        active > 0 || !waiting.isEmpty || sessions.values.contains { $0.isSyncing || ($0.schedule.demanded && $0.runsAutomatically) }
    }

    /// Waits until no run goes and none was asked for (the app left the screen: what was in flight finishes
    /// under background time), or the task is canceled.
    func waitForRunsToEnd(poll: Duration = .milliseconds(200)) async {
        while hasWorkInFlight, !Task.isCancelled {
            try? await Task.sleep(for: poll)
        }
    }

    // MARK: - Reachability

    /// The network went away or came back (`WebDAVReachability`). Coming back, every WebDAV session runs soon
    /// and forgets its backoff (design §4: "network reachable: run, cancel the backoff"). Folder targets
    /// follow their provider, not the network.
    func networkChanged(reachable: Bool) {
        defer { lastReachable = reachable }
        guard reachable, lastReachable == false else { return }
        for s in sessions.values where s.kind == .webdav { s.networkReturned() }
    }
    @ObservationIgnored private var lastReachable: Bool?

    /// A voice note was delivered into vault `id`'s copy (quick capture, open or not): its sessions run soon
    /// rather than at the idle pace.
    func captureDelivered(vault id: UUID) {
        for s in sessions.values where s.vaultID == id { s.noteWrite() }
    }
}
