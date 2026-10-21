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
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let q): return "no sync target \(q)"
        case .ambiguous(let q): return "\(q) names several sync targets; use the id"
        case .duplicate(let id): return "the vault already syncs with that place (target \(id.uuidString.lowercased()))"
        case .overlapsStore(let p): return "\(p) overlaps the vault store; choose a folder outside it"
        case .notAFolder(let p): return "\(p) is not a folder"
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
    /// store, not holding it, and not a file. A missing folder is fine (the first run creates it).
    public func checkFolderTarget(_ folder: URL) throws {
        let url = folder.standardizedFileURL
        if url.overlaps(root) { throw SyncTargetError.overlapsStore(url.path) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            throw SyncTargetError.notAFolder(url.path)
        }
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

    public var description: String {
        switch self {
        case .missing(let p): return "\(p): the folder is gone (it was synced before); nothing was synced. Choose it again, or remove the target"
        case .unavailable(let p): return "\(p): the folder it is in cannot be reached now"
        }
    }
}

/// One run of a store vault with a folder target (docs/design/device-first-sync.md §3.3): the app's
/// sessions and `sempere store sync` both use it, so the rules are the same.
public enum FolderTargetRun {
    /// Refuses to start when a folder synced before (its state exists) is gone: when the folder it was in is
    /// gone too, it cannot be reached now (a drive not connected, a share not mounted); otherwise it was
    /// deleted or moved, and is not recreated (that would upload the whole vault again behind the user's
    /// back). A folder never synced yet may be missing: the first run creates it.
    public static func check(_ folder: URL, stateURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) || !fm.fileExists(atPath: stateURL.path) { return }
        if !fm.fileExists(atPath: folder.deletingLastPathComponent().path) {
            throw FolderTargetError.unavailable(folder.path)
        }
        throw FolderTargetError.missing(folder.path)
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
