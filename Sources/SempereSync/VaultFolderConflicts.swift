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
// version the files the current folder lacks (by kind) and the mutable files that differ. `merge` (`sempere vault
// conflicts --merge`) copies back only missing WRITE-ONCE files (format.md §1.3: revisions, blobs, inbox files, epoch
// records, join requests, notebook records, the passphrase copy), each checked first as a received file (§9.1, under
// the vault's key) and placed through a temporary name that never replaces a file, in a coordinated write. A file that
// fails its check goes to the quarantine folder instead. Mutable files follow the rules the engine and `vault
// merge-copy` already use (`settings.age` merged per key; `vault.json` taken only as a later version by home, an older
// one is superseded; the web viewer's files and insights are rewritten by every writer), anything else is kept aside
// and reported, never picked. Versions are marked resolved only after everything they hold was placed, quarantined or
// settled; they are kept (the system's version browser still has them) unless `removeVersions`.

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
        return out.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Reports the folder's provider record and its unresolved conflict versions (see the top of the file). Reads only.
    public static func inspect(folder: URL, provider: any FolderProvider) -> Inspection {
        var inspection = Inspection(folder: folder.path, provider: provider.name, record: provider.itemRecord(of: folder),
                                    versions: [])
        let current = listFiles(folder, mapStandIns: true)
        for v in provider.conflictVersions(of: folder) {
            guard let root = provider.versionFile(of: folder, id: v.id) else { continue }
            let theirs = listFiles(root, mapStandIns: false)
            var missing: [String: [String]] = [:]
            var differing: [String] = []
            for path in theirs.sorted() {
                guard let kind = kind(of: path) else { continue }
                if !current.contains(path) {
                    missing[kind.rawValue, default: []].append(path)
                } else if !kind.isWriteOnce, kind != .derived,
                          !sameBytes(root.appendingPathComponent(path), folder.appendingPathComponent(path)) {
                    differing.append(path)
                }
            }
            inspection.versions.append(Version(id: v.id, item: "", modified: v.modified, device: v.device,
                                               files: theirs.count, missing: missing, differing: differing))
        }
        for path in versionedFiles(in: folder) {
            let url = folder.appendingPathComponent(path)
            for v in provider.conflictVersions(of: url) {
                guard let file = provider.versionFile(of: url, id: v.id) else { continue }
                let differs = kind(of: path) != .derived && !sameBytes(file, url)
                inspection.versions.append(Version(id: v.id, item: path, modified: v.modified, device: v.device, files: 1,
                                                   missing: [:], differing: differs ? [path] : []))
            }
        }
        return inspection
    }

    /// Every regular file below `root`, as relative paths; hidden names skipped, except that iCloud Drive's stand-ins
    /// (`.<name>.icloud`) count as the file they stand for when `mapStandIns`.
    static func listFiles(_ root: URL, mapStandIns: Bool) -> Set<String> {
        var out = Set<String>()
        func walk(_ dir: URL, _ prefix: String, depth: Int) {
            guard depth < 8, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if name.hasPrefix(".") {
                    if mapStandIns, !isDir.boolValue, let real = UbiquitousPlaceholder.realName(of: name) {
                        out.insert(prefix + real)
                    }
                    continue
                }
                if isDir.boolValue { walk(url, prefix + name + "/", depth: depth + 1) } else { out.insert(prefix + name) }
            }
        }
        walk(root, "", depth: 0)
        return out
    }

    /// Mutable files are small (`vault.json`, settings, summaries); anything larger is taken as differing.
    static let maxCompareBytes = 64 << 20

    static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? BoundedRead.contents(of: a, maxBytes: maxCompareBytes),
              let y = try? BoundedRead.contents(of: b, maxBytes: maxCompareBytes) else { return false }
        return x == y
    }

    // MARK: Merge

    /// How `merge` runs.
    public struct MergeOptions: Sendable {
        /// Only report what would be done; nothing is written, nothing resolved.
        public var dryRun = false
        /// Remove each version once resolved (`NSFileVersion.remove`); otherwise they are only marked resolved.
        public var removeVersions = false
        /// Where files that fail their check (`<quarantine>/<version>/<path>`) and the mutable files of the versions
        /// (`<quarantine>/kept/<version>/<path>`) are copied, with `report.json`. Never inside the vault.
        public var quarantine: URL

        public init(quarantine: URL, dryRun: Bool = false, removeVersions: Bool = false) {
            self.quarantine = quarantine; self.dryRun = dryRun; self.removeVersions = removeVersions
        }
    }

    /// What `merge` did (or, `dryRun`, would do).
    public struct MergeReport: Codable, Hashable, Sendable {
        public var dryRun = false
        /// Write-once files copied into the vault folder, sorted.
        public var copied: [String] = []
        /// Write-once files that failed their check (path → why): copied into the quarantine, never placed.
        public var quarantined: [String: String] = [:]
        /// Mutable or unknown files of the versions copied aside into `<quarantine>/kept/`.
        public var keptAside: [String] = []
        /// Mutable files written by a rule: `vault.json` (a later version by home), `settings.age` (merged per key).
        public var written: [String] = []
        /// Mutable files of versions settled by a rule (path → how).
        public var settled: [String: String] = [:]
        /// Mutable files left as they are and reported (path → why): their versions stay unresolved.
        public var unsettled: [String: String] = [:]
        /// Versions marked resolved (ids), and removed (`removeVersions`).
        public var resolved: [String] = []
        public var removed: [String] = []
        /// Versions left unresolved (ids).
        public var left: [String] = []
        /// Failures that leave a version unresolved (path → message).
        public var errors: [String: String] = [:]
        /// The quarantine folder, when anything went there.
        public var quarantine: String?
        /// The inspection the merge worked from.
        public var inspection: Inspection

        /// Everything was merged and every version resolved.
        public var isComplete: Bool { left.isEmpty && errors.isEmpty && unsettled.isEmpty && quarantined.isEmpty }
    }

    /// Errors from `merge`.
    public enum MergeError: Error, Hashable, Sendable, CustomStringConvertible {
        /// The quarantine folder is inside the vault folder.
        case quarantineInsideVault(String)

        public var description: String {
            switch self {
            case .quarantineInsideVault(let p): return "the quarantine folder \(p) is inside the vault folder"
            }
        }
    }

    /// Merges the folder's conflict versions back (see the top of the file). `vault` is the vault opened at `folder`;
    /// unlocked for a real run (each file is checked under its key), locked is enough for a dry run (structural checks).
    ///
    /// - Throws: `VaultError.locked` (a real run without the key), `VaultError.readOnly` (a vault of a newer format),
    ///   `MergeError`; per-file failures are reported, never thrown.
    public static func merge(folder: URL, provider: any FolderProvider, vault: Vault,
                             options: MergeOptions) throws -> MergeReport {
        if !options.dryRun {
            try vault.requireNotReadOnly()
            guard vault.canRead else { throw VaultError.locked }
        }
        let q = options.quarantine.standardizedFileURL.path, f = folder.standardizedFileURL.path
        if q == f || q.hasPrefix(f + "/") { throw MergeError.quarantineInsideVault(q) }

        var m = Merger(folder: folder, provider: provider, vault: vault, options: options,
                       report: MergeReport(dryRun: options.dryRun, inspection: inspect(folder: folder, provider: provider)))
        m.run()
        return m.report
    }

    /// One merge's state.
    struct Merger {
        let folder: URL
        let provider: any FolderProvider
        let vault: Vault
        let options: MergeOptions
        var report: MergeReport
        /// Version ids that may not be resolved (an error or an unsettled file).
        var blocked = Set<String>()
        var copied = Set<String>()
        /// `vault.json` versions that are later versions by home of the current one: (version id, bytes).
        var laterManifests: [(id: String, data: Data)] = []
        var mergedSettings: SharedSettings?
        var settingsChanged = false
        var settingsVersions: [String] = []

        var fm: FileManager { .default }

        mutating func run() {
            let versions = report.inspection.versions
            for (index, v) in versions.enumerated() {
                let itemURL = v.item.isEmpty ? folder : folder.appendingPathComponent(v.item)
                guard let root = provider.versionFile(of: itemURL, id: v.id) else {
                    fail(v.id, v.item.isEmpty ? "(vault folder)" : v.item, "the version is gone")
                    continue
                }
                let tag = Self.tag(index, v)
                // A file's version holds one file; the folder's, files at their paths.
                func source(_ path: String) -> URL { v.item.isEmpty ? root.appendingPathComponent(path) : root }
                let missing = v.missing.values.flatMap { $0 }.sorted()
                for path in missing {
                    guard let kind = VaultFolderConflicts.kind(of: path) else { continue }
                    if kind.isWriteOnce {
                        placeWriteOnce(path, kind, from: source(path), version: v.id, tag: tag)
                    } else {
                        settleMutable(path, kind, from: source(path), version: v.id, tag: tag, currentExists: false)
                    }
                }
                for path in v.differing {
                    guard let kind = VaultFolderConflicts.kind(of: path) else { continue }
                    settleMutable(path, kind, from: source(path), version: v.id, tag: tag, currentExists: true)
                }
            }
            finishSettings()
            finishManifest()
            resolve(versions)
            report.copied = copied.sorted()
            report.keptAside.sort()
            if !options.dryRun, !report.quarantined.isEmpty || !report.keptAside.isEmpty {
                report.quarantine = options.quarantine.path
                writeReportFile()
            }
        }

        static func tag(_ index: Int, _ v: Version) -> String {
            let device = (v.device ?? "unknown").map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let n = String(index + 1)
            return String(repeating: "0", count: max(0, 2 - n.count)) + n + "-" + String(device.prefix(40))
        }

        mutating func fail(_ version: String, _ path: String, _ message: String) {
            report.errors[path] = message
            blocked.insert(version)
        }

        // MARK: write-once files

        mutating func placeWriteOnce(_ path: String, _ kind: FileKind, from: URL, version: String, tag: String) {
            let dest = folder.appendingPathComponent(path)
            if copied.contains(path) || Vault.holds(dest) { return }   // an earlier version brought it
            do {
                try check(path, kind, from)
            } catch let e as VaultError {
                // The vault cannot judge it now (a tampered list, an I/O failure): neither placed nor quarantined.
                fail(version, path, "\(e)")
                return
            } catch {
                report.quarantined[path] = "\(error)"
                if !options.dryRun {
                    do { try copyAside(from, to: options.quarantine.appendingPathComponent(tag).appendingPathComponent(path)) } catch {
                        fail(version, path, "cannot quarantine: \(error)")
                    }
                }
                return
            }
            if options.dryRun {
                copied.insert(path)
                return
            }
            do {
                try provider.coordinatedWrite(dest) { try Vault.copyNew(from, to: dest) }
                copied.insert(path)
            } catch {
                fail(version, path, "cannot copy: \(error)")
            }
        }

        /// The received-file check of its kind (format.md §9.1); throws `IncomingFileProblem` (or another error) for
        /// a file's own fault, `VaultError` when the vault cannot judge it.
        func check(_ path: String, _ kind: FileKind, _ from: URL) throws {
            let parts = path.split(separator: "/").map(String.init)
            let name = parts.last ?? path
            switch kind {
            case .revision:
                guard let id = VaultFolderConflicts.noteId(parts[1]), let rev = RevisionName(name) else {
                    throw IncomingFileProblem("not a revision path")
                }
                let data = try BoundedRead.contents(of: from, maxBytes: BoundedRead.maxRevisionBytes)
                try vault.checkIncomingRevision(data, noteId: id, name: rev)
            case .blob:
                try vault.checkIncomingBlob(at: from, fileName: name, note: VaultFolderConflicts.noteId(parts[1]))
            case .inbox:
                try vault.checkIncomingInboxFile(at: from, name: name)
            case .epoch:
                try Vault.checkIncomingEpochRecord(try BoundedRead.contents(of: from, maxBytes: EpochRecord.maxBytes), name: name)
            case .join:
                _ = try JoinRequest.parse(try BoundedRead.contents(of: from, maxBytes: JoinRequest.maxBytes))
            case .notebook:
                let data = try BoundedRead.contents(of: from, maxBytes: NotebookRecords.maxFileBytes)
                if vault.canRead { _ = try vault.openNotebookRecord(data, fileName: name) }
            case .passphraseCopy:
                try Vault.checkIncomingPassphraseCopy(try BoundedRead.contents(of: from, maxBytes: BoundedRead.maxSmallFileBytes),
                                                      name: name)
            case .manifest, .settings, .journal, .derived, .other:
                throw IncomingFileProblem("not a write-once file")
            }
        }

        // MARK: mutable files

        mutating func settleMutable(_ path: String, _ kind: FileKind, from: URL, version: String, tag: String,
                                    currentExists: Bool) {
            if kind == .derived {
                report.settled[path] = currentExists ? "rewritten by every writer: the current one stays"
                    : "rewritten by every writer: the next sync writes it"
                return
            }
            keepAside(from, path, tag: tag, version: version)
            switch kind {
            case .manifest: judgeManifest(path, from: from, version: version)
            case .settings: judgeSettings(path, from: from, version: version)
            case .journal:
                unsettle(version, path, "a re-encryption journal differs: kept aside for review, never picked")
            default:
                report.settled[path] = "not a file this version knows: kept aside (\(tag))"
            }
        }

        mutating func unsettle(_ version: String, _ path: String, _ why: String) {
            report.unsettled[path] = why
            blocked.insert(version)
        }

        mutating func keepAside(_ from: URL, _ path: String, tag: String, version: String) {
            report.keptAside.append("\(tag)/\(path)")
            guard !options.dryRun else { return }
            do { try copyAside(from, to: options.quarantine.appendingPathComponent("kept").appendingPathComponent(tag)
                                .appendingPathComponent(path)) } catch {
                fail(version, path, "cannot keep aside: \(error)")
            }
        }

        /// `vault.json`: the same (or label only) is settled; a later version by home is a candidate (`finishManifest`);
        /// one the current is a later version of, or of an earlier epoch of the same vault, is superseded; anything else
        /// is left (design §5.1: never merged, never picked).
        mutating func judgeManifest(_ path: String, from: URL, version: String) {
            guard let theirs = try? BoundedRead.contents(of: from, maxBytes: BoundedRead.maxManifestBytes) else {
                unsettle(version, path, "a version of vault.json cannot be read")
                return
            }
            let current = try? BoundedRead.contents(of: folder.appendingPathComponent(Vault.manifestName),
                                                    maxBytes: BoundedRead.maxManifestBytes)
            if let current, theirs == current || EpochManifest.sameExceptLabel(theirs, current) {
                report.settled[path] = "the same vault.json (or only its label differs)"
                return
            }
            guard vault.canRead else {
                unsettle(version, path, "vault.json differs: judging it needs the vault's key")
                return
            }
            if vault.laterVersion(theirs) != nil {
                laterManifests.append((version, theirs))
                return
            }
            if let m = try? Vault.readManifest(theirs), m.vaultId == vault.vaultId, m.root == vault.manifest.root,
               vault.listStatus.problem == nil,
               m.epoch < vault.manifest.epoch || vault.isLaterVersion(vault.manifest, of: m) {
                report.settled[path] = "an earlier vault.json (epoch \(m.epoch), \(m.keys.count) keys): the current one is later"
                return
            }
            unsettle(version, path, "another vault.json that is neither earlier nor a later version by home: both kept, "
                + "nothing picked (design §5.1)")
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
            if vault.isRecoveryOpen {
                for c in laterManifests {
                    unsettle(c.id, path, "a later vault.json by home: the recovery key never writes; run again with the device key")
                }
                return
            }
            if !options.dryRun {
                let dest = folder.appendingPathComponent(path)
                do {
                    try provider.coordinatedWrite(dest) { try FileIO.writeAtomically(latest.1, to: dest, replacing: true) }
                } catch {
                    for c in laterManifests { fail(c.id, path, "cannot write vault.json: \(error)") }
                    return
                }
            }
            report.written.append(path)
            report.settled[path] = "a later version by home taken (design §5.1)"
        }

        /// `settings.age`: merged per key (format.md §13.3) once the vault is unlocked by a device key.
        mutating func judgeSettings(_ path: String, from: URL, version: String) {
            guard vault.canRead, !vault.isRecoveryOpen else {
                unsettle(version, path, vault.isRecoveryOpen
                         ? "settings.age differs: merging writes it, and the recovery key never writes"
                         : "settings.age differs: merging it needs the vault's key")
                return
            }
            guard let data = try? BoundedRead.contents(of: from, maxBytes: SharedSettings.maxFileBytes) else {
                unsettle(version, path, "a version of settings.age cannot be read")
                return
            }
            do {
                let theirs = SharedSettingsMigrations.migrated(try vault.openSharedSettings(data).settings)
                if mergedSettings == nil, settingsVersions.isEmpty { mergedSettings = try? vault.readSharedSettings() }
                let before = mergedSettings
                mergedSettings = mergedSettings.map { $0.merging(theirs) } ?? theirs
                if mergedSettings != before { settingsChanged = true }
                settingsVersions.append(version)
            } catch SharedSettingsError.needsNewerReader {
                unsettle(version, path, "a version of settings.age needs a newer reader: left")
            } catch {
                // Another vault's, or damaged: not settings of this vault (the engine's rule); kept aside above.
                report.settled[path] = "a version that is not this vault's settings (damaged or another vault's): kept aside"
            }
        }

        mutating func finishSettings() {
            let path = SharedSettings.fileName
            guard !settingsVersions.isEmpty else { return }
            guard settingsChanged, let merged = mergedSettings else {
                report.settled[path] = report.settled[path] ?? "the versions add nothing: merged per key, no change"
                return
            }
            if !options.dryRun {
                do {
                    try provider.coordinatedWrite(folder.appendingPathComponent(path)) { try vault.writeSharedSettings(merged) }
                } catch {
                    for v in settingsVersions { fail(v, path, "cannot write the merged settings: \(error)") }
                    return
                }
            }
            report.written.append(path)
            report.settled[path] = "merged per key (format.md §13.3)"
        }

        // MARK: resolving

        mutating func resolve(_ versions: [Version]) {
            var byItem: [String: Set<String>] = [:]
            for v in versions {
                if blocked.contains(v.id) { report.left.append(v.id) } else { byItem[v.item, default: []].insert(v.id) }
            }
            for (item, ids) in byItem.sorted(by: { $0.key < $1.key }) {
                let url = item.isEmpty ? folder : folder.appendingPathComponent(item)
                if options.dryRun {
                    report.resolved += ids.sorted()
                    continue
                }
                do {
                    if options.removeVersions {
                        try provider.resolveConflicts(of: url, ids: ids)
                        report.removed += ids.sorted()
                    } else {
                        try provider.markConflictsResolved(of: url, ids: ids)
                    }
                    report.resolved += ids.sorted()
                } catch {
                    report.errors[item.isEmpty ? "(vault folder)" : item] = "cannot resolve its versions: \(error)"
                    report.left += ids.sorted()
                }
            }
        }

        // MARK: files outside the vault

        func copyAside(_ from: URL, to: URL) throws {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { return }
            try fm.copyItem(at: from, to: to)
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
