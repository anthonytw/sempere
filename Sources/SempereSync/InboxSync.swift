import Foundation
import Sempere

// MARK: - Capture inbox (format.md §11.4, design §5.3)
//
// `inbox/<captureId>.<kind>.age` files are not write-once (an adoption deletes
// them, a key change re-seals them), so they follow a table of their own:
//
// | local | remote | in last sync | action |
// | --- | --- | --- | --- |
// | yes | no | — | adoption explains it: delete it here; else upload (create only) |
// | no | yes | — | adoption explains it: delete it there; else download (checked first, §9.1; quarantined if it fails) |
// | yes | yes | — | in step when the bytes are the same; different bytes are reported, neither replaced |
//
// "Adoption explains it" (format.md §11.3, `CaptureAdoption.consumed`): the
// note derived from the capture id has a revision here, and adoption would
// delete that file after it: a capture once the note exists, a transcript once
// the recording has one (or is gone, or holds other audio). It is judged with
// the vault unlocked, over the notes this run left in step (the inbox is synced
// after them, so an adopted note travels before its inbox file goes), and never
// for a note this copy has not completely downloaded. A file adoption explains is
// never copied, whether or not both sides held it before: devices that bridge two
// targets would otherwise hand it back and forth. Locked, nothing is judged: a file
// both sides held is left for an unlocked run (neither deleted nor copied back), one
// never synced is copied (quick captures into a closed vault). Push-only runs upload
// and follow explained deletions on the server, never write locally.

extension SyncEngine {
    func syncInbox(remoteRoot: [String: RemoteEntry]) throws {
        let folder = CaptureFile.folderName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        let all = try LocalFS.entries(localDir)
        let local = Set(all.filter { CaptureFile.parse(name: $0) != nil })
        removeStaleInboxStaging(localDir, names: all)
        // A folder a provider listed before its files is left for a later run (`Arrivals.swift`).
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        var listed: [String: RemoteEntry] = [:]
        if remoteRoot[folder]?.isCollection == true, let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection {
                if CaptureFile.parse(name: e.name) != nil {
                    listed[e.name] = e
                } else if !e.name.hasPrefix(".") {
                    report.ignored.append("\(folder)/\(SyncReport.printable(e.name))")
                }
            }
        }
        let records = state.inbox ?? [:]
        var kept: [String: SyncState.InboxRecord] = [:]
        for name in local.union(listed.keys).sorted() {
            let path = "\(folder)/\(name)"
            do {
                try checkCancelled()
                try budget.checkTime()
                if let r = try syncInboxFile(name, hasLocal: local.contains(name), remote: listed[name], record: records[name]) {
                    kept[name] = r
                }
            } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: path, message: Self.describe(error)))
                if let r = records[name] { kept[name] = r }
            }
        }
        if !options.dryRun { state.inbox = kept.isEmpty ? nil : kept }
    }

    /// One inbox file; returns what the state records for it (nil: nothing,
    /// so the next run takes it as never synced).
    private func syncInboxFile(_ name: String, hasLocal: Bool, remote: RemoteEntry?,
                               record: SyncState.InboxRecord?) throws -> SyncState.InboxRecord? {
        let folder = CaptureFile.folderName
        let path = "\(folder)/\(name)"
        let file = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
        switch (hasLocal, remote) {
        case (true, let remote?):
            if try !available([folder, name], entry: remote) { return record }
            let mark = Self.localMark(file)
            if let record, record.stamp != nil, record.stamp == remote.stamp, record.size == mark.size,
               record.modified == mark.modified {
                return record
            }
            let localHash = try FileDigest.sha256(of: file).hex
            if let record, record.hash == localHash, record.stamp != nil, record.stamp == remote.stamp {
                return .init(hash: localHash, stamp: remote.stamp, size: mark.size, modified: mark.modified)
            }
            guard let staged = try stageInboxDownload(name, entry: remote) else { return record }
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            let remoteHash = try FileDigest.sha256(of: staged).hex
            if remoteHash == localHash {
                return .init(hash: localHash, stamp: remote.stamp, size: mark.size, modified: mark.modified)
            }
            // A key change re-sealed one copy (format.md §3.3.1 step 3): replacing it is rewrap-replace
            // (key-hierarchy KH6). Until then neither copy is touched.
            report.skipped.append(.init(path: path, message: "differs on the two sides; neither copy is replaced"))
            return nil

        case (true, nil):
            // Adoption explains the file whether or not the remote held it before: one that is
            // consumed is never copied anywhere, only deleted (two devices that bridge two targets
            // would otherwise hand an adopted capture back and forth for ever).
            switch inboxDeletionExplained(name, localFile: file, remoteFile: nil) {
            case nil where record != nil:
                report.skipped.append(.init(path: path, message: "gone from the remote; judged when the vault is unlocked"))
                return record
            case true?:
                guard !options.pushOnly else { return nil }
                try requireLocalWrite("delete \(path)")
                report.deleted.append(.init(side: "local", path: path))
                if !options.dryRun { try LocalFS.remove(file) }
                return nil
            default:
                // Not explained (copied back), or locked and never synced (a capture into a closed vault).
                return try uploadInboxFile(name, file: file)
            }

        case (false, let remote?):
            if Self.parsedKind(name) == .capture {
                // A capture is judged without its bytes (up to 256 MiB).
                switch inboxDeletionExplained(name, localFile: nil, remoteFile: nil) {
                case nil where record != nil:
                    report.skipped.append(.init(path: path, message: "deleted here; judged when the vault is unlocked"))
                    return record
                case true?:
                    try deleteRemoteInboxFile(name, entry: remote)
                    return nil
                default:
                    break
                }
            }
            guard !options.pushOnly else {
                if record == nil { report.skipped.append(.init(path: path, message: "only on the remote; a push-only run does not download")) }
                return nil
            }
            if options.dryRun {
                report.downloaded.append(path)
                return nil
            }
            guard let staged = try stageInboxDownload(name, entry: remote) else { return record }
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            if Self.parsedKind(name) == .transcript {
                switch inboxDeletionExplained(name, localFile: nil, remoteFile: staged) {
                case nil where record != nil:
                    report.skipped.append(.init(path: path, message: "deleted here; judged when the vault is unlocked"))
                    return record
                case true?:
                    try deleteRemoteInboxFile(name, entry: remote)
                    return nil
                default:
                    break
                }
            }
            return try placeInboxFile(name, staged: staged, entry: remote)

        case (false, nil):
            return nil
        }
    }

    // MARK: Transfers

    /// Uploads a local inbox file without replacing anything on the remote. On a
    /// remote with no atomic create, it goes to a temporary name first and is
    /// moved into place without overwriting, as blobs are (a capture may be large,
    /// and a reader must never see half of one under its name).
    private func uploadInboxFile(_ name: String, file: URL) throws -> SyncState.InboxRecord? {
        let folder = CaptureFile.folderName
        let path = "\(folder)/\(name)"
        guard let kind = Self.parsedKind(name), let size = LocalFS.regularFileSize(file) else {
            throw SyncError.io("\(path) is not a regular file")
        }
        guard size <= CaptureFile.maxSealedBytes(kind) else {
            throw SyncError.io("\(path) is \(size) bytes, over the inbox limit; not uploaded")
        }
        guard !options.dryRun else {
            report.uploaded.append(path)
            return nil
        }
        let hash = try FileDigest.sha256(of: file).hex
        try ensureCollection([folder])
        let created: Bool
        if transport.capabilities.atomicCreate {
            created = try transport.write([folder, name], .file(file), condition: .create)
        } else {
            let temp = [folder, FileIO.tempPrefix + UUID().uuidString.lowercased()]
            let tempRel = temp.joined(separator: "/")
            locked { state.remoteTemps.append(tempRel) }
            checkpoint()
            var moved = false
            defer {
                if moved || (try? transport.delete(temp)) != nil { locked { state.remoteTemps.removeAll { $0 == tempRel } } }
            }
            guard try transport.write(temp, .file(file), condition: .create) else {
                throw SyncError.io("\(path): the temporary upload name already exists on the remote")
            }
            moved = try transport.moveNoOverwrite(temp, to: [folder, name])
            created = moved
        }
        guard created else {
            // Already there (a listing that missed it, or another device's upload meanwhile): compared next run.
            return nil
        }
        report.uploaded.append(path)
        let mark = Self.localMark(file)
        let stamp = (try? transport.stat([folder, name]))??.stamp
        return .init(hash: hash, stamp: stamp, size: mark.size, modified: mark.modified)
    }

    /// Downloads a remote inbox file into a staging folder inside the local
    /// `inbox/` (hidden, so no listing sees it), under its own name; nil when
    /// it was not downloaded (arriving, or quarantined by an earlier run).
    private func stageInboxDownload(_ name: String, entry: RemoteEntry) throws -> URL? {
        let folder = CaptureFile.folderName
        let path = "\(folder)/\(name)"
        guard let kind = Self.parsedKind(name) else { return nil }
        let limit = CaptureFile.maxSealedBytes(kind)
        if let size = entry.size, size > limit { throw SyncError.responseTooLarge(path: path, limit: limit) }
        if skipQuarantined(path, path: path, entry: entry) { return nil }
        if try !available([folder, name], entry: entry) { return nil }
        let reserved = try locked { try budget.willDownload(entry.size) }
        var counted = false
        defer { if !counted { locked { budget.release(reserved) } } }
        let stage = root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(FileIO.tempPrefix + UUID().uuidString.lowercased(), isDirectory: true)
        do { try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true) } catch {
            throw SyncError.io("create \(stage.path): \(error.localizedDescription)")
        }
        let staged = stage.appendingPathComponent(name)
        do {
            try transport.download([folder, name], to: staged, resumeFrom: 0, ifETag: nil, maxBytes: limit,
                                   segmentBytes: options.blobSegmentBytes, progress: nil)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            if Self.isUnavailable(error) {
                noteArriving([folder, name])
                return nil
            }
            throw error
        }
        let size = LocalFS.regularFileSize(staged) ?? 0
        counted = true
        try locked { try budget.downloaded(size, reserved: reserved) }
        return staged
    }

    /// Checks a staged inbox file (format.md §9.1) and links it into place, never
    /// over an existing file; one that fails is quarantined.
    private func placeInboxFile(_ name: String, staged: URL, entry: RemoteEntry) throws -> SyncState.InboxRecord? {
        let folder = CaptureFile.folderName
        let path = "\(folder)/\(name)"
        try requireLocalWrite("write \(path)")
        var problem: String?
        if (try? LocalFS.prefix(of: staged, count: Self.ageMagic.count)) != Self.ageMagic {
            problem = "not an age file"
        } else if let checker = checker() {
            do { try checker.checkIncomingInboxFile(at: staged, name: name) } catch let e as IncomingFileProblem {
                problem = e.reason
            } catch {
                // The vault cannot judge it now (a tampered device list, I/O): neither placed nor quarantined.
                report.skipped.append(.init(path: path, message: SyncReport.printable("not placed: \(Self.describe(error))")))
                return nil
            }
        }
        if let problem {
            quarantine(path, path: path, entry: entry, reason: problem, file: staged)
            return nil
        }
        locked { state.quarantined?[path] = nil }
        let hash = try FileDigest.sha256(of: staged).hex
        let target = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
        guard try LocalFS.placeNew(staged, at: target) else { return nil }
        report.downloaded.append(path)
        let mark = Self.localMark(target)
        return .init(hash: hash, stamp: entry.stamp, size: mark.size, modified: mark.modified)
    }

    /// Deletes an adopted inbox file from the remote, only in the version listed.
    private func deleteRemoteInboxFile(_ name: String, entry: RemoteEntry) throws {
        let path = "\(CaptureFile.folderName)/\(name)"
        guard !options.dryRun else {
            report.deleted.append(.init(side: "remote", path: path))
            return
        }
        let etag = entry.etag.flatMap { Self.isStrong($0) ? $0 : nil }
        if try transport.delete([CaptureFile.folderName, name], ifETag: etag) {
            report.deleted.append(.init(side: "remote", path: path))
        } else {
            report.skipped.append(.init(path: path, message: "changed on the remote meanwhile; not deleted"))
        }
    }

    // MARK: Judging a deletion

    /// Whether adoption explains that inbox file `name` is gone from one side
    /// (format.md §11.4): nil when it cannot be judged now (locked). The
    /// file's bytes matter only for a transcript (which audio it is bound to):
    /// `localFile` or `remoteFile` (staged) is where they are.
    func inboxDeletionExplained(_ name: String, localFile: URL?, remoteFile: URL?) -> Bool? {
        guard let parsed = CaptureFile.parse(name: name) else { return false }
        guard let v = checker(), v.canRead else { return nil }
        let note = CaptureAdoption.ids(for: parsed.id).note
        // Never for a note this copy has not completely downloaded (format.md §1.2).
        if PartialCopyState.incompleteNotes(root).contains(note.uuidString.lowercased()) { return false }
        guard let names = try? v.revisionNames(of: note), !names.isEmpty,
              let loaded = try? v.loadNote(note, detail: .withoutStrokePoints), loaded.failures.isEmpty,
              let after = try? v.reconstruct(loaded) else { return false }
        switch parsed.kind {
        case .capture:
            // `CaptureAdoption.consumed`: a capture goes once its note exists.
            return !after.pages.isEmpty || !after.recordings.isEmpty
        case .transcript:
            guard let file = remoteFile ?? localFile,
                  let pending = try? v.readCapture(parsed.id, in: file.deletingLastPathComponent()) else { return false }
            return CaptureAdoption.consumed(pending, after: after).contains(name)
        }
    }

    // MARK: Helpers

    /// Staging folders a killed run left in `inbox/` (an hour old: a run of another target may be using a newer one).
    private func removeStaleInboxStaging(_ dir: URL, names: [String]) {
        guard !options.dryRun, !options.pushOnly else { return }
        for n in names where n.hasPrefix(FileIO.tempPrefix) {
            let url = dir.appendingPathComponent(n)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) > 3600 { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func parsedKind(_ name: String) -> CaptureFile.Kind? { CaptureFile.parse(name: name)?.kind }

    /// A local file's size and modification time (seconds since 1970).
    static func localMark(_ file: URL) -> (size: Int, modified: Double?) {
        let a = try? FileManager.default.attributesOfItem(atPath: file.path)
        return ((a?[.size] as? NSNumber)?.intValue ?? 0, (a?[.modificationDate] as? Date)?.timeIntervalSince1970)
    }
}
