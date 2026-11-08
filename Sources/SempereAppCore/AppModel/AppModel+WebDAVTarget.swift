import Foundation
import Sempere
import SempereSync
import SempereWebDAV

/// Add WebDAV Server… in Vault Details (docs/design/device-first-sync.md §8.3; P9): a server folder becomes a target of
/// a store vault already on this device.
extension AppModelCore {
    /// The add-target sheet's check of a server folder: reachable with these credentials, and empty, missing
    /// (the first run creates it) or holding this same vault.
    public func probeWebDAVTarget(url: URL, user: String?, password: String, pin: String?, vaultID: UUID) async -> WebDAVTargetProbe {
        let remote = webdavRemote
        let endpoint = WebDAVEndpoint(url: url, user: user, password: user == nil ? nil : password, pinnedCertificate: pin)
        return await Task.detached(priority: .userInitiated) { remote.checkTarget(endpoint, vaultID: vaultID) }.value
    }

    /// Adds the server folder `url` as a WebDAV target of the store vault `vaultID` (the password goes to the
    /// Keychain only). The vault is on this device, so nothing is downloaded: the first run is a union that
    /// uploads the vault.
    @discardableResult
    public func addWebDAVTarget(url: URL, user: String?, password: String, pin: String?, to vaultID: UUID) async throws -> UUID {
        guard let entry = syncStore.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let text = url.absoluteString
        if syncStore.targets.targets(of: vaultID).contains(where: { $0.kind == .webdav && SyncTarget.sameCollection($0.url ?? "", text) }) {
            throw SyncTargetProblem.duplicate
        }
        // Checked again here, whatever the sheet found: the folder may have changed since.
        switch await probeWebDAVTarget(url: url, user: user, password: password, pin: pin, vaultID: vaultID) {
        case .checked(let found) where found.acceptable: break
        case .checked: throw SyncTargetProblem.serverFolderTaken
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
