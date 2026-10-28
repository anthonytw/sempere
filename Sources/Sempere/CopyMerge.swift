import Foundation

// MARK: - Merging another copy of the vault (format.md §1.3)

/// What merging another copy of the vault into it did (or would do, `dryRun`).
public struct CopyMergeReport: Hashable, Sendable, Codable {
    /// Files copied in (or that would be), as paths relative to the vault, sorted.
    public var added: [String] = []
    /// Write-once files both copies hold under one name with different bytes:
    /// the vault's own is kept.
    public var differing: [String] = []
    /// Files of the other copy that failed the received-file checks (§9.1),
    /// with why; never copied.
    public var refused: [String: String] = [:]
    /// `settings.age` was merged per key (§13.3) and the merge written.
    public var settingsMerged = false
    /// The other copy's `settings.age` differs and could not be merged now
    /// (the vault is locked, or one of the files does not verify).
    public var settingsPending: String?
    /// The other copy's `vault.json` differs from the vault's and was not taken: the vault's own is
    /// kept (format.md §1.3).
    public var manifestDiffers = false
    /// The other copy's `vault.json` was a later version of the vault's own by its home (the same
    /// epoch, verified, its list holding the vault's: design §5.1) and was taken.
    public var manifestUpdated = false

    public init() {}

    /// Nothing was (or would be) copied or merged, and nothing differs.
    public var isEmpty: Bool {
        added.isEmpty && differing.isEmpty && refused.isEmpty && !settingsMerged && settingsPending == nil && !manifestDiffers
            && !manifestUpdated
    }
}

/// Errors from `Vault.mergeCopy`.
public enum CopyMergeError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The other folder holds no readable `vault.json`.
    case notAVault(String)
    /// The other folder is a copy of a different vault.
    case otherVault(UUID)

    public var description: String {
        switch self {
        case .notAVault(let why): return "not a copy of a vault: \(why)"
        case .otherVault(let id): return "a copy of another vault (\(id.uuidString.lowercased()))"
        }
    }
}

extension Vault {
    /// Merges `other`, another copy of this vault (the same `vaultId`), into
    /// this one (format.md §1.3): every write-once file the vault lacks is
    /// copied in after the received-file checks (§9.1): revisions and blobs
    /// under `notes/`, capture inbox files (§11), epoch records (`epochs/`), join requests (`joins/`)
    /// and the passphrase copy under `keys/`. `settings.age` is merged per key (§13.3) when the vault is
    /// unlocked and both copies verify. `vault.json` is taken from `other` only when it is a later
    /// version by the vault's home of the one here (one writer, design §5.1: the same epoch, every check
    /// passes, and its list holds this one's); otherwise the vault's own stays and a difference is
    /// reported. The two are never merged. Nothing is ever deleted or overwritten, so merging is
    /// idempotent and merging any number of copies in any order gives the same
    /// files. A file the vault already holds as an iCloud Drive placeholder
    /// (`.<name>.icloud`) counts as held.
    ///
    /// Revisions a compaction deleted here and the other copy still holds come
    /// back: they are covered by the snapshot that let them go, so the notes
    /// read the same, and the next compaction or thinning deletes them again.
    ///
    /// - Throws: `CopyMergeError` when `other` is not a copy of this vault;
    ///   `VaultError.readOnly` for a vault of a newer format (§7.3); I/O errors.
    @discardableResult
    public func mergeCopy(from other: URL, dryRun: Bool = false) throws -> CopyMergeReport {
        try requireNotReadOnly()
        let otherManifestURL = other.appendingPathComponent(Self.manifestName)
        let otherManifestData: Data
        do { otherManifestData = try BoundedRead.contents(of: otherManifestURL, maxBytes: BoundedRead.maxManifestBytes) } catch {
            throw CopyMergeError.notAVault("\(error)")
        }
        let otherManifest: EpochManifest
        do { otherManifest = try Self.readManifest(otherManifestData) } catch {
            throw CopyMergeError.notAVault("\(error)")
        }
        guard otherManifest.vaultId == vaultId else { throw CopyMergeError.otherVault(otherManifest.vaultId) }

        var report = CopyMergeReport()
        let ownManifest = try? FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes)
        if let ownManifest, !EpochManifest.sameExceptLabel(ownManifest, otherManifestData) {
            if laterVersion(otherManifestData) != nil {
                report.manifestUpdated = true
                if !dryRun { try FileIO.writeAtomically(otherManifestData, to: manifestURL, replacing: true) }
            } else {
                report.manifestDiffers = true
            }
        }

        // epochs/<record>, joins/<request>: write-once, so the union (bounded; their readers check them).
        for (folder, limit, valid) in [(Self.epochsName, EpochRecord.maxBytes, { (n: String) in n.hasSuffix(".epoch.age") }),
                                       (Self.joinsName, JoinRequest.maxBytes, { (n: String) in n.hasSuffix(".join.json") })] {
            let from = other.appendingPathComponent(folder, isDirectory: true)
            for name in Self.visibleEntries(from) where valid(name) {
                let to = url.appendingPathComponent(folder).appendingPathComponent(name)
                if Self.holds(to) { continue }
                if let size = FileIO.size(from.appendingPathComponent(name)), size > Int64(limit) {
                    report.refused["\(folder)/\(name)"] = "too large"
                    continue
                }
                report.added.append("\(folder)/\(name)")
                if !dryRun { try Self.copyNew(from.appendingPathComponent(name), to: to) }
            }
        }

        // notes/<id>/<revision> and notes/<id>/att/<blob>
        let otherNotes = other.appendingPathComponent(Self.notesName, isDirectory: true)
        for dir in Self.visibleEntries(otherNotes) {
            guard let noteId = UUID(uuidString: dir), dir == dir.lowercased() else { continue }
            let source = otherNotes.appendingPathComponent(dir, isDirectory: true)
            guard FileIO.isDirectory(source) else { continue }
            let target = noteURL(noteId)
            for name in Self.visibleEntries(source) {
                guard let rev = RevisionName(name) else { continue }
                let path = "\(Self.notesName)/\(dir)/\(name)"
                let from = source.appendingPathComponent(name)
                let to = target.appendingPathComponent(name)
                if Self.holds(to) {
                    if FileIO.exists(to), let a = try? FileIO.read(to, maxBytes: BoundedRead.maxRevisionBytes),
                       let b = try? BoundedRead.contents(of: from, maxBytes: BoundedRead.maxRevisionBytes), a != b {
                        report.differing.append(path)
                    }
                    continue
                }
                let data: Data
                do {
                    data = try BoundedRead.contents(of: from, maxBytes: BoundedRead.maxRevisionBytes)
                    try checkIncomingRevision(data, noteId: noteId, name: rev)
                } catch {
                    report.refused[path] = "\(error)"
                    continue
                }
                report.added.append(path)
                if !dryRun {
                    try FileIO.createDirectory(target)
                    do { try FileIO.writeAtomically(data, to: to, replacing: false) } catch VaultError.alreadyExists {}
                }
            }
            let att = source.appendingPathComponent(Self.attachmentsName, isDirectory: true)
            for name in Self.visibleEntries(att) where BlobName.parse(name) != nil {
                let path = "\(Self.notesName)/\(dir)/\(Self.attachmentsName)/\(name)"
                let to = attURL(noteId).appendingPathComponent(name)
                // Blob names are keyed hashes of their content: the same name is the same blob.
                if Self.holds(to) { continue }
                let from = att.appendingPathComponent(name)
                do { try checkIncomingBlob(at: from, fileName: name) } catch {
                    report.refused[path] = "\(error)"
                    continue
                }
                report.added.append(path)
                if !dryRun { try Self.copyNew(from, to: to) }
            }
        }

        // inbox/<capture> (adoption is idempotent, §11.3: a capture already adopted here is adopted into the same note)
        let otherInbox = other.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        for name in Self.visibleEntries(otherInbox) where CaptureFile.parse(name: name) != nil {
            let to = inboxURL.appendingPathComponent(name)
            if Self.holds(to) { continue }
            let from = otherInbox.appendingPathComponent(name)
            if let size = FileIO.size(from), size > Int64(CaptureFile.maxBytes) + (64 << 20) {
                report.refused["\(CaptureFile.folderName)/\(name)"] = "too large"
                continue
            }
            report.added.append("\(CaptureFile.folderName)/\(name)")
            if !dryRun { try Self.copyNew(from, to: to) }
        }

        // notebooks/<record> (§14): write-once, so the union. Unlocked, a record must open
        // (decrypt, verify, decode) before it is placed; locked, only its size is checked.
        let otherNotebooks = other.appendingPathComponent(NotebookRecords.folderName, isDirectory: true)
        for name in Self.visibleEntries(otherNotebooks) where NotebookRecords.id(ofFileName: name) != nil {
            let path = "\(NotebookRecords.folderName)/\(name)"
            let to = notebooksURL.appendingPathComponent(name)
            if Self.holds(to) { continue }
            let data: Data
            do {
                data = try BoundedRead.contents(of: otherNotebooks.appendingPathComponent(name), maxBytes: NotebookRecords.maxFileBytes)
                if canRead { _ = try openNotebookRecord(data, fileName: name) }
            } catch {
                report.refused[path] = "\(error)"
                continue
            }
            report.added.append(path)
            if !dryRun {
                try FileIO.createDirectory(notebooksURL)
                do { try FileIO.writeAtomically(data, to: to, replacing: false) } catch VaultError.alreadyExists {}
            }
        }

        // keys/recovery-<fingerprint>.key.age: named by the key it holds (§15.11), never replaced.
        let otherKeys = other.appendingPathComponent(Self.keysName, isDirectory: true)
        for name in Self.visibleEntries(otherKeys) where name.hasPrefix("recovery-") && name.hasSuffix(".key.age") {
            let to = keysURL.appendingPathComponent(name)
            if Self.holds(to) { continue }
            let from = otherKeys.appendingPathComponent(name)
            guard let data = try? BoundedRead.contents(of: from, maxBytes: BoundedRead.maxSmallFileBytes) else {
                report.refused["\(Self.keysName)/\(name)"] = "unreadable or too large"
                continue
            }
            report.added.append("\(Self.keysName)/\(name)")
            if !dryRun {
                try FileIO.createDirectory(keysURL)
                do { try FileIO.writeAtomically(data, to: to, replacing: false) } catch VaultError.alreadyExists {}
            }
        }

        // settings.age: merged per key (§13.3).
        let otherSettingsURL = other.appendingPathComponent(SharedSettings.fileName)
        if FileIO.exists(otherSettingsURL) {
            let theirs = try? BoundedRead.contents(of: otherSettingsURL, maxBytes: SharedSettings.maxFileBytes)
            let ours = try? FileIO.read(sharedSettingsURL, maxBytes: SharedSettings.maxFileBytes)
            if let theirs, theirs != ours {
                if !canRead {
                    report.settingsPending = "the vault is locked"
                } else {
                    do {
                        let other = SharedSettingsMigrations.migrated(try openSharedSettings(theirs).settings)
                        let own = try readSharedSettings()
                        let merged = own.map { $0.merging(other) } ?? other
                        if merged != own {
                            report.settingsMerged = true
                            if !dryRun { try writeSharedSettings(merged) }
                        }
                    } catch {
                        report.settingsPending = "\(error)"
                    }
                }
            }
        }
        report.added.sort()
        report.differing.sort()
        return report
    }

    /// The names in `dir` that are not hidden (format.md §1.1); empty when it cannot be listed.
    static func visibleEntries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// True when `url` exists, or iCloud Drive holds it as a placeholder (`.<name>.icloud`).
    static func holds(_ url: URL) -> Bool {
        if FileIO.exists(url) { return true }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileIO.exists(placeholder)
    }

    /// Copies the regular file `from` to `to` (a new name) through a temporary
    /// file in `to`'s folder, never replacing an existing file.
    static func copyNew(_ from: URL, to: URL) throws {
        let dir = to.deletingLastPathComponent()
        try FileIO.createDirectory(dir)
        let tmp = FileIO.tempURL(in: dir)
        let input = try BoundedRead.openRegularFile(from)
        defer { try? input.close() }
        try FileIO.writeNewFile(tmp) { write in
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try write(chunk) }
        }
        do { try FileIO.placeNew(tmp, at: to) } catch VaultError.alreadyExists {}
    }
}
