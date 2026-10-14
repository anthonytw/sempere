import Foundation

/// What the tests that check a folder on disk compare: which files it holds, and their bytes.
public enum FileTree {
    /// The regular files below `dir`, as paths relative to it, sorted. `skipHidden` leaves out those whose
    /// relative path starts with a dot (a hidden file or folder at the top).
    public static func regularFiles(under dir: URL, skipHidden: Bool = false) -> [String] {
        let base = dir.standardizedFileURL.path
        let walker = FileManager.default.enumerator(atPath: base)
        var out: [String] = []
        while let rel = walker?.nextObject() as? String {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + "/" + rel, isDirectory: &isDir), !isDir.boolValue,
               !(skipHidden && rel.hasPrefix(".")) { out.append(rel) }
        }
        return out.sorted()
    }

    /// Every regular file below `dir` with its bytes, by relative path.
    public static func snapshot(of dir: URL) throws -> [String: Data] {
        let base = dir.standardizedFileURL
        return try Dictionary(uniqueKeysWithValues: regularFiles(under: base).map {
            ($0, try Data(contentsOf: base.appendingPathComponent($0)))
        })
    }
}
