import Foundation
import Sempere

// MARK: - Notebook records (format.md §14)
//
// Records are write-once files with unique names, so both sides end with the
// union: what the server lacks is uploaded (create only, never replacing), what
// this side lacks is downloaded (push-only runs never write locally). Nothing is
// ever deleted. With the vault unlocked a downloaded record must open (decrypt,
// verify, decode) before it is placed; one that does not is skipped and reported.

extension WebDAVSync {
    func syncNotebookRecords(remoteRoot: [String: RemoteEntry]) throws {
        let folder = NotebookRecords.folderName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        let local = Set(try LocalFS.entries(localDir).filter { NotebookRecords.id(ofFileName: $0) != nil })
        var remote: Set<String> = []
        if remoteRoot[folder]?.isCollection == true, let entries = try client.list([folder]) {
            try budget.list(entries.count)
            remote = Set(entries.filter { !$0.isCollection && NotebookRecords.id(ofFileName: $0.name) != nil }.map(\.name))
        }
        for name in local.subtracting(remote).sorted() {
            let path = "\(folder)/\(name)"
            let data = try BoundedRead.contents(of: localDir.appendingPathComponent(name), maxBytes: NotebookRecords.maxFileBytes)
            if options.dryRun { report.uploaded.append(path); continue }
            try ensureCollection([folder])
            if try client.put([folder, name], data, condition: .create) { report.uploaded.append(path) }
        }
        guard !options.pushOnly else { return }
        for name in remote.subtracting(local).sorted() {
            let path = "\(folder)/\(name)"
            let got = try client.get([folder, name], maxBytes: NotebookRecords.maxFileBytes)
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
