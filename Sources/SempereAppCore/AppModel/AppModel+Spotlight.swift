import Foundation
import Sempere

// Opt-in Spotlight indexing and opening a note from a link (docs/design/1.3-spotlight.md §3.1 to §3.5). What is
// donated is `SpotlightPlanner` (Sempere, also `sempere spotlight plan`); the Core Spotlight calls are the app's
// `SpotlightIndexing`. The index is the operating system's, outside the vault's encryption, so everything here is
// off by default, per vault and per device, and every removal in §3.4 is driven by an event the app sees.

/// The keys a vault's index depends on: its epoch and the devices listed (a removal or a new epoch is a key change).
struct SpotlightKeys: Equatable {
    var epoch: Int
    var devices: Set<String>

    init(_ vault: Vault) {
        epoch = vault.manifest.epoch
        devices = Set(vault.devices.compactMap(\.id))
    }

    /// The change after `old` is one that distrusts older copies: a new epoch, or a device gone.
    func isKeyChange(from old: SpotlightKeys) -> Bool { epoch != old.epoch || !old.devices.isSubset(of: devices) }
}

/// The model's Spotlight bookkeeping: what this session donated, and the pass in flight.
@MainActor
final class SpotlightRuntime {
    /// Fingerprints of what this session donated, by item id (`SpotlightPlanner.diff`).
    var fingerprints: [String: Int] = [:]
    /// The first pass after an unlock removes the vault's items first, so notes deleted elsewhere while the vault was
    /// closed do not linger until they expire, then donates everything again (which also renews the expiry).
    var needsFull = true
    var task: Task<Void, Never>?
    var running = false {
        didSet { if !running { let waiting = idleWaiters; idleWaiters = []; for w in waiting { w.resume() } } }
    }
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var again = false
    /// A pass was wanted while the app was not active (`.complete` forbids index writes while the device is locked).
    var deferred = false
    /// Pause after a change before the pass runs.
    var debounce: Duration = .seconds(2)

    /// Returns once no pass is in flight (at once when none is): a removal waits for it, so an upsert batch the pass
    /// had already sent cannot land after the removal.
    func untilIdle() async {
        guard running else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func reset() {
        task?.cancel()
        task = nil
        fingerprints = [:]
        needsFull = true
        again = false
        deferred = false
    }
}

extension AppModelCore {
    // MARK: - The switch

    /// Whether the switch can be on for the open vault (§3.1).
    public var spotlightEligibility: SpotlightEligibility {
        guard phase == .unlocked, let vault else { return .notUnlocked }
        #if DEBUG
        if vaultURL?.lastPathComponent == DemoVault.folderName { return .demo }
        #endif
        if unlistedNotice != nil { return .removed }
        if vault.isRecoveryOpen || unlockKeys.device == nil { return .noDeviceKeys }
        if listProblem != nil { return .listNotTrusted }
        return .eligible
    }

    /// Sets the open vault's Spotlight switches (the app asks for the owner's confirmation first). Turning it off
    /// removes the vault's items; turning Include Note Text off replaces them without text; turning it on donates.
    public func setSpotlight(_ mode: SpotlightMode) async {
        guard let vault, phase == .unlocked else { return }
        if mode.isOn, spotlightEligibility != .eligible { return }
        let id = vault.vaultId
        guard spotlight.mode(for: id) != mode else { return }
        spotlight.record(mode, for: id)
        spotlightMode = mode
        spotlightNotice = nil
        spotlightRuntime.task?.cancel()
        if mode == .off {
            spotlightRuntime.reset()
            await spotlightRuntime.untilIdle()
            // Turned back on while the pass finished: its re-donation stands, and removing now would empty an index
            // the switch says is on (with fingerprints claiming it is full).
            guard spotlight.mode(for: id) == .off else { return }
            await spotlight.removeDomain(id)
            await spotlight.clearIndexIfNoneOn()
        } else {
            // A first donation replaces nothing; text switched off or on changes the fingerprints, so the pass upserts.
            await runSpotlightPass()
        }
    }

    public func dismissSpotlightNotice() { spotlightNotice = nil }

    /// Turns the switch off for a reason the user did not choose, with a notice (§3.4: this device removed, or the
    /// list stopped checking).
    func forceSpotlightOff(_ notice: SpotlightNotice) {
        guard let id = vault?.vaultId, spotlight.mode(for: id).isOn else { return }
        spotlight.record(.off, for: id)
        spotlightMode = .off
        spotlightNotice = notice
        spotlightRuntime.reset()
        let runtime = spotlightRuntime
        Task {
            await runtime.untilIdle()
            guard spotlight.mode(for: id) == .off else { return }   // turned back on meanwhile: keep its donation
            await spotlight.removeDomain(id)
            await spotlight.clearIndexIfNoneOn()
        }
    }

    // MARK: - Hooks (the lifecycle of §3.4)

    /// Every unlock: the switches of this vault are read, failed removals are retried, and the first pass is a full one.
    func spotlightUnlocked() {
        guard let id = vault?.vaultId else { return }
        spotlightRuntime.reset()
        spotlightMode = spotlight.mode(for: id)
        Task { await spotlight.retryPending() }
        spotlightCheckEligibility()
    }

    /// The open vault's list is in: the first full pass, and a link waiting for it.
    func spotlightListLoaded() {
        if spotlightMode.isOn { scheduleSpotlightPass(after: .zero) }
        resolvePendingNoteLink()
    }

    /// The model's notes changed: an incremental pass follows (debounced).
    func spotlightNotesChanged() {
        guard spotlightMode.isOn, listLoaded else { return }
        scheduleSpotlightPass(after: spotlightRuntime.debounce)
    }

    /// The vault closed: nothing is removed (the items stay while the switch is on and expire after 30 days).
    func spotlightClosed() {
        spotlightRuntime.reset()
        spotlightMode = .off
    }

    /// The app became active: a pass that waited for it runs.
    func spotlightBecameActive() {
        guard spotlightRuntime.deferred, spotlightMode.isOn else { return }
        spotlightRuntime.deferred = false
        scheduleSpotlightPass(after: .zero)
    }

    /// The vault was opened again after `vault.json` changed: a key change removes the vault's items and donates
    /// them again only if this device is still listed, unlocked and the setting is on (§3.4).
    func spotlightVaultReopened(before: SpotlightKeys?) {
        guard let vault else { return }
        spotlightCheckEligibility()
        guard let before, spotlightMode.isOn, SpotlightKeys(vault).isKeyChange(from: before) else { return }
        let id = vault.vaultId
        spotlightRuntime.reset()
        Task {
            guard await spotlight.removeDomain(id) else { return }
            spotlightRuntime.needsFull = false
            if spotlightMode.isOn, spotlightEligibility == .eligible { await runSpotlightPass() }
        }
    }

    /// Turns the switch off when the vault stopped being eligible for it.
    func spotlightCheckEligibility() {
        guard spotlightMode.isOn else { return }
        switch spotlightEligibility {
        case .removed: forceSpotlightOff(.deviceRemoved)
        case .listNotTrusted: forceSpotlightOff(.listNotTrusted)
        case .noDeviceKeys, .demo: forceSpotlightOff(.unavailable)
        case .eligible, .notUnlocked: break
        }
    }

    // MARK: - Passes

    func scheduleSpotlightPass(after delay: Duration) {
        let runtime = spotlightRuntime
        runtime.task?.cancel()
        let gen = generation
        runtime.task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            await self.runSpotlightPass()
        }
    }

    /// One pass: plans the vault, compares it with what was donated, and sends the difference in batches of 200.
    /// Only while the app is active and the vault unlocked and listed; one at a time.
    func runSpotlightPass() async {
        let runtime = spotlightRuntime
        guard spotlightMode.isOn, listLoaded, phase == .unlocked, spotlightEligibility == .eligible else { return }
        guard services.lifecycle.isActive else { runtime.deferred = true; return }
        if runtime.running { runtime.again = true; return }
        runtime.running = true
        defer { runtime.running = false }
        repeat {
            runtime.again = false
            await spotlightOnePass()
        } while runtime.again && spotlightMode.isOn
    }

    /// Checked immediately before every index write: a pass that resumes after the switch changed sends nothing.
    private func canSend(_ gen: Int, _ mode: SpotlightMode) -> Bool {
        spotlightMode == mode && mode.isOn && gen == generation
    }

    private func spotlightOnePass() async {
        guard let vault, spotlightMode.isOn else { return }
        let gen = generation
        let id = vault.vaultId
        let runtime = spotlightRuntime
        let mode = spotlightMode
        let name = spotlight.vaultsOn.count >= 2 ? vaultURL?.deletingPathExtension().lastPathComponent : nil
        let options = SpotlightOptions(includeText: mode.includesText, vaultName: name, untitled: spotlightUntitled,
                                       dateText: spotlightDateText)
        let snapshot = notes
        let waiting = pendingNoteIDs
        // A voice note with no title of its own is donated under the title the list shows for it.
        let shownTitles = Dictionary(snapshot.map { ($0.id, displayTitle($0)) }, uniquingKeysWith: { a, _ in a })
        // Transcripts are blobs: read only with Include Note Text, and only when search may use them (§3.2).
        var transcripts: [UUID: [String]] = [:]
        if mode.includesText, searchTranscripts, let reader = transcriptReader() {
            for note in snapshot where !note.deleted && !waiting.contains(note.id) && !note.transcribed.isEmpty {
                for recording in note.transcribed {
                    var transcript = transcriptCache.transcript(for: recording.blob.sha256)
                    if transcript == nil {
                        transcript = await reader.read(ref: recording.blob, recording: recording.recording, note: note.id)
                        if let fresh = transcript { transcriptCache.store(fresh, for: recording.blob.sha256, bytes: Int(recording.blob.size)) }
                    }
                    if let transcript { transcripts[note.id, default: []].append(transcript.spotlightText) }
                }
            }
        }
        let plan = await Task.detached(priority: .utility) {
            SpotlightPlanner.plan(vaultId: id, notes: snapshot, options: options, transcripts: transcripts, notDownloaded: waiting,
                                  shownTitles: shownTitles)
        }.value
        guard canSend(gen, mode) else { return }
        spotlightOmitted = plan.omitted
        if runtime.needsFull {
            guard await spotlight.removeDomain(id) else { return }
            guard gen == generation else { return }
            runtime.fingerprints = [:]
            runtime.needsFull = false
        }
        let change = SpotlightPlanner.diff(old: runtime.fingerprints, new: plan.items)
        do {
            for batch in stride(from: 0, to: change.deletes.count, by: SpotlightPlanner.batchSize) {
                let ids = Array(change.deletes[batch..<min(batch + SpotlightPlanner.batchSize, change.deletes.count)])
                guard canSend(gen, mode) else { return }
                try await spotlight.index.delete(ids: ids)
                guard gen == generation else { return }
                for id in ids { runtime.fingerprints[id] = nil }
            }
            for batch in stride(from: 0, to: change.upserts.count, by: SpotlightPlanner.batchSize) {
                let items = Array(change.upserts[batch..<min(batch + SpotlightPlanner.batchSize, change.upserts.count)])
                guard canSend(gen, mode) else { return }
                try await spotlight.index.index(items)
                guard gen == generation, spotlightMode == mode else { return }
                for item in items { runtime.fingerprints[item.id] = item.fingerprint }
            }
        } catch {
            // The next change or the next launch tries again; nothing is claimed as donated that was not.
            let failure = error as NSError
            services.perf.event("spotlight.pass", "failed \(failure.domain) \(failure.code)")
        }
    }

    // MARK: - Opening a note from a link (§3.5)

    /// Opens the note `link` names, in this window. A vault not open, unlocked or listed yet keeps the link
    /// (`pendingNoteLink`) and the caller opens the vault (`openNoteLink(_:library:)`); a note that is not here says so
    /// and removes the stale Spotlight item.
    @discardableResult
    public func open(_ link: NoteLink) -> NoteLinkOutcome {
        guard let vault, phase == .unlocked, vault.vaultId == link.vaultId else {
            holdNoteLink(link)
            return .needsVault
        }
        guard listLoaded else {
            holdNoteLink(link)
            return .waiting
        }
        pendingNoteLink = nil
        guard notes.contains(where: { $0.id == link.noteId && !$0.deleted }) else {
            reportMissing(link)
            return .gone
        }
        pendingJump = link.page.map { PageJump(note: link.noteId, page: $0) }
        selectedNoteID = link.noteId
        applyPendingJump()
        return .opened
    }

    private func holdNoteLink(_ link: NoteLink) {
        pendingNoteLink = link
        pendingNoteLinkSince = Date()
    }

    private func reportMissing(_ link: NoteLink) {
        pendingNoteLink = nil
        noteLinkProblem = .notOnThisDevice
        let ids = [link.spotlightIdentifier]
        let index = spotlight.index
        Task { try? await index.delete(ids: ids) }
    }

    /// Follows the held link once its vault is open and listed. A link older than five minutes (its unlock was
    /// cancelled) is dropped.
    func resolvePendingNoteLink() {
        guard let link = pendingNoteLink else { return }
        guard Date().timeIntervalSince(pendingNoteLinkSince) < 300 else { pendingNoteLink = nil; return }
        guard vault?.vaultId == link.vaultId, phase == .unlocked, listLoaded else { return }
        open(link)
    }

    /// `open(_:)`, and when the vault is another one of this device's, opens it first (a store vault of this
    /// device's library opens and unlocks with this device's keys; a locked one shows its unlock screen and the
    /// link follows). A vault this device does not have is reported like a missing note.
    public func openNoteLink(_ link: NoteLink, library: VaultLibrary) async {
        guard open(link) == .needsVault else { return }
        if vault?.vaultId == link.vaultId { return }   // locked: the unlock screen shows, the link follows it
        guard let entry = library.storedVaults.first(where: { $0.vaultId == link.vaultId }) else {
            reportMissing(link)
            return
        }
        do {
            try await openStored(entry, library: library)
        } catch is CancellationError {
        } catch {
            pendingNoteLink = nil
            alert = .error(error)
        }
    }

    /// Drops a held link (the user cancelled the unlock).
    public func discardPendingNoteLink() { pendingNoteLink = nil }
}
