import Foundation
import Observation
import Sempere
import SempereSync
import SempereWebDAV

/// Every in-app vault with a sync target keeps syncing, open or not, each isolated from the others
/// (docs/design/device-first-sync.md §4.2, docs/io.md "Sync targets in the app"). One per app; it owns
/// one `SyncSession` per (vault, target). P5's targets are WebDAV locations (each one a vault's local
/// copy and its server); P6 adds folder targets and several targets per vault.
///
/// - The open vault's session runs two-way while it is unlocked here (`attachOpen`, `vaultUnlocked`) and
///   hands each run's local changes to the model. Every other vault's session runs upload-only at the
///   idle pace (`start`): its captures and last edits go up, and what other devices wrote arrives at its
///   next unlock (nothing unverified is placed in a vault nobody unlocked, design §4.1).
/// - Isolation: each session has its own copy, sync state, quarantine, credentials (Keychain item by
///   location id), schedule, backoff and status. A failure (a hung server bounded by the run's limits, a
///   wrong password, a full disk) marks only its own session.
/// - Budget: at most `maxConcurrentRuns` runs at once across the app, at most one per session. One slot is
///   kept for the open vault: background runs take at most `maxConcurrentRuns - 1`, so slow uploads of
///   closed vaults never hold up the open vault's runs or Sync Now (review of #70, F2).
@MainActor
@Observable
final class SyncCoordinator {
    /// The sessions, by location id.
    private(set) var sessions: [UUID: SyncSession] = [:]
    /// The location whose vault is open in the model, if any.
    private(set) var openLocation: UUID?
    /// Whether every location's session runs (the app at launch); off, only the open vault's does (tests).
    private(set) var runsAll = false

    /// At most this many runs at once across the app.
    @ObservationIgnored var maxConcurrentRuns = 2
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var waiting: [(priority: Bool, resume: CheckedContinuation<Void, Never>)] = []

    /// Builds the session of a location (the model supplies endpoint, copy, remote and options).
    @ObservationIgnored var makeSession: @MainActor (WebDAVLocation) -> SyncSession?
    /// The locations there are now.
    @ObservationIgnored var locations: @MainActor () -> [WebDAVLocation]
    /// How often sessions look at their schedules, and their write delay (tests shorten both).
    @ObservationIgnored var tick = Duration.seconds(1)
    @ObservationIgnored var configure: (inout SyncSchedule) -> Void = { _ in }

    init(locations: @escaping @MainActor () -> [WebDAVLocation],
         makeSession: @escaping @MainActor (WebDAVLocation) -> SyncSession?) {
        self.locations = locations
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

    /// Starts a session for every location (the app at launch, and after one is added or removed).
    func start() {
        runsAll = true
        refresh()
    }

    /// Makes sessions for new locations and drops those of removed ones (when `runsAll`). The model calls
    /// it when a location is added (`connectWebDAV`) or removed (`removeWebDAVLocation`).
    func refresh() {
        let now = Set(locations().map(\.id))
        for id in sessions.keys where !now.contains(id) && id != openLocation { _ = stop(id) }
        guard runsAll else { return }
        // A location whose first download has not finished has no copy to sync yet (`openWebDAV` makes it).
        for location in locations() where location.downloaded && sessions[location.id] == nil { _ = session(for: location) }
    }

    /// The session of `location`, made and started if there is none.
    @discardableResult
    func session(for location: WebDAVLocation) -> SyncSession? {
        if let existing = sessions[location.id] { return existing }
        guard let made = makeSession(location) else { return nil }
        made.tick = tick
        configure(&made.schedule)
        made.admit = { [weak self] priority in await self?.admit(priority: priority) }
        made.release = { [weak self] in self?.releaseRun() }
        sessions[location.id] = made
        made.start()
        return made
    }

    /// The model opened the vault of `location`: its session is the open one (made if needed).
    func attachOpen(_ location: WebDAVLocation) -> SyncSession? {
        openLocation = location.id
        let s = session(for: location)
        s?.isOpenVault = true
        return s
    }

    /// The model closed the open vault: its session goes back to upload-only (or stops when only the
    /// open vault syncs). Returns a run still going, which must end before the copy is replaced.
    @discardableResult
    func detachOpen() -> Task<SyncReport?, Never>? {
        guard let id = openLocation else { return nil }
        openLocation = nil
        guard let session = sessions[id] else { return nil }
        session.vaultClosed()
        session.isOpenVault = false
        guard runsAll else { return stop(id) }
        return nil
    }

    /// Stops and forgets the session of `id` (a removed location); returns its run still going.
    @discardableResult
    func stop(_ id: UUID) -> Task<SyncReport?, Never>? {
        guard let session = sessions.removeValue(forKey: id) else { return nil }
        if openLocation == id { openLocation = nil }
        return session.stop()
    }

    /// Asks every session for a run soon (the app became active, the network came back).
    func demandAll() {
        for s in sessions.values { s.demand() }
    }

    // MARK: - Budget

    /// Background runs may hold at most this many slots; the open vault's may use them all.
    private func fits(priority: Bool) -> Bool {
        active < (priority ? max(maxConcurrentRuns, 1) : max(maxConcurrentRuns - 1, 1))
    }

    private func admit(priority: Bool) async {
        if waiting.isEmpty || priority, fits(priority: priority) {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if priority, let i = waiting.firstIndex(where: { !$0.priority }) {
                waiting.insert((priority, c), at: i)
            } else {
                waiting.append((priority, c))
            }
        }
    }

    private func releaseRun() {
        active = max(active - 1, 0)
        // Each waiter that fits now takes a slot, the open vault's first.
        var i = 0
        while i < waiting.count {
            if fits(priority: waiting[i].priority) {
                active += 1
                waiting.remove(at: i).resume.resume()
            } else {
                i += 1
            }
        }
    }

    /// The number of runs going now (tests).
    var runsGoing: Int { active }

    /// A voice note was delivered into vault `id`'s copy (quick capture, open or not): its sessions run soon
    /// rather than at the idle pace.
    func captureDelivered(vault id: UUID) {
        for s in sessions.values where s.vaultID == id { s.noteWrite() }
    }
}
