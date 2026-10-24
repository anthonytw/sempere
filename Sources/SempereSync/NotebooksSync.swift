import Foundation
import Sempere

// MARK: - Notebook records (format.md §14)
//
// Records are write-once files with unique names, so both sides end with the
// union: what the server lacks is uploaded (create only, never replacing), what
// this side lacks is downloaded (push-only runs never write locally). Nothing is
// ever deleted. With the vault unlocked a downloaded record must open (decrypt,
// verify, decode) before it is placed; one that does not is skipped and reported.

extension SyncEngine {
    func syncNotebookRecords(remoteRoot: [String: RemoteEntry]) throws {
        let folder = NotebookRecords.folderName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        let local = Set(try LocalFS.entries(localDir).filter { NotebookRecords.id(ofFileName: $0) != nil })
        var remote: Set<String> = []
        var listed: [String: RemoteEntry] = [:]
        // A folder a provider listed before its files is left for a later run (`Arrivals.swift`).
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        if remoteRoot[folder]?.isCollection == true, let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection && NotebookRecords.id(ofFileName: e.name) != nil { listed[e.name] = e }
            remote = Set(listed.keys)
        }
        // Both sides hold it: the accepted copy replaces an unaccepted one (key-hierarchy design §5.4 step 4).
        for name in local.intersection(remote).sorted() where !options.dryRun {
            let path = "\(folder)/\(name)"
            do {
                try replaceUnaccepted(path, remotePath: [folder, name], recordKey: path, entry: listed[name],
                                      recorded: state.notebookShas?[path]) { data in
                    guard let vault, vault.canRead else { return }
                    _ = try vault.openNotebookRecord(data, fileName: name)
                }
            } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: path, message: Self.describe(error)))
            }
        }
        var uploadedNames = Set<String>()
        for (k, sha) in locked({ placedShas }) where k.hasPrefix(folder + "/") {
            state.notebookShas = state.notebookShas ?? [:]
            state.notebookShas?[k] = sha
        }
        for name in local.subtracting(remote).sorted() {
            let path = "\(folder)/\(name)"
            let data = try BoundedRead.contents(of: localDir.appendingPathComponent(name), maxBytes: NotebookRecords.maxFileBytes)
            if options.dryRun { report.uploaded.append(path); continue }
            try ensureCollection([folder])
            if try transport.write([folder, name], .data(data), condition: .create) {
                report.uploaded.append(path)
                uploadedNames.insert(name)
            }
        }
        defer {
            if !options.dryRun {
                let held = Set((try? LocalFS.entries(localDir)) ?? []).intersection(remote.union(uploadedNames))
                state.notebookNames = held.isEmpty ? nil : held.sorted()
            }
        }
        guard !options.pushOnly else { return }
        for name in remote.subtracting(local).sorted() {
            let path = "\(folder)/\(name)"
            if try !available([folder, name], entry: listed[name]) { continue }
            let got: (data: Data, etag: String?)
            do { got = try transport.read([folder, name], maxBytes: NotebookRecords.maxFileBytes) } catch where Self.isUnavailable(error) {
                noteArriving([folder, name])
                continue
            }
            try budget.downloaded(got.data.count)
            if let vault, vault.canRead {
                do { _ = try vault.openNotebookRecord(got.data, fileName: name) } catch NotebookRecordError.setAside(let r) {
                    // Under an earlier key, not sealed (key-hierarchy design §5.3): set aside, never placed.
                    refuseIncoming(path, path: path, entry: listed[name],
                                   problem: IncomingFileProblem("set aside: \(r.text)", setAside: r), data: got.data)
                    continue
                } catch {
                    report.skipped.append(.init(path: path, message: SyncReport.printable("not placed: \(Self.describe(error))")))
                    continue
                }
            }
            try requireLocalWrite("write \(path)")
            report.downloaded.append(path)
            guard !options.dryRun else { continue }
            try LocalFS.write(got.data, to: localDir.appendingPathComponent(name), replacing: false)
        }
    }
}
