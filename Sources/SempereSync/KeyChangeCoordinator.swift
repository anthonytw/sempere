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

    public init(afterClaims: Bool = false, rewrap: RewrapFaults = .none, afterStep: [String: KeyChangeStep] = [:]) {
        self.afterClaims = afterClaims; self.rewrap = rewrap; self.afterStep = afterStep
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

    public var description: String {
        switch self {
        case .anotherChangeInFlight(let t): return "another device's key change is in progress on \(t): try again once it finished"
        case .targetUnreachable(let t, let why): return "\(t) cannot be reached (\(why)); a routine key change needs every target"
        case .targetNotRecentlySynced(let t): return "\(t) has not synced in the last minute: sync it first"
        case .changeInProgress: return "a key change is still propagating from this device"
        case .interrupted: return "interrupted (test)"
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

    func load() -> KeyChangeFile {
        guard let data = try? BoundedRead.contents(of: ledgerURL, maxBytes: 16 << 20) else { return KeyChangeFile() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(KeyChangeFile.self, from: data)) ?? KeyChangeFile()
    }

    func save(_ f: KeyChangeFile) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LocalFS.write(try e.encode(f), to: ledgerURL, replacing: true)
    }

    func update(_ body: (inout KeyChangeFile) throws -> Void) throws {
        var f = load()
        try body(&f)
        try save(f)
    }

    /// True while a change from this device is still propagating.
    public var inProgress: Bool { load().change != nil }

    /// Per target, how far the change got; empty when none is in progress.
    public var steps: [String: KeyChangeStep] { load().change?.steps ?? [:] }

    /// Targets where another change was met (F7).
    public var conflicts: [String: String] { load().change?.conflicts ?? [:] }

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
        var file = load()
        guard file.change == nil else { throw KeyChangeError.changeInProgress }
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
        // C1: claim every target with the journal's exact bytes.
        var claimed: [KeyChangeTarget] = []
        for t in targets {
            do {
                switch try claim(t, journal: prepared.journal, vault: vault, now: now) {
                case .claimed:
                    ledger.steps[t.id] = .claimed
                    claimed.append(t)
                case .taken:
                    takeBack(claimed, journal: prepared.journal)
                    throw KeyChangeError.anotherChangeInFlight(target: t.id)
                }
            } catch let e as KeyChangeError {
                throw e
            } catch {
                // Unreachable: routine refuses unless overridden; compromised claims it when it is back.
                if routine && !overriding.contains(t.id) {
                    takeBack(claimed, journal: prepared.journal)
                    throw KeyChangeError.targetUnreachable(target: t.id, SyncEngine.describe(error))
                }
            }
        }
        file.change = ledger
        try save(file)
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

    /// Deletes this device's own claims (only those versions).
    func takeBack(_ claimed: [KeyChangeTarget], journal: Data) {
        for t in claimed {
            guard let (there, etag) = try? t.remote.read([Vault.journalName], maxBytes: BoundedRead.maxManifestBytes),
                  there == journal else { continue }
            _ = try? t.remote.delete([Vault.journalName], ifETag: etag.flatMap { SyncEngine.isStrong($0) ? $0 : nil })
        }
    }

    /// Records the step-4 `vault.json` once the change finished locally.
    func recordFinished(_ vault: Vault) throws {
        guard !vault.pendingRewrap else { return }
        let bytes = try BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                             maxBytes: BoundedRead.maxManifestBytes)
        try update { f in
            guard f.change != nil else { return }
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
        guard let ledger = load().change else { return false }
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

    // MARK: C5 and runs

    /// One target's run: the change's propagation first (C5), then an
    /// ordinary two-way run with the keyring and rewrap-replace, holding the
    /// mutable files while the propagation there has not reached (c).
    /// A run without errors or conflicts records the target as synced (C0).
    public func sync(target id: String, vault: inout Vault, options: SyncOptions,
                     faults: KeyChangeFaults = KeyChangeFaults()) throws -> (propagation: KeyChangePropagation?, report: SyncReport) {
        guard let t = targets.first(where: { $0.id == id }) else { throw SyncError.io("no target \(id)") }
        var propagation: KeyChangePropagation?
        if vault.canRead, load().change != nil {
            try recover(&vault)
            if load().change != nil { propagation = try propagate(t, vault: &vault, options: options, faults: faults) }
        }
        var o = options
        o.keyring = keyring
        o.rewrapReplace = true
        let pending = load().change.map { ($0.steps[id] ?? .claimed) < .finished || $0.conflicts[id] != nil } ?? false
        o.holdMutableFiles = pending
        let report = try SyncEngine(directory: folder, vault: vault.canRead ? vault : nil, remote: t.remote,
                                    stateURL: t.stateURL, options: o).run()
        if report.errors.isEmpty, report.conflicts.isEmpty, report.rejected.isEmpty {
            try update { $0.lastClean[id] = o.now }
        }
        return (propagation, report)
    }

    /// C5 on one target, from where it stopped.
    func propagate(_ t: KeyChangeTarget, vault: inout Vault, options: SyncOptions,
                   faults: KeyChangeFaults) throws -> KeyChangePropagation {
        guard var ledger = load().change else { return KeyChangePropagation() }
        var out = KeyChangePropagation(step: ledger.steps[t.id], conflict: ledger.conflicts[t.id])
        guard let step2 = ledger.step2, let step4 = ledger.step4 else { return out }
        if out.conflict != nil {
            // Looked at again: the other change may have given way there (the other device kept this one).
            guard let (there, _) = try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes),
                  Vault.sameList(there, step2) || Vault.sameList(there, ledger.base) else { return out }
            if let (j, _) = try? t.remote.read([Vault.journalName], maxBytes: BoundedRead.maxManifestBytes), j != ledger.journal {
                return out
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
                } else if Vault.sameList(there, ledger.base), let etag, SyncEngine.isStrong(etag) {
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

    // MARK: F7

    /// "Keep the other change" (design §6.2 F7): takes the device list of
    /// another device's concurrent change from `target`, rewraps every local
    /// file to it from the keyring, takes this device's claims back and
    /// drops its own change's propagation. The caller then redoes its change.
    public func adoptOtherChange(from target: String, vault: inout Vault, now: Date = Date()) throws {
        guard let t = targets.first(where: { $0.id == target }) else { throw SyncError.io("no target \(target)") }
        let (other, _) = try t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes)
        try vault.adoptConcurrentChange(other, keyring: keyring, now: now)
        if let ledger = load().change {
            takeBack(targets, journal: ledger.journal)
            // Targets this change reached hold its vault.json: the adopted one replaces it there.
            for t in targets {
                guard let (there, etag) = try? t.remote.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes),
                      let s2 = ledger.step2, Vault.sameList(there, s2), let etag, SyncEngine.isStrong(etag) else { continue }
                _ = try? t.remote.write([Vault.manifestName], .data(other), condition: .replace(etag: etag))
            }
        }
        try update { $0.change = nil }
        vault = try vault.reopened()
    }
}
