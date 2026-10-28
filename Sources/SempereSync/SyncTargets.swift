import Foundation
import Sempere

/// The kind of a sync target (docs/design/device-first-sync.md §2, §3.4). A string, so a later transport
/// (Dropbox, S3) adds a kind without changing the registry's file, and a registry written by a newer
/// version keeps targets this one does not know (they are listed, never run).
public struct SyncTargetKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A folder: iCloud Drive, another provider's storage, a drive, a share, any folder (`FolderRemote`).
    public static let folder = SyncTargetKind(rawValue: "folder")
    /// A WebDAV collection (SempereWebDAV's remote).
    public static let webdav = SyncTargetKind(rawValue: "webdav")

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One sync target of a store vault: where an outside copy lives and how to reach it. Holds no secret
/// (a WebDAV password is in the app's Keychain or the CLI's environment, keyed by `id`).
public struct SyncTarget: Codable, Sendable, Hashable, Identifiable {
    /// The target's id: its sync state's folder, and the Keychain account of its password.
    public var id: UUID
    public var kind: SyncTargetKind
    /// For display (the folder's or server folder's name).
    public var name: String
    public var added: Date
    /// When a run last finished without problems.
    public var lastSuccess: Date?

    // Folder targets.
    /// The folder holding the vault's copy, as an absolute path (the CLI's, and the app's last known one).
    public var path: String?
    /// The app's bookmark of the folder the user picked (opaque here; `options: []`).
    public var bookmark: Data?
    /// The copy's folder inside the picked one, when the user picked its parent ("Keep a copy in…").
    public var subfolder: String?

    // WebDAV targets.
    /// The collection holding the vault.
    public var url: String?
    /// The Basic auth user, if any.
    public var user: String?
    /// SHA-256 (lowercase hex) of a certificate the user chose to trust although the system does not.
    public var pinnedCertificate: String?
    /// The first download of a join finished (a WebDAV vault opened from its server).
    public var joined: Bool?

    public init(id: UUID = UUID(), kind: SyncTargetKind, name: String, added: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.added = added
    }

    /// A folder target at `path`.
    public static func folder(_ path: URL, name: String? = nil, bookmark: Data? = nil, subfolder: String? = nil) -> SyncTarget {
        var t = SyncTarget(kind: .folder, name: name ?? VaultStore.displayName(of: path))
        t.path = path.standardizedFileURL.path
        t.bookmark = bookmark
        t.subfolder = subfolder
        return t
    }

    /// A WebDAV target at `url`.
    public static func webdav(_ url: String, user: String?, name: String, id: UUID = UUID()) -> SyncTarget {
        var t = SyncTarget(id: id, kind: .webdav, name: name)
        t.url = url
        t.user = user
        return t
    }

    /// `url`'s standardized path with `/private` dropped before `var`, `tmp` and `etc` whether or not the path exists.
    /// `standardizedFileURL` drops it only for a path that exists, so on an iPhone or iPad a picked folder (there) and
    /// the copy's folder inside it (not made yet) compared as unrelated and build 10 saved no subfolder.
    public static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        for top in ["var", "tmp", "etc"] where path == "/private/\(top)" || path.hasPrefix("/private/\(top)/") {
            path.removeFirst("/private".count)
            break
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The path of `inner` below `base` ("Wompa.sempere"), nil when it is `base` itself or not below it
    /// (`comparablePath` on both).
    public static func subfolder(of inner: URL, in base: URL) -> String? {
        let i = comparablePath(inner), b = comparablePath(base)
        guard i != b else { return nil }
        let prefix = b == "/" ? "/" : b + "/"
        return i.hasPrefix(prefix) ? String(i.dropFirst(prefix.count)) : nil
    }

    /// The path the app's bookmark recorded for the picked folder, read without resolving it; nil without a bookmark
    /// or where bookmarks cannot be read (Linux).
    public var bookmarkedPath: String? {
        #if canImport(Darwin)
        guard let bookmark else { return nil }
        return (try? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark))?.path
        #else
        return nil
        #endif
    }

    /// A folder target TestFlight build 10 set up wrong: its stored path is below the folder its bookmark recorded, but
    /// no subfolder is saved, so its runs wrote the vault into the picked folder itself. Decided from the record alone,
    /// never from what the folder shows. Such a target is held: neither the app nor `store sync` runs it (review of
    /// #113); the user removes it or chooses the folder again.
    public var isMisrecorded: Bool {
        guard kind == .folder, subfolder == nil, let path, let recorded = bookmarkedPath else { return false }
        return Self.subfolder(of: URL(fileURLWithPath: path, isDirectory: true),
                              in: URL(fileURLWithPath: recorded, isDirectory: true)) != nil
    }

    /// True when `other` reaches the same place (one folder, or one server folder and user).
    public func samePlace(as other: SyncTarget) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .folder:
            guard let a = path, let b = other.path else { return false }
            return URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
        case .webdav:
            guard let a = url, let b = other.url else { return false }
            return Self.sameCollection(a, b) && (user ?? "") == (other.user ?? "")
        default:
            return false
        }
    }

    /// Two collection URLs naming the same folder (trailing slashes and the case of scheme and host aside).
    public static func sameCollection(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            guard var c = URLComponents(string: s) else { return s }
            c.scheme = c.scheme?.lowercased()
            c.host = c.host?.lowercased()
            var path = c.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            c.percentEncodedPath = path
            return c.string ?? s
        }
        return key(a) == key(b)
    }
}

/// Why a target could not be added, found or changed.
public enum SyncTargetError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String)
    /// The vault already has a target at that place (its id).
    case duplicate(UUID)
    /// A folder target inside the store, or holding the vault's own copy.
    case overlapsStore(String)
    /// The folder named is a file.
    case notAFolder(String)
    /// The folder is a backup (it holds `backup.json`): a sync would write into it and pass deletions on.
    case isBackup(String)
    /// The folder lies inside a vault or a backup (the folder path, then the nearest such folder): a sync would
    /// write into it (review of #109).
    case insideVault(String, String)
    /// The target was set up wrong by an earlier build (`SyncTarget.isMisrecorded`): held, never synced.
    case misrecorded(String)
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let q): return "no sync target \(q)"
        case .ambiguous(let q): return "\(q) names several sync targets; use the id"
        case .duplicate(let id): return "the vault already syncs with that place (target \(id.uuidString.lowercased()))"
        case .overlapsStore(let p): return "\(p) overlaps the vault store; choose a folder outside it"
        case .notAFolder(let p): return "\(p) is not a folder"
        case .isBackup(let p):
            return "\(p) is a backup (it holds backup.json), never a sync target: a sync would write into it and pass "
                + "deletions on. Restore it (sempere store restore), or copy it in once (sempere store import without --keep-syncing)"
        case .insideVault(let p, let holder):
            return "\(p) is inside the vault or backup \(holder), never a sync target: a sync would write into it. "
                + "Choose a folder outside it"
        case .misrecorded(let p):
            return "\(p): this target was set up wrong by an earlier build (its copy went into the folder above it); "
                + "nothing was synced. Remove it and add the folder again"
        case .io(let m): return m
        }
    }
}

/// The sync targets of a store's vaults (docs/design/device-first-sync.md §2, §4.2), one file per vault:
/// `<store>/.sync/<vault id>/targets.json`, and each target's sync state, quarantine and transfers in
/// `<store>/.sync/<vault id>/<target id>/`. Everything is keyed by vault id and target id, so vaults never
/// share state. The app and `sempere store target` read and write the same files.
public struct SyncTargetRegistry: Sendable {
    /// `<store>/.sync`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    static let fileName = "targets.json"

    // MARK: - Reading

    /// The targets of `vault`, in the order they were added. Unreadable: none (`load` throws instead).
    public func targets(of vault: UUID) -> [SyncTarget] {
        (try? load(vault)) ?? []
    }

    /// The targets of `vault`.
    ///
    /// - Throws: `SyncTargetError.io` when the file exists but cannot be read.
    public func load(_ vault: UUID) throws -> [SyncTarget] {
        let url = file(vault)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try BoundedRead.contents(of: url, maxBytes: 4 << 20)
            return try JSONDecoder.targets.decode([SyncTarget].self, from: data)
        } catch {
            throw SyncTargetError.io("\(url.path): \(error)")
        }
    }

    /// Every vault's targets, by vault id (vaults without targets are left out).
    public func all() -> [UUID: [SyncTarget]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var out: [UUID: [SyncTarget]] = [:]
        for name in names {
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name else { continue }
            let list = targets(of: id)
            if !list.isEmpty { out[id] = list }
        }
        return out
    }

    /// The target `query` names among `vault`'s: its id, a unique id prefix (4 characters or more) or its
    /// exact name when unique.
    public func resolve(_ query: String, of vault: UUID) throws -> SyncTarget {
        let list = try load(vault)
        let q = query.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: q), let hit = list.first(where: { $0.id == id }) { return hit }
        let lower = q.lowercased()
        if lower.count >= 4, lower.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let hits = list.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { throw SyncTargetError.ambiguous(query) }
        }
        let named = list.filter { $0.name == q || $0.path == q || $0.url == q }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw SyncTargetError.ambiguous(query) }
        throw SyncTargetError.notFound(query)
    }

    // MARK: - Changing

    /// Adds `target` to `vault`. A target at the same place is refused (`duplicate`): a second session on
    /// one folder would only double the work.
    @discardableResult
    public func add(_ target: SyncTarget, to vault: UUID) throws -> SyncTarget {
        try change(vault) { list in
            if let same = list.first(where: { $0.id == target.id || $0.samePlace(as: target) }) {
                throw SyncTargetError.duplicate(same.id)
            }
            list.append(target)
        }
        return target
    }

    /// Adds `target`, or replaces the one with its id.
    public func save(_ target: SyncTarget, to vault: UUID) throws {
        try change(vault) { list in
            if let i = list.firstIndex(where: { $0.id == target.id }) { list[i] = target } else { list.append(target) }
        }
    }

    /// Changes the target `id` of `vault` (nothing when there is none).
    public func update(_ id: UUID, of vault: UUID, _ body: (inout SyncTarget) -> Void) throws {
        try change(vault) { list in
            if let i = list.firstIndex(where: { $0.id == id }) { body(&list[i]) }
        }
    }

    /// Starts target `id`'s sync over: deletes its state file and the transfers in progress (the folder was
    /// chosen again), keeping its quarantine. The next run is a union that deletes nothing.
    public func resetState(_ id: UUID, of vault: UUID) {
        let state = stateURL(id, of: vault)
        try? FileManager.default.removeItem(at: state)
        SyncState.removeTransfers(state)
    }

    /// Forgets the target `id` of `vault` and deletes its sync state on this device. Nothing at the target
    /// itself is touched.
    public func remove(_ id: UUID, of vault: UUID) throws {
        try change(vault) { list in list.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(at: stateDirectory(id, of: vault))
    }

    // MARK: - Places

    /// The folder of target `id`'s sync state: `sync-state.json`, `sync-state.quarantine/` and transfers.
    public func stateDirectory(_ id: UUID, of vault: UUID) -> URL {
        folder(vault).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Target `id`'s sync-state file.
    public func stateURL(_ id: UUID, of vault: UUID) -> URL {
        stateDirectory(id, of: vault).appendingPathComponent("sync-state.json")
    }

    /// Where target `id`'s quarantined files go.
    public func quarantineDirectory(_ id: UUID, of vault: UUID) -> URL {
        stateDirectory(id, of: vault).appendingPathComponent("sync-state.quarantine", isDirectory: true)
    }

    private func folder(_ vault: UUID) -> URL {
        root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
    }

    private func file(_ vault: UUID) -> URL { folder(vault).appendingPathComponent(Self.fileName) }

    private func change(_ vault: UUID, _ body: (inout [SyncTarget]) throws -> Void) throws {
        let dir = folder(vault)
        do {
            try FileIO.createPrivateDirectory(root)
            try FileIO.createPrivateDirectory(dir)
        } catch {
            throw SyncTargetError.io("\(dir.path): \(error)")
        }
        let lock = VaultFileLock.at(dir.appendingPathComponent("targets.lock"))
        do {
            try lock.withLock(timeout: 10) {
                var list = try load(vault)
                try body(&list)
                let data = try JSONEncoder.targets.encode(list)
                do { try data.write(to: file(vault), options: .atomic) } catch {
                    throw SyncTargetError.io("\(file(vault).path): \(error)")
                }
            }
        } catch VaultFileLock.LockError.timedOut {
            throw SyncTargetError.io("\(dir.path): another process holds the targets' lock")
        }
    }
}

extension VaultStore {
    /// The sync targets of this store's vaults (`<root>/.sync`).
    public var targets: SyncTargetRegistry {
        SyncTargetRegistry(root: root.appendingPathComponent(VaultStore.syncName, isDirectory: true))
    }

    /// Checks that a folder target at `folder` may be added to the store vault `entry`: not inside the
    /// store, not holding it, not a file, not a backup (`backup.json`: a sync would write into it and
    /// pass note deletions and compactions on, the loss a backup is there to undo), and not inside a vault or a
    /// backup (`BackupDestination.enclosingHolders`: a backup's `versions/<time>/` holds a `vault.json` of the
    /// same vault, which the engine's same-vault check takes; review of #109). A folder above holding the copy of
    /// `vaultId` itself (a bare copy an earlier build synced there) does not count: the target next to it is this
    /// vault's too. Checked when a target is added only; runs check the folder itself (`FolderTargetRun.check`). A
    /// missing folder is fine (the first run creates it).
    public func checkFolderTarget(_ folder: URL, vaultId: UUID? = nil) throws {
        let url = folder.standardizedFileURL
        if url.overlaps(root) { throw SyncTargetError.overlapsStore(url.path) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            throw SyncTargetError.notAFolder(url.path)
        }
        if BackupDestination.isBackup(url) { throw SyncTargetError.isBackup(url.path) }
        let own = vaultId?.uuidString.lowercased()
        if let holder = BackupDestination.enclosingHolders(of: url).first(where: { holder in
            BackupDestination.isBackup(holder) || own == nil || Self.manifestVaultId(holder) != own
        }) {
            throw SyncTargetError.insideVault(url.path, holder.path)
        }
    }

    /// The vault id in `folder`'s `vault.json`, nil when it cannot be read.
    static func manifestVaultId(_ folder: URL) -> String? {
        guard let data = try? BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                                   maxBytes: BoundedRead.maxManifestBytes) else { return nil }
        return SyncEngine.manifestFields(data)?.vaultId
    }
}

extension JSONEncoder {
    static var targets: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var targets: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Running a folder target

/// Why a folder target's run did not start.
public enum FolderTargetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The folder was synced before and is gone (deleted, or moved): nothing is recreated or deleted.
    case missing(String)
    /// The folder it lives in is not there (a drive not connected, a share not mounted, a provider not
    /// signed in): a later run may find it.
    case unavailable(String)
    /// The folder is a backup (`backup.json`): never synced (a target added before that was refused).
    case isBackup(String)

    public var description: String {
        switch self {
        case .missing(let p): return "\(p): the folder is gone (it was synced before); nothing was synced. Choose it again, or remove the target"
        case .unavailable(let p): return "\(p): the folder it is in cannot be reached now"
        case .isBackup(let p): return "\(p) is a backup (it holds backup.json): it is never synced. Remove the target"
        }
    }
}

/// One run of a store vault with a folder target (docs/design/device-first-sync.md §3.3): the app's
/// sessions and `sempere store sync` both use it, so the rules are the same.
public enum FolderTargetRun {
    /// Refuses to start when a folder synced before (`syncedBefore(stateURL:)`) is gone: when the folder it was in is
    /// gone too, it cannot be reached now (a drive not connected, a share not mounted); otherwise it was
    /// deleted or moved, and is not recreated (that would upload the whole vault again behind the user's
    /// back). A folder never synced yet may be missing: the first run creates it. A backup folder
    /// (`backup.json`) is never synced: a run would write into it and pass deletions on. What lies above the folder
    /// is not looked at here: a new target inside a vault or a backup is refused when it is added
    /// (`VaultStore.checkFolderTarget`), and a target that worked before (under an earlier build's plain-folder
    /// backup, or next to a bare copy) keeps working (review of #113).
    ///
    /// The rule for a folder that is not there is `FolderRemote.absentBase`, which the engine applies again at the
    /// moment it would make the folder (`SyncRemote.checkAbsentBase`), so `sempere sync folder` and a folder that went
    /// away after this check keep it too. A folder present only as a provider's stand-in (a vault iCloud Drive holds
    /// as a package, evicted whole) passes here: the run asks for it and reports it arriving, and a later run syncs it.
    public static func check(_ folder: URL, stateURL: URL) throws {
        let fm = FileManager.default
        if BackupDestination.isBackup(folder, fileManager: fm) { throw FolderTargetError.isBackup(folder.path) }
        if case .refused(let why)? = FolderRemote.absentBase(folder, syncedBefore: syncedBefore(stateURL: stateURL)) {
            throw why
        }
    }

    /// Whether this device synced with the target whose sync state is `stateURL` (`SyncState.syncedBefore`: something
    /// recorded, not merely a state file there; a state file that cannot be read counts as synced before).
    public static func syncedBefore(stateURL: URL) -> Bool {
        SyncState.syncedBefore(Result { try SyncState.load(stateURL) })
    }

    /// What is wrong with a folder target (or a backup folder) reached by its stored `path`, nil when it is there
    /// (`FolderReachability`, offline audit A-P2): `.unavailable` when the removable volume it is on is not mounted,
    /// `.missing` otherwise. The app's `FolderReach` uses the same rule when a target's bookmark does not resolve: an
    /// unplugged drive is offline, not "choose it again".
    public static func problem(path: String) -> FolderTargetError? {
        switch FolderReachability.of(path: path) {
        case .reachable: return nil
        case .unavailable: return .unavailable(path)
        case .missing: return .missing(path)
        }
    }

    /// Runs the vault folder `vaultFolder` against the target folder `folder`: two-way (`twoWay`, the vault
    /// unlocked here: takes what other devices wrote, merges settings, follows explained deletions) or
    /// upload-only (never writes the vault folder). Every received file is checked before it is placed and
    /// quarantined otherwise; the quarantine is the target's own (`stateURL`'s folder).
    public static func run(vaultFolder: URL, folder: URL, provider: (any FolderProvider)? = nil, vault: Vault?,
                           stateURL: URL, twoWay: Bool, options base: SyncOptions = SyncOptions()) throws -> SyncReport {
        try check(folder, stateURL: stateURL)
        var o = base
        o.dryRun = false
        o.deleteExtraneous = false
        o.publishForWebViewer = false
        o.pushOnly = !twoWay
        o.keepServerChanges = !twoWay
        if o.quarantineDirectory == nil {
            o.quarantineDirectory = stateURL.deletingPathExtension().appendingPathExtension("quarantine")
        }
        try FileIO.createPrivateDirectory(stateURL.deletingLastPathComponent())
        let remote = FolderRemote(root: folder, provider: provider)
        let engine = SyncEngine(directory: vaultFolder, vault: twoWay ? vault : nil, remote: remote, stateURL: stateURL,
                                options: o)
        return try engine.run()
    }
}
