import Foundation
import Sempere

/// A vault found on a WebDAV server (`WebDAVConnection.check`).
public struct WebDAVVaultListing: Codable, Hashable, Sendable {
    /// Where it is below the checked URL: `[]` for the URL itself, else one
    /// collection name (`WebDAVClient.descendant`).
    public var path: [String]
    /// For display: the collection name without `.sempere` (the last
    /// component of the URL for the URL itself), control characters escaped,
    /// at most `WebDAVConnection.maxNameLength` characters.
    public var name: String
    /// The `vaultId` of its `vault.json`, lowercased.
    public var vaultId: String
    /// Its `format` string (`sempere/1`), bounded and printable.
    public var format: String?
    /// The collection's URL.
    public var url: String

    public init(path: [String], name: String, vaultId: String, format: String?, url: String) {
        self.path = path; self.name = name; self.vaultId = vaultId; self.format = format; self.url = url
    }
}

/// What a connection check found at a URL.
public struct WebDAVCheckResult: Codable, Hashable, Sendable {
    /// `vault`: the URL is a vault. `vaults-below`: vaults one level below
    /// it. `no-vault`: reachable, but no vault there or one level below.
    public enum Outcome: String, Codable, Sendable {
        case vault
        case vaultsBelow = "vaults-below"
        case noVault = "no-vault"
    }

    public var outcome: Outcome
    public var vaults: [WebDAVVaultListing]
    /// Collections below the URL that were looked into.
    public var foldersChecked: Int
    /// Collections not looked into (over `WebDAVConnection.maxFoldersChecked`)
    /// or that could not be listed.
    public var foldersSkipped: Int
    /// Collections holding a `vault.json` that is not a vault manifest.
    public var unreadable: [String]

    public init(outcome: Outcome, vaults: [WebDAVVaultListing], foldersChecked: Int, foldersSkipped: Int,
                unreadable: [String]) {
        self.outcome = outcome; self.vaults = vaults; self.foldersChecked = foldersChecked
        self.foldersSkipped = foldersSkipped; self.unreadable = unreadable
    }
}

/// Testing a WebDAV URL and finding the vaults there ("Test Connection" and
/// the vault list of the app's Open Vault ▸ WebDAV…; `sempere webdav check`).
///
/// Everything read from the server is untrusted: listings and manifests are
/// bounded by `WebDAVClient`, names are escaped and shortened, and a vault id
/// must be a UUID.
public enum WebDAVConnection {
    /// Most collections below the URL that are listed to find vaults.
    public static let maxFoldersChecked = 64
    /// Longest vault name shown.
    public static let maxNameLength = 80

    /// Lists the URL and the collections directly below it.
    ///
    /// - Throws: what listing the URL itself throws: `WebDAVError.offline`,
    ///   `.untrustedCertificate`, `.http` (401/403 wrong credentials, 404 or
    ///   405 not a WebDAV collection), `.redirect`, `.transport`,
    ///   `.malformedResponse` (not a WebDAV answer).
    public static func check(_ client: WebDAVClient) throws -> WebDAVCheckResult {
        guard let root = try client.list([]) else {
            throw WebDAVError.http(method: "PROPFIND", path: "", status: 404)
        }
        var unreadable: [String] = []
        if root.contains(where: { $0.name == "vault.json" && !$0.isCollection }) {
            let base = WebDAVClient.components(of: client.baseURL.path).last ?? ""
            if let listing = listing(client, path: [], name: base) {
                return WebDAVCheckResult(outcome: .vault, vaults: [listing], foldersChecked: 0, foldersSkipped: 0,
                                         unreadable: [])
            }
            unreadable.append(display(base))
        }
        let folders = root.filter { $0.isCollection && !$0.name.hasPrefix(".") && $0.name != "notes" && $0.name != "keys" }
            .map(\.name).sorted()
        var vaults: [WebDAVVaultListing] = []
        var checked = 0, skipped = max(0, folders.count - maxFoldersChecked)
        for name in folders.prefix(maxFoldersChecked) {
            guard let sub = try? client.descendant([name]), let entries = try? sub.list([]) else {
                skipped += 1
                continue
            }
            checked += 1
            guard entries.contains(where: { $0.name == "vault.json" && !$0.isCollection }) else { continue }
            if let listing = listing(client, path: [name], name: name) {
                vaults.append(listing)
            } else {
                unreadable.append(display(name))
            }
        }
        return WebDAVCheckResult(outcome: vaults.isEmpty ? .noVault : .vaultsBelow, vaults: vaults,
                                 foldersChecked: checked, foldersSkipped: skipped, unreadable: unreadable)
    }

    /// The listing for the vault at `path`, or nil when its `vault.json`
    /// cannot be read or is not a manifest.
    private static func listing(_ client: WebDAVClient, path: [String], name: String) -> WebDAVVaultListing? {
        guard let sub = try? client.descendant(path),
              let data = try? sub.get(["vault.json"], maxBytes: BoundedRead.maxManifestBytes).data,
              let manifest = manifestFields(data) else { return nil }
        return WebDAVVaultListing(path: path, name: display(name), vaultId: manifest.vaultId,
                                  format: manifest.format, url: sub.baseURL.absoluteString)
    }

    /// `vaultId` (a UUID, lowercased) and `format` of a manifest; nil if it is not one.
    static func manifestFields(_ data: Data) -> (vaultId: String, format: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["vaultId"] as? String, let uuid = UUID(uuidString: id) else { return nil }
        let format = (obj["format"] as? String).map { SyncReport.printable(String($0.prefix(64))) }
        return (uuid.uuidString.lowercased(), format)
    }

    /// A server-chosen name made safe to show: no `.sempere`, control
    /// characters escaped, bounded.
    static func display(_ name: String) -> String {
        var n = name
        if n.lowercased().hasSuffix(".sempere") { n = String(n.dropLast(".sempere".count)) }
        if n.isEmpty { n = "vault" }
        let printable = SyncReport.printable(n)
        return printable.count > maxNameLength ? String(printable.prefix(maxNameLength - 1)) + "…" : printable
    }
}
