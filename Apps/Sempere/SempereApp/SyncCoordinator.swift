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
/// - Budget: at most `maxConcurrentRuns` runs at once across the app, at most one per session; the open
///   vault's runs go first.
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
    }

    // MARK: - Sessions

    /// Starts a session for every location (the app at launch, and after one is added or removed).
    func start() {
        runsAll = true
        refresh()
    }

    /// Makes sessions for new locations and drops those of removed ones (when `runsAll`).
    func refresh() {
        let now = Set(locations().map(\.id))
        for id in sessions.keys where !now.contains(id) && id != openLocation { _ = stop(id) }
        guard runsAll else { return }
        for location in locations() where sessions[location.id] == nil { _ = session(for: location) }
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
        return session(for: location)
    }

    /// The model closed the open vault: its session goes back to upload-only (or stops when only the
    /// open vault syncs). Returns a run still going, which must end before the copy is replaced.
    @discardableResult
    func detachOpen() -> Task<SyncReport?, Never>? {
        guard let id = openLocation else { return nil }
        openLocation = nil
        guard let session = sessions[id] else { return nil }
        session.vaultClosed()
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

    private func admit(priority: Bool) async {
        if active < maxConcurrentRuns {
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
        if waiting.isEmpty {
            active = max(active - 1, 0)
        } else {
            // The slot passes to the next waiter (the open vault's first).
            waiting.removeFirst().resume.resume()
        }
    }
}
