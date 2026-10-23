import Foundation
import Sempere

// MARK: - Vault details, storage and repair (docs/design/device-first-sync.md §8.3, §8.4; P9)
//
// What the app's Vault Details, Settings ▸ Storage and Repair show, and what `sempere store info` and
// `sempere store quarantine` print: read from the store vault's folder and each target's own state folder
// (`<store>/.sync/<vault id>/<target id>/`), never from the network.

/// One device as a target looked at this device's last sync with it (`TargetDetails.devices`): the revisions
/// it wrote that the target held, and whether its `summaries/<device>.sealed` was there. A device that never
/// syncs with a target (an island, design §5.6, Q8) is missing from that target's list.
public struct TargetDevice: Codable, Hashable, Sendable {
    /// The device id (8 hex digits).
    public var device: String
    /// Its name in the vault's device list (`vault.json` `keys`, format.md §15.3), control characters escaped;
    /// nil for a device the list does not name (removed, or from before the key hierarchy).
    public var name: String?
    /// Revisions by this device that both sides had at the last sync.
    public var revisions: Int
    /// The clock of its newest such revision.
    public var newest: Date?
    /// Its published summaries file was on the target.
    public var publishesSummaries: Bool
    /// It is this device.
    public var isThisDevice: Bool

    public init(device: String, name: String? = nil, revisions: Int, newest: Date?, publishesSummaries: Bool,
                isThisDevice: Bool) {
        self.device = device; self.name = name; self.revisions = revisions; self.newest = newest
        self.publishesSummaries = publishesSummaries; self.isThisDevice = isThisDevice
    }
}

/// A file a sync run refused (format.md §9.1), kept in its target's quarantine.
public struct QuarantinedFile: Codable, Hashable, Sendable, Identifiable {
    /// Its path in the quarantine folder (`notes/<id>/<name>`, or a later copy `….copy-<hash>`).
    public var path: String
    /// The vault path it was refused for (a later copy's suffix removed).
    public var vaultPath: String
    public var size: Int64
    /// When it was quarantined.
    public var quarantined: Date?
    /// Only write-once files (notes, keys, the inbox, notebooks, device summaries) can be adopted; root files
    /// such as `vault.json` arrive only through a sync run and its checks.
    public var adoptable: Bool

    public var id: String { path }
}

/// The sizes of a store vault's copy on this device.
public struct VaultStorage: Codable, Hashable, Sendable {
    /// Revisions under `notes/` (attachments excluded).
    public var notes: Int64
    /// Attachment blobs (`notes/<id>/att/`).
    public var attachments: Int64
    /// Everything else in the vault folder (root files, keys, inbox, summaries).
    public var other: Int64
    public var total: Int64 { notes + attachments + other }

    public init(notes: Int64 = 0, attachments: Int64 = 0, other: Int64 = 0) {
        self.notes = notes; self.attachments = attachments; self.other = other
    }
}

/// One target of a store vault: what this device knows of it.
public struct TargetDetails: Codable, Hashable, Sendable, Identifiable {
    public var target: SyncTarget
    /// Revisions and blobs both sides had at the last sync.
    public var syncedFiles: Int
    public var devices: [TargetDevice]
    public var quarantined: [QuarantinedFile]
    /// Files a locked run staged for the next unlock (`LockedStaging.pending`).
    public var staged: Int
    /// Bytes of the target's state folder on this device (sync state, quarantine, staging).
    public var stateBytes: Int64
    /// Bytes of a folder target's copy that are on this device, when measured.
    public var folderBytes: Int64?
    /// Files of that copy its provider has not downloaded (`.<name>.icloud` stand-ins), when measured.
    public var folderNotDownloaded: Int?

    public var id: UUID { target.id }
}

/// Why a quarantined file was not adopted, exported or deleted.
public enum QuarantineError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not in the quarantine (any more).
    case notFound(String)
    /// A root file: it comes only through a sync run.
    case notAdoptable(String)
    /// The vault has a different file under that name.
    case differentFileInVault(String)
    /// It still fails the checks under the vault's current keys.
    case stillRefused(String)
    /// The vault must be unlocked to check it.
    case locked
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let p): return "\(p) is not in the quarantine"
        case .notAdoptable(let p): return "\(p) is a root file: it arrives only through a sync run, never by adoption"
        case .differentFileInVault(let p): return "the vault already has a different \(p); it was not replaced"
        case .stillRefused(let why): return "it still fails the checks: \(why)"
        case .locked: return "the vault must be unlocked to check the file"
        case .io(let why): return why
        }
    }
}

/// The quarantine of one target (`SyncTargetRegistry.quarantineDirectory`): list, adopt, export, delete. A
/// sync run never removes anything from it; a file leaves it only by one of these (design §6, I6).
public struct TargetQuarantine: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Every quarantined file, sorted by path.
    public func list() -> [QuarantinedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var out: [QuarantinedFile] = []
        let base = directory.standardizedFileURL.pathComponents
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let rel = Array(url.standardizedFileURL.pathComponents.dropFirst(base.count))
            guard !rel.isEmpty else { continue }
            let vaultRel = Self.vaultPath(rel)
            out.append(QuarantinedFile(path: rel.joined(separator: "/"), vaultPath: vaultRel.joined(separator: "/"),
                                       size: Int64(v.fileSize ?? 0), quarantined: v.contentModificationDate,
                                       adoptable: LockedStaging.isWriteOnce(vaultRel)))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `rel` without a later copy's `.copy-<16 hex>` suffix (`SyncEngine.quarantineCopyName`).
    static func vaultPath(_ rel: [String]) -> [String] {
        guard let last = rel.last, let range = last.range(of: ".copy-", options: .backwards),
              last[range.upperBound...].count == 16 else { return rel }
        return rel.dropLast() + [String(last[..<range.lowerBound])]
    }

    /// The file at `path` (as `list` names it).
    public func file(_ path: String) throws -> (url: URL, item: QuarantinedFile) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let item = list().first(where: { $0.path == path }) else { throw QuarantineError.notFound(path) }
        return (parts.reduce(directory) { $0.appendingPathComponent($1) }, item)
    }

    /// Copies the file into `folder` (made if missing) under its own name, never over a file there (a taken
    /// name gets " 2", " 3"…). The quarantine keeps it. Returns the copy.
    @discardableResult
    public func export(_ path: String, to folder: URL) throws -> URL {
        let (url, _) = try file(path)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = url.lastPathComponent
            var target = folder.appendingPathComponent(name)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(name) \(n)")
                n += 1
            }
            try fm.copyItem(at: url, to: target)
            return target
        } catch {
            throw QuarantineError.io("\(folder.path): \(error.localizedDescription)")
        }
    }

    /// Deletes the file from the quarantine (the user's choice; a sync run never does).
    public func delete(_ path: String) throws {
        let (url, _) = try file(path)
        do { try FileManager.default.removeItem(at: url) } catch {
            throw QuarantineError.io("\(path): \(error.localizedDescription)")
        }
        var dir = url.deletingLastPathComponent().standardizedFileURL
        let root = directory.standardizedFileURL.path
        while dir.path.hasPrefix(root + "/"), (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Places the file in the vault at `vaultFolder` if it now passes every check a download gets, under the
    /// vault's current keys (`vault` unlocked). The check is one pull-only engine run confined to that file:
    /// from a scratch folder holding the vault's root files and the file, into a scratch working copy holding
    /// the root files and (hard links of) the one note folder or file the file belongs with, so the run never
    /// walks the rest of the vault. A file that passes is then copied into the vault under `writeLock`, never
    /// over a file there, and leaves the quarantine; the result names what arrived. A file the vault already
    /// holds with the same bytes leaves it too (nil); one that differs is refused, and so is a root file.
    @discardableResult
    public func adopt(_ path: String, vaultFolder: URL, vault: Vault, writeLock: VaultFileLock? = nil) throws -> LocalChanges? {
        let (url, item) = try file(path)
        guard item.adoptable else { throw QuarantineError.notAdoptable(item.vaultPath) }
        guard vault.canRead else { throw QuarantineError.locked }
        let rel = item.vaultPath.split(separator: "/").map(String.init)
        let local = rel.reduce(vaultFolder) { $0.appendingPathComponent($1) }
        let fm = FileManager.default
        func same(_ a: URL, _ b: URL) -> Bool { (try? FileDigest.sha256(of: a).hex) == (try? FileDigest.sha256(of: b).hex) }
        if fm.fileExists(atPath: local.path) {
            guard same(local, url) else { throw QuarantineError.differentFileInVault(item.vaultPath) }
            try delete(path)
            return nil
        }
        let scratch = directory.deletingLastPathComponent()
            .appendingPathComponent(".adopt-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("source.sempere", isDirectory: true)
        let work = scratch.appendingPathComponent("work.sempere", isDirectory: true)
        // The folder the file belongs with: its note (`notes/<id>`, blobs and revisions together), else its own folder.
        let group = Array(rel.prefix(rel.first == Vault.notesName ? 2 : rel.count - 1))
        do {
            try FileIO.createPrivateDirectory(scratch)
            for dir in [source, work] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            for name in [Vault.manifestName, Vault.journalName, SharedSettings.fileName] {
                let from = vaultFolder.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                try fm.copyItem(at: from, to: source.appendingPathComponent(name))
                try fm.copyItem(at: from, to: work.appendingPathComponent(name))
            }
            let localGroup = group.reduce(vaultFolder) { $0.appendingPathComponent($1) }
            let workGroup = group.reduce(work) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: workGroup, withIntermediateDirectories: true)
            if group.first == Vault.notesName, fm.fileExists(atPath: localGroup.path) {
                try Self.link(localGroup, into: workGroup)
            }
            let placed = rel.reduce(source) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: placed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: placed)
        } catch {
            throw QuarantineError.io("cannot prepare the check: \(error.localizedDescription)")
        }
        var o = SyncOptions()
        o.pullOnly = true
        o.keepServerChanges = true
        o.retryQuarantined = true
        o.quarantineDirectory = scratch.appendingPathComponent("refused", isDirectory: true)
        let report = try SyncEngine(directory: work, vault: vault, remote: FolderRemote(root: source),
                                    stateURL: scratch.appendingPathComponent("state.json"), options: o).run()
        let checked = rel.reduce(work) { $0.appendingPathComponent($1) }
        guard fm.fileExists(atPath: checked.path) else {
            let why = report.quarantined.first { $0.path == item.vaultPath }?.message
                ?? report.errors.first { $0.path.hasSuffix(rel.last ?? "") }?.message
                ?? report.skipped.first { $0.path.hasSuffix(rel.last ?? "") }?.message
                ?? "it was not placed"
            throw QuarantineError.stillRefused(why)
        }
        // Into the vault: a temporary name beside it, then a link that never replaces a file there.
        func place() throws {
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = local.deletingLastPathComponent().appendingPathComponent(".sempere-tmp-adopt-\(UUID().uuidString.lowercased())")
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: checked, to: temp)
            do { try fm.linkItem(at: temp, to: local) } catch {
                guard fm.fileExists(atPath: local.path), same(local, checked) else {
                    throw QuarantineError.differentFileInVault(item.vaultPath)
                }
            }
        }
        do {
            if let writeLock { try writeLock.withLock(timeout: 30, place) } else { try place() }
        } catch let e as QuarantineError {
            throw e
        } catch {
            throw QuarantineError.io("\(item.vaultPath): \(error.localizedDescription)")
        }
        try delete(path)
        var changes = LocalChanges()
        if rel.first == Vault.notesName, rel.count > 1 { changes.notes = [rel[1].lowercased()] }
        if rel.first == CaptureFile.folderName { changes.inbox = true }
        if rel.first == NotebookRecords.folderName { changes.notebooks = true }
        if rel.first == PublishedSummaries.deviceFolderName { changes.summaries = true }
        return changes
    }

    /// Hard links of every file below `from` at the same paths below `to` (copies where a link fails).
    private static func link(_ from: URL, into to: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: from, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let base = from.standardizedFileURL.pathComponents.count
        for case let file as URL in e {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = file.standardizedFileURL.pathComponents.dropFirst(base)
            let target = rel.reduce(to) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.linkItem(at: file, to: target) } catch { try fm.copyItem(at: file, to: target) }
        }
    }
}

/// Reads a target's state folder and a vault's copy for the details, Storage and Repair views.
public enum TargetInspection {
    /// The devices whose revisions or summaries file the target held at this device's last sync with it,
    /// the most recent first. `thisDevice` marks this device; `names` (device id → name) names them.
    public static func devices(stateURL: URL, thisDevice: DeviceID? = nil, names: [String: String] = [:]) -> [TargetDevice] {
        guard let state = try? SyncState.load(stateURL) else { return [] }
        var counts: [String: (n: Int, newest: Int64)] = [:]
        for key in state.files.keys {
            let parts = key.split(separator: "/")
            guard parts.count == 2, let name = RevisionName(String(parts[1])) else { continue }
            let d = name.device.description
            let c = counts[d] ?? (0, 0)
            counts[d] = (c.n + 1, max(c.newest, name.hlc.millis))
        }
        let withSummaries = Set((state.deviceSummaries ?? [:]).keys.compactMap { PublishedSummaries.device(ofFileName: $0)?.description })
        let mine = thisDevice?.description
        return Set(counts.keys).union(withSummaries).map { d in
            let c = counts[d]
            return TargetDevice(device: d, name: names[d], revisions: c?.n ?? 0,
                                newest: c.map { Date(timeIntervalSince1970: Double($0.newest) / 1000) },
                                publishesSummaries: withSummaries.contains(d), isThisDevice: d == mine)
        }.sorted { ($0.newest ?? .distantPast, $0.device) > ($1.newest ?? .distantPast, $1.device) }
    }

    /// The names of the vault's devices (device id → name) from its `vault.json`, read without the key, for
    /// display only; empty when it does not open.
    public static func deviceNames(of vaultFolder: URL) -> [String: String] {
        guard let vault = try? Vault.open(at: vaultFolder) else { return [:] }
        var out: [String: String] = [:]
        for entry in vault.devices {
            guard let id = entry.id?.lowercased() else { continue }
            out[id] = SyncReport.printable(entry.name)
        }
        return out
    }

    /// Revisions and blobs both sides had at the last sync.
    public static func syncedFiles(stateURL: URL) -> Int {
        ((try? SyncState.load(stateURL)) ?? nil)?.files.count ?? 0
    }

    /// The sizes of the vault folder's files.
    public static func storage(of vaultFolder: URL) -> VaultStorage {
        var s = VaultStorage()
        let base = vaultFolder.standardizedFileURL.pathComponents
        walk(vaultFolder) { url, size in
            let rel = Array(url.standardizedFileURL.pathComponents.dropFirst(base.count))
            if rel.first == Vault.notesName, rel.count >= 3 {
                if rel[2] == "att" { s.attachments += size } else { s.notes += size }
            } else {
                s.other += size
            }
        }
        return s
    }

    /// Bytes of every file below `folder`.
    public static func bytes(of folder: URL) -> Int64 {
        var total: Int64 = 0
        walk(folder) { _, size in total += size }
        return total
    }

    /// A folder target's copy: the bytes of the files on this device, and how many are stand-ins of files a
    /// provider has not downloaded (`.<name>.icloud`, `CloudScan`), which are not counted as bytes.
    public static func measureFolder(_ folder: URL) -> (bytes: Int64, notDownloaded: Int) {
        var total: Int64 = 0, pending = 0
        walk(folder) { url, size in
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { pending += 1 } else { total += size }
        }
        return (total, pending)
    }

    private static func walk(_ folder: URL, _ body: (URL, Int64) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            body(url, Int64(v.fileSize ?? 0))
        }
    }
}

extension VaultStore {
    /// Every target of the store vault `entry` with what this device knows of it (no network).
    /// `measureFolders`: also measure each folder target's copy (in a provider, that may take a while), at the
    /// folder `folder` gives for it (the app resolves its bookmark; default: its path).
    public func targetDetails(_ entry: Entry, thisDevice: DeviceID? = nil, measureFolders: Bool = false,
                              folder: (SyncTarget) -> URL? = { $0.path.map { URL(fileURLWithPath: $0, isDirectory: true) } })
        throws -> [TargetDetails] {
        let registry = targets
        let names = TargetInspection.deviceNames(of: entry.url)
        return try registry.load(entry.vaultId).map { t in
            let stateURL = registry.stateURL(t.id, of: entry.vaultId)
            var measured: (bytes: Int64, notDownloaded: Int)?
            if measureFolders, t.kind == .folder, let url = folder(t) { measured = TargetInspection.measureFolder(url) }
            return TargetDetails(target: t, syncedFiles: TargetInspection.syncedFiles(stateURL: stateURL),
                                 devices: TargetInspection.devices(stateURL: stateURL, thisDevice: thisDevice, names: names),
                                 quarantined: quarantine(t.id, of: entry.vaultId).list(),
                                 staged: LockedStaging(targetState: stateURL).pending(vaultFolder: entry.url).count,
                                 stateBytes: TargetInspection.bytes(of: registry.stateDirectory(t.id, of: entry.vaultId)),
                                 folderBytes: measured?.bytes, folderNotDownloaded: measured?.notDownloaded)
        }
    }

    /// The quarantine of target `target` of the store vault `vault`.
    public func quarantine(_ target: UUID, of vault: UUID) -> TargetQuarantine {
        TargetQuarantine(directory: targets.quarantineDirectory(target, of: vault))
    }
}
