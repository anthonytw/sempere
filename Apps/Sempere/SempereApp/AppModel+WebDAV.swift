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

    /// Opens the local copy of the location `id`, downloading it first when
    /// it is not complete, and starts its push-only sync (which waits for the
    /// unlock). Works offline once the copy is complete.
    func openWebDAV(_ id: UUID, library: VaultLibrary) async throws {
        close()
        let gen = generation
        guard let location = webdavLocations.location(id) else { throw WebDAVVaultError.noSuchLocation }
        let copy = webdavLocations.copy(of: location)
        if !location.downloaded || !copy.exists {
            let remote = webdavRemote, passwords = webdavPasswords
            webdavDownloading = location.name
            defer { webdavDownloading = nil }
            let report = try await offMain {
                try remote.download(try Self.endpoint(location, passwords: passwords), into: copy)
            }
            try ensureCurrent(gen)
            if !report.errors.isEmpty || report.stoppedEarly != nil {
                throw WebDAVVaultError.downloadIncomplete(Self.firstProblems(report))
            }
            webdavLocations.update(id) { $0.downloaded = true }
        }
        try await openVault(at: copy.folder)
        try ensureCurrent(generation)
        startWebDAVSession(location, copy: copy)
        library.rememberWebDAV(id, name: location.name)
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

    /// Stops the open WebDAV vault's pushes (`close`).
    func stopWebDAV() {
        webdav?.stop()
        webdav = nil
    }

    // MARK: - Commands

    /// "Sync Now".
    func webdavSyncNow() async {
        await webdav?.pushNow()
    }

    /// "Download Again": saves and closes the open notes, pushes (and stops
    /// unless that push finished without errors), downloads the server's vault
    /// into a new copy that replaces this one, and reopens and unlocks it with
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
            webdavDownloading = location.name
            defer { webdavDownloading = nil }
            let result = try await offMain {
                try remote.redownload(try Self.endpoint(location, passwords: passwords), copy: copy, identities: identities)
            }
            guard result.replaced else { throw WebDAVVaultError.redownloadFailed(Self.firstProblems(result.report)) }
        } catch {
            // The copy is as it was: open it again before reporting.
            try? await openWebDAV(location.id, library: library)
            if phase == .locked { try? await unlock(with: identities) }
            if let e = error as? WebDAVVaultError { throw e }
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
