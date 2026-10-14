import Foundation
import os
import Sempere

private let inboxLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "capture")

/// Quick voice notes on the model's side (docs/quick-capture.md): turning
/// them on for the open vault (the capture profile into the Keychain), keeping
/// the profile current after the vault's keys change, and adopting the
/// inbox's captures as notes once the vault is unlocked (format.md §11.3),
/// transcribing on device those that came without a transcript.
extension AppModel {
    /// The stored quick-capture profile, if this device has one. Throws
    /// `QuickCaptureError.profileUnreadable` when one may be stored but cannot
    /// be read now (the Keychain before the first unlock after a restart):
    /// not the same as none.
    func storedQuickCaptureProfile() throws -> StoredCaptureProfile? {
        do { return try quickCapture.storedProfile() } catch QuickCaptureError.notSetUp { return nil }
    }

    /// Quick voice notes on this device, as Settings shows them.
    enum QuickCaptureSetting: Equatable {
        /// No profile is stored: quick voice notes are off.
        case off
        case on(StoredCaptureProfile)
        /// A profile may be stored but cannot be read now
        /// (`QuickCaptureError.profileUnreadable`): neither on nor off.
        case unreadable
    }

    /// `storedQuickCaptureProfile()` with its error as a case: every reader
    /// says which of "off" and "cannot be read" it is, never a nil for both.
    var quickCaptureSetting: QuickCaptureSetting {
        do { return try storedQuickCaptureProfile().map { .on($0) } ?? .off } catch { return .unreadable }
    }

    /// Whether quick voice notes go into the open vault.
    var quickCaptureIsForOpenVault: Bool {
        guard let vault, case .on(let stored) = quickCaptureSetting else { return false }
        return stored.profile.vaultId == vault.vaultId
    }

    /// Whether Settings' switch shows quick voice notes as on: for the open
    /// vault, or with a profile that cannot be read (as far as anyone knows it
    /// is on, and turning it off and on again replaces it, as
    /// `profileUnreadable` suggests). Never "off" for a profile that is there.
    var quickCaptureSwitchIsOn: Bool {
        quickCaptureSetting == .unreadable || quickCaptureIsForOpenVault
    }

    /// The app became active (each window's scene, `RootView`): the widgets'
    /// status is written again (Live Activities may have been switched in
    /// Settings ▸ Sempere meanwhile), voice notes queued while the vault folder
    /// was out of reach move into it, and recordings no seal could finish yet
    /// are sealed (`QuickCapture.sweep`: one the launch could not read before
    /// the first unlock after a restart, or one a failed seal kept). Returns
    /// the sweep (tests wait for it); sweeps never overlap.
    @discardableResult
    func quickCaptureBecameActive() -> Task<Void, Never> {
        quickCapture.publishStatus()
        do { try quickCapture.flushStoredQueue() } catch {
            // They stay queued; unlocking the vault moves them too.
            inboxLog.error("voice notes stay queued: \(String(describing: error), privacy: .public)")
        }
        let capture = quickCapture
        return Task { await capture.sweep() }
    }

    /// Turns quick voice notes on for the open vault: voice notes then go to
    /// its inbox, adopted into `notebook`. Needs the vault unlocked (the
    /// capture key comes from its secret); afterwards capture needs nothing.
    /// Without a `notebook`, voice notes go to "Inbox".
    func enableQuickCapture(notebook: String? = nil, transcribe: Bool = true) throws {
        guard let vault, vault.canRead, let url = vaultURL, phase == .unlocked else { throw ModelError.noVaultOpen }
        try requireWritableVault()
        let clock = try deviceClockForWriting()
        let profile = try vault.captureProfile(device: clock.device,
                                               notebook: notebook ?? CaptureProfile.defaultNotebook)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try quickCapture.store.save(StoredCaptureProfile(profile: profile, vaultName: vaultName ?? "Vault", bookmark: bookmark,
                                                         transcribe: transcribe))
        // The widgets and the control stop showing "Set Up".
        quickCapture.publishStatus()
    }

    /// Turns quick voice notes off on this device (what is in the inbox stays
    /// and is still adopted when the vault is unlocked).
    func disableQuickCapture() throws {
        try quickCapture.store.delete()
        quickCapture.publishStatus()
    }

    /// After an unlock or a key change: the stored profile of this vault gets
    /// the current recipients and this device's capture key (a removed key
    /// rotates both), attributed to the key this device unlocked with
    /// (format.md §11.1, security review 2026-10, C2).
    func refreshQuickCaptureProfile() {
        // Never a list that does not check (format.md §2.1, §11.1): captures are sealed to it.
        let current: StoredCaptureProfile?
        do { current = try storedQuickCaptureProfile() } catch {
            // Left as it is: Settings and a start say it cannot be read; turning it off and on again replaces it.
            inboxLog.error("quick capture profile not refreshed: \(String(describing: error), privacy: .public)")
            return
        }
        guard let vault, vault.canRead, vault.recipientsStatus.allowsWriting, var stored = current,
              stored.profile.vaultId == vault.vaultId, let device = DeviceID(stored.profile.device),
              let here = vaultURL, Self.isProfileFolder(stored.bookmark, here),
              let fresh = try? vault.captureProfile(device: device, notebook: stored.profile.notebook) else { return }
        guard stored.profile.recipients != fresh.recipients || stored.profile.key != fresh.key
              || stored.profile.recipient != fresh.recipient else { return }
        stored.profile.recipients = fresh.recipients
        stored.profile.key = fresh.key
        stored.profile.recipient = fresh.recipient
        // The bookmark is never pointed elsewhere: only the folder the profile was made for is refreshed.
        try? quickCapture.store.save(stored)
    }

    /// Whether the profile's `bookmark` resolves to the open vault's folder
    /// `here` (security review 2026-10 stage 4, S16): a lookalike folder with
    /// the same vault id, opened from outside, must not take over the profile
    /// (its recipients, its key and where voice notes go).
    nonisolated static func isProfileFolder(_ bookmark: Data, _ here: URL) -> Bool {
        var stale = false
        guard let target = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return false }
        func path(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
        return path(target) == path(here)
    }

    /// Starts adopting the inbox (a task the model owns; one at a time).
    /// `close` cancels it; a task of a vault closed meanwhile never clears
    /// the next vault's.
    func startInboxAdoption() {
        guard inboxAdoption == nil else { return }
        let gen = generation
        inboxAdoption = Task { [weak self] in
            await self?.adoptInbox()
            if self?.generation == gen { self?.inboxAdoption = nil }
        }
    }

    /// Adopts every capture in the open vault's inbox (queued captures are
    /// moved in first). Returns how many captures were adopted or updated.
    @discardableResult
    func adoptInbox() async -> Int {
        // A read-only vault (format.md §7.3) adopts nothing: the captures wait in the inbox.
        guard let vault, vault.canRead, phase == .unlocked, !isVaultReadOnly, let url = vaultURL else { return 0 }
        let gen = generation
        let cloud = isCloudVault, hooks = cloudHooks
        quickCapture.flushQueue(into: url, vaultId: vault.vaultId, coordinated: cloud)
        var done = 0
        do {
            // Not `offMain`: an empty inbox (the usual case) does no vault work,
            // so it must not pass the `afterIO` hook that tests use to order
            // the listing's reads.
            let items = try await Task.detached(priority: .utility) { try CloudScan.inboxItems(inVault: url) }.value
            guard !items.isEmpty else { return 0 }
            try ensureCurrent(gen)
            if cloud {
                try await CloudVault.download(items: items.map(\.item), hooks: hooks, stallTimeout: cloudStallTimeout,
                                              pollInterval: cloudPollInterval) { _ in }
            }
            // Cleared first, so a capture that fails below stays reported.
            if gen == generation { inboxProblem = nil }
            var seen = Set<UUID>()
            for id in items.map(\.id) where seen.insert(id).inserted {
                try ensureCurrent(gen)
                if await adoptCapture(id, from: vault) { done += 1 }
            }
        } catch is CancellationError {
        } catch {
            if gen == generation {
                inboxProblem = String(localized: "Voice notes could not be read from the inbox: \(String(describing: error))")
            }
        }
        return done
    }

    /// Adopts one capture: its blobs, then one delta (`CaptureAdoption.ops`),
    /// then the inbox files it consumed are deleted. A capture that does not
    /// verify is left in the inbox and reported.
    private func adoptCapture(_ id: UUID, from vault: Vault) async -> Bool {
        let coordinate = coordinationURL
        let ids = CaptureAdoption.ids(for: id)
        let backoff = inboxBackoff
        do {
            // A file that failed before is not read again until its back-off
            // ends (it is reported below, as `backedOff`).
            let pending = try await offMain {
                try CloudVault.coordinatedRead(coordinate) { try vault.readCapture(id, backoff: backoff) }
            }
            // The note exists once it has a revision (in iCloud Drive, once one
            // is listed, local or not); a folder holding only blobs is still new.
            let url = vault.url, cloud = isCloudVault
            let exists = try await offMain { () throws -> Bool in
                if cloud { return try CloudScan.noteItems(inVault: url, id: ids.note).isEmpty == false }
                return try vault.revisionNames(of: ids.note).isEmpty == false
            }
            // A transcript whose capture has not arrived yet waits, and writes
            // nothing: a blob alone would make a note folder without revisions.
            guard pending.manifest != nil || exists else { return false }
            // Adopted before (maybe on another device): every revision must be
            // local before a delta is written to it.
            if exists { try await downloadNote(ids.note) }
            let clock = try deviceClockForWriting()
            let writer = NoteWriter(vault: vault, noteID: ids.note, clock: clock, nextSeq: 1, coordinated: isCloudVault)
            let prepare = blobWritePreparer(note: ids.note)
            var audioRef: BlobRef?
            var transcriptRef: BlobRef?
            if let audio = pending.audio, let m = pending.manifest {
                try await prepare?(m.audio)
                audioRef = try await writer.addBlob(audio, type: m.audio.type)
            }
            if let content = pending.transcriptContent {
                try await prepare?(BlobRef(content: content, type: BlobRef.transcriptType))
                transcriptRef = try await writer.addBlob(content, type: BlobRef.transcriptType)
            }
            let audio = audioRef, transcript = transcriptRef
            try await commit(ids: [ids.note], creating: exists ? [] : [ids.note]) { vault, clock, cloud, verifier in
                try await NoteWriter.append(to: ids.note, vault: vault, clock: clock, coordinated: cloud,
                                            verify: verifier(ids.note)) { state in
                    CaptureAdoption.ops(pending, audio: audio, transcript: transcript, current: state)
                }
            }
            let after = try? await offMain {
                try CloudVault.coordinatedRead(coordinate) { try vault.reconstruct(noteId: ids.note) }
            }
            let consumed = CaptureAdoption.consumed(pending, after: after)
            if !consumed.isEmpty {
                let inbox = vault.inboxURL
                try? await offMain {
                    try CloudVault.coordinatedWrite(coordinate == nil ? nil : inbox) { vault.removeInboxFiles(consumed) }
                }
            }
            if let r = after?.recordings.first(where: { $0.id == ids.recording }) {
                for e in [editor].compactMap({ $0 }) + Array(windowEditors.values) where e.noteID == ids.note {
                    e.adoptTranscript(r.transcript, for: r.id)
                }
                // Captured without a transcript (no time left, or the model was missing): transcribe now.
                if r.transcript == nil, (try? storedQuickCaptureProfile())?.transcribe ?? TranscriptionPreference.isOn() {
                    Task { await self.transcribeStored(r, note: ids.note, meta: after?.meta) }
                }
            }
            if after?.recordings.isEmpty == false { capturesAdopted += 1 }
            return true
        } catch is CancellationError {
            return false
        } catch {
            let reason = (error as? CaptureError)?.description ?? "\(error)"
            inboxProblem = String(localized: "A voice note could not be added: \(reason)")
            return false
        }
    }

    /// Transcribes a recording already in the vault (from the blob cache).
    func transcribeStored(_ recording: Recording, note: UUID, meta: NoteMeta?) async {
        guard let cache = attachmentCache() else { return }
        do {
            let url = try await cache.acquire(note: note, ref: recording.blob)
            await transcribe(recording, note: note, file: url, meta: meta)
            await cache.release(note: note, ref: recording.blob, discard: true)
        } catch {
            errorMessage = String(localized: "Could not read the voice note to transcribe it: \(String(describing: error))")
        }
    }
}
