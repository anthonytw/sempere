import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Why a vault store operation failed. Messages are English (the CLI's); the app words its own.
public enum VaultStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The name cannot be a vault folder's name.
    case invalidName(String)
    /// The source folder holds no readable `vault.json`.
    case notAVault(path: String, detail: String)
    /// The store already holds this vault (by id), under `name`.
    case alreadyInStore(vaultId: UUID, name: String)
    /// The source is inside the store (or holds it).
    case sourceInsideStore(String)
    /// The source is a partial copy (format.md §1.2) or has notes still marked incomplete.
    case partialCopy(String)
    /// The source is a restore that did not finish (`Backup.restore`'s marker is there).
    case unfinishedRestore(String)
    /// Files of the source are cloud placeholders, not on this device yet (a few of them, and how many).
    case notDownloaded(examples: [String], count: Int)
    /// The source holds a symbolic link or a special file (vaults hold only folders and regular files).
    case unsupportedEntry(String)
    /// The source changed while it was copied.
    case sourceChanged(String)
    /// The copy does not read back identical to the source.
    case copyMismatch(String)
    /// No vault in the store matches.
    case notFound(String)
    /// Several vaults in the store match.
    case ambiguous(String, [UUID])
    /// The vault is open (by the app or a command): it cannot be removed now.
    case inUse(UUID)
    /// Another writer held the vault's lock for the whole wait.
    case busy(UUID)
    /// A restore could not bring back every file of the backup (how many failed): nothing was added.
    case restoreIncomplete(Int)
    /// A file system failure.
    case io(String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            return "“\(name)” cannot name a vault: give a name without slashes, colons, leading dots or control characters"
        case .notAVault(let path, let detail):
            return "\(path) is not a Sempere vault: \(detail)"
        case .alreadyInStore(let id, let name):
            return "this vault is already in the store as “\(name)” (\(id.uuidString.lowercased()))"
        case .sourceInsideStore(let path):
            return "\(path) is inside the vault store; choose a vault outside it"
        case .partialCopy(let path):
            return "\(path) is a partial copy (format.md §1.2); complete it before copying it in"
        case .unfinishedRestore(let path):
            return "\(path) is an unfinished restore; finish it (run the same restore again) before copying it in"
        case .notDownloaded(let examples, let count):
            return "\(count) files of the vault are not on this device yet (cloud placeholders: "
                + examples.joined(separator: ", ") + (count > examples.count ? ", …" : "") + "); download them first"
        case .unsupportedEntry(let path):
            return "\(path) is a symbolic link or special file; a vault holds only folders and regular files"
        case .sourceChanged(let path):
            return "the vault changed while it was being copied (\(path)); nothing was added, try again"
        case .copyMismatch(let path):
            return "the copy of \(path) does not match the original; nothing was added"
        case .notFound(let query):
            return "no vault in the store matches '\(query)'"
        case .ambiguous(let query, let ids):
            return "'\(query)' matches several vaults: " + ids.map { $0.uuidString.lowercased() }.joined(separator: ", ")
        case .inUse(let id):
            return "vault \(id.uuidString.lowercased()) is open (in the app or another command); close it first"
        case .busy(let id):
            return "another writer is using vault \(id.uuidString.lowercased()); try again"
        case .restoreIncomplete(let count):
            return "\(count) files of the backup could not be restored (see `sempere backup verify`); nothing was added"
        case .io(let detail):
            return detail
        }
    }
}

/// The vaults kept on this device (docs/design/device-first-sync.md §2, "In-app copy"): every vault
/// the app reads and writes is a complete working copy in one store folder, hidden in the app's
/// container on every platform. Outside folders are not opened in place: "Open Vault…" copies a
/// vault in (`importVault`), and keeping that folder in sync is a later step (P6, sync targets).
///
/// Layout of `root`:
///
/// ```
/// <root>/<vaultId>/<name>.sempere/   one vault (its id as in vault.json, lowercase)
/// <root>/.staging/<uuid>/            a vault being built or copied in (never listed)
/// <root>/.trash/<uuid>/              a vault being removed (never listed)
/// <root>/.locks/<vaultId>.write      the vault's VaultFileLock (writers)
/// <root>/.locks/<vaultId>.open       held shared while the vault is open (`lease`)
/// <root>/<vaultId>/.replaced-<name>  the vault being replaced (`restore` with `replace`), for an instant
/// ```
///
/// Each vault is isolated by its id (§4.2): its own folder, write lock and lease, so two vaults are
/// open, written and removed independently. A vault appears in the store only complete: it is built
/// or copied under `.staging`, checked there, and moved into place by one `rename(2)` of its folder,
/// so an interrupted create or copy-in leaves nothing listed (`sweep` removes what it left). The
/// store holds one copy of each vault id. A replace (`restore` with `replace`) builds the new copy in
/// staging first, then moves the old copy aside and the new one in; a crash between the two renames
/// leaves the old copy aside, and `sweep` puts it back.
///
/// Every byte of a copied-in source is untrusted (format.md §9): only folders and regular files are
/// copied, no symbolic link is followed, each file is bounded, and the whole copy is compared byte for
/// byte with the source before it is placed.
public struct VaultStore: Sendable {
    /// The store folder.
    public let root: URL

    static let stagingName = ".staging"
    static let trashName = ".trash"
    static let locksName = ".locks"
    /// The folder of the store vaults' sync targets and their sync state (`SyncTargetRegistry` in
    /// SempereSync): `<root>/.sync/<vault id>/`. Removed with its vault.
    public static let syncName = ".sync"
    /// How long `create`, `importVault` and `remove` wait for a vault's write lock.
    public static let lockTimeout: TimeInterval = 30

    public init(root: URL) {
        self.root = root
    }

    /// One vault in the store.
    public struct Entry: Sendable, Hashable, Encodable {
        /// The vault id (the folder's name, and `vault.json`'s).
        public var vaultId: UUID
        /// The vault folder's name without `.sempere`.
        public var name: String
        /// The vault folder (open it with `Vault.open(at:)`).
        public var url: URL
        /// The display label from `vault.json` (unauthenticated, for display only), if any.
        public var label: String?
        /// Why `vault.json` did not open or does not match the folder, if so.
        public var problem: String?

        private enum CodingKeys: String, CodingKey { case vaultId, name, path, label, problem }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(vaultId.uuidString.lowercased(), forKey: .vaultId)
            try c.encode(name, forKey: .name)
            try c.encode(url.path, forKey: .path)
            try c.encode(label, forKey: .label)
            try c.encode(problem, forKey: .problem)
        }
    }

    /// Options of `importVault`.
    public struct ImportOptions: Sendable {
        /// The vault's name in the store (its folder, without `.sempere`); nil keeps the source folder's.
        public var name: String?
        /// Called after each file with the files copied so far and the total.
        public var progress: (@Sendable (Int, Int) -> Void)?
        /// Test seam: called after each file is copied, with its relative path; throwing stops the copy.
        public var afterEachFile: (@Sendable (String) throws -> Void)?
        /// Test seam: on failure, leave the staging folder as a crash would (`sweep` removes it).
        var keepStagingOnFailure = false

        public init(name: String? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil,
                    afterEachFile: (@Sendable (String) throws -> Void)? = nil) {
            self.name = name
            self.progress = progress
            self.afterEachFile = afterEachFile
        }
    }

    // MARK: - Names

    /// The folder name for a vault called `name`: `<name>.sempere`, `name` trimmed.
    ///
    /// - Throws: `VaultStoreError.invalidName` for an empty name, a leading dot, a slash, colon or
    ///   control character, a name already ending in `.sempere`, or more than 255 bytes.
    public static func folderName(for name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = trimmed.isEmpty || trimmed.hasPrefix(".") || trimmed.lowercased().hasSuffix(".sempere")
            || trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            || trimmed.contains { $0 == "/" || $0 == ":" || $0 == "\\" }
            || (trimmed + ".sempere").utf8.count > 255
        if bad { throw VaultStoreError.invalidName(name) }
        return trimmed + ".sempere"
    }

    /// A vault folder's name without `.sempere`.
    public static func displayName(of url: URL) -> String {
        let last = url.lastPathComponent
        return last.hasSuffix(".sempere") && last.count > ".sempere".count ? String(last.dropLast(".sempere".count)) : last
    }

    // MARK: - Listing

    /// Every vault in the store, sorted by name (then id). Folders an interrupted operation left are
    /// not listed. Reads only each `vault.json` (no key).
    public func list() -> [Entry] {
        let names = (try? FileIO.entries(root, directories: true) { !$0.hasPrefix(".") }) ?? []
        var out: [Entry] = []
        for name in names {
            guard let id = Self.storeID(name), let entry = loadEntry(id) else { continue }
            out.append(entry)
        }
        return out.sorted {
            let a = $0.name.lowercased(), b = $1.name.lowercased()
            return a != b ? a < b : $0.vaultId.uuidString < $1.vaultId.uuidString
        }
    }

    /// The vault with id `id`, if the store holds it.
    public func entry(id: UUID) -> Entry? {
        loadEntry(id)
    }

    /// The store vault that `url` is (or is inside), if any.
    public func entry(containing url: URL) -> Entry? {
        guard url.isSameOrInside(root) else { return nil }
        let rootPath = root.canonicalPath
        let rest = url.canonicalPath.dropFirst(rootPath.count).split(separator: "/")
        guard let first = rest.first, let id = Self.storeID(String(first)), let entry = loadEntry(id),
              url.isSameOrInside(entry.url) else { return nil }
        return entry
    }

    /// The vault `query` names: its id, a unique prefix of it (at least 4 characters), or its exact
    /// name (folder name without `.sempere`) when unique.
    ///
    /// - Throws: `VaultStoreError.notFound` or `.ambiguous`.
    public func resolve(_ query: String) throws -> Entry {
        let all = list()
        let q = query.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: q), let hit = all.first(where: { $0.vaultId == id }) { return hit }
        let lower = q.lowercased()
        if lower.count >= 4, lower.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let hits = all.filter { $0.vaultId.uuidString.lowercased().hasPrefix(lower) }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { throw VaultStoreError.ambiguous(query, hits.map(\.vaultId)) }
        }
        let named = all.filter { $0.name == q }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw VaultStoreError.ambiguous(query, named.map(\.vaultId)) }
        throw VaultStoreError.notFound(query)
    }

    // MARK: - Create

    /// Creates a vault named `name` in the store: `build` creates it at the URL it is given (a
    /// `<name>.sempere` folder in a staging folder, not there yet), then it is moved into place as
    /// `<root>/<vaultId>/<name>.sempere`. A failing `build` leaves nothing in the store.
    ///
    /// - Returns: the new entry and what `build` returned.
    public func create<T>(name: String, _ build: (URL) throws -> T) throws -> (entry: Entry, result: T) {
        let folder = try Self.folderName(for: name)
        try prepare()
        sweep()
        let staging = try makeStaging()
        defer { staging.discard() }
        let vaultURL = staging.dir.appendingPathComponent(folder, isDirectory: true)
        let result = try build(vaultURL)
        let id: UUID
        do { id = try Vault.open(at: vaultURL).vaultId } catch {
            throw VaultStoreError.notAVault(path: vaultURL.path, detail: "\(error)")
        }
        return (try install(vaultURL, id: id), result)
    }

    // MARK: - Copy in

    /// Copies the vault folder `source` into the store ("Open Vault…": the source is never written).
    ///
    /// The source must be a complete vault: a readable `vault.json`, no partial-copy markers
    /// (format.md §1.2), no cloud placeholders (download it first), only folders and regular files.
    /// Hidden files (`.DS_Store`, temporary files) are not copied. Each file is copied and read back
    /// (`Backup.copyVerified`), then the whole copy is compared byte for byte with the source, and
    /// the source is listed again, before the vault is moved into place. Any failure leaves nothing
    /// in the store.
    ///
    /// - Throws: `VaultStoreError` (`.alreadyInStore` when the store holds this vault id), or a
    ///   `VaultError` from copying.
    @discardableResult
    public func importVault(from source: URL, options: ImportOptions = ImportOptions()) throws -> Entry {
        let src = source.standardizedFileURL
        if src.overlaps(root) { throw VaultStoreError.sourceInsideStore(src.path) }
        let id: UUID
        do { id = try Vault.open(at: src).vaultId } catch {
            throw VaultStoreError.notAVault(path: src.path, detail: "\(error)")
        }
        if let existing = entry(id: id) { throw VaultStoreError.alreadyInStore(vaultId: id, name: existing.name) }
        let folder = try Self.folderName(for: options.name ?? Self.displayName(of: src))
        let scan = try Self.scan(src)
        try prepare()
        sweep()
        let staging = try makeStaging()
        var keep = false
        defer { if keep { staging.abandon() } else { staging.discard() } }
        do {
            let staged = staging.dir.appendingPathComponent(folder, isDirectory: true)
            try FileIO.createDirectory(staged)
            for dir in scan.directories { try FileIO.createDirectory(Backup.url(staged, dir)) }
            for (i, path) in scan.files.enumerated() {
                try Backup.copyVerified(from: src, path, followLinks: false, to: Backup.url(staged, path), replacing: false,
                                        maxBytes: BoundedRead.maxBlobFileBytes)
                try options.afterEachFile?(path)
                options.progress?(i + 1, scan.files.count)
            }
            // The source as it is now must be what was copied, and the copy exactly that.
            guard try Self.scan(src) == scan else { throw VaultStoreError.sourceChanged(src.path) }
            guard try Self.scan(staged) == scan else { throw VaultStoreError.copyMismatch(staged.path) }
            for path in scan.files {
                guard try Self.sameBytes(src, staged, path) else { throw VaultStoreError.copyMismatch(path) }
            }
            let copied: Vault
            do { copied = try Vault.open(at: staged) } catch {
                throw VaultStoreError.copyMismatch("\(Vault.manifestName): \(error)")
            }
            guard copied.vaultId == id else { throw VaultStoreError.sourceChanged(Vault.manifestName) }
            return try install(staged, id: id)
        } catch {
            keep = options.keepStagingOnFailure
            throw error
        }
    }

    // MARK: - Restore

    /// Options of `restore`.
    public struct RestoreOptions: Sendable {
        /// The vault's name in the store; nil keeps the name of the copy it replaces, else the backup folder's.
        public var name: String?
        /// Replace the store's copy of the same vault id (else that is refused with `.alreadyInStore`).
        public var replace: Bool
        /// Test seam: stop (as a crash would) after the old copy was moved aside, before the new one is in.
        var crashAfterSettingAside = false

        public init(name: String? = nil, replace: Bool = false) {
            self.name = name
            self.replace = replace
        }
    }

    /// Restores the backup folder (or any vault folder) `backup` into the store (`Backup.restore`: every
    /// file checked against `backup.json`). The restore is built in staging and must bring back every file,
    /// else nothing is added (`.restoreIncomplete`). When the store holds the vault id already, the restore
    /// is refused unless `options.replace`: then the old copy is replaced as a whole, after the new one is
    /// complete, and only while the vault is not open anywhere (`.inUse`).
    ///
    /// - Returns: the new entry and the restore's report.
    @discardableResult
    public func restore(from backup: URL, options: RestoreOptions = RestoreOptions()) throws
        -> (entry: Entry, report: RestoreReport)
    {
        let src = backup.standardizedFileURL
        if src.overlaps(root) { throw VaultStoreError.sourceInsideStore(src.path) }
        let id: UUID
        do { id = try Vault.open(at: src).vaultId } catch {
            throw VaultStoreError.notAVault(path: src.path, detail: "\(error)")
        }
        let existing = entry(id: id)
        if let existing, !options.replace { throw VaultStoreError.alreadyInStore(vaultId: id, name: existing.name) }
        let folder = try Self.folderName(for: options.name ?? existing?.name ?? Self.displayName(of: src))
        try prepare()
        sweep()
        let staging = try makeStaging()
        defer { staging.discard() }
        let staged = staging.dir.appendingPathComponent(folder, isDirectory: true)
        let report = try Backup.restore(from: src, to: staged)
        guard report.errors.isEmpty, FileIO.exists(staged.appendingPathComponent(Vault.manifestName)) else {
            throw VaultStoreError.restoreIncomplete(max(report.errors.count, 1))
        }
        let restored: UUID
        do { restored = try Vault.open(at: staged).vaultId } catch {
            throw VaultStoreError.copyMismatch("\(Vault.manifestName): \(error)")
        }
        guard restored == id else { throw VaultStoreError.sourceChanged(Vault.manifestName) }
        let entry = try install(staged, id: id, replacing: options.replace,
                                crashAfterSettingAside: options.crashAfterSettingAside)
        return (entry, report)
    }

    // MARK: - Remove

    /// Removes the vault `id` from the store, permanently: its folder is moved out of the store in one
    /// `rename(2)` and then deleted. Refused while the vault is open anywhere (`lease`).
    ///
    /// - Throws: `.notFound`, `.inUse`, `.busy` (a writer held the lock for `timeout` seconds).
    public func remove(_ id: UUID, timeout: TimeInterval = VaultStore.lockTimeout) throws {
        guard entry(id: id) != nil || FileIO.isDirectory(folder(of: id)) else {
            throw VaultStoreError.notFound(id.uuidString.lowercased())
        }
        try prepare()
        guard let exclusive = try FileLock.acquire(openLockURL(id), exclusive: true, deadline: .distantPast,
                                                   createParent: true, throwOnTimeout: false) else {
            throw VaultStoreError.inUse(id)
        }
        defer { exclusive.release() }
        let trash = root.appendingPathComponent(Self.trashName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try writeLock(for: id).withLock(timeout: timeout) {
                try Self.rename(folder(of: id), to: trash)
                try FileIO.syncDirectory(root)
            }
        } catch VaultFileLock.LockError.timedOut {
            throw VaultStoreError.busy(id)
        }
        try? FileManager.default.removeItem(at: trash)
        // Its sync targets and their state go with it (nothing remote is touched).
        try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.syncName, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true))
    }

    // MARK: - Locks

    /// The `VaultFileLock` of vault `id`: every writer of its files on this device takes it.
    public func writeLock(for id: UUID) -> VaultFileLock {
        VaultFileLock.at(root.appendingPathComponent(Self.locksName, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased() + ".write"))
    }

    /// A hold on an open vault: while any lease of a vault is held (in any process), `remove` refuses it.
    public final class Lease: @unchecked Sendable {
        public let vaultId: UUID
        private let held: FileLock

        init(vaultId: UUID, held: FileLock) {
            self.vaultId = vaultId
            self.held = held
        }

        /// Ends the hold (also when the lease is released from memory).
        public func release() {
            held.release()
        }
    }

    /// Takes a lease on vault `id` for as long as it is open. Several leases of one vault coexist.
    ///
    /// - Throws: `.busy` while the vault is being removed.
    public func lease(_ id: UUID) throws -> Lease {
        try prepare()
        guard let held = try FileLock.acquire(openLockURL(id), exclusive: false, deadline: Date().addingTimeInterval(5),
                                              createParent: true, throwOnTimeout: false) else {
            throw VaultStoreError.busy(id)
        }
        return Lease(vaultId: id, held: held)
    }

    // MARK: - Clean-up

    /// Removes what interrupted operations left: staging folders no running operation holds, folders
    /// being removed, and vault-id folders without a vault (a crash between claiming the id and moving
    /// the vault in). Never touches a listed vault. Best effort.
    public func sweep() {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(Self.stagingName, isDirectory: true)
        for name in (try? FileIO.entries(staging)) ?? [] {
            let dir = staging.appendingPathComponent(name, isDirectory: true)
            if let held = try? FileLock.acquire(dir, exclusive: true, deadline: .distantPast, throwOnTimeout: false) {
                try? fm.removeItem(at: dir)
                held.release()
            }
        }
        let trash = root.appendingPathComponent(Self.trashName, isDirectory: true)
        for name in (try? FileIO.entries(trash)) ?? [] {
            try? fm.removeItem(at: trash.appendingPathComponent(name, isDirectory: true))
        }
        for name in (try? FileIO.entries(root, directories: true) { !$0.hasPrefix(".") }) ?? [] {
            guard let id = Self.storeID(name) else { continue }
            let dir = folder(of: id)
            let aside = Self.setAside(in: dir)
            guard Self.vaultFolder(in: dir) == nil || !aside.isEmpty else { continue }
            _ = try? writeLock(for: id).withLockIfFree {
                let aside = Self.setAside(in: dir)
                if Self.vaultFolder(in: dir) != nil {
                    // A replace finished: the old copy goes.
                    for old in aside { try? fm.removeItem(at: old) }
                } else if let old = aside.first {
                    // A replace stopped between its two renames: the old copy comes back.
                    let back = dir.appendingPathComponent(String(old.lastPathComponent.dropFirst(Self.asidePrefix.count)),
                                                          isDirectory: true)
                    try? Self.rename(old, to: back)
                } else {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }

    // MARK: - Internals

    private func folder(of id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func openLockURL(_ id: UUID) -> URL {
        root.appendingPathComponent(Self.locksName, isDirectory: true).appendingPathComponent(id.uuidString.lowercased() + ".open")
    }

    /// The vault id a store folder name is: a lowercase UUID.
    static func storeID(_ name: String) -> UUID? {
        guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name else { return nil }
        return id
    }

    /// The prefix of a copy being replaced, inside its vault-id folder (`.replaced-<name>.sempere`).
    static let asidePrefix = ".replaced-"

    /// The copies set aside by a replace in the vault-id folder `dir`.
    static func setAside(in dir: URL) -> [URL] {
        ((try? FileIO.entries(dir, directories: true) { $0.hasPrefix(asidePrefix) && $0.count > asidePrefix.count }) ?? [])
            .map { dir.appendingPathComponent($0, isDirectory: true) }
    }

    /// The vault folder inside a vault-id folder: the `.sempere` folder holding a `vault.json`.
    static func vaultFolder(in dir: URL) -> URL? {
        let names = (try? FileIO.entries(dir, directories: true) { !$0.hasPrefix(".") && $0.hasSuffix(".sempere") }) ?? []
        return names.lazy.map { dir.appendingPathComponent($0, isDirectory: true) }
            .first { FileIO.exists($0.appendingPathComponent(Vault.manifestName)) }
    }

    private func loadEntry(_ id: UUID) -> Entry? {
        guard let url = Self.vaultFolder(in: folder(of: id)) else { return nil }
        var entry = Entry(vaultId: id, name: Self.displayName(of: url), url: url, label: nil, problem: nil)
        do {
            let vault = try Vault.open(at: url)
            entry.label = vault.label
            if vault.vaultId != id { entry.problem = "vault.json names vault \(vault.vaultId.uuidString.lowercased())" }
        } catch {
            entry.problem = "\(error)"
        }
        return entry
    }

    private func prepare() throws {
        for name in [Self.stagingName, Self.trashName, Self.locksName] {
            try FileIO.createPrivateDirectory(root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// A fresh staging folder, locked while this operation uses it.
    private struct Staging {
        let dir: URL
        let held: FileLock

        /// Removes the folder (the operation finished or failed).
        func discard() {
            try? FileManager.default.removeItem(at: dir)
            held.release()
        }

        /// Leaves the folder as a crash would (test seam).
        func abandon() {
            held.release()
        }
    }

    private func makeStaging() throws -> Staging {
        let dir = root.appendingPathComponent(Self.stagingName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileIO.createStagingDirectory(dir)
        guard let held = try FileLock.acquire(dir, exclusive: true, deadline: .distantPast, throwOnTimeout: false) else {
            throw VaultStoreError.io("cannot lock \(dir.path)")
        }
        return Staging(dir: dir, held: held)
    }

    /// Moves the finished vault folder `vaultURL` into `<root>/<id>/` under the vault's write lock. With
    /// `replacing`, a copy already there is first moved aside (`.replaced-<name>`), then deleted once the new
    /// one is in; refused while that vault is open anywhere.
    private func install(_ vaultURL: URL, id: UUID, replacing: Bool = false,
                         crashAfterSettingAside: Bool = false) throws -> Entry {
        let dir = folder(of: id)
        var notOpen: FileLock?
        defer { notOpen?.release() }
        if replacing, Self.vaultFolder(in: dir) != nil {
            guard let held = try FileLock.acquire(openLockURL(id), exclusive: true, deadline: .distantPast,
                                                  createParent: true, throwOnTimeout: false) else {
                throw VaultStoreError.inUse(id)
            }
            notOpen = held
        }
        var aside: URL?
        do {
            try writeLock(for: id).withLock(timeout: Self.lockTimeout) {
                if FileIO.isDirectory(dir) {
                    if let present = Self.vaultFolder(in: dir) {
                        guard replacing, notOpen != nil else {
                            throw VaultStoreError.alreadyInStore(vaultId: id, name: Self.displayName(of: present))
                        }
                        let old = dir.appendingPathComponent(Self.asidePrefix + present.lastPathComponent, isDirectory: true)
                        for stale in Self.setAside(in: dir) { try? FileManager.default.removeItem(at: stale) }
                        try Self.rename(present, to: old)
                        try FileIO.syncDirectory(dir)
                        aside = old
                        if crashAfterSettingAside { throw VaultStoreError.io("simulated crash after setting the old copy aside") }
                        do {
                            try Self.rename(vaultURL, to: dir.appendingPathComponent(vaultURL.lastPathComponent, isDirectory: true))
                        } catch {
                            try? Self.rename(old, to: present)   // the old copy stays
                            aside = nil
                            throw error
                        }
                    } else {
                        try Self.rename(vaultURL, to: dir.appendingPathComponent(vaultURL.lastPathComponent, isDirectory: true))
                    }
                } else {
                    try FileIO.createStagingDirectory(dir)
                    try Self.rename(vaultURL, to: dir.appendingPathComponent(vaultURL.lastPathComponent, isDirectory: true))
                }
                try FileIO.syncDirectory(dir)
                try FileIO.syncDirectory(root)
                if let old = aside { try? FileManager.default.removeItem(at: old) }
            }
        } catch VaultFileLock.LockError.timedOut {
            throw VaultStoreError.busy(id)
        }
        guard let entry = loadEntry(id) else { throw VaultStoreError.io("\(dir.path): the vault did not arrive") }
        return entry
    }

    /// `rename(2)`: atomic within one file system; refuses to replace a non-empty folder.
    static func rename(_ from: URL, to: URL) throws {
        let rc = from.withUnsafeFileSystemRepresentation { src in
            to.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return posixRename(src, dst)
            }
        }
        guard rc == 0 else { throw VaultStoreError.io("rename \(from.path) to \(to.path): \(FileIO.errnoText(errno))") }
    }

    /// What a source folder holds: its folders and regular files (relative paths, sorted).
    struct Scan: Equatable {
        var directories: [String] = []
        var files: [String] = []
    }

    /// Lists `root` without following symbolic links: refuses partial copies, unfinished restores,
    /// cloud placeholders, links and special files; skips other hidden names.
    static func scan(_ root: URL) throws -> Scan {
        var scan = Scan()
        var placeholders: [String] = []
        func walk(_ rel: [String], depth: Int) throws {
            let dir = rel.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            for name in try FileIO.entries(dir) {
                let path = (rel + [name]).joined(separator: "/")
                if rel.isEmpty, name == PartialCopy.folderName { throw VaultStoreError.partialCopy(root.path) }
                if rel.isEmpty, name == Backup.restoreMarker { throw VaultStoreError.unfinishedRestore(root.path) }
                if name == PartialCopy.noteMarkerName || PartialCopy.realName(ofStandIn: name) != nil {
                    throw VaultStoreError.partialCopy(root.path)
                }
                if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
                    placeholders.append(path)
                    continue
                }
                if name.hasPrefix(".") { continue }
                var st = stat()
                let rc = dir.appendingPathComponent(name).withUnsafeFileSystemRepresentation { p -> Int32 in
                    guard let p else { return -1 }
                    return lstat(p, &st)
                }
                guard rc == 0 else { throw VaultStoreError.io("stat \(path): \(FileIO.errnoText(errno))") }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    guard depth < 16 else { throw VaultStoreError.unsupportedEntry(path) }
                    scan.directories.append(path)
                    try walk(rel + [name], depth: depth + 1)
                case S_IFREG:
                    scan.files.append(path)
                default:
                    throw VaultStoreError.unsupportedEntry(path)
                }
            }
        }
        try walk([], depth: 0)
        if !placeholders.isEmpty {
            throw VaultStoreError.notDownloaded(examples: Array(placeholders.sorted().prefix(3)), count: placeholders.count)
        }
        scan.directories.sort()
        scan.files.sort()
        return scan
    }

    /// Whether the file `path` holds the same bytes under `a` and `b` (no symbolic link followed).
    static func sameBytes(_ a: URL, _ b: URL, _ path: String) throws -> Bool {
        let ha = try BoundedRead.openRegularFile(under: a, path)
        defer { try? ha.close() }
        let hb = try BoundedRead.openRegularFile(under: b, path)
        defer { try? hb.close() }
        while true {
            let (pa, pb) = try autoreleasing { () throws -> (Data, Data) in
                (try ha.read(upToCount: 1 << 20) ?? Data(), try hb.read(upToCount: 1 << 20) ?? Data())
            }
            if pa != pb { return false }
            if pa.isEmpty { return true }
        }
    }
}

/// `rename(2)` (outside `VaultStore`, whose own `rename` would shadow it).
private func posixRename(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>) -> Int32 {
    rename(from, to)
}
