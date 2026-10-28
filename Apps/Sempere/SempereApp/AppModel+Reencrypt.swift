import Age
import Foundation
import Sempere
import SempereSync

/// Where a re-encryption stands, for the progress sheet (key-hierarchy design §7.2 "Progress").
struct ReencryptProgress: Equatable, Sendable {
    /// This device's files (derived from them, never stored); nil when they could not be read after the step (the sheet
    /// keeps what it showed and reads again).
    var status: ReencryptStatus?
    /// Each target as its last confirmation left it (none before one ran).
    var targets: [TargetLine] = []
    /// The last step's problems (files the pass could not do, set-aside files), for the sheet.
    var problems: [String] = []
    /// The finish happened in the last step.
    var finished = false

    struct TargetLine: Equatable, Sendable, Identifiable {
        var name: String
        var reached: Bool
        var confirmed: Bool
        var files: Int
        var current: Int
        var id: String { name }
        /// 0…1 of the target's files under the new keys.
        var fraction: Double { files == 0 ? (confirmed ? 1 : 0) : Double(current) / Double(files) }
    }
}

extension AppModel {
    /// The open vault's re-encryption status (off the main actor).
    func reencryptStatus() async throws -> ReencryptStatus {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        return try await offMain { try vault.reencryptStatus() }
    }

    /// Re-encrypt everything, the start (design §7.1 steps 1–4; on home, after device-owner authentication and the
    /// device review): the targets run first (bounded), the journal is made and claims every target the open vault
    /// syncs with, then the `reencrypt` epoch is written (a new vault key and `newKit`). A refused claim releases the
    /// claims made and changes nothing. The progress sheet then advances it (`advanceReencryption`).
    func startReencryption(_ newKit: MLKEM768X25519Identity, keep: Set<String>, remove: Set<String>,
                           passphrase: String?) async throws -> DeviceChangeOutcome {
        let (targets, close) = try await openReencryptTargets(requireAll: true)
        defer { close() }
        let claimsURL = vault.map(\.vaultId).map { ReencryptCoordinator.claimSightingsURL(store: syncStore, vaultId: $0) }
        return try await performDeviceChange { v in
            // A start an earlier launch did not carry to its epoch (killed between the claim and the epoch): its local
            // journal and its claims go first, as the CLI's --resume does, or they would hold this start off for a
            // day (review of #89, S6). On the fresh value, judged against the disk under the write lock (R1).
            if let leftover = try v.abandonReencryptionStart() { ReencryptCoordinator.release(leftover, on: targets) }
            let prep = try v.prepareReencryption(newKit, keep: keep, remove: remove, passphrase: passphrase)
            var seen = claimsURL.map(ReencryptCoordinator.loadClaimSightings) ?? [:]
            let claims = ReencryptCoordinator.claim(prep.journalFile, vault: v, on: targets, seen: &seen)
            if let claimsURL { ReencryptCoordinator.saveClaimSightings(seen, to: claimsURL) }
            let refused = claims.filter { !$0.value.isClaimed }
            guard refused.isEmpty else {
                ReencryptCoordinator.release(prep.journalFile, on: targets)
                _ = try? v.abandonReencryptionStart()
                let why = refused.sorted { $0.key < $1.key }.map { name, outcome -> String in
                    switch outcome {
                    case .refused(let s), .unreachable(let s): return "\(name): \(s)"
                    case .claimed: return name
                    }
                }
                throw VaultError.epochChangeRefused("the re-encryption could not claim every sync target (\(why.joined(separator: "; ")))")
            }
            return try v.beginReencryption(prep)
        }
    }

    /// Stops the step going (between files of a confirmation, and before the next run or confirmation); what it did
    /// stays done, and the next Continue goes on from there.
    func cancelReencryptionStep() {
        reencryptCancel?.cancel()
    }

    /// One step of a pending re-encryption (design §7.1 steps 5–7), as `ReencryptCoordinator.advance` makes it in the
    /// CLI: with the editors closed, the pass over this device's files, a run of every target, each target confirmed,
    /// and once every one is, the finish and a run of every target again. The vault is opened again after. Only
    /// home; a step that cannot finish (a target unreachable, a file to wait for) leaves it for the next. One at a time
    /// (`isAdvancingReencryption`), cancellable (`cancelReencryptionStep`, throws `CancellationError`); the confirm
    /// memo persists beside the claim sightings and is seeded from the targets' sync states, so no step reads again
    /// what an earlier one found current (review of #89, S7, S8; offline audit P17).
    func advanceReencryption() async throws -> ReencryptProgress {
        guard phase == .unlocked, let before = vault else { throw KeyError.notUnlocked }
        try requireWritableVault()
        guard before.isHome else { throw VaultError.notHome("only the home device re-encrypts the vault") }
        guard !isAdvancingReencryption else { throw VaultError.epochChangeRefused("a re-encryption step is going already") }
        isAdvancingReencryption = true
        let cancel = SyncRunCancel()
        reencryptCancel = cancel
        defer { isAdvancingReencryption = false; reencryptCancel = nil }
        func checkCancelled() throws { if cancel.isSet { throw CancellationError() } }
        let gen = generation
        let (targets, close) = try await openReencryptTargets(requireAll: false)
        defer { close() }
        try checkCancelled()
        isChangingKeys = true
        defer { isChangingKeys = false }
        await editGate.acquire()
        defer { editGate.release() }
        let shown = editor?.noteID
        let windows = Array(windowEditors.keys)
        try? await openEditor(for: nil)
        await closeWindowEditors()
        guard generation == gen, let start = vault else { throw KeyError.vaultChanged }
        let store = syncStore, vaultId = start.vaultId
        let memoURL = ReencryptCoordinator.confirmMemoURL(store: store, vaultId: vaultId)
        let stateURLs = Dictionary(syncSessions.map { ($0.targetName, store.targets.stateURL($0.locationID, of: vaultId)) },
                                   uniquingKeysWith: { a, _ in a })
        var problems: [String] = []
        var lines: [ReencryptProgress.TargetLine] = []
        var finished = false
        do {
            // The pass (design §7.1 step 5).
            let pass = try await offMain { try start.reencryptPass() }
            problems += pass.problems.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            problems += pass.left.sorted { $0.key < $1.key }.map { "\($0.key): set aside, \($0.value)" }
            try checkCancelled()
            // The runs carry the new copies (step 6).
            isChangingKeys = false
            await runEveryTarget()
            isChangingKeys = true
            try checkCancelled()
            let reached = Set(targets.map(\.name))
            var current = try await offMain { try start.reopened() }
            if pass.remaining == 0, pass.problems.isEmpty, current.isReencryptPending {
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SempereReencrypt-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: scratch) }
                let vaultNow = current
                let confirmed = try await offMain { () -> [ReencryptCoordinator.Confirmation] in
                    let id = vaultNow.reencryptEpoch?.epochId ?? Data()
                    var memo = ReencryptCoordinator.loadConfirmMemo(memoURL, epochId: id)
                    defer { ReencryptCoordinator.saveConfirmMemo(memo, epochId: id, to: memoURL) }
                    let budget = ReencryptCoordinator.Budget(isCancelled: { cancel.isSet })
                    return targets.map { t in
                        var m = memo[t.name] ?? [:]
                        if let url = stateURLs[t.name] { ReencryptCoordinator.seedConfirmMemo(&m, vault: vaultNow, stateURL: url) }
                        let c = ReencryptCoordinator.confirm(vault: vaultNow, target: t, memo: &m, scratch: scratch, budget: budget)
                        memo[t.name] = m
                        return c
                    }
                }
                try checkCancelled()
                lines = confirmed.map {
                    .init(name: $0.target, reached: true, confirmed: $0.confirmed, files: $0.files,
                          current: $0.confirmed ? $0.files : min($0.files, $0.current + $0.replaced.count))
                }
                // Every target the vault syncs with must be confirmed: one not reached waits for the next step.
                if confirmed.allSatisfy(\.confirmed), reached.count == syncSessions.count {
                    current = try await offMain { () throws -> Vault in
                        var v = vaultNow
                        try v.finishReencryption()
                        try? FileManager.default.removeItem(at: memoURL)
                        return v
                    }
                    finished = true
                    // The finished vault is adopted before the runs that carry it, so they run as the vault now is
                    // (not as one whose vault.json changed under it, which only uploads).
                    let finishedVault = current
                    current = try await offMain { try finishedVault.reopened() }
                    guard generation == gen else { throw KeyError.vaultChanged }
                    adoptReopened(current)
                    isChangingKeys = false
                    await runEveryTarget()
                    isChangingKeys = true
                    guard let adopted = vault else { throw KeyError.vaultChanged }
                    current = adopted
                }
            }
            for s in syncSessions where !reached.contains(s.targetName) {
                lines.append(.init(name: s.targetName, reached: false, confirmed: false, files: 0, current: 0))
            }
            guard generation == gen else { throw KeyError.vaultChanged }
            adoptReopened(current)
        } catch {
            if generation == gen {
                // Only when the disk moved under it (as `performDeviceChange` does): a stopped step changed no list.
                let changed = (try? await offMain { Self.manifestChangedOnDisk(start) }) ?? true
                if changed { await reopenUnderSameKeys() }
            }
            isChangingKeys = false
            await reopenEditors(shown: shown, windows: windows)
            throw error
        }
        isChangingKeys = false
        syncSessions.forEach { $0.demand() }
        await reopenEditors(shown: shown, windows: windows)
        // A status that cannot be read after a step that did its work is not a failure (review of #89, N5): nil, and
        // the sheet keeps what it showed (re-check T3: no "0 of 0").
        let status = try? await reencryptStatus()
        return ReencryptProgress(status: status, targets: lines, problems: problems, finished: finished)
    }

    /// One full two-way run of every target of the open vault, one after another (a re-encryption's uploads are
    /// every file, so the runs are not bounded like the pull before a device change).
    private func runEveryTarget() async {
        for session in syncSessions { _ = await session.syncNow() }
    }

    /// The open vault's targets as the sync engine's remotes; `close` ends their access. With `requireAll`, a target
    /// that cannot be reached refuses (design §7.1 step 2: every target reachable at the start).
    func openReencryptTargets(requireAll: Bool) async throws -> (targets: [ReencryptCoordinator.Target], close: @Sendable () -> Void) {
        var targets: [ReencryptCoordinator.Target] = []
        var closers: [@Sendable () -> Void] = []
        for session in syncSessions {
            do {
                guard let open = session.openRemote else { throw SyncTargetProblem.other(String(localized: "This target cannot be opened for re-encryption.")) }
                let (remote, close, syncedBefore) = try await open()
                _ = try await offMain { try remote.list([]) }
                targets.append(.init(name: session.targetName, remote: remote, syncedBefore: syncedBefore))
                closers.append(close)
            } catch where !requireAll {
                continue
            } catch {
                closers.forEach { $0() }
                throw VaultError.epochChangeRefused("“\(session.targetName)” cannot be reached (\(DeviceChangeText.message(error))): every sync target must be, to start")
            }
        }
        let all = closers
        return (targets, { all.forEach { $0() } })
    }
}
