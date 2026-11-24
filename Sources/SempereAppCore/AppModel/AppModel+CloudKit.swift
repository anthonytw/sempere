import Age
import Foundation
import Sempere
import SempereInsights
import SempereSync

/// The CloudKit side of the app's sync targets (docs/design/1.4-cloudkit.md §3.2, §4, §6.3): the front end gives the model the
/// Apple adapter as a `CloudRecordStore` (`SempereCloudKit`, never linked here: this library builds on Linux), and the model
/// runs the target like any other, through `CloudTargetRun`. Nothing here needs a push for correctness: a push only makes a run
/// start now (`cloudKitDatabaseChanged`).
public struct CloudKitServices: Sendable {
    /// The private database of the app's container (the app's `CloudKitDatabase`); one value is used from several threads.
    public var makeStore: @Sendable () -> any CloudRecordStore
    /// Whether this build is signed for the container (`CloudKitDatabase.availability()`); a run without it fails plainly.
    public var isAvailable: @Sendable () -> Bool

    public init(makeStore: @escaping @Sendable () -> any CloudRecordStore, isAvailable: @escaping @Sendable () -> Bool = { true }) {
        self.makeStore = makeStore
        self.isAvailable = isAvailable
    }
}

/// Why a CloudKit target could not be added.
public enum CloudKitTargetProblem: Error, Equatable, Sendable {
    /// This build cannot use CloudKit (no entitlement: a build without the iCloud capability).
    case unavailable
    /// The device is not signed in to iCloud, or the account cannot be used now (the status says why).
    case account(CloudAccount.Status)
    /// The vault is not a store vault of this device.
    case notAStoreVault
    /// The vault has a CloudKit target already.
    case duplicate
    /// The account's iCloud holds no such vault (its zone is gone).
    case noSuchVault
    case other(String)
}

extension AppModelCore {
    /// Adds an iCloud (CloudKit) target to the store vault `vaultID`: this vault's zone in the signed-in Apple Account's
    /// private database. The first run uploads the vault, or makes a union with the zone another device made; nothing is deleted.
    /// The account is recorded (hashed) so that a run in another account pauses instead of uploading into it.
    @discardableResult
    public func addCloudKitTarget(to vaultID: UUID) async throws -> SyncTarget {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { throw CloudKitTargetProblem.unavailable }
        guard syncStore.entry(id: vaultID) != nil else { throw CloudKitTargetProblem.notAStoreVault }
        let account = try await offMain { try cloud.makeStore().account() }
        guard account.status == .available else { throw CloudKitTargetProblem.account(account.status) }
        let store = syncStore
        let target: SyncTarget
        do {
            target = try store.targets.add(.cloudkit(user: account.userHash), to: vaultID)
        } catch SyncTargetError.duplicate {
            throw CloudKitTargetProblem.duplicate
        } catch {
            throw CloudKitTargetProblem.other(services.describeError(error))
        }
        syncTargetsChanged()
        syncCoordinator.sessions[target.id]?.demand()
        return target
    }

    /// A CloudKit target's session: two-way runs with the vault the model has open and unlocked, upload-only runs otherwise,
    /// each through `CloudTargetRun` (the CLI's `store sync`) under the vault's write lock. The schedule is the folder
    /// targets' (a CloudKit run is cheap: no listing round trips, design §3.2) and, like a WebDAV target's, it waits for a
    /// network path.
    func makeCloudKitSession(_ ref: SyncTargetRef) -> SyncSession? {
        guard let cloud = services.cloudKit else { return nil }
        let store = syncStore, vaultID = ref.vaultID, targetID = ref.id
        guard let entry = store.entry(id: vaultID) else { return nil }
        let stateURL = store.targets.stateURL(targetID, of: vaultID)
        let quarantine = store.targets.quarantineDirectory(targetID, of: vaultID)
        let lock = store.writeLock(for: vaultID)
        let cacheDirectory = summaryCacheDirectory, deviceState = deviceStateURL
        let undoneURL = UndoneRemovalsRecord.url(targets: store.targets, vaultId: vaultID)
        let counting = LocalCopy(folder: entry.url, stateDirectory: stateURL.deletingLastPathComponent())
        let notes = CloudRunNotes()
        let session = SyncSession(
            locationID: targetID, vaultID: vaultID, name: ref.vaultName, lastSuccess: ref.target.lastSuccess,
            run: { [weak self] request in
                let (target, vault, join) = await MainActor.run { () -> (SyncTarget?, Vault?, NativeIdentity?) in
                    let run = self?.syncRunKeys(for: targetID)
                    return (store.targets.targets(of: vaultID).first { $0.id == targetID }, run?.vault, run?.join)
                }
                guard let target else { throw SyncTargetError.notFound(targetID.uuidString) }
                return try await Task.detached(priority: .utility) { () throws -> SyncReport in
                    guard cloud.isAvailable() else { throw CloudRecordError.unsupported("this build is not signed for iCloud") }
                    var options = SyncOptions(deviceLabel: "app")
                    options.summaryCacheDirectory = cacheDirectory
                    options.derivedTitles = { InsightsNotes.derivedTitles($0, for: $1) }
                    options.localWriteLock = lock
                    options.quarantineDirectory = quarantine
                    request.apply(to: &options)
                    options.deviceID = vault?.writerDevice ?? (FileManager.default.fileExists(atPath: deviceState.path)
                        ? (try? DeviceState.loadOrCreate(at: deviceState))?.device : nil)
                    options.recordSynced = true
                    options.undoneRemovalsURL = undoneURL
                    options.epochTrust = Self.defaultTrust
                    let twoWay = request.mode == .twoWay && vault?.canRead == true
                    options.publishSummaries = twoWay && !PartialCopy.isPartial(entry.url)
                    let remote = CloudTargetRun.remote(store: cloud.makeStore(), vaultId: vaultID, stateURL: stateURL,
                                                       expectedUser: target.cloudUser)
                    if let join {
                        // A join run (design §6.2): the request goes out, home's approval comes in, keyless.
                        var joinOptions = options
                        joinOptions.firstPullIdentities = [join]
                        return try CloudTargetRun.run(vaultFolder: entry.url, remote: remote, vault: nil, stateURL: stateURL,
                                                      twoWay: true, options: joinOptions)
                    }
                    let staging = LockedStaging(targetState: stateURL)
                    // The unlock places what locked runs staged (checked under the key), then the run goes on.
                    let placed = twoWay ? try vault.flatMap { try staging.place(vaultFolder: entry.url, vault: $0, options: options) } : nil
                    var report = try CloudTargetRun.run(vaultFolder: entry.url, remote: remote, vault: vault, stateURL: stateURL,
                                                        twoWay: twoWay, options: options)
                    if let placed { report.changed = Self.union(placed.changed, report.changed) }
                    if remote.storageWasFull { notes.noteStorageFull() }
                    if !twoWay, request.stage, !PartialCopy.isPartial(entry.url) {
                        // Locked: what other devices wrote is staged, never placed (design §4.1). Best effort.
                        _ = try? staging.stage(vaultFolder: entry.url, options: options) { shadow, state, pullOnly in
                            try CloudTargetRun.run(vaultFolder: shadow, remote: CloudTargetRun.remote(store: cloud.makeStore(), vaultId: vaultID, stateURL: state,
                                                                                                     expectedUser: target.cloudUser),
                                                   vault: nil, stateURL: state, twoWay: true, options: pullOnly)
                        }
                    }
                    return report
                }.value
            },
            countUnconfirmed: { await Task.detached(priority: .utility) { counting.unconfirmedChanges() }.value })
        session.cloudNotes = notes
        session.onSuccess = { date in try? store.targets.update(targetID, of: vaultID) { $0.lastSuccess = date } }
        session.openRemote = {
            guard let target = store.targets.targets(of: vaultID).first(where: { $0.id == targetID }) else {
                throw SyncTargetError.notFound(targetID.uuidString)
            }
            let remote = CloudTargetRun.remote(store: cloud.makeStore(), vaultId: vaultID, stateURL: stateURL, expectedUser: target.cloudUser)
            return (remote, {}, FolderTargetRun.syncedBefore(stateURL: stateURL))
        }
        let staging = LockedStaging(targetState: stateURL), vaultFolder = entry.url
        session.countStaged = { await Task.detached(priority: .utility) { staging.pending(vaultFolder: vaultFolder).count }.value }
        return session
    }

    // MARK: Pushes and the account (hints only: a run's own `prepareRun` is the guarantee)

    /// A push arrived (the database subscription, `CloudKitDatabase.isDatabaseNotification`) or the app opened: asks the database
    /// which zones changed and demands a run of each matching vault's CloudKit target. Returns true when a run was demanded. With
    /// `runNow` the runs are made before it returns (a push that wakes the app for a few seconds: the sessions' bounds apply).
    /// The database's change token is kept under the store's `.sync` folder; losing it only means every zone is looked at.
    @discardableResult
    public func cloudKitDatabaseChanged(runNow: Bool = false) async -> Bool {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { return false }
        let tokenURL = syncStore.root.appendingPathComponent(".sync", isDirectory: true).appendingPathComponent("cloudkit-database-token")
        let zones: Set<String>? = try? await offMain {
            let db = cloud.makeStore()
            var token = (try? Data(contentsOf: tokenURL)).flatMap(CloudChangeToken.init)
            var changed = Set<String>()
            do {
                while true {
                    let page = try db.fetchDatabaseChanges(since: token)
                    changed.formUnion(page.changedZones)
                    token = page.token
                    if !page.moreComing { break }
                }
            } catch let e as CloudStoreError where e.code == .changeTokenExpired {
                try? FileManager.default.removeItem(at: tokenURL)
                return nil   // every zone is looked at
            } catch {
                return Set()
            }
            try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? token?.data.write(to: tokenURL, options: .atomic)
            return changed
        }
        var demanded: [SyncSession] = []
        for session in syncCoordinator.sessions.values where session.kind == .cloudkit {
            guard let id = session.vaultID else { continue }
            if let zones, !zones.contains(CloudTargetRun.zone(vaultId: id)) { continue }
            if runNow { demanded.append(session) } else { session.demand() }
            if !runNow { demanded.append(session) }
        }
        if runNow { for session in demanded { _ = await session.syncNow() } }
        return !demanded.isEmpty
    }

    /// The iCloud account changed (`CloudKitDatabase.accountChangedNotification`): every CloudKit target runs again, which
    /// checks the account first (another account pauses the target, a signed-out one waits: `CloudRecordError.account`).
    public func cloudKitAccountChanged() {
        for session in syncCoordinator.sessions.values where session.kind == .cloudkit { session.demand() }
    }

    /// True when some store vault has a CloudKit target (the app then registers for pushes and keeps the subscription).
    public var hasCloudKitTargets: Bool {
        syncStore.targets.all().values.contains { $0.contains { $0.kind == .cloudkit } }
    }
}
