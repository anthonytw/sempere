import Foundation
import Sempere

// MARK: - A key change across sync targets (docs/design/device-first-sync.md §6.1)
//
// `KeyChangeCoordinator` runs one device's key change against all of a
// vault's targets:
//
// - C0: preconditions (routine mode: every target synced cleanly within the
//   last minute, unless the user overrides a target);
// - C1: the claim, the change's exact journal written create-only to every
//   target; another device's journal in flight aborts the change, and this
//   device's own claims are taken back (`If-Match`);
// - K1 to K4: the change itself (`Vault.commit`), with the outgoing secret
//   stored in the keyring first;
// - C5, per target, in order: (a) the step-2 `vault.json` (its journal is
//   there from C1), (b) the rewrapped files by rewrap-replace, (c) the step-4
//   `vault.json`, (d) the journal deleted (`If-Match`) only once a run found
//   every file there current.
//
// Its progress is kept in a small device-local file (`ledger`), so a crash
// anywhere resumes: claims with no local change behind them are taken back
// at the next launch (F1), and propagation continues where it stopped.
// `sync(target:)` always propagates first, so in compromised mode the change
// reaches each target ahead of all other sync work, and a target that was
// unreachable is claimed when it comes back.

/// One sync target of a vault, as the coordinator reaches it.
public struct KeyChangeTarget: Sendable {
    public var id: String
    public var remote: any SyncRemote
    /// The target's sync state (the engine's, shared with ordinary runs).
    public var stateURL: URL

    public init(id: String, remote: any SyncRemote, stateURL: URL) {
        self.id = id; self.remote = remote; self.stateURL = stateURL
    }
}

/// How far a key change got on one target (design §6.1 C1, C5).
public enum KeyChangeStep: Int, Codable, Sendable, Comparable, CaseIterable {
    /// C1: the journal is there.
    case claimed = 1
    /// C5(a): the step-2 `vault.json` is there.
    case manifest
    /// C5(b): every file there is current.
    case files
    /// C5(c): the step-4 `vault.json` is there.
    case finished
    /// C5(d): the journal is gone; nothing left to do there.
    case journalRemoved

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Where the coordinator stops as a crash there would (tests, design §6.4).
public struct KeyChangeFaults: Sendable, Hashable {
    /// Stop after C1 (every claim written), before K1.
    public var afterClaims = false
    /// The vault change's own fault (K1 to K4).
    public var rewrap = RewrapFaults.none
    /// Stop on a target right after this step.
    public var afterStep: [String: KeyChangeStep] = [:]
    /// Stop right after the first claim is written, before the ledger records it (a crash there).
    public var afterFirstClaimWrite = false

    public init(afterClaims: Bool = false, rewrap: RewrapFaults = .none, afterStep: [String: KeyChangeStep] = [:],
                afterFirstClaimWrite: Bool = false) {
        self.afterClaims = afterClaims; self.rewrap = rewrap; self.afterStep = afterStep
        self.afterFirstClaimWrite = afterFirstClaimWrite
    }
}

/// Why a key change was refused or stopped.
public enum KeyChangeError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A target holds another device's journal in flight (design §6.1 C1).
    case anotherChangeInFlight(target: String)
    /// Routine mode: a target cannot be reached; override it to go on (C1).
    case targetUnreachable(target: String, String)
    /// Routine mode: a target has not synced cleanly in the last minute (C0).
    case targetNotRecentlySynced(target: String)
    /// A change is already in progress on this device.
    case changeInProgress
    /// A fault point (tests).
    case interrupted
    /// This device's record of its key changes cannot be read: no change starts until it is repaired
    /// (`repairLedger`), and nothing it would record is guessed.
    case ledgerUnreadable(String)
    /// "Keep the other change" dropped keys this device had added under the same secret: they can still
    /// open every file until the secret rotates, which the coordinator does first, by itself.
    case rotationOwed

    public var description: String {
        switch self {
        case .anotherChangeInFlight(let t): return "another device's key change is in progress on \(t): try again once it finished"
        case .targetUnreachable(let t, let why): return "\(t) cannot be reached (\(why)); a routine key change needs every target"
        case .targetNotRecentlySynced(let t): return "\(t) has not synced in the last minute: sync it first"
        case .changeInProgress: return "a key change is still propagating from this device"
        case .interrupted: return "interrupted (test)"
        case .ledgerUnreadable(let why): return "this device's key-change record cannot be read (\(why)): repair it first"
        case .rotationOwed: return "the vault secret must rotate first (keys dropped when another change was kept)"
        }
    }
}

/// What a target's propagation found.
public struct KeyChangePropagation: Hashable, Sendable {
    /// The step reached on the target (nil: not even claimed).
    public var step: KeyChangeStep?
    /// The target holds another change's `vault.json` or journal: two key
    /// changes met (design §6.2 F7). Nothing is replaced there until the user
    /// keeps one of them (`adoptOtherChange`).
    public var conflict: String?
    /// The engine run of C5(b), if one ran.
    public var report: SyncReport?
    /// This device's record of its key changes cannot be read (`repairLedger`).
    public var ledgerProblem: String?
    /// A rotation is owed and could not run yet (`KeyChangeError.rotationOwed`); why.
    public var rotationOwed: String?
    /// A refused journal left on the target by a change that is over (older than the in-flight day) was
    /// removed (`If-Match`): it held back blob collection and every run's clean state.
    public var removedStaleJournal = false

    public init(step: KeyChangeStep? = nil, conflict: String? = nil, report: SyncReport? = nil) {
        self.step = step; self.conflict = conflict; self.report = report
    }
}

/// The device-local record of a change in progress.
struct KeyChangeLedger: Codable, Equatable {
    var journal: Data
    var policy: KeyChangePolicy
    /// `vault.json` before the change (what a target not reached yet holds).
    var base: Data
    /// `vault.json` after K2 and after K4.
    var step2: Data?
    var step4: Data?
    /// Per target: the step reached; absent: claim pending.
    var steps: [String: KeyChangeStep] = [:]
    /// Per target: another change met there (F7).
    var conflicts: [String: String] = [:]
}

struct KeyChangeFile: Codable, Equatable {
    var lastClean: [String: Date] = [:]
    var change: KeyChangeLedger?
    /// Claims to take back from targets that could not be reached when they were dropped, by target.
    var takeBack: [String: [Data]]?
    /// Keys "Keep the other change" dropped under the same secret: the secret must rotate (review finding 3).
    var rotationOwed: [String]?
}

/// One device's key changes against the targets of one vault.
public final class KeyChangeCoordinator: @unchecked Sendable {
    public let folder: URL
    public let targets: [KeyChangeTarget]
    public let keyring: any SecretKeyringStore
    let ledgerURL: URL
    /// The window within which every target must have synced cleanly before a routine change (C0).
    public static let recentSync: TimeInterval = 60

    /// - Parameters:
    ///   - folder: the working copy.
    ///   - ledger: this device's record of the change (device-local, outside the vault).
    public init(folder: URL, targets: [KeyChangeTarget], keyring: any SecretKeyringStore, ledger: URL) {
        self.folder = folder
        self.targets = targets
        self.keyring = keyring
        self.ledgerURL = ledger
    }

    /// The record; none yet is an empty one. One that exists but cannot be read is an error, never taken
    /// as "nothing in progress" (claims and a half-propagated change would be forgotten; review finding 6).
    func load() throws -> KeyChangeFile {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return KeyChangeFile() }
        do {
            let data = try BoundedRead.contents(of: ledgerURL, maxBytes: 16 << 20)
            let d = JSONDecoder()
            d.dateDecodingStrategy = .secondsSince1970
            return try d.decode(KeyChangeFile.self, from: data)
        } catch {
            throw KeyChangeError.ledgerUnreadable(SyncEngine.describe(error))
        }
    }

    /// Why the record cannot be read; nil when it can.
    public var ledgerProblem: String? {
        do { _ = try load(); return nil } catch { return "\(error)" }
    }

    /// Sets an unreadable record aside (kept beside it, never deleted), so changes can start again. Claims
    /// it named stay on targets as refused journals; any device removes them after the in-flight day
    /// (`sync(target:)`), and a change it left half-propagated is finished by the devices that hold its
    /// journal or superseded by the next change. Returns where it was put.
    @discardableResult
    public func repairLedger() throws -> URL? {
        guard ledgerProblem != nil else { return nil }
        let aside = ledgerURL.deletingLastPathComponent()
            .appendingPathComponent(ledgerURL.lastPathComponent + ".unreadable-\(UUID().uuidString.prefix(8))")
        try FileManager.default.moveItem(at: ledgerURL, to: aside)
        return aside
    }

    func save(_ f: KeyChangeFile) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LocalFS.write(try e.encode(f), to: ledgerURL, replacing: true)
    }

    func update(_ body: (inout KeyChangeFile) throws -> Void) throws {
        var f = try load()
        try body(&f)
        try save(f)
    }

    /// True while a change from this device is still propagating.
    /// True too while the record cannot be read (it may name one).
    public var inProgress: Bool { (try? load()).map { $0.change != nil } ?? true }

    /// Per target, how far the change got; empty when none is in progress.
    public var steps: [String: KeyChangeStep] { (try? load())?.change?.steps ?? [:] }

    /// Targets where another change was met (F7).
    public var conflicts: [String: String] { (try? load())?.change?.conflicts ?? [:] }

    /// Keys a kept change dropped under the same secret: a rotation is owed (it runs at the next sync).
    public var rotationOwed: [String] { (try? load())?.rotationOwed ?? [] }

    // MARK: C0, C1, K1 to K4

    /// Makes a key change: checks C0, claims every target (C1), then runs
    /// K1 to K4 on `vault`. Propagation (C5) follows in `sync(target:)`.
    ///
    /// - Parameters:
    ///   - prepare: builds the change on the vault (`prepareAddRecipient`, …).
    ///   - overriding: targets the user chose to leave out of the routine
    ///     preconditions (unreachable, or not synced lately); warned in the UI.
    /// - Throws: `KeyChangeError`; the vault's errors.
    @discardableResult
    public func change(_ vault: inout Vault, overriding: Set<String> = [], now: Date = Date(),
                       faults: KeyChangeFaults = KeyChangeFaults(),
                       prepare: (inout Vault) throws -> PreparedKeyChange) throws -> Vault.RewrapReport {
        try change(&vault, overriding: overriding, now: now, faults: faults, owedRotation: false, prepare: prepare)
    }

    func change(_ vault: inout Vault, overriding: Set<String>, now: Date, faults: KeyChangeFaults, owedRotation: Bool,
                prepare: (inout Vault) throws -> PreparedKeyChange) throws -> Vault.RewrapReport {
        var file = try load()
        guard file.change == nil else { throw KeyChangeError.changeInProgress }
        if file.rotationOwed != nil, !owedRotation { throw KeyChangeError.rotationOwed }
        let prepared = try prepare(&vault)
        let routine = prepared.keyChange.mode == .routine
        // C0: in routine mode every target synced cleanly within the last minute.
        if routine {
            for t in targets where !overriding.contains(t.id) {
                guard let last = file.lastClean[t.id], now.timeIntervalSince(last) <= Self.recentSync else {
                    throw KeyChangeError.targetNotRecentlySynced(target: t.id)
                }
            }
        }
        let base = try BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                            maxBytes: BoundedRead.maxManifestBytes)
        var ledger = KeyChangeLedger(journal: prepared.journal, policy: prepared.keyChange, base: base)
        // The record first: a crash at any point after a claim is written finds it, and takes the claims
        // back (`recover`); a record that cannot be written stops the change before any claim.
        file.change = ledger
        try save(file)
        // C1: claim every target with the journal's exact bytes.
        // Every target written to, claimed or not: a write whose answer was lost may have landed.
        var claimed: [KeyChangeTarget] = []
        for t in targets {
            claimed.append(t)
            do {
                let result = try claim(t, journal: prepared.journal, vault: vault, now: now)
                if faults.afterFirstClaimWrite { throw KeyChangeError.interrupted }
                switch result {
                case .claimed:
                    ledger.steps[t.id] = .claimed
                    do { try update { $0.change = ledger } } catch {
                        takeBack(claimed, journal: prepared.journal)
                        try? update { $0.change = nil }
                        throw error
                    }
                case .taken:
                    try? update { $0.change = nil }
                    takeBack(claimed, journal: prepared.journal)
                    throw KeyChangeError.anotherChangeInFlight(target: t.id)
                }
            } catch let e as KeyChangeError {
                throw e
            } catch {
                // Unreachable: routine refuses unless overridden; compromised claims it when it is back.
                if routine && !overriding.contains(t.id) {
                    takeBack(claimed, journal: prepared.journal)
                    try? update { $0.change = nil }
                    throw KeyChangeError.targetUnreachable(target: t.id, SyncEngine.describe(error))
                }
            }
        }
        if faults.afterClaims { throw KeyChangeError.interrupted }
        // K1 to K4.
        let report = try vault.commit(prepared, faults: faults.rewrap, keyring: keyring, now: now) { written in
            try self.update { $0.change?.step2 = written }
        }
        try recordFinished(vault)
        return report
    }

    enum ClaimResult { case claimed, taken }

    /// Writes the journal create-only; a journal there already is ours, a
    /// stale one this device refuses (replaced), or another change in flight.
    func claim(_ t: KeyChangeTarget, journal: Data, vault: Vault, now: Date) throws -> ClaimResult {
        if try t.remote.write([Vault.journalName], .data(journal), condition: .create) { return .claimed }
        let (there, etag) = try t.remote.read([Vault.journalName], maxBytes: BoundedRead.maxManifestBytes)
        if there == journal { return .claimed }
        let manifest = (try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes).data)
            ?? (try? BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName), maxBytes: BoundedRead.maxManifestBytes))
        guard case .refused? = Vault.incomingJournalProblem(there, local: nil, manifest: manifest, vault: vault) else {
            return .taken   // this device accepts it, or cannot judge it: someone's change
        }
        if Vault.incomingJournalMayBeInFlight(there, manifest: manifest, vault: vault) {
            // Step 1 of a change whose vault.json has not arrived: in flight for a day after this device first saw it.
            let state = (try? SyncState.load(t.stateURL)) ?? nil
            guard let seen = state?.inFlightJournal, seen.hash == FileDigest.sha256(there),
                  now.timeIntervalSince(seen.firstSeen) >= Vault.inFlightJournalWindow else { return .taken }
        }
        // A stale journal nothing binds and nobody is writing: replaced by the claim.
        guard let etag, SyncEngine.isStrong(etag),
              try t.remote.write([Vault.journalName], .data(journal), condition: .replace(etag: etag)) else { return .taken }
        return .claimed
    }

    /// Deletes this device's own claims (only those versions). A target that cannot be reached now is
    /// remembered and tried again at its next run (`sync(target:)`), so no claim is left for ever.
    func takeBack(_ claimed: [KeyChangeTarget], journal: Data) {
        var missed: [String] = []
        for t in claimed where !takeBack(t, journal: journal) { missed.append(t.id) }
        guard !missed.isEmpty else { return }
        try? update { f in
            for id in missed where !(f.takeBack?[id]?.contains(journal) ?? false) {
                f.takeBack = f.takeBack ?? [:]
                f.takeBack?[id, default: []].append(journal)
            }
        }
    }

    /// True when the target holds no such claim any more.
    func takeBack(_ t: KeyChangeTarget, journal: Data) -> Bool {
        let there: (data: Data, etag: String?)
        do { there = try t.remote.read([Vault.journalName], maxBytes: BoundedRead.maxManifestBytes) } catch {
            return (try? t.remote.stat([Vault.journalName])).map { $0 == nil } ?? false
        }
        guard there.data == journal else { return true }
        return (try? t.remote.delete([Vault.journalName], ifETag: there.etag.flatMap { SyncEngine.isStrong($0) ? $0 : nil })) == true
    }

    /// Claims still to take back from `t`.
    func retryTakeBack(_ t: KeyChangeTarget) {
        guard let pending = (try? load())?.takeBack?[t.id], !pending.isEmpty else { return }
        let left = pending.filter { !takeBack(t, journal: $0) }
        try? update { f in
            f.takeBack?[t.id] = left.isEmpty ? nil : left
            if f.takeBack?.isEmpty == true { f.takeBack = nil }
        }
    }

    /// Records the step-4 `vault.json` once the change finished locally.
    func recordFinished(_ vault: Vault) throws {
        guard !vault.pendingRewrap else { return }
        let bytes = try BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                             maxBytes: BoundedRead.maxManifestBytes)
        try update { f in
            // Once: what this device holds later may be another change made on top of this one.
            guard f.change != nil, f.change?.step4 == nil else { return }
            if let step2 = f.change?.step2, !Vault.sameList(step2, bytes) { return }
            f.change?.step4 = bytes
            if f.change?.step2 == nil { f.change?.step2 = bytes }
        }
    }

    // MARK: Recovery (F1, F2, F3)

    /// At launch (and before each propagation): a change that never reached
    /// K2 is abandoned, its claims taken back (F1, F2: the journal left
    /// locally is unbound and refused, and moved aside); one stopped in K3
    /// is finished (F3). Returns whether a change is still propagating.
    @discardableResult
    public func recover(_ vault: inout Vault) throws -> Bool {
        guard let ledger = try load().change else { return false }
        let local = try BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                             maxBytes: BoundedRead.maxManifestBytes)
        if ledger.step2 == nil && Vault.sameList(local, ledger.base) {
            // Crashed before K2: nothing changed; the claims bind nothing.
            if vault.pendingRewrap { _ = try? vault.discardRefusedJournal() }
            takeBack(targets, journal: ledger.journal)
            try update { $0.change = nil }
            return false
        }
        if vault.pendingRewrap {
            let r = try vault.resumeRewrap()
            guard r.isComplete else { return true }
        }
        try recordFinished(vault)
        return true
    }

    /// This device took a later list since its change finished (another device's change made on top of
    /// it, or one the user kept): that change propagates now, so this one's work is over. Its claims
    /// are taken back (only its own bytes) and its record dropped.
    func dropIfSuperseded(_ vault: Vault) throws {
        guard let ledger = try load().change, let step4 = ledger.step4, !vault.pendingRewrap,
              let local = try? BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                                    maxBytes: BoundedRead.maxManifestBytes),
              !Vault.sameList(local, step4), !Vault.sameList(local, ledger.step2 ?? step4),
              !isBaseOrOlder(local, ledger.base, vault) else { return }
        takeBack(targets, journal: ledger.journal)
        try update { $0.change = nil }
    }

    // MARK: C5 and runs

    /// One target's run: the change's propagation first (C5), then an
    /// ordinary two-way run with the keyring and rewrap-replace, holding the
    /// mutable files while the propagation there has not reached (c).
    /// A run without errors or conflicts records the target as synced (C0).
    public func sync(target id: String, vault: inout Vault, options: SyncOptions,
                     faults: KeyChangeFaults = KeyChangeFaults()) throws -> (propagation: KeyChangePropagation?, report: SyncReport) {
        guard let t = targets.first(where: { $0.id == id }) else { throw SyncError.io("no target \(id)") }
        var propagation: KeyChangePropagation?
        retryTakeBack(t)
        let file: KeyChangeFile
        do { file = try load() } catch {
            // Fail closed: nothing is propagated or recorded from a record that cannot be read; the run
            // itself goes on (the vault's own checks hold), and the problem is reported until repaired.
            var o = options
            o.keyring = keyring
            o.rewrapReplace = true
            var p = KeyChangePropagation()
            p.ledgerProblem = "\(error)"
            if vault.canRead { p.removedStaleJournal = removeStaleJournal(t, vault: vault, now: options.now, own: nil) }
            let report = try SyncEngine(directory: folder, vault: vault.canRead ? vault : nil, remote: t.remote,
                                        stateURL: t.stateURL, options: o).run()
            return (p, report)
        }
        if vault.canRead, file.change != nil {
            try recover(&vault)
            try dropIfSuperseded(vault)
            if try load().change != nil { propagation = try propagate(t, vault: &vault, options: options, faults: faults) }
        }
        if vault.canRead, try load().change == nil, try load().rotationOwed != nil {
            // The owed rotation runs by itself, ahead of other work (compromised mode: no preconditions, 0 days).
            do {
                try change(&vault, overriding: Set(targets.map(\.id)), now: options.now, faults: KeyChangeFaults(),
                           owedRotation: true) { try $0.prepareRotation(keyChange: .compromised, now: options.now) }
                try update { $0.rotationOwed = nil }
                if try load().change != nil { propagation = try propagate(t, vault: &vault, options: options, faults: faults) }
            } catch {
                var p = propagation ?? KeyChangePropagation()
                p.rotationOwed = "\(error)"
                propagation = p
            }
        }
        if vault.canRead {
            let own = try load().change?.journal
            if removeStaleJournal(t, vault: vault, now: options.now, own: own) {
                var p = propagation ?? KeyChangePropagation()
                p.removedStaleJournal = true
                propagation = p
            }
        }
        var o = options
        o.keyring = keyring
        o.rewrapReplace = true
        let pending = try load().change.map { ($0.steps[id] ?? .claimed) < .finished || $0.conflicts[id] != nil } ?? false
        o.holdMutableFiles = pending
        let report = try SyncEngine(directory: folder, vault: vault.canRead ? vault : nil, remote: t.remote,
                                    stateURL: t.stateURL, options: o).run()
        if report.errors.isEmpty, report.conflicts.isEmpty, report.rejected.isEmpty {
            try update { $0.lastClean[id] = o.now }
        }
        return (propagation, report)
    }

    /// Removes from `t` a rewrap journal this device refuses and that is not in flight any more (refused
    /// for longer than `Vault.inFlightJournalWindow` since this device first saw it, or not a change's
    /// step 1 at all): a claim or journal a finished, abandoned or crashed change left there (review
    /// finding 6). Only that version (`If-Match`), and never this device's own claim (`own`). Any device
    /// may do it: such a journal binds nothing and gives no secret.
    func removeStaleJournal(_ t: KeyChangeTarget, vault: Vault, now: Date, own: Data?) -> Bool {
        guard let (there, etag) = try? t.remote.read([Vault.journalName], maxBytes: BoundedRead.maxManifestBytes),
              there != own, let etag, SyncEngine.isStrong(etag) else { return false }
        let manifest = (try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes).data)
        guard let manifest, case .refused? = Vault.incomingJournalProblem(there, local: nil, manifest: manifest, vault: vault)
        else { return false }
        if Vault.incomingJournalMayBeInFlight(there, manifest: manifest, vault: vault) {
            let state = (try? SyncState.load(t.stateURL)) ?? nil
            guard let seen = state?.inFlightJournal, seen.hash == FileDigest.sha256(there),
                  now.timeIntervalSince(seen.firstSeen) >= Vault.inFlightJournalWindow else { return false }
        }
        return (try? t.remote.delete([Vault.journalName], ifETag: etag)) == true
    }

    /// C5 on one target, from where it stopped.
    func propagate(_ t: KeyChangeTarget, vault: inout Vault, options: SyncOptions,
                   faults: KeyChangeFaults) throws -> KeyChangePropagation {
        guard var ledger = try load().change else { return KeyChangePropagation() }
        var out = KeyChangePropagation(step: ledger.steps[t.id], conflict: ledger.conflicts[t.id])
        // A later change built on this one is on the target while this one could not finish locally
        // (a file it cannot rewrap keeps its journal): that change carries it; this device takes it.
        if let step2 = ledger.step2, ledger.step4 == nil,
           let (there, _) = try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes),
           !Vault.sameList(there, step2), !replaces(there, ledger, vault),
           Vault.incomingManifestProblem(there, local: step2, vault: vault) == nil {
            takeBack(targets, journal: ledger.journal)
            try update { $0.change = nil }
            return out
        }
        // Not finished here yet: (a) and (b) go on with the step-2 vault.json; (c) waits for step 4.
        guard let step2 = ledger.step2 else { return out }
        let step4 = ledger.step4 ?? step2
        if out.conflict != nil {
            // Looked at again: the other change may have given way there (the other device kept this one).
            guard let (there, _) = try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes),
                  Vault.sameList(there, step2) || replaces(there, ledger, vault) else { return out }
            if let (j, _) = try? t.remote.read([Vault.journalName], maxBytes: BoundedRead.maxManifestBytes), j != ledger.journal {
                // Another journal: a change in flight keeps the conflict; a stale one nothing binds (left by a
                // finished change, uploaded again by a device that held it) gives way to this change's claim.
                guard case .claimed = try claim(t, journal: ledger.journal, vault: vault, now: options.now) else { return out }
            }
            ledger.conflicts[t.id] = nil
            out.conflict = nil
            try update { $0.change = ledger }
        }
        func done(_ step: KeyChangeStep) throws {
            ledger.steps[t.id] = step
            out.step = step
            try update { $0.change = ledger }
            if faults.afterStep[t.id] == step { throw KeyChangeError.interrupted }
        }
        func conflict(_ why: String) throws -> KeyChangePropagation {
            ledger.conflicts[t.id] = why
            out.conflict = why
            try update { $0.change = ledger }
            return out
        }
        let journalPath = [Vault.journalName], manifestPath = [Vault.manifestName]
        if ledger.steps[t.id] == nil {
            switch try claim(t, journal: ledger.journal, vault: vault, now: options.now) {
            case .claimed: try done(.claimed)
            case .taken: return try conflict("another device's key change is in progress there")
            }
        }
        if ledger.steps[t.id]! < .manifest {
            let current = try? t.remote.read(manifestPath, maxBytes: BoundedRead.maxManifestBytes)
            if let (there, etag) = current {
                if there == step2 || there == step4 || Vault.sameList(there, step2) {
                    // There already.
                } else if replaces(there, ledger, vault), let etag, SyncEngine.isStrong(etag) {
                    guard try t.remote.write(manifestPath, .data(step2), condition: .replace(etag: etag)) else {
                        return out   // it moved meanwhile: next time
                    }
                } else {
                    return try conflict("the target holds another device list (two key changes met, design §6.2 F7)")
                }
            } else {
                _ = try t.remote.write(manifestPath, .data(step2), condition: .create)
            }
            // The journal is there from C1; make sure, never over another one.
            if let (j, _) = try? t.remote.read(journalPath, maxBytes: BoundedRead.maxManifestBytes) {
                guard j == ledger.journal else { return try conflict("the target holds another change's journal") }
            } else {
                _ = try t.remote.write(journalPath, .data(ledger.journal), condition: .create)
            }
            try done(.manifest)
        }
        // The target may have moved on since (a): another device's later change made on top of this one;
        // or back (its vault.json put back, a hostile target): then (a) is done again next time.
        if ledger.steps[t.id]! < .journalRemoved,
           let (there, _) = try? t.remote.read(manifestPath, maxBytes: BoundedRead.maxManifestBytes),
           !Vault.sameList(there, step2) {
            if replaces(there, ledger, vault) {
                ledger.steps[t.id] = .claimed
                try update { $0.change = ledger }
                return out
            }
            let local = try? BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                                  maxBytes: BoundedRead.maxManifestBytes)
            if Vault.incomingManifestProblem(there, local: local, vault: vault) == nil {
                // This device would take it: the later change carries this one; its own work is over.
                takeBack(targets, journal: ledger.journal)
                try update { $0.change = nil }
                return out
            }
            return try conflict("the target holds another device list (two key changes met, design §6.2 F7)")
        }
        if ledger.steps[t.id]! < .files {
            var o = options
            o.keyring = keyring
            o.rewrapReplace = true
            o.holdMutableFiles = true
            let report = try SyncEngine(directory: folder, vault: vault, remote: t.remote, stateURL: t.stateURL, options: o).run()
            out.report = report
            guard report.keyChange?.settled == true else { return out }
            try done(.files)
        }
        if ledger.steps[t.id]! < .finished, ledger.step4 == nil { return out }
        if ledger.steps[t.id]! < .finished {
            let (there, etag) = try t.remote.read(manifestPath, maxBytes: BoundedRead.maxManifestBytes)
            if there != step4 {
                guard Vault.sameList(there, step4), let etag, SyncEngine.isStrong(etag) else {
                    return try conflict("the target holds another device list (two key changes met, design §6.2 F7)")
                }
                guard try t.remote.write(manifestPath, .data(step4), condition: .replace(etag: etag)) else { return out }
            }
            try done(.finished)
        }
        if ledger.steps[t.id]! < .journalRemoved {
            if let (j, etag) = try? t.remote.read(journalPath, maxBytes: BoundedRead.maxManifestBytes), j == ledger.journal {
                guard try t.remote.delete(journalPath, ifETag: etag.flatMap { SyncEngine.isStrong($0) ? $0 : nil }) else { return out }
            }
            try done(.journalRemoved)
        }
        if targets.allSatisfy({ ledger.steps[$0.id] == .journalRemoved }) {
            try update { $0.change = nil }
        }
        return out
    }

    /// True when `there` is the list the change started from, or an older one under the same secret
    /// (a list only grows under one secret): what the change replaces.
    /// True when this change replaces the list `there` on a target: the list it started from, an older
    /// one, or one that only added keys under the secret this change rotates away from (another
    /// device's concurrent addition: a rotation is never undone for it; the addition must be redone,
    /// and until then its key opens nothing written after the rotation).
    func replaces(_ there: Data, _ ledger: KeyChangeLedger, _ vault: Vault) -> Bool {
        if isBaseOrOlder(there, ledger.base, vault) { return true }
        guard let step2 = ledger.step2, let a = vault.secret(ofManifest: there), let b = vault.secret(ofManifest: ledger.base),
              let c = vault.secret(ofManifest: step2) else { return false }
        return a == b && c != b
    }

    /// Also a list under a secret this device replaced before (its keyring says so): a target that
    /// missed earlier changes.
    func isBaseOrOlder(_ there: Data, _ base: Data, _ vault: Vault) -> Bool {
        if Vault.sameList(there, base) { return true }
        guard let a = vault.secret(ofManifest: there) else { return false }
        if let entry = ((try? keyring.load(vaultId: vault.vaultId)) ?? nil)?.entry(for: a), entry.replaced != nil,
           let b = vault.secret(ofManifest: base), a != b {
            return true
        }
        guard let b = vault.secret(ofManifest: base), a == b,
              let x = try? VaultManifest.decode(there), let y = try? VaultManifest.decode(base) else { return false }
        return Set(x.recipients.map(\.key)).isSubset(of: Set(y.recipients.map(\.key)))
    }

    // MARK: F7

    /// "Keep this change" (design §6.2 F7), the counterpart of `adoptOtherChange`: puts this device's
    /// `vault.json` on `target` over a list under a secret this device rotated away from (another
    /// device's addition made concurrently with this device's rotation, or an older list). A rotation
    /// is never undone for an addition; the other device redoes its addition on top. Only that version
    /// is replaced (`If-Match`). Returns false when the target holds anything else.
    @discardableResult
    public func keepThisList(on target: String, vault: Vault) throws -> Bool {
        guard let t = targets.first(where: { $0.id == target }) else { throw SyncError.io("no target \(target)") }
        let (there, etag) = try t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes)
        let local = try BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                             maxBytes: BoundedRead.maxManifestBytes)
        guard let theirs = vault.secret(ofManifest: there), theirs != vault.currentSecret,
              ((try? keyring.load(vaultId: vault.vaultId)) ?? nil)?.entry(for: theirs)?.replaced != nil,
              let etag, SyncEngine.isStrong(etag),
              try t.remote.write([Vault.manifestName], .data(local), condition: .replace(etag: etag)) else { return false }
        if var state = (try? SyncState.load(t.stateURL)) ?? nil {
            state.mutable[Vault.manifestName] = .init(hash: FileDigest.sha256(local), stamp: nil)
            try? state.save(t.stateURL)
        }
        return true
    }

    /// "Keep the other change" (design §6.2 F7): takes the device list of
    /// another device's concurrent change from `target`, rewraps every local
    /// file to it from the keyring, takes this device's claims back and
    /// drops its own change's propagation. The caller then redoes its change.
    ///
    /// - Parameter confirmed: the user checked the target's list and confirms it, for a device that
    ///   missed two or more rotations (format.md §2.1): no link from a secret it held is required.
    ///
    /// - Returns: the keys this device listed that the kept change does not. Under the same secret
    ///   (two additions met) they could still open every file, which no stanza count can tell: the
    ///   caller redoes its change (adds them again), or removes them for real (which rotates).
    @discardableResult
    public func adoptOtherChange(from target: String, vault: inout Vault, now: Date = Date(),
                                 confirmed: Bool = false) throws -> [String] {
        guard let t = targets.first(where: { $0.id == target }) else { throw SyncError.io("no target \(target)") }
        let (other, _) = try t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes)
        let ownKeys = vault.recipients.map(\.key)
        let ownSecret = vault.currentSecret
        try vault.adoptConcurrentChange(other, keyring: keyring, now: now, confirmed: confirmed)
        if let ledger = try load().change {
            takeBack(targets, journal: ledger.journal)
            // Targets this change reached hold its vault.json: the adopted one replaces it there.
            for t in targets {
                guard let (there, etag) = try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes),
                      let s2 = ledger.step2, Vault.sameList(there, s2), let etag, SyncEngine.isStrong(etag) else { continue }
                _ = try? t.remote.write([Vault.manifestName], .data(other), condition: .replace(etag: etag))
            }
        }
        try update { $0.change = nil }
        // The adopted vault.json is this device's own now: each pair whose target holds it takes later
        // versions of it by the usual checks instead of seeing a change on both sides.
        for t in targets {
            guard (try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes).data) == other,
                  var state = (try? SyncState.load(t.stateURL)) ?? nil else { continue }
            state.mutable[Vault.manifestName] = .init(hash: FileDigest.sha256(other), stamp: nil)
            try? state.save(t.stateURL)
        }
        vault = try vault.reopened()
        let kept = Set(vault.recipients.map(\.key))
        let dropped = ownKeys.filter { !kept.contains($0) }
        if !dropped.isEmpty, let ownSecret, ownSecret == vault.currentSecret {
            // Same secret: the dropped keys still open every file (stanza counts cannot tell) and hold the
            // secret. The rotation is owed and blocks other changes; `sync(target:)` makes it (review 3).
            try update { $0.rotationOwed = dropped }
        }
        return dropped
    }
}
