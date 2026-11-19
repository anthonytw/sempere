import Foundation
import Sempere

// MARK: - Conflict versions of a vault folder held as a package (docs/io.md "A vault folder held as a package")
//
// iCloud Drive syncs a folder it records as a package as ONE item. Two devices writing into such a vault folder make a
// conflict of the whole folder: the provider keeps one side as the folder and the other as an `NSFileVersion`
// conflict version, and a file only the losing side had (a revision, a blob, a capture, a join request) is missing
// from the folder. The sync engine settles conflict versions of the mutable root files (`ConflictVersions.swift`), but
// never looked at versions of the base folder itself, so nothing merged those back (owner's vault, 2026-11-19: 13
// whole-vault versions from three devices, four files missing).
//
// `inspect` reports, without a key and without writing: what the provider records about the folder
// (`FolderProvider.itemRecord`), the unresolved conflict versions of the folder and of its mutable files, and for each
// version the files the current folder lacks (by kind) and the mutable files that differ. A version that cannot be
// listed whole (its contents not on this device, a folder that cannot be read, its root gone) carries a `problem` and
// is never judged from what it lists. Walks use `lstat`: symbolic links and special files are reported, never
// followed; reads are bounded and follow no link below the version's root.
//
// `merge` (`sempere vault conflicts --merge`) runs inside ONE coordinated write of the vault folder (a plain folder:
// its `.sempere-lock`, as `FolderRemote` takes it), with no coordination nested inside it. It re-reads `vault.json`
// there, then:
// 1. places the missing epoch records of every version and reopens the vault, so files under a new key are judged
//    under it;
// 2. places the other missing WRITE-ONCE files (format.md §1.3), each staged privately with a no-follow bounded read,
//    checked as a received file (§9.1, under the vault's key) and placed through a temporary name that never replaces
//    a file. The acceptance rule's outcomes are kept apart: pending leaves the version unresolved, set aside goes to
//    the vault's set-aside store; neither is quarantined. A file that fails its own check goes to the quarantine.
// 3. settles mutable files by the engine's rules: `settings.age` merged per key with what is on disk just before it
//    is written (never when the current file cannot be read); `vault.json` decided by `Vault.judgeIncoming` (only a
//    later version in the same epoch is taken); anything else is kept aside and reported, never picked.
// Versions are marked resolved only after everything they hold was placed, set aside, quarantined or settled; they are
// kept (the system's version browser still has them) unless `removeVersions`, and a version any of whose files went
// only to the quarantine (or was not placed: unknown files, links) is never removed.

/// Inspecting and merging a vault folder's provider conflict versions (see above).
public enum VaultFolderConflicts {
    /// What a file of a vault is, by its path (format.md §1).
    public enum FileKind: String, Codable, Hashable, Sendable, CaseIterable {
        case revision, blob, inbox, join, epoch, notebook, passphraseCopy
        case manifest, settings, journal
        /// Rewritten whole by every writer (`sempere-summaries.sealed`, `sempere-index.json`, `summaries/`, `insights/`).
        case derived
        /// Not a vault file this version knows (ignored by readers, never deleted, format.md §1).
        case other

        /// Written once under a name no other writer uses (format.md §1.3): the union of two copies is safe.
        public var isWriteOnce: Bool {
            switch self {
            case .revision, .blob, .inbox, .join, .epoch, .notebook, .passphraseCopy: return true
            case .manifest, .settings, .journal, .derived, .other: return false
            }
        }
    }

    /// The kind of the file at `path` (relative, `/`-separated); nil for a hidden name (format.md §1.1).
    public static func kind(of path: String) -> FileKind? {
        let p = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !p.isEmpty, !p.contains(where: { $0.isEmpty || $0.hasPrefix(".") }) else { return nil }
        switch (p.count, p[0]) {
        case (1, Vault.manifestName): return .manifest
        case (1, SharedSettings.fileName): return .settings
        case (1, Vault.journalName): return .journal
        case (1, PublishedSummaries.fileName), (1, WebIndex.fileName): return .derived
        case (2, PublishedSummaries.deviceFolderName), (2, Vault.insightsName): return .derived
        case (2, CaptureFile.folderName): return CaptureFile.parse(name: p[1]) != nil ? .inbox : .other
        case (2, Vault.epochsName): return Vault.isEpochRecordFileName(p[1]) ? .epoch : .other
        case (2, Vault.joinsName): return p[1].hasSuffix(".join.json") ? .join : .other
        case (2, NotebookRecords.folderName): return NotebookRecords.id(ofFileName: p[1]) != nil ? .notebook : .other
        case (2, Vault.keysName): return Vault.passphraseCopyFingerprint(p[1]) != nil ? .passphraseCopy : .other
        case (3, Vault.notesName):
            return noteId(p[1]) != nil && RevisionName(p[2]) != nil ? .revision : .other
        case (4, Vault.notesName):
            return noteId(p[1]) != nil && p[2] == Vault.attachmentsName && BlobName.parse(p[3]) != nil ? .blob : .other
        default: return .other
        }
    }

    static func noteId(_ s: String) -> UUID? {
        guard s == s.lowercased() else { return nil }
        return UUID(uuidString: s)
    }

    // MARK: Inspection

    /// One unresolved conflict version: of the vault folder (`item` empty) or of one of its files.
    public struct Version: Codable, Hashable, Sendable {
        /// The provider's id of the version.
        public var id: String
        /// What it is a version of: "" for the vault folder, else the file's path.
        public var item: String
        public var modified: Date?
        /// The device the provider names (display only).
        public var device: String?
        /// Files it holds (1 for a file's version).
        public var files: Int
        /// Files it holds that the current folder lacks, by kind (`FileKind` raw values), each list sorted.
        public var missing: [String: [String]]
        /// Mutable files (and unknown ones) it holds with other bytes than the current folder's, sorted.
        public var differing: [String]
        /// Entries it holds that are neither a regular file nor a folder (symbolic links, special files): never
        /// followed, never copied, reported (`path (why)`).
        public var skipped: [String] = []
        /// Why it cannot be judged (its contents are not on this device, it cannot be listed whole, it is gone): it is
        /// never resolved while this is set.
        public var problem: String?

        /// How many of `missing` are write-once (safe to copy back).
        public var writeOnceMissing: Int {
            missing.reduce(0) { $0 + ((FileKind(rawValue: $1.key)?.isWriteOnce ?? false) ? $1.value.count : 0) }
        }
    }

    /// What `inspect` found.
    public struct Inspection: Codable, Hashable, Sendable {
        /// The vault folder.
        public var folder: String
        /// What holds it ("iCloud Drive", "a folder").
        public var provider: String
        /// What the provider records about the folder; nil when it records nothing (a plain folder, Linux).
        public var record: ProviderItemRecord?
        public var versions: [Version]
        /// Entries of the current folder that are neither a regular file nor a folder (never followed), sorted.
        public var skipped: [String] = []

        /// The provider syncs the folder as one item.
        public var heldAsPackage: Bool { record?.heldAsPackage ?? false }

        /// Distinct write-once files that only conflict versions hold, sorted.
        public var writeOnceMissing: [String] {
            Set(versions.flatMap { v in
                v.missing.filter { FileKind(rawValue: $0.key)?.isWriteOnce ?? false }.flatMap(\.value)
            }).sorted()
        }

        /// Distinct mutable or unknown files that a version lacks from the folder or holds with other bytes, sorted.
        public var mutableToReview: [String] {
            Set(versions.flatMap { v in
                v.differing + v.missing.filter { !(FileKind(rawValue: $0.key)?.isWriteOnce ?? true) }.flatMap(\.value)
            }).sorted()
        }

        /// Nothing to do: no version and the folder is not held as a package.
        public var isClean: Bool { versions.isEmpty && !heldAsPackage }
    }

    /// The mutable files whose own conflict versions are looked for: the root's, `summaries/` and `insights/`.
    static func versionedFiles(in folder: URL) -> [String] {
        var out = [Vault.manifestName, SharedSettings.fileName, Vault.journalName, PublishedSummaries.fileName,
                   WebIndex.fileName]
        for dir in [PublishedSummaries.deviceFolderName, Vault.insightsName] {
            out += Vault.visibleEntries(folder.appendingPathComponent(dir, isDirectory: true)).map { "\(dir)/\($0)" }
        }
        return out.filter { FolderRemote.lstatItem(folder.appendingPathComponent($0)).stat?.isRegularFile == true }
    }

    /// Reports the folder's provider record and its unresolved conflict versions (see the top of the file). Reads only.
    ///
    /// - Throws: `ListingError` when the current folder cannot be listed whole.
    public static func inspect(folder: URL, provider: any FolderProvider) throws -> Inspection {
        let current = try listFiles(folder, current: true)
        var inspection = Inspection(folder: folder.path, provider: provider.name, record: provider.itemRecord(of: folder),
                                    versions: [], skipped: current.skipped)
        for v in provider.conflictVersions(of: folder) {
            var version = Version(id: v.id, item: "", modified: v.modified, device: v.device, files: 0, missing: [:],
                                  differing: [])
            defer { inspection.versions.append(version) }
            if v.hasLocalContents == false {
                version.problem = "its contents are not on this device (open the folder's versions in the Finder so they "
                    + "download, then run again)"
                continue
            }
            guard let root = provider.versionFile(of: folder, id: v.id) else {
                version.problem = "the provider lists it but has no contents for it"
                continue
            }
            let theirs: Listing
            do { theirs = try listFiles(root, current: false) } catch {
                version.problem = "it cannot be listed whole: \(error)"
                continue
            }
            version.files = theirs.files.count
            version.skipped = theirs.skipped
            for path in theirs.files.sorted() {
                guard let kind = kind(of: path) else { continue }
                if !current.files.contains(path) {
                    version.missing[kind.rawValue, default: []].append(path)
                } else if !kind.isWriteOnce, kind != .derived,
                          !sameBytes(Source(base: root, path: path), Source(base: folder, path: path)) {
                    version.differing.append(path)
                }
            }
        }
        for path in versionedFiles(in: folder) {
            let url = folder.appendingPathComponent(path)
            for v in provider.conflictVersions(of: url) {
                var version = Version(id: v.id, item: path, modified: v.modified, device: v.device, files: 1, missing: [:],
                                      differing: [])
                defer { inspection.versions.append(version) }
                if v.hasLocalContents == false {
                    version.problem = "its contents are not on this device"
                    continue
                }
                guard let file = provider.versionFile(of: url, id: v.id) else {
                    version.problem = "the provider lists it but has no contents for it"
                    continue
                }
                guard FolderRemote.lstatItem(file).stat?.isRegularFile == true else {
                    version.problem = "its contents are not a regular file"
                    continue
                }
                if kind(of: path) != .derived, !sameBytes(Source(file: file), Source(base: folder, path: path)) {
                    version.differing = [path]
                }
            }
        }
        return inspection
    }

    /// Why a folder cannot be listed whole (a version that throws one is never judged).
    public enum ListingError: Error, Hashable, Sendable, CustomStringConvertible {
        case missing(String)
        case unreadable(String, String)
        case tooManyEntries(String, Int)
        case tooDeep(String)

        public var description: String {
            switch self {
            case .missing(let p): return "\(p) does not exist"
            case .unreadable(let p, let why): return "\(p) cannot be read: \(why)"
            case .tooManyEntries(let p, let n): return "\(p) holds more than \(n) entries"
            case .tooDeep(let p): return "\(p) is nested deeper than any vault folder"
            }
        }
    }

    /// The most entries a listing walks before it gives up (a vault holds far fewer).
    public static let maxEntries = 2_000_000
    /// Folders deeper than this are no vault's (`notes/<id>/att/` is the deepest).
    static let maxDepth = 8

    /// A listing: regular files by relative path, and entries skipped (links, special files).
    struct Listing {
        var files = Set<String>()
        var skipped: [String] = []
    }

    /// Every regular file below `root`, as relative paths, by `lstat`: hidden names skipped, symbolic links and special
    /// files reported in `skipped`, never followed. For the `current` folder an iCloud stand-in (`.<name>.icloud`)
    /// counts as the file it stands for, and a link counts as present (nothing is ever placed over it).
    ///
    /// - Throws: `ListingError` when `root` or any folder below it cannot be listed, or past the limits.
    static func listFiles(_ root: URL, current: Bool, maxEntries: Int = VaultFolderConflicts.maxEntries) throws -> Listing {
        var out = Listing()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else { throw ListingError.missing(root.path) }
        guard isDir.boolValue else { throw ListingError.unreadable(root.path, "not a folder") }
        var count = 0
        func walk(_ dir: URL, _ prefix: String, depth: Int) throws {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch {
                throw ListingError.unreadable(prefix.isEmpty ? "the folder" : String(prefix.dropLast()), "\(error)")
            }
            for name in names.sorted() {
                count += 1
                guard count <= maxEntries else { throw ListingError.tooManyEntries(root.path, maxEntries) }
                let url = dir.appendingPathComponent(name)
                let item = FolderRemote.lstatItem(url)
                if name.hasPrefix(".") {
                    if current, item.stat?.isRegularFile == true, let real = UbiquitousPlaceholder.realName(of: name) {
                        out.files.insert(prefix + real)
                    }
                    continue
                }
                if item.isLink {
                    out.skipped.append(prefix + name + " (a symbolic link: not followed)")
                    if current { out.files.insert(prefix + name) }
                    continue
                }
                guard let stat = item.stat else {
                    throw ListingError.unreadable(prefix + name, "lstat failed (errno \(item.errno))")
                }
                if stat.isDirectory {
                    guard depth + 1 < maxDepth else { throw ListingError.tooDeep(prefix + name) }
                    try walk(url, prefix + name + "/", depth: depth + 1)
                } else if stat.isRegularFile {
                    out.files.insert(prefix + name)
                } else {
                    out.skipped.append(prefix + name + " (not a regular file: not copied)")
                    if current { out.files.insert(prefix + name) }
                }
            }
        }
        try walk(root, "", depth: 0)
        out.skipped.sort()
        return out
    }

    /// Where a file's bytes are: `path` below `base`, read without following a link below `base`.
    struct Source {
        var base: URL
        var path: String

        init(base: URL, path: String) { self.base = base; self.path = path }
        /// A file version (the file itself).
        init(file: URL) { base = file.deletingLastPathComponent(); path = file.lastPathComponent }

        func read(maxBytes: Int) throws -> Data { try BoundedRead.contents(under: base, path, maxBytes: maxBytes) }
        func open() throws -> FileHandle { try BoundedRead.openRegularFile(under: base, path) }
    }

    /// Mutable files are small (`vault.json`, settings, summaries); anything larger is taken as differing.
    static let maxCompareBytes = 64 << 20

    static func sameBytes(_ a: Source, _ b: Source) -> Bool {
        guard let x = try? a.read(maxBytes: maxCompareBytes), let y = try? b.read(maxBytes: maxCompareBytes) else { return false }
        return x == y
    }

    // MARK: Merge

    /// How `merge` runs.
    public struct MergeOptions: Sendable {
        /// Only report what would be done; nothing is written in the vault, the quarantine or the provider, nothing
        /// resolved (files are checked from a private temporary copy, removed at the end).
        public var dryRun = false
        /// Remove each version once resolved (`NSFileVersion.remove`); otherwise they are only marked resolved. A
        /// version with a file that went only to the quarantine (or was not placed) is never removed.
        public var removeVersions = false
        /// Where files that fail their check (`<quarantine>/<version>/<path>`) and the mutable files of the versions
        /// (`<quarantine>/kept/<version>/<path>`) are copied, with `report.json`. Never inside the vault; a real run
        /// refuses one that is not empty.
        public var quarantine: URL
        /// Where files are staged to be checked (removed at the end); nil: a new folder in the temporary directory.
        public var staging: URL?
        /// How long a plain folder's `.sempere-lock` is waited for.
        var lockTimeout: TimeInterval = 30
        /// Tests: replaces the received-file check of a staged file.
        var checkOverride: (@Sendable (_ path: String, _ kind: FileKind, _ staged: URL) throws -> Void)?

        public init(quarantine: URL, dryRun: Bool = false, removeVersions: Bool = false, staging: URL? = nil) {
            self.quarantine = quarantine; self.dryRun = dryRun; self.removeVersions = removeVersions; self.staging = staging
        }
    }

    /// What `merge` did (or, `dryRun`, would do).
    public struct MergeReport: Codable, Hashable, Sendable {
        public var dryRun = false
        /// Write-once files copied into the vault folder, sorted.
        public var copied: [String] = []
        /// Write-once files that failed their check (path → one `version: why` per version): copied into the
        /// quarantine, never placed.
        public var quarantined: [String: [String]] = [:]
        /// Write-once files the acceptance rule sets aside (an earlier key it does not take): kept in the vault's
        /// set-aside store, never placed, never quarantined (key-hierarchy design §5.3).
        public var setAside: [String] = []
        /// Mutable or unknown files of the versions copied aside into `<quarantine>/kept/`.
        public var keptAside: [String] = []
        /// Unknown files only a version holds (format.md §1): not known to be write-once, so never placed; kept aside
        /// in `<quarantine>/kept/` for a person to look at. Sorted.
        public var keptUnknown: [String] = []
        /// Mutable files written by a rule: `vault.json` (a later version by home), `settings.age` (merged per key).
        public var written: [String] = []
        /// Mutable files of versions settled by a rule (path → how).
        public var settled: [String: String] = [:]
        /// Files left as they are and reported (path → one `version: why` per version): their versions stay unresolved.
        public var unsettled: [String: [String]] = [:]
        /// Versions marked resolved (ids), and removed (`removeVersions`).
        public var resolved: [String] = []
        public var removed: [String] = []
        /// Versions left unresolved (ids).
        public var left: [String] = []
        /// Failures that leave a version unresolved (path → one `version: message` per version).
        public var errors: [String: [String]] = [:]
        /// The quarantine folder, when anything went there.
        public var quarantine: String?
        /// The inspection the merge worked from (made inside the merge's write).
        public var inspection: Inspection

        /// Everything was merged and every version resolved.
        public var isComplete: Bool {
            left.isEmpty && errors.isEmpty && unsettled.isEmpty && quarantined.isEmpty && keptUnknown.isEmpty
                && inspection.versions.allSatisfy(\.skipped.isEmpty)
        }
    }

    /// Errors from `merge`.
    public enum MergeError: Error, Hashable, Sendable, CustomStringConvertible {
        /// The quarantine folder is inside the vault folder.
        case quarantineInsideVault(String)
        /// The quarantine folder holds files already (a real run starts from an empty one, so nothing is mixed).
        case quarantineNotEmpty(String)
        /// Another writer holds the plain folder's `.sempere-lock`.
        case busy(String)

        public var description: String {
            switch self {
            case .quarantineInsideVault(let p): return "the quarantine folder \(p) is inside the vault folder"
            case .quarantineNotEmpty(let p): return "the quarantine folder \(p) is not empty: name a new one"
            case .busy(let p): return "another writer holds \(p)'s lock: quit Sempere and other sempere commands, then run again"
            }
        }
    }

    /// The path of `url` with symbolic links resolved, including those of a folder above a part that does not exist yet.
    static func canonical(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var out = URL(fileURLWithPath: existing.canonicalPath)
        for part in rest { out.appendPathComponent(part) }
        return out.standardizedFileURL.path
    }

    /// Merges the folder's conflict versions back (see the top of the file). `vault` is the vault opened at `folder`;
    /// a real run needs it writable (a device key, a trusted list), a dry run reads only (locked: structural checks).
    ///
    /// - Throws: what `Vault.requireWritable` throws (a real run), `MergeError`, `ListingError` (the current folder);
    ///   per-file failures are reported, never thrown.
    public static func merge(folder: URL, provider: any FolderProvider, vault: Vault,
                             options: MergeOptions) throws -> MergeReport {
        if !options.dryRun {
            try vault.requireNotReadOnly()
            guard vault.canRead else { throw VaultError.locked }
            try vault.requireWritable()
        }
        let q = canonical(options.quarantine), f = canonical(folder)
        if q == f || q.hasPrefix(f + "/") { throw MergeError.quarantineInsideVault(q) }
        if !options.dryRun, let entries = try? FileManager.default.contentsOfDirectory(atPath: options.quarantine.path),
           !entries.isEmpty {
            throw MergeError.quarantineNotEmpty(options.quarantine.path)
        }
        let staging = options.staging ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("sempere-conflicts-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileIO.createPrivateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }

        var m = Merger(folder: folder, provider: provider, vault: vault, options: options, staging: staging,
                       report: MergeReport(dryRun: options.dryRun,
                                           inspection: Inspection(folder: folder.path, provider: provider.name, versions: [])))
        if options.dryRun {
            try m.run()
        } else {
            try withBaseWrite(folder, provider, timeout: options.lockTimeout) { try m.run() }
        }
        return m.report
    }

    /// Runs `body` holding one write of the vault folder: a coordinated write in a provider's folder (nothing inside may
    /// coordinate again), the folder's `.sempere-lock` in a plain one (as `FolderRemote.locked`).
    static func withBaseWrite<T>(_ folder: URL, _ provider: any FolderProvider, timeout: TimeInterval,
                                 _ body: () throws -> T) throws -> T {
        if provider.managesFiles { return try provider.coordinatedWrite(folder, body) }
        let lock = VaultFileLock.at(folder.appendingPathComponent(FolderRemote.lockName), kind: "folder")
        do {
            return try lock.withLock(timeout: timeout, body)
        } catch VaultFileLock.LockError.timedOut, VaultFileLock.LockError.suspended {
            throw MergeError.busy(folder.path)
        }
    }

    /// One merge's state.
    struct Merger {
        let folder: URL
        let provider: any FolderProvider
        var vault: Vault
        let options: MergeOptions
        let staging: URL
        var report: MergeReport
        /// Version ids that may not be resolved (an error, a pending or unsettled file).
        var blocked = Set<String>()
        /// Version ids that may be marked resolved but never removed (a file only the quarantine has, an unknown file
        /// not placed, a link not followed).
        var keep = Set<String>()
        var tags: [String: String] = [:]
        var placed = Set<String>()
        var staged = 0
        /// `vault.json` versions that are later versions by home in this epoch: (version id, bytes).
        var laterManifests: [(id: String, data: Data)] = []
        /// The versions' settings merged per key (not yet with the current file).
        var versionSettings: SharedSettings?
        var settingsVersions: [String] = []

        var fm: FileManager { .default }

        mutating func run() throws {
            if !options.dryRun {
                // Inside the write: vault.json as it is now, checked again (S5).
                vault = try vault.reopened()
                try vault.requireWritable()
            }
            report.inspection = try inspect(folder: folder, provider: provider)
            let versions = report.inspection.versions
            var usable: [(Version, URL)] = []
            for (index, v) in versions.enumerated() {
                tags[v.id] = Self.tag(index, v)
                if !v.skipped.isEmpty { keep.insert(v.id) }
                if let problem = v.problem {
                    fail(v.id, Self.itemName(v), problem)
                    continue
                }
                let itemURL = v.item.isEmpty ? folder : folder.appendingPathComponent(v.item)
                guard let root = provider.versionFile(of: itemURL, id: v.id) else {
                    fail(v.id, Self.itemName(v), "the version is gone")
                    continue
                }
                usable.append((v, root))
            }
            // Pass 1: every version's epoch records, then the vault reopened, so files under a new key are judged
            // under it (design §5.3).
            var placedRecord = false
            for (v, root) in usable {
                for path in (v.missing[FileKind.epoch.rawValue] ?? []).sorted() {
                    if placeWriteOnce(path, .epoch, from: source(v, root, path), version: v.id) { placedRecord = true }
                }
            }
            if placedRecord, !options.dryRun {
                do { vault = try vault.reopened() } catch {
                    for (v, _) in usable { fail(v.id, Vault.manifestName, "cannot reopen the vault after placing epoch records: \(error)") }
                    usable = []
                }
            }
            // Pass 2: the other files.
            for (v, root) in usable {
                for path in v.missing.filter({ $0.key != FileKind.epoch.rawValue }).values.flatMap({ $0 }).sorted() {
                    guard let kind = VaultFolderConflicts.kind(of: path) else { continue }
                    if kind.isWriteOnce {
                        placeWriteOnce(path, kind, from: source(v, root, path), version: v.id)
                    } else {
                        settleMutable(path, kind, from: source(v, root, path), version: v.id, currentExists: false)
                    }
                }
                for path in v.differing {
                    guard let kind = VaultFolderConflicts.kind(of: path) else { continue }
                    settleMutable(path, kind, from: source(v, root, path), version: v.id, currentExists: true)
                }
            }
            finishSettings()
            finishManifest()
            resolve(versions)
            report.copied = placed.sorted()
            report.keptAside.sort()
            report.keptUnknown = Set(report.keptUnknown).sorted()
            report.setAside = Set(report.setAside).sorted()
            if !options.dryRun, !report.quarantined.isEmpty || !report.keptAside.isEmpty {
                report.quarantine = options.quarantine.path
                writeReportFile()
            }
        }

        /// A file's version holds one file; the folder's, files at their paths.
        func source(_ v: Version, _ root: URL, _ path: String) -> Source {
            v.item.isEmpty ? Source(base: root, path: path) : Source(file: root)
        }

        static func itemName(_ v: Version) -> String { v.item.isEmpty ? "(vault folder)" : v.item }

        static func tag(_ index: Int, _ v: Version) -> String {
            let device = (v.device ?? "unknown").map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let n = String(index + 1)
            return String(repeating: "0", count: max(0, 2 - n.count)) + n + "-" + String(device.prefix(40))
        }

        func tag(_ version: String) -> String { tags[version] ?? version }

        mutating func fail(_ version: String, _ path: String, _ message: String) {
            report.errors[path, default: []].append("\(tag(version)): \(message)")
            blocked.insert(version)
        }

        mutating func unsettle(_ version: String, _ path: String, _ why: String) {
            report.unsettled[path, default: []].append("\(tag(version)): \(why)")
            blocked.insert(version)
        }

        // MARK: write-once files

        /// Places one missing write-once file; true when it was placed (or, dry run, would be).
        @discardableResult
        mutating func placeWriteOnce(_ path: String, _ kind: FileKind, from: Source, version: String) -> Bool {
            if placed.contains(path) { return false }   // an earlier version brought it
            let dest = folder.appendingPathComponent(path)
            let present = FolderRemote.lstatItem(dest)
            if present.stat != nil || present.isLink
                || FolderRemote.lstatItem(dest.deletingLastPathComponent()
                    .appendingPathComponent(UbiquitousPlaceholder.standInName(for: dest.lastPathComponent))).stat != nil {
                report.settled[path] = "already in the folder"
                return false
            }
            let name = dest.lastPathComponent
            if kind == .passphraseCopy, Vault.passphraseCopyFingerprint(name) != vault.manifest.recoveryFingerprint {
                // A retired kit's copy (format.md §15.11): a kit replacement deleted it on purpose.
                keepAside(from, path, version: version)
                report.settled[path] = "a retired recovery kit's passphrase copy: kept aside, not copied back"
                return false
            }
            let file: URL
            do { file = try stage(from, name: name, maxBytes: Self.maxBytes(kind, name)) } catch let e as IncomingFileProblem {
                quarantine(from, path, version: version, why: e.reason)
                return false
            } catch {
                fail(version, path, "cannot read it from the version: \(error)")
                return false
            }
            do {
                if let override = options.checkOverride { try override(path, kind, file) } else { try check(path, kind, file) }
            } catch let p as IncomingFileProblem where p.pending {
                unsettle(version, path, "waits for a device-change record (\(p.reason)): left with its version")
                return false
            } catch let p as IncomingFileProblem where p.setAside != nil {
                setAside(file, path, reason: p.setAside ?? .notSealed, version: version)
                return false
            } catch let e as VaultError {
                // The vault cannot judge it now (a tampered list, an I/O failure): neither placed nor quarantined.
                fail(version, path, "\(e)")
                return false
            } catch {
                quarantine(from, path, version: version, why: "\(error)")
                return false
            }
            if options.dryRun {
                placed.insert(path)
                return true
            }
            do {
                try vault.requireWritable()
                if try Self.placeNew(file, at: dest) {
                    placed.insert(path)
                    return true
                }
                report.settled[path] = "already in the folder (it appeared during the merge)"
            } catch {
                fail(version, path, "cannot copy: \(error)")
            }
            return false
        }

        static func maxBytes(_ kind: FileKind, _ name: String) -> Int {
            switch kind {
            case .revision: return BoundedRead.maxRevisionBytes
            case .blob: return BoundedRead.maxBlobFileBytes
            case .inbox: return CaptureFile.parse(name: name).map { CaptureFile.maxSealedBytes($0.kind) } ?? 0
            case .epoch: return EpochRecord.maxBytes
            case .join: return JoinRequest.maxBytes
            case .notebook: return NotebookRecords.maxFileBytes
            case .passphraseCopy: return RecoveryPassphraseCopy.maxBytes
            case .manifest, .settings, .journal, .derived, .other: return maxCompareBytes
            }
        }

        /// Copies the file into a private folder of its own under its name (the inbox check reads it by name), with a
        /// no-follow read, at most `maxBytes`.
        ///
        /// - Throws: `IncomingFileProblem` when it is larger (its own fault), else the read's error.
        mutating func stage(_ from: Source, name: String, maxBytes: Int) throws -> URL {
            staged += 1
            let dir = staging.appendingPathComponent(String(staged), isDirectory: true)
            try FileIO.createPrivateDirectory(dir)
            let to = dir.appendingPathComponent(name)
            let input = try from.open()
            defer { try? input.close() }
            var total = 0
            try FileIO.writeNewFile(to) { write in
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    total += chunk.count
                    guard total <= maxBytes else { throw IncomingFileProblem("larger than \(maxBytes) bytes") }
                    try write(chunk)
                }
            }
            return to
        }

        /// Places `file` (staged) at `dest` through a temporary name in its folder: never replaces anything. False when
        /// something is there already.
        static func placeNew(_ file: URL, at dest: URL) throws -> Bool {
            let dir = dest.deletingLastPathComponent()
            try FileIO.createDirectory(dir)
            let tmp = FileIO.tempURL(in: dir)
            let input = try BoundedRead.openRegularFile(file)
            defer { try? input.close() }
            try FileIO.writeNewFile(tmp) { write in
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try write(chunk) }
            }
            do { try FileIO.placeNew(tmp, at: dest) } catch VaultError.alreadyExists {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            return true
        }

        /// The received-file check of its kind (format.md §9.1) on the staged copy; throws `IncomingFileProblem` (or
        /// another error) for a file's own fault, `VaultError` when the vault cannot judge it.
        func check(_ path: String, _ kind: FileKind, _ file: URL) throws {
            let parts = path.split(separator: "/").map(String.init)
            let name = parts.last ?? path
            func data() throws -> Data { try BoundedRead.contents(of: file, maxBytes: Self.maxBytes(kind, name)) }
            switch kind {
            case .revision:
                guard let id = VaultFolderConflicts.noteId(parts[1]), let rev = RevisionName(name) else {
                    throw IncomingFileProblem("not a revision path")
                }
                try vault.checkIncomingRevision(try data(), noteId: id, name: rev)
            case .blob:
                try vault.checkIncomingBlob(at: file, fileName: name, note: VaultFolderConflicts.noteId(parts[1]))
            case .inbox:
                try vault.checkIncomingInboxFile(at: file, name: name)
            case .epoch:
                try Vault.checkIncomingEpochRecord(try data(), name: name)
            case .join:
                // Plaintext and untrusted (format.md §15.12): it must parse, be named after its own key and name this
                // vault (as `EpochSync` requires of one it downloads).
                let request = try JoinRequest.parse(try data())
                guard request.fileName == name else { throw IncomingFileProblem("not named after its own key") }
                guard request.vaultId == vault.vaultId else { throw IncomingFileProblem("a join request of another vault") }
            case .notebook:
                let bytes = try data()
                guard vault.canRead else { return }
                do { _ = try vault.openNotebookRecord(bytes, fileName: name) } catch NotebookRecordError.setAside(let r) {
                    throw IncomingFileProblem("set aside: \(r.text)", setAside: r)
                } catch NotebookRecordError.pending {
                    throw IncomingFileProblem("waits for a device-change record", pending: true)
                }
            case .passphraseCopy:
                try Vault.checkIncomingPassphraseCopy(try data(), name: name)
            case .manifest, .settings, .journal, .derived, .other:
                throw IncomingFileProblem("not a write-once file")
            }
        }

        mutating func quarantine(_ from: Source, _ path: String, version: String, why: String) {
            report.quarantined[path, default: []].append("\(tag(version)): \(why)")
            keep.insert(version)
            guard !options.dryRun else { return }
            do {
                try Self.copyAside(from, to: options.quarantine.appendingPathComponent(tag(version)).appendingPathComponent(path))
            } catch {
                fail(version, path, "cannot quarantine: \(error)")
            }
        }

        /// A file the acceptance rule sets aside: kept in the vault's set-aside store (never placed, never quarantined),
        /// and then settled.
        mutating func setAside(_ file: URL, _ path: String, reason: SetAsideReason, version: String) {
            guard let store = vault.setAsideStore else {
                fail(version, path, "set aside by the acceptance rule (\(reason.text)), and this run has no set-aside store")
                return
            }
            if !options.dryRun {
                do { try store.keep(file: file, path: path, vaultId: vault.vaultId, reason: reason) } catch {
                    fail(version, path, "cannot keep it set aside: \(error)")
                    return
                }
            }
            report.setAside.append(path)
        }

        // MARK: mutable files

        mutating func settleMutable(_ path: String, _ kind: FileKind, from: Source, version: String, currentExists: Bool) {
            switch kind {
            case .derived:
                report.settled[path] = currentExists ? "rewritten by every writer: the current one stays"
                    : "rewritten by every writer: the next sync writes it"
            case .manifest:
                keepAside(from, path, version: version)
                judgeManifest(path, from: from, version: version)
            case .settings:
                keepAside(from, path, version: version)
                judgeSettings(path, from: from, version: version)
            case .journal:
                keepAside(from, path, version: version)
                unsettle(version, path, "a re-encryption journal differs: kept aside for review, never picked")
            default:
                keepAside(from, path, version: version)
                if currentExists {
                    report.settled[path] = "an unknown file that differs: the current one stays, the version's is kept aside"
                } else {
                    // Unknown files are never deleted (format.md §1), but nothing says they are write-once: not placed.
                    report.keptUnknown.append(path)
                    keep.insert(version)
                }
            }
        }

        mutating func keepAside(_ from: Source, _ path: String, version: String) {
            report.keptAside.append("\(tag(version))/\(path)")
            guard !options.dryRun else { return }
            do {
                try Self.copyAside(from, to: options.quarantine.appendingPathComponent("kept").appendingPathComponent(tag(version))
                    .appendingPathComponent(path))
            } catch {
                fail(version, path, "cannot keep aside: \(error)")
            }
        }

        /// `vault.json`, judged by `Vault.judgeIncoming` against the one on disk now: the same (or label only) and an
        /// earlier one are settled; a later version by home in the same epoch is a candidate (`finishManifest`);
        /// anything else (another epoch, a conflict, refused, waiting) is left (design §5.1: never merged, never picked).
        mutating func judgeManifest(_ path: String, from: Source, version: String) {
            guard let theirs = try? from.read(maxBytes: BoundedRead.maxManifestBytes) else {
                unsettle(version, path, "a version of vault.json cannot be read")
                return
            }
            let local = try? BoundedRead.contents(under: folder, Vault.manifestName, maxBytes: BoundedRead.maxManifestBytes)
            switch vault.judgeIncoming(theirs, local: local) {
            case .same:
                report.settled[path] = "the same vault.json (or only its label differs)"
            case .behind:
                report.settled[path] = "an earlier vault.json: the current one is later"
            case .later:
                if (try? Vault.readManifest(theirs))?.epochId == vault.manifest.epochId {
                    laterManifests.append((version, theirs))
                } else {
                    unsettle(version, path, "a vault.json of a later epoch: only a sync takes another epoch (its record "
                        + "first); left")
                }
            case .laterRecordPending:
                unsettle(version, path, "a vault.json of a later epoch whose record has not arrived: left")
            case .waiting(let why), .unlisted(let why), .conflict(let why), .refused(let why):
                unsettle(version, path, "another vault.json, not taken: \(why)")
            }
        }

        /// The later versions by home: one of them later than every other is taken (written last), else none.
        mutating func finishManifest() {
            guard !laterManifests.isEmpty else { return }
            let path = Vault.manifestName
            let parsed = laterManifests.compactMap { c in (try? Vault.readManifest(c.data)).map { (c.id, c.data, $0) } }
            let latest = parsed.first { c in
                parsed.allSatisfy { o in o.1 == c.1 || vault.isLaterVersion(c.2, of: o.2) }
            }
            guard let latest else {
                for c in laterManifests { unsettle(c.id, path, "several later versions of vault.json that do not follow each other") }
                return
            }
            if !options.dryRun {
                let dest = folder.appendingPathComponent(path)
                do {
                    try vault.requireWritable()
                    // Judged again against the file on disk right now (still inside the merge's write).
                    let local = try BoundedRead.contents(under: folder, path, maxBytes: BoundedRead.maxManifestBytes)
                    guard vault.judgeIncoming(latest.1, local: local) == .later else {
                        for c in laterManifests { unsettle(c.id, path, "vault.json changed during the merge: left") }
                        return
                    }
                    try FileIO.writeAtomically(latest.1, to: dest, replacing: true)
                } catch {
                    for c in laterManifests { fail(c.id, path, "cannot write vault.json: \(error)") }
                    return
                }
            }
            report.written.append(path)
            report.settled[path] = "a later version by home taken (design §5.1)"
        }

        /// `settings.age`: each version's merged per key (format.md §13.3) once the vault is unlocked by a device key;
        /// pending, set-aside and newer-reader versions leave their version unresolved.
        mutating func judgeSettings(_ path: String, from: Source, version: String) {
            guard vault.canRead, !vault.isRecoveryOpen else {
                unsettle(version, path, vault.isRecoveryOpen
                         ? "settings.age differs: merging writes it, and the recovery key never writes"
                         : "settings.age differs: merging it needs the vault's key")
                return
            }
            guard let data = try? from.read(maxBytes: SharedSettings.maxFileBytes) else {
                unsettle(version, path, "a version of settings.age cannot be read")
                return
            }
            do {
                let theirs = SharedSettingsMigrations.migrated(try vault.openSharedSettings(data).settings)
                versionSettings = versionSettings.map { $0.merging(theirs) } ?? theirs
                settingsVersions.append(version)
            } catch SharedSettingsError.needsNewerReader {
                unsettle(version, path, "a version of settings.age needs a newer reader: left")
            } catch SharedSettingsError.pending {
                unsettle(version, path, "a version of settings.age waits for a device-change record: left")
            } catch SharedSettingsError.setAside(let r) {
                unsettle(version, path, "a version of settings.age under an earlier key (\(r.text)): kept aside, left")
            } catch {
                // Another vault's, or damaged: not settings of this vault (the engine's rule); kept aside above.
                report.settled[path] = "a version that is not this vault's settings (damaged or another vault's): kept aside"
            }
        }

        /// Writes the versions' settings merged with the file on disk just before writing (`updateSharedSettings`),
        /// only when the current file reads (or is absent) and `vault.json` on disk is still of this vault's epoch.
        mutating func finishSettings() {
            let path = SharedSettings.fileName
            guard !settingsVersions.isEmpty, let merged = versionSettings else { return }
            let current: SharedSettings?
            do { current = try vault.readSharedSettings() } catch {
                for v in settingsVersions {
                    unsettle(v, path, "the current settings.age cannot be read (\(error)): never replaced; left")
                }
                return
            }
            let base = current ?? SharedSettings()
            if current != nil, base.merging(merged) == base {
                report.settled[path] = report.settled[path] ?? "the versions add nothing: merged per key, no change"
                return
            }
            if !options.dryRun {
                guard vault.keysMatchManifestOnDisk() else {
                    for v in settingsVersions {
                        unsettle(v, path, "vault.json on disk is of another epoch than this run's: run again; left")
                    }
                    return
                }
                do {
                    try vault.requireWritable()
                    try vault.updateSharedSettings { $0 = $0.merging(merged) }
                } catch {
                    for v in settingsVersions { fail(v, path, "cannot write the merged settings: \(error)") }
                    return
                }
            }
            report.written.append(path)
            report.settled[path] = "merged per key (format.md §13.3)"
        }

        // MARK: resolving

        /// Resolves the versions that may be: without coordinating (the merge holds the folder's write).
        mutating func resolve(_ versions: [Version]) {
            var byItem: [String: Set<String>] = [:]
            for v in versions {
                if blocked.contains(v.id) { report.left.append(v.id) } else { byItem[v.item, default: []].insert(v.id) }
            }
            for (item, ids) in byItem.sorted(by: { $0.key < $1.key }) {
                let url = item.isEmpty ? folder : folder.appendingPathComponent(item)
                let removable = options.removeVersions ? ids.subtracting(keep) : []
                let markOnly = ids.subtracting(removable)
                if options.dryRun {
                    report.resolved += ids.sorted()
                    continue
                }
                do {
                    if !removable.isEmpty {
                        try provider.settleConflictVersions(of: url, ids: removable, remove: true)
                        report.removed += removable.sorted()
                    }
                    if !markOnly.isEmpty { try provider.settleConflictVersions(of: url, ids: markOnly, remove: false) }
                    report.resolved += ids.sorted()
                } catch {
                    report.errors[item.isEmpty ? "(vault folder)" : item, default: []].append("cannot resolve its versions: \(error)")
                    report.left += ids.subtracting(report.removed).sorted()
                    report.resolved += ids.intersection(report.removed).sorted()
                }
            }
        }

        // MARK: files outside the vault

        /// Copies `from` (no link followed) to `to`, a new file. A file already at `to` with the same bytes is kept;
        /// one with other bytes is an error (never overwritten, never taken for this one).
        static func copyAside(_ from: Source, to: URL) throws {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FolderRemote.lstatItem(to).stat != nil || FolderRemote.lstatItem(to).isLink {
                guard let a = try? from.read(maxBytes: maxCompareBytes),
                      let b = try? BoundedRead.contents(under: to.deletingLastPathComponent(), to.lastPathComponent,
                                                         maxBytes: maxCompareBytes), a == b else {
                    throw VaultError.alreadyExists("\(to.path) holds other bytes")
                }
                return
            }
            let input = try from.open()
            defer { try? input.close() }
            try FileIO.writeNewFile(to) { write in
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try write(chunk) }
            }
        }

        func writeReportFile() {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(report) else { return }
            try? fm.createDirectory(at: options.quarantine, withIntermediateDirectories: true)
            try? data.write(to: options.quarantine.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
