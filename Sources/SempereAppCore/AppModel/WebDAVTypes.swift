import Age
import Foundation
import Observation
import Sempere
import SempereSync
import SempereWebDAV

/// Where and as whom to reach a WebDAV vault.
public struct WebDAVEndpoint: Sendable {
    public var url: URL
    public var user: String?
    /// From the Keychain; never logged.
    public var password: String?
    /// The certificate pin of the location (`WebDAVLocation.pinnedCertificate`).
    public var pinnedCertificate: String?

    public init(url: URL, user: String? = nil, password: String? = nil, pinnedCertificate: String? = nil) {
        self.url = url
        self.user = user
        self.password = password
        self.pinnedCertificate = pinnedCertificate
    }
}

/// A server certificate the system did not trust, as the connect sheet shows it.
public struct ServerCertificate: Hashable, Sendable {
    /// SHA-256 of the DER bytes, lowercase hex: what a pin stores.
    public var sha256: String
    /// The certificate's subject summary (usually its common name).
    public var subject: String

    /// The fingerprint grouped in pairs, as servers print it ("AB:CD:…").
    public var fingerprint: String {
        stride(from: 0, to: sha256.count, by: 2).map { i -> String in
            let start = sha256.index(sha256.startIndex, offsetBy: i)
            return sha256[start..<sha256.index(start, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }

    public init(sha256: String, subject: String) {
        self.sha256 = sha256
        self.subject = subject
    }
}

/// What the add-target sheet found at a server folder (`WebDAVConnection.checkTargetFolder`).
public enum WebDAVTargetProbe: Sendable {
    case checked(WebDAVTargetFolder)
    /// `certificate` is set when the server's certificate was not trusted.
    case failed(WebDAVSyncProblem, message: String, certificate: ServerCertificate?)
}

/// What "Test Connection" found.
public enum WebDAVProbe: Sendable {
    case reachable(WebDAVCheckResult)
    /// `certificate` is set when the server's certificate was not trusted.
    case failed(WebDAVSyncProblem, message: String, certificate: ServerCertificate?)
}

extension WebDAVRemote {
    /// Fakes that do not model folders: an empty folder.
    func checkTarget(_ endpoint: WebDAVEndpoint, vaultID: UUID) -> WebDAVTargetProbe { .checked(.empty) }
}

/// The server operations the app makes, all blocking (call them off the
/// main actor). `LiveWebDAVRemote` is the network; tests use a fake.
public protocol WebDAVRemote: Sendable {
    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe
    /// Add WebDAV Server…: what the folder holds (`WebDAVConnection.checkTargetFolder`).
    func checkTarget(_ endpoint: WebDAVEndpoint, vaultID: UUID) -> WebDAVTargetProbe
    func download(_ endpoint: WebDAVEndpoint, into copy: LocalCopy) throws -> SyncReport
    /// The root files, sealed summaries and note list into a partial copy (format.md §1.2). `options`
    /// carry the progress callback and the Cancel (`AppModel.withWebDAVDownload`).
    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: LocalCopy, options: SyncOptions) throws -> SyncReport
    /// Fetches what the partial copy lacks within `scope`; never uploads or deletes.
    func fetch(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, scope: FetchScope) throws -> SyncReport
    func push(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport
    /// A two-way run of the copy with the server (`LocalCopy.sync`): takes what other devices wrote, checked
    /// before it is placed, and uploads what this device wrote.
    func sync(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport
    /// With `partial`, the new copy is a partial copy filled by `fetch` afterwards.
    func redownload(_ endpoint: WebDAVEndpoint, copy: LocalCopy, identities: [any AgeIdentity],
                    partial: Bool, options: SyncOptions) throws -> (report: SyncReport, replaced: Bool)
    /// The open vault closed: drop any connections kept for it.
    func releaseConnections()
    /// The server as the sync engine's remote, for what a re-encryption does on a target itself (its claim, its
    /// confirmation: key-hierarchy KH6, `ReencryptCoordinator`).
    func syncRemote(_ endpoint: WebDAVEndpoint) throws -> any SyncRemote
}

extension WebDAVRemote {
    func releaseConnections() {}
    func syncRemote(_ endpoint: WebDAVEndpoint) throws -> any SyncRemote {
        throw WebDAVVaultError.noSuchLocation
    }
}

/// A `WebDAVRemote` with no network (the headless services: tests and the CLI pass their own): every server call
/// fails with `WebDAVVaultError.noSuchLocation`, a check reports the server unreachable.
struct OfflineWebDAVRemote: WebDAVRemote {
    init() {}
    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe {
        .failed(.offline, message: "offline", certificate: nil)
    }
    func checkTarget(_ endpoint: WebDAVEndpoint, vaultID: UUID) -> WebDAVTargetProbe {
        .failed(.offline, message: "offline", certificate: nil)
    }
    func download(_ endpoint: WebDAVEndpoint, into copy: LocalCopy) throws -> SyncReport {
        throw WebDAVVaultError.noSuchLocation
    }
    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: LocalCopy, options: SyncOptions) throws -> SyncReport {
        throw WebDAVVaultError.noSuchLocation
    }
    func fetch(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, scope: FetchScope) throws -> SyncReport {
        throw WebDAVVaultError.noSuchLocation
    }
    func push(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        throw WebDAVVaultError.noSuchLocation
    }
    func sync(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        throw WebDAVVaultError.noSuchLocation
    }
    func redownload(_ endpoint: WebDAVEndpoint, copy: LocalCopy, identities: [any AgeIdentity],
                           partial: Bool, options: SyncOptions) throws -> (report: SyncReport, replaced: Bool) {
        throw WebDAVVaultError.noSuchLocation
    }
}

/// A WebDAV target of a store vault, as the WebDAV code sees it (docs/io.md "WebDAV vaults in the
/// app", docs/design/device-first-sync.md §2): a `SyncTarget` of kind `.webdav` in the store's registry,
/// whose in-app copy is the store vault. Holds no secret: the password is in the Keychain
/// (`WebDAVPasswordStore`), under `id` (the target's id).
public struct WebDAVLocation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// The collection holding the vault (`vault.json` at its root).
    public var url: String
    /// The Basic auth user, if any.
    public var user: String?
    /// SHA-256 (lowercase hex) of the server certificate the user chose to
    /// trust although the system does not (a self-signed one); nil: the
    /// system decides.
    public var pinnedCertificate: String?
    /// The vault's id, as the server listed it.
    public var vaultId: String
    /// For display (the folder name without `.sempere`, escaped, bounded).
    public var name: String
    /// The in-app copy's folder name, used until the store lists the vault.
    var folderName: String
    /// True once a download run finished without errors: the copy may be opened.
    var downloaded = false
    /// When the last run finished without problems.
    var lastPush: Date?
    /// When it was set up (the list's order).
    var added = Date()

    /// The host, for display.
    public var host: String { URL(string: url)?.host ?? url }

    init(id: UUID, url: String, user: String? = nil, pinnedCertificate: String? = nil, vaultId: String, name: String, folderName: String, downloaded: Bool = false, lastPush: Date? = nil, added: Date = Date()) {
        self.id = id
        self.url = url
        self.user = user
        self.pinnedCertificate = pinnedCertificate
        self.vaultId = vaultId
        self.name = name
        self.folderName = folderName
        self.downloaded = downloaded
        self.lastPush = lastPush
        self.added = added
    }
}

/// The WebDAV targets of this device's store vaults: a view of the store's target registry
/// (`<store>/.sync/<vault id>/targets.json`, shared with `sempere store target`). Each location's copy
/// is its store vault (`<store>/<vault id>/<name>.sempere`, created by the first download), and its sync
/// state is the target's own (`<store>/.sync/<vault id>/<target id>/`).
@MainActor
@Observable
public final class WebDAVLocationStore {
    public private(set) var locations: [WebDAVLocation] = []
    /// The in-app vault store.
    let store: VaultStore

    init(store: VaultStore) {
        self.store = store
        reload()
    }

    /// Reads the registry again (after another part of the app or the CLI changed it).
    func reload() {
        let all = store.targets.all()
        locations = all.flatMap { vaultId, targets in
            targets.filter { $0.kind == .webdav }.map { Self.location($0, vault: vaultId) }
        }.sorted { $0.added < $1.added }
    }

    private static func location(_ t: SyncTarget, vault: UUID) -> WebDAVLocation {
        var l = WebDAVLocation(id: t.id, url: t.url ?? "", user: t.user, pinnedCertificate: t.pinnedCertificate,
                               vaultId: vault.uuidString.lowercased(), name: t.name,
                               folderName: WebDAVLocationStore.folderName(for: t.name))
        l.downloaded = t.joined ?? false
        l.lastPush = t.lastSuccess
        l.added = t.added
        return l
    }

    /// The local copy of `location`: its store vault, with the target's own sync state.
    public nonisolated func copy(of location: WebDAVLocation) -> LocalCopy {
        let vault = UUID(uuidString: location.vaultId) ?? UUID()
        let folder = store.entry(id: vault)?.url
            ?? store.root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(location.folderName, isDirectory: true)
        return LocalCopy(folder: folder, stateDirectory: store.targets.stateDirectory(location.id, of: vault))
    }

    public func location(_ id: UUID) -> WebDAVLocation? { locations.first { $0.id == id } }

    /// The location for this server folder and user, if there is one.
    public func location(url: String, user: String?) -> WebDAVLocation? {
        locations.first { Self.sameFolder($0.url, url) && ($0.user ?? "") == (user ?? "") }
    }

    /// Adds or replaces (same id) a location: a WebDAV target of its vault.
    func save(_ location: WebDAVLocation) {
        guard let vault = UUID(uuidString: location.vaultId) else { return }
        var t = store.targets.targets(of: vault).first { $0.id == location.id }
            ?? SyncTarget.webdav(location.url, user: location.user, name: location.name, id: location.id)
        t.url = location.url
        t.user = location.user
        t.name = location.name
        t.pinnedCertificate = location.pinnedCertificate
        t.joined = location.downloaded
        t.lastSuccess = location.lastPush
        try? store.targets.save(t, to: vault)
        reload()
    }

    func update(_ id: UUID, _ change: (inout WebDAVLocation) -> Void) {
        guard var l = location(id) else { return }
        change(&l)
        save(l)
    }

    /// Forgets the location and its sync state. Its vault stays on this device, unless the first
    /// download never completed it (a partial copy is useless without its server).
    func remove(_ id: UUID) throws {
        guard let location = location(id), let vault = UUID(uuidString: location.vaultId) else { return }
        let copy = copy(of: location)
        try store.targets.remove(id, of: vault)
        if !copy.exists || copy.isPartial, store.targets.targets(of: vault).isEmpty {
            if store.entry(id: vault) != nil { try? store.remove(vault) } else {
                try? FileManager.default.removeItem(at: copy.folder.deletingLastPathComponent())
            }
        }
        reload()
    }

    /// Two collection URLs naming the same folder (trailing slash and case of
    /// scheme and host aside).
    nonisolated static func sameFolder(_ a: String, _ b: String) -> Bool { SyncTarget.sameCollection(a, b) }

    /// The local copy's folder name for a vault called `name`: `<name>.sempere`
    /// when that is a valid name, else `Vault.sempere`.
    nonisolated static func folderName(for name: String) -> String {
        (try? VaultStore.folderName(for: name)) ?? "Vault.sempere"
    }
}

/// Why a WebDAV password could not be stored or read.
public enum WebDAVPasswordError: Error, Equatable, Sendable, DeviceUnlockWaiting {
    case notFound
    case missingEntitlement
    /// The device is locked and has not been unlocked since it started (`errSecInteractionNotAllowed`): the
    /// password can be read once it is. A sync waits for that; it is not a problem (review of #74, B1).
    case locked
    case keychain(Int32)

    /// `.locked`: a sync waits for the device's unlock (`DeviceUnlockWaiting`).
    var waitsForDeviceUnlock: Bool { self == .locked }
}

/// WebDAV passwords, one per location. The model talks to this protocol;
/// tests use an in-memory one.
public protocol WebDAVPasswordStore: Sendable {
    func password(for location: UUID) throws -> String
    func save(_ password: String, for location: UUID, label: String) throws
    /// No error when there is none.
    func delete(for location: UUID) throws
}

/// `WebDAVPasswordStore` in memory (tests, previews).
final class MemoryWebDAVPasswordStore: WebDAVPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]
    private var locked = false

    init() {}

    /// Reads fail as the Keychain's do while the device is locked before its first unlock.
    var deviceLocked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return locked }
        set { lock.lock(); locked = newValue; lock.unlock() }
    }

    func password(for location: UUID) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if locked { throw WebDAVPasswordError.locked }
        guard let p = passwords[location] else { throw WebDAVPasswordError.notFound }
        return p
    }

    func save(_ password: String, for location: UUID, label: String) throws {
        lock.lock(); passwords[location] = password; lock.unlock()
    }

    func delete(for location: UUID) throws {
        lock.lock(); passwords[location] = nil; lock.unlock()
    }
}
