import Age
import Foundation
import Sempere
import SempereWebDAV

/// Why a WebDAV vault could not be opened or changed.
enum WebDAVVaultError: Error, Equatable, CustomStringConvertible {
    case noSuchLocation
    /// The download stopped before every file arrived (the first problems);
    /// opening it again continues.
    case downloadIncomplete(String)
    /// "Download Again" needs a push that finished without errors first.
    case pushNotClean(String)
    /// Key changes rewrap files in place, which sync never propagates.
    case keyChangesUnavailable
    /// The server's re-download failed; the local copy is unchanged.
    case redownloadFailed(String)
    /// Another vault now lives at a location whose copy holds changes the server never confirmed.
    case replacedWithChanges(Int)

    var description: String {
        switch self {
        case .noSuchLocation:
            return String(localized: "That WebDAV vault is no longer set up on this device. Connect to it again.")
        case .downloadIncomplete(let detail):
            return String(localized: "The vault was not completely downloaded: \(detail)\n\nOpen it again to continue the download.",
                          comment: "The value is the first problems (English)")
        case .pushNotClean(let detail):
            return String(localized: "This device's changes could not all be uploaded first, so the vault was not downloaded again (nothing would be lost, but nothing changed): \(detail)",
                          comment: "The value is the problem (English)")
        case .keyChangesUnavailable:
            return String(localized: "Device keys of a WebDAV vault cannot be changed in the app: the server would keep files a removed key can read. Change them with the sempere command-line tool on a folder copy and upload that to a new server folder.")
        case .redownloadFailed(let detail):
            return String(localized: "The vault could not be downloaded again; this device's copy is unchanged: \(detail)",
                          comment: "The value is the problem (English)")
        case .replacedWithChanges(let n):
            return String(localized: "Another vault is now at this address, and this device has \(n) changes of the vault that was there which were never uploaded. Nothing was changed. To start over, remove that WebDAV vault on the welcome screen first.",
                          comment: "Connect to WebDAV: the folder holds another vault; the count is files not uploaded")
        }
    }
}

/// WebDAV vaults (docs/io.md, "WebDAV vaults in the app"): a local copy in
/// the app's container, opened like any vault folder, and a push-only sync
/// to the server (`WebDAVSession`) that never takes anything from it.
extension AppModel {
    /// True when the open vault is a WebDAV location's local copy.
    var isWebDAVVault: Bool { webdav != nil }

    /// The endpoint of `location`, with its password from the Keychain.
    nonisolated static func endpoint(_ location: WebDAVLocation, passwords: any WebDAVPasswordStore) throws -> WebDAVEndpoint {
        guard let url = URL(string: location.url) else { throw WebDAVError.insecureURL("not a usable URL") }
        let password = location.user == nil ? nil : try passwords.password(for: location.id)
        return WebDAVEndpoint(url: url, user: location.user, password: password, pinnedCertificate: location.pinnedCertificate)
    }

    // MARK: - Connecting

    /// "Test Connection": lists `url` with these credentials (never stored by this).
    func probeWebDAV(url: URL, user: String?, password: String, pin: String?) async -> WebDAVProbe {
        let remote = webdavRemote
        let endpoint = WebDAVEndpoint(url: url, user: user, password: user == nil ? nil : password, pinnedCertificate: pin)
        return await Task.detached(priority: .userInitiated) { remote.check(endpoint) }.value
    }

    /// Sets up the vault `listing` found by the connect sheet (the password
    /// goes to the Keychain only), downloads it and opens it locked. A
    /// location for the same folder and user is reused, never duplicated.
    @discardableResult
    func connectWebDAV(_ listing: WebDAVVaultListing, user: String?, password: String, pin: String?,
                       library: VaultLibrary) async throws -> UUID {
        var location = webdavLocations.location(url: listing.url, user: user)
            ?? WebDAVLocation(id: UUID(), url: listing.url, user: user, vaultId: listing.vaultId, name: listing.name,
                              folderName: WebDAVLocationStore.folderName(for: listing.name))
        if location.vaultId != listing.vaultId {
            // Another vault now lives there: start a new copy rather than mix two vaults. The old copy
            // goes only when it holds nothing the server lacks (else its notes would be lost), after it
            // is closed, and with its Keychain password.
            let old = location.id
            let pending = await unconfirmedWebDAVChanges(old)
            guard pending == 0 else { throw WebDAVVaultError.replacedWithChanges(pending) }
            if webdav?.locationID == old {
                close()
                await closingEditor?.value
            }
            let passwords = webdavPasswords
            try await offMain { try passwords.delete(for: old) }
            try webdavLocations.remove(old)
            library.forgetWebDAV(old)
            location = WebDAVLocation(id: UUID(), url: listing.url, user: user, vaultId: listing.vaultId, name: listing.name,
                                      folderName: WebDAVLocationStore.folderName(for: listing.name))
        }
        location.pinnedCertificate = pin
        location.name = listing.name
        if user != nil {
            let passwords = webdavPasswords, id = location.id, label = "\(location.name) (\(location.host))"
            try await offMain { try passwords.save(password, for: id, label: label) }
        }
        webdavLocations.save(location)
        try await openWebDAV(location.id, library: library)
        return location.id
    }

    /// Changes a location's password and certificate pin (the edit sheet),
    /// then pushes if it is the open vault.
    func updateWebDAVLocation(_ id: UUID, password: String?, pin: String?) async throws {
        guard let location = webdavLocations.location(id) else { throw WebDAVVaultError.noSuchLocation }
        if let password, location.user != nil {
            let passwords = webdavPasswords, label = "\(location.name) (\(location.host))"
            try await offMain { try passwords.save(password, for: id, label: label) }
        }
        webdavLocations.update(id) { $0.pinnedCertificate = pin }
        if webdav?.locationID == id { await webdav?.pushNow() }
    }

    // MARK: - Opening

    /// Opens the local copy of the location `id` and starts its push-only
    /// sync (which waits for the unlock). A copy not usable yet gets its root
    /// files, the server's sealed summaries and its note list first (a
    /// partial copy, format.md §1.2: a few requests, whatever the vault's
    /// size); the notes and attachments then arrive while it is open
    /// (`WebDAVFetcher`, through the iCloud machinery). Works offline once
    /// the copy is usable.
    func openWebDAV(_ id: UUID, library: VaultLibrary) async throws {
        close()
        await stoppingWebDAV[id]?.value   // a push or fetch of this copy still running ends first
        let gen = generation
        guard let location = webdavLocations.location(id) else { throw WebDAVVaultError.noSuchLocation }
        let copy = webdavLocations.copy(of: location)
        if !location.downloaded || !copy.isUsable {
            let remote = webdavRemote, passwords = webdavPasswords
            // Cancel stops it with what arrived kept (`CancellationError`, no alert): opening it again continues.
            let report = try await withWebDAVDownload(name: location.name) { options in
                try remote.downloadMetadata(try Self.endpoint(location, passwords: passwords), into: copy, options: options)
            }
            try ensureCurrent(gen)
            if !report.errors.isEmpty || report.stoppedEarly != nil || !copy.isUsable {
                throw WebDAVVaultError.downloadIncomplete(Self.firstProblems(report))
            }
            webdavLocations.update(id) { $0.downloaded = true }
        }
        let fetcher = copy.isPartial ? makeFetcher(location, copy: copy) : nil
        try await openVault(at: copy.folder, fetcher: fetcher)
        try ensureCurrent(generation)
        startWebDAVSession(location, copy: copy)
        fetcher?.start()
        // The vault's own label (vault.json, format.md §2) names it in the lists, not the server folder.
        let named = await Task.detached(priority: .utility) { copy.label }.value
        if let named, named != location.name { webdavLocations.update(id) { $0.name = named } }
        library.rememberWebDAV(id, name: named ?? location.name)
    }

    // MARK: - Filling a partial copy

    /// Where the open vault's missing files come from, for the download texts:
    /// the server of a partial WebDAV copy, else iCloud Drive.
    var cloudSource: CloudSource { webdavFetcher.map { .server($0.serverName) } ?? .iCloudDrive }

    /// `ModelError.noteNotDownloaded`, naming the server for a WebDAV copy.
    var noteNotDownloadedError: ModelError {
        cloudSource.serverName.map(ModelError.noteNotDownloadedFromServer) ?? .noteNotDownloaded
    }

    /// `UserDefaults` key of "Download Attachments in the Background" (on unless turned off).
    static let webdavFillsBlobsKey = "Sempere.webdavFetchAttachments"

    /// Whether a partial WebDAV copy fetches its attachments in the
    /// background once every note is in (otherwise only when shown or played).
    var webdavFillsBlobs: Bool {
        get { UserDefaults.standard.object(forKey: Self.webdavFillsBlobsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.webdavFillsBlobsKey)
            webdavFetcher?.setFillsBlobs(newValue)
        }
    }

    /// The fetcher of a partial copy: fetches run off the main actor with the
    /// location as stored at that moment (an edited password or pin applies at once).
    private func makeFetcher(_ location: WebDAVLocation, copy: WebDAVLocalCopy) -> WebDAVFetcher {
        let remote = webdavRemote, passwords = webdavPasswords, store = webdavLocations, id = location.id
        return WebDAVFetcher(copy: copy, serverName: location.host, fillsBlobs: webdavFillsBlobs, fetch: { scope, vault in
            let current = await MainActor.run { store.location(id) }
            guard let current else { throw WebDAVVaultError.noSuchLocation }
            return try await Task.detached(priority: .utility) {
                try remote.fetch(try Self.endpoint(current, passwords: passwords), copy: copy, vault: vault, scope: scope)
            }.value
        }, changed: { [weak self] fetcher, notes, complete in
            self?.webdavFetched(fetcher, notes: notes, complete: complete)
        })
    }

    /// A fetch run ended: the sync loop looks at the notes it touched now, so
    /// their rows stop spinning as soon as they are in.
    func webdavFetched(_ fetcher: WebDAVFetcher, notes: Set<UUID>, complete: Bool) {
        guard webdavFetcher === fetcher else { return }
        if !notes.isEmpty { noteFoldersChanged(notes) }
    }

    /// The vault was unlocked: a partial copy's fetches check each file under
    /// the key from now on, and the notes not downloaded yet get their rows
    /// from the server's sealed summaries (opened with the key, format.md §12;
    /// a missing or unreadable file only means they are listed as they arrive).
    func webdavUnlocked() async {
        guard let fetcher = webdavFetcher, let vault, vault.canRead else { return }
        fetcher.setVault(vault)
        let gen = generation
        let url = WebDAVPartialCopy.summariesURL(fetcher.copy.folder)
        let rows = await Task.detached(priority: .userInitiated) { () -> [UUID: NoteSummary] in
            guard let data = try? BoundedRead.contents(of: url, maxBytes: PublishedSummaries.maxFileBytes),
                  let entries = try? vault.openPublishedSummaries(data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, Self.pendingSummary($0.key, $0.value)) })
        }.value
        guard generation == gen else { return }
        publishedRows = rows
    }

    /// The row of a note not downloaded yet, from its published summary. It
    /// is only shown (and searched) until the note arrives and is read.
    nonisolated static func pendingSummary(_ id: UUID, _ e: PublishedSummaries.Entry) -> NoteSummary {
        var s = NoteSummary(id: id, title: e.title, tags: e.tags, notebook: e.notebook, deleted: e.deleted, pages: e.pages,
                            strokes: 0, modified: e.modified, problem: nil)
        s.favorite = e.favorite
        s.created = e.created
        // Page ids are not published; a search hit opens the note (its page is found once it is read).
        s.pageTexts = e.pageTexts.map { PageText(pageId: UUID(), number: $0.page, text: $0.text) }
        return s
    }

    /// The session of the copy just opened (`openVault` closed the last one).
    private func startWebDAVSession(_ location: WebDAVLocation, copy: WebDAVLocalCopy) {
        let remote = webdavRemote, passwords = webdavPasswords, cacheDirectory = summaryCacheDirectory
        let id = location.id
        let store = webdavLocations
        let session = WebDAVSession(
            locationID: id, name: location.name, lastPush: location.lastPush,
            push: { [weak self] in
                // The location as stored now (an edited password or pin applies at once).
                let (current, vault) = await MainActor.run { (store.location(id), self?.vault) }
                guard let current else { throw WebDAVVaultError.noSuchLocation }
                return try await Task.detached(priority: .utility) { () throws -> SyncReport in
                    var options = WebDAVSyncOptions(deviceLabel: "app")
                    options.summaryCacheDirectory = cacheDirectory
                    return try remote.push(try Self.endpoint(current, passwords: passwords), copy: copy,
                                           vault: vault, options: options)
                }.value
            },
            countUnconfirmed: { await Task.detached(priority: .utility) { copy.unconfirmedChanges() }.value })
        session.onSuccess = { [weak store] date in store?.update(id) { $0.lastPush = date } }
        session.tick = webdavTick
        session.schedule.writeDelay = webdavWriteDelay
        webdav = session
        session.start()
    }

    /// Stops the open WebDAV vault's pushes and fetches (`close`). Whatever
    /// run is in progress finishes; nothing replaces or removes the copy
    /// before it has (`stoppingWebDAV`).
    func stopWebDAV() {
        let fetching = webdavFetcher?.stop()
        webdavFetcher = nil
        if let session = webdav {
            let running = session.stop()
            if running != nil || fetching != nil {
                let earlier = stoppingWebDAV[session.locationID]
                stoppingWebDAV[session.locationID] = Task {
                    await earlier?.value
                    _ = await running?.value
                    await fetching?.value
                }
            }
        }
        webdav = nil
    }

    // MARK: - Downloading

    /// Runs a download of a WebDAV vault (`work`, given the options to pass
    /// to the library) off the main actor, with its progress in
    /// `webdavDownload` for the overlay and its Cancel.
    ///
    /// - Throws: `CancellationError` when Cancel was pressed (what arrived is
    ///   kept; a first download continues when the vault is opened again),
    ///   else what `work` throws.
    func withWebDAVDownload<T: Sendable>(name: String,
                                         _ work: @escaping @Sendable (WebDAVSyncOptions) throws -> T) async throws -> T {
        let flag = WebDAVCancelFlag()
        let relay = WebDAVProgressRelay { [weak self] progress in self?.webdavDownload?.progress = progress }
        webdavDownload = WebDAVDownloadStatus(name: name)
        webdavDownloadCancel = flag
        defer {
            relay.close()
            if webdavDownloadCancel === flag {
                webdavDownload = nil
                webdavDownloadCancel = nil
            }
        }
        var options = WebDAVSyncOptions(deviceLabel: "app")
        options.concurrency = webdavConcurrency
        options.progress = { relay.send($0) }
        options.isCancelled = { flag.isSet }
        let runOptions = options   // a `let` for the @Sendable closure (Swift 6)
        let result: T
        do {
            result = try await offMain { try work(runOptions) }
        } catch {
            if flag.isSet { throw CancellationError() }   // a canceled run may also throw `.cancelled`
            throw error
        }
        if flag.isSet { throw CancellationError() }
        return result
    }

    /// The overlay's Cancel: the download stops after the transfers in flight.
    func cancelWebDAVDownload() {
        guard let flag = webdavDownloadCancel else { return }
        flag.cancel()
        webdavDownload?.cancelling = true
    }

    // MARK: - Commands

    /// "Sync Now".
    func webdavSyncNow() async {
        await webdav?.pushNow()
    }

    /// "Download Again": saves and closes the open notes, pushes (and stops
    /// unless that push finished without errors), takes the server's root
    /// files and note list into a new partial copy that replaces this one
    /// (what this copy holds is linked in; the rest, other devices' changes
    /// included, is fetched as it is used), and reopens and unlocks it with
    /// the same keys. The new copy's device list is checked at that unlock
    /// against this device's trust record (format.md §2.1).
    func downloadWebDAVAgain(library: VaultLibrary) async throws {
        guard let session = webdav, phase == .unlocked, let vault,
              let location = webdavLocations.location(session.locationID) else { throw ModelError.noVaultOpen }
        let identities = unlockIdentities
        let copy = webdavLocations.copy(of: location)
        let remote = webdavRemote, passwords = webdavPasswords, cacheDirectory = summaryCacheDirectory
        close()
        await closingEditor?.value   // the last canvas changes are in the copy before the push
        await stoppingWebDAV[location.id]?.value   // and the session's push still running has ended
        do {
            let pushed = try await offMain { () throws -> SyncReport in
                var options = WebDAVSyncOptions(deviceLabel: "app")
                options.summaryCacheDirectory = cacheDirectory
                return try remote.push(try Self.endpoint(location, passwords: passwords), copy: copy, vault: vault,
                                       options: options)
            }
            guard pushed.errors.isEmpty, pushed.stoppedEarly == nil else {
                throw WebDAVVaultError.pushNotClean(Self.firstProblems(pushed))
            }
            // A partial copy: the root files and note list now, the notes as the copy is used (format.md §1.2).
            let result = try await withWebDAVDownload(name: location.name) { options in
                try remote.redownload(try Self.endpoint(location, passwords: passwords), copy: copy, identities: identities,
                                      partial: true, options: options)
            }
            guard result.replaced else { throw WebDAVVaultError.redownloadFailed(Self.firstProblems(result.report)) }
        } catch {
            // The copy is as it was: open it again before reporting.
            try? await openWebDAV(location.id, library: library)
            if phase == .locked { try? await unlock(with: identities) }
            if error is CancellationError || error is WebDAVVaultError { throw error }
            throw WebDAVVaultError.redownloadFailed(WebDAVErrorText.message(error))
        }
        try await openWebDAV(location.id, library: library)
        try await unlock(with: identities)
    }

    /// Forgets a location: closes it if open, deletes its local copy, sync
    /// state and Keychain password, and its recent entry.
    func removeWebDAVLocation(_ id: UUID, library: VaultLibrary) async throws {
        if webdav?.locationID == id {
            close()
            await closingEditor?.value
        }
        await stoppingWebDAV[id]?.value
        let passwords = webdavPasswords
        try await offMain { try passwords.delete(for: id) }
        try webdavLocations.remove(id)
        library.forgetWebDAV(id)
    }

    /// Files of the location's copy the server has not confirmed (the remove
    /// confirmation warns about them).
    func unconfirmedWebDAVChanges(_ id: UUID) async -> Int {
        guard let location = webdavLocations.location(id) else { return 0 }
        let copy = webdavLocations.copy(of: location)
        guard copy.exists else { return 0 }
        return await Task.detached(priority: .userInitiated) { copy.unconfirmedChanges() }.value
    }

    /// Throws when the open vault's keys must not be changed in the app (a WebDAV copy).
    func requireLocalKeyChanges() throws {
        if isWebDAVVault { throw WebDAVVaultError.keyChangesUnavailable }
    }

    nonisolated static func firstProblems(_ report: SyncReport) -> String {
        let lines = report.errors.prefix(3).map { "\($0.path): \($0.message)" } + [report.stoppedEarly].compactMap { $0 }
        return lines.isEmpty ? "?" : lines.joined(separator: "; ")
    }
}
