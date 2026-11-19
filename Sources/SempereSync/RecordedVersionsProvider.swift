#if DEBUG
import Foundation

// MARK: - Conflict versions recorded in a folder, for tests and drills (docs/io.md "A vault folder held as a package")
//
// A provider whose conflict versions are plain files and folders on any file system, so `VaultFolderConflicts` and
// `sempere vault conflicts` are tested without iCloud (the CLI takes one from `SEMPERE_TEST_PROVIDER_VERSIONS`):
//
//     <store>/package                         present: the folder is recorded as a package (`itemRecord`)
//     <store>/versions/@/<id>/…               a conflict version of the vault folder itself (a folder)
//     <store>/versions/<path, / as %2F>/<id>  a conflict version of the file at <path> (a file)
//     <store>/resolved/<same>/<id>            a version marked resolved (moved here); `resolveConflicts` deletes it
//     <store>/dataless/<id>                   present: the version's bytes are not on this device (`hasLocalContents`)
//
// The device is the part of `<id>` after the last `@` (`v1@iPad`), if any. Foundation only. Debug builds only: a
// release build never takes conflict versions from a folder an environment variable names.

/// A provider simulated by a folder of recorded versions (see above).
public struct RecordedVersionsProvider: FolderProvider {
    /// The vault folder the versions belong to.
    public let root: URL
    /// The folder holding the records.
    public let store: URL

    public init(root: URL, store: URL) {
        self.root = root.standardizedFileURL
        self.store = store
    }

    public var name: String { "recorded versions" }
    public var managesFiles: Bool { true }

    /// The record folder's name for `url`: `@` for the root, else its path with `/` as `%2F`; nil outside the root.
    func key(_ url: URL) -> String? {
        let base = root.resolvingSymlinksInPath().pathComponents
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count >= base.count, Array(parts.prefix(base.count)) == base else { return nil }
        let rel = parts.dropFirst(base.count).joined(separator: "/")
        return rel.isEmpty ? "@" : rel.replacingOccurrences(of: "/", with: "%2F")
    }

    func folder(_ kind: String, _ url: URL) -> URL? {
        key(url).map { store.appendingPathComponent(kind, isDirectory: true).appendingPathComponent($0, isDirectory: true) }
    }

    public func conflictVersions(of url: URL) -> [RemoteVersion] {
        guard let dir = folder("versions", url),
              let ids = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return ids.filter { !$0.hasPrefix(".") }.sorted().map { id in
            let modified = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(id).path))?[.modificationDate] as? Date
            let device = id.split(separator: "@").count > 1 ? id.split(separator: "@").last.map(String.init) : nil
            let dataless = FileManager.default.fileExists(atPath: store.appendingPathComponent("dataless/\(id)").path)
            return RemoteVersion(id: id, modified: modified, device: device, hasLocalContents: !dataless)
        }
    }

    public func versionFile(of url: URL, id: String) -> URL? {
        guard !id.contains("/"), let dir = folder("versions", url) else { return nil }
        let file = dir.appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    public func resolveConflicts(of url: URL, ids: Set<String>) throws {
        for id in ids { if let f = versionFile(of: url, id: id) { try FileManager.default.removeItem(at: f) } }
    }

    public func markConflictsResolved(of url: URL, ids: Set<String>) throws {
        guard let to = folder("resolved", url) else { return }
        for id in ids {
            guard let f = versionFile(of: url, id: id) else { continue }
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: f, to: to.appendingPathComponent(id))
        }
    }

    public func itemRecord(of url: URL) -> ProviderItemRecord? {
        let package = key(url) == "@" && FileManager.default.fileExists(atPath: store.appendingPathComponent("package").path)
        return ProviderItemRecord(isPackage: package, contentType: package ? "dyn.recorded-package" : "public.folder",
                                  finderBundleBit: false, ubiquitous: true,
                                  hasUnresolvedConflicts: !conflictVersions(of: url).isEmpty)
    }
}
#endif
