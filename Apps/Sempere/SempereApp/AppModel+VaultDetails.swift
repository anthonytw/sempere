import Foundation
import Sempere
import SempereSync
import SempereWebDAV

/// What Vault Details shows for one store vault (docs/design/device-first-sync.md §8.3, §8.4; P9): the copy's
/// sizes and each target with its devices, quarantine and staging. The same as `sempere store info`.
struct VaultDetailsSnapshot: Sendable, Equatable {
    var storage: VaultStorage
    var targets: [TargetDetails]
}

/// Why Repair could not act on a quarantined file.
enum RepairProblem: Error, Equatable, CustomStringConvertible {
    /// Adopting checks the file under the vault's keys: the vault must be open and unlocked.
    case unlockFirst

    var description: String {
        switch self {
        case .unlockFirst: return String(localized: "Open and unlock this vault to check the file under its keys.")
        }
    }
}

/// What the add-target sheet found at a server folder (`WebDAVConnection.checkTargetFolder`).
enum WebDAVTargetProbe: Sendable {
    case checked(WebDAVTargetFolder)
    /// `certificate` is set when the server's certificate was not trusted.
    case failed(WebDAVSyncProblem, message: String, certificate: ServerCertificate?)
}

extension AppModel {
    /// Vault Details for the store vault `vaultID`, read off the main actor from this device only.
    func vaultDetails(_ vaultID: UUID, measureFolders: Bool = false) async throws -> VaultDetailsSnapshot {
        let store = syncStore
        guard let entry = store.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let device = try? deviceClockForWriting().device
        return try await offMain(priority: .utility) {
            // A folder target is measured through its bookmark (its path alone is outside the sandbox on iOS).
            var opened: [FolderTargetAccess] = []
            defer { opened.forEach { $0.close() } }
            let targets = try store.targetDetails(entry, thisDevice: device, measureFolders: measureFolders) { target in
                guard let access = try? FolderTargetAccess.open(target) else { return nil }
                opened.append(access)
                return access.folder
            }
            return VaultDetailsSnapshot(storage: TargetInspection.storage(of: entry.url), targets: targets)
        }
    }

    /// Repair ▸ Adopt: checks the quarantined `path` of target `target` again under the open vault's keys and
    /// places it if it passes (`TargetQuarantine.adopt`); what it brought reaches the list as an arrival.
    func adoptQuarantined(_ path: String, target: UUID, of vaultID: UUID) async throws {
        guard let vault, vault.vaultId == vaultID, phase == .unlocked, vault.canRead else { throw RepairProblem.unlockFirst }
        try requireWritableVault()
        let store = syncStore
        guard let entry = store.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let quarantine = store.quarantine(target, of: vaultID), lock = store.writeLock(for: vaultID)
        let changed = try await offMain {
            try quarantine.adopt(path, vaultFolder: entry.url, vault: vault, writeLock: lock)
        }
        if let changed { applySyncChanges(changed) }
    }

    /// Repair ▸ Export: a copy of the quarantined file in `folder` (picked: its security scope is held for the
    /// copy). The quarantine keeps it.
    @discardableResult
    func exportQuarantined(_ path: String, target: UUID, of vaultID: UUID, to folder: URL) async throws -> URL {
        let quarantine = syncStore.quarantine(target, of: vaultID)
        return try await offMain {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            return try quarantine.export(path, to: folder)
        }
    }

    /// Repair ▸ Delete: the user's choice; no sync run ever deletes a quarantined file.
    func deleteQuarantined(_ path: String, target: UUID, of vaultID: UUID) async throws {
        let quarantine = syncStore.quarantine(target, of: vaultID)
        try await offMain { try quarantine.delete(path) }
    }

    // MARK: - Adding a WebDAV target

    /// The add-target sheet's check of a server folder: reachable with these credentials, and empty, missing
    /// (the first run creates it) or holding this same vault.
    func probeWebDAVTarget(url: URL, user: String?, password: String, pin: String?, vaultID: UUID) async -> WebDAVTargetProbe {
        let remote = webdavRemote
        let endpoint = WebDAVEndpoint(url: url, user: user, password: user == nil ? nil : password, pinnedCertificate: pin)
        return await Task.detached(priority: .userInitiated) { remote.checkTarget(endpoint, vaultID: vaultID) }.value
    }

    /// Adds the server folder `url` as a WebDAV target of the store vault `vaultID` (the password goes to the
    /// Keychain only). The vault is on this device, so nothing is downloaded: the first run is a union that
    /// uploads the vault.
    @discardableResult
    func addWebDAVTarget(url: URL, user: String?, password: String, pin: String?, to vaultID: UUID) async throws -> UUID {
        guard let entry = syncStore.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let text = url.absoluteString
        if syncStore.targets.targets(of: vaultID).contains(where: { $0.kind == .webdav && SyncTarget.sameCollection($0.url ?? "", text) }) {
            throw SyncTargetProblem.duplicate
        }
        // Checked again here, whatever the sheet found: the folder may have changed since.
        switch await probeWebDAVTarget(url: url, user: user, password: password, pin: pin, vaultID: vaultID) {
        case .checked(let found) where found.acceptable: break
        case .checked: throw SyncTargetProblem.other(String(localized: "The server folder holds another vault or other files. Choose an empty or new folder."))
        case .failed(_, let message, _): throw SyncTargetProblem.other(message)
        }
        var location = WebDAVLocation(id: UUID(), url: text, user: user, vaultId: vaultID.uuidString.lowercased(),
                                      name: entry.label ?? entry.name, folderName: entry.url.lastPathComponent)
        location.pinnedCertificate = pin
        location.downloaded = true
        if user != nil {
            let passwords = webdavPasswords, id = location.id, label = "\(location.name) (\(location.host))"
            try await offMain { try passwords.save(password, for: id, label: label) }
        }
        webdavLocations.save(location)
        syncTargetsChanged()
        syncCoordinator.sessions[location.id]?.demand()
        return location.id
    }
}
