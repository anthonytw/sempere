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
        for name in local.subtracting(remote).sorted() {
            let path = "\(folder)/\(name)"
            let data = try BoundedRead.contents(of: localDir.appendingPathComponent(name), maxBytes: NotebookRecords.maxFileBytes)
            if options.dryRun { report.uploaded.append(path); continue }
            try ensureCollection([folder])
            if try transport.write([folder, name], .data(data), condition: .create) { report.uploaded.append(path) }
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
                do { _ = try vault.openNotebookRecord(got.data, fileName: name) } catch {
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
