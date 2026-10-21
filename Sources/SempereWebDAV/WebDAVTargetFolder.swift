import Foundation
import Sempere
import SempereSync

/// What a server folder holds, for adding it as a sync target of a vault (`WebDAVConnection.checkTargetFolder`;
/// `sempere store target add --webdav URL --check`, the app's Add WebDAV Server…).
public enum WebDAVTargetFolder: String, Codable, Hashable, Sendable {
    /// Not there: the first sync creates it (its parent must exist).
    case missing
    /// There and empty (hidden entries aside).
    case empty
    /// It holds this same vault: the first sync is a union.
    case sameVault = "same-vault"
    /// It holds another vault.
    case otherVault = "other-vault"
    /// It holds other files.
    case notEmpty = "not-empty"

    /// The vault may sync with it.
    public var acceptable: Bool { self == .missing || self == .empty || self == .sameVault }
}

extension WebDAVConnection {
    /// Lists the folder at the client's base URL and, if it holds a vault, reads its `vault.json` (bounded).
    ///
    /// - Throws: what listing it throws (offline, untrusted certificate, wrong credentials, not WebDAV).
    public static func checkTargetFolder(_ client: WebDAVClient, vaultId: UUID) throws -> WebDAVTargetFolder {
        guard let entries = try client.list([]) else { return .missing }
        if entries.contains(where: { $0.name == Vault.manifestName && !$0.isCollection }) {
            guard let data = try? client.get([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes).data,
                  let fields = manifestFields(data) else { return .notEmpty }
            return fields.vaultId == vaultId.uuidString.lowercased() ? .sameVault : .otherVault
        }
        return entries.contains { !$0.name.hasPrefix(".") } ? .notEmpty : .empty
    }
}
