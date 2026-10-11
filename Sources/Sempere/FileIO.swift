import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Small portable filesystem helpers (Foundation + POSIX `rename(2)`), so the
/// vault layer behaves the same on Apple platforms and Linux. `package`
/// members are shared with SempereWebDAV.
package enum FileIO {
    static var fm: FileManager { FileManager.default }

    /// Prefix of in-flight temporary files. They start with a dot and carry no
    /// `.age` suffix, so every listing ignores them as unknown files.
    package static let tempPrefix = ".sempere-tmp-"

    /// Writes `data` to `url` atomically: a temporary file in the same
    /// directory is written and flushed to disk, then renamed into place.
    /// Readers see either nothing (or the old file) or the complete new one.
    ///
    /// - Parameter replacing: when false the call refuses an existing
    ///   destination with `VaultError.alreadyExists`. The check happens right
    ///   before the rename; a writer racing on the very same name is outside
    ///   the format's model (names embed a per-device sequence number).
    static func writeAtomically(_ data: Data, to url: URL, replacing: Bool) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(tempPrefix + UUID().uuidString.lowercased())
        do {
            try data.write(to: tmp, options: [.withoutOverwriting])
            let h = try FileHandle(forWritingTo: tmp)
            try h.synchronize()
            try h.close()
        } catch {
            try? fm.removeItem(at: tmp)
            throw VaultError.io("write \(tmp.path): \(error)")
        }
        if !replacing && exists(url) {
            try? fm.removeItem(at: tmp)
            throw VaultError.alreadyExists(url.path)
        }
        let rc = tmp.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return rename(src, dst)
            }
        }
        guard rc == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw VaultError.io("rename to \(url.path): \(errnoText(code))")
        }
        try syncDirectory(dir)
    }

    /// Creates `url` (mode 0600, refusing an existing file), lets `body`
    /// write to it, flushes it to disk (`fsync`) and closes it. On any
    /// failure the file is removed and the error rethrown. For streamed
    /// files (attachment blobs) written under a temporary name and then put
    /// in place with `placeNew` / `place(_:replacing:)`.
    package static func writeNewFile(_ url: URL, _ body: (_ write: (Data) throws -> Void) throws -> Void) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw VaultError.io("create \(url.path): \(errnoText(errno))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try body { data in
                guard !data.isEmpty else { return }
                do { try autoreleasing { try handle.write(contentsOf: data) } } catch {
                    throw VaultError.io("write \(url.path): \(error)")
                }
            }
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                throw VaultError.io("flush \(url.path): \(error)")
            }
        } catch {
            try? handle.close()
            try? fm.removeItem(at: url)
            throw error
        }
    }

    /// A fresh temporary name in `dir` (ignored by every listing).
    package static func tempURL(in dir: URL) -> URL {
        dir.appendingPathComponent(tempPrefix + UUID().uuidString.lowercased())
    }

    /// Moves the finished temporary file `tmp` to `url` in the same
    /// directory without ever replacing an existing file: `link(2)` (which
    /// fails if `url` exists), then unlink `tmp`. On file systems without
    /// hard links (FAT, some network shares) it falls back to an existence
    /// check and `rename(2)`, as `writeAtomically` does. The directory is
    /// fsynced. `tmp` is removed in every case.
    ///
    /// - Throws: `VaultError.alreadyExists` if `url` exists, `.io` otherwise.
    package static func placeNew(_ tmp: URL, at url: URL) throws {
        defer { try? fm.removeItem(at: tmp) }
        let rc = tmp.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return link(src, dst)
            }
        }
        if rc != 0 {
            let code = errno
            if code == EEXIST { throw VaultError.alreadyExists(url.path) }
            guard [EPERM, ENOTSUP, EOPNOTSUPP, EXDEV, ENOSYS, EMLINK].contains(code) else {
                throw VaultError.io("link to \(url.path): \(errnoText(code))")
            }
            guard !exists(url) else { throw VaultError.alreadyExists(url.path) }
            try place(tmp, at: url)
            return
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    /// Renames the finished temporary file `tmp` onto `url` (replacing it),
    /// then fsyncs the directory. `tmp` is removed on failure.
    package static func place(_ tmp: URL, at url: URL) throws {
        let rc = tmp.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return rename(src, dst)
            }
        }
        guard rc == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw VaultError.io("rename to \(url.path): \(errnoText(code))")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    /// Flushes a directory's entries (a rename or unlink in it) to disk with
    /// `fsync(2)` on the directory. Filesystems that cannot fsync a directory
    /// (`EINVAL`, `ENOTSUP`) are accepted as is.
    static func syncDirectory(_ dir: URL) throws {
        let fd = dir.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard fd >= 0 else { throw VaultError.io("open \(dir.path) for fsync: \(errnoText(errno))") }
        defer { _ = close(fd) }
        if fsync(fd) != 0 {
            let code = errno
            guard code == EINVAL || code == ENOTSUP else {
                throw VaultError.io("fsync \(dir.path): \(errnoText(code))")
            }
        }
    }

    /// Reads a whole regular file of at most `maxBytes` (`BoundedRead`).
    static func read(_ url: URL, maxBytes: Int) throws -> Data {
        try BoundedRead.contents(of: url, maxBytes: maxBytes)
    }

    /// `strerror(3)` text with the number, for error messages people read.
    static func errnoText(_ code: Int32) -> String {
        "\(String(cString: strerror(code))) (errno \(code))"
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    package static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// The size of the file at `url`; nil when it cannot be read.
    static func size(_ url: URL) -> Int64? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Entry names in `dir`, sorted. A directory that does not exist is
    /// empty (sync tools drop empty directories); any other failure to list
    /// it throws `VaultError.io`, so "could not read" never looks like
    /// "nothing there".
    static func entries(_ dir: URL) throws -> [String] {
        guard fm.fileExists(atPath: dir.path) else { return [] }
        do { return try fm.contentsOfDirectory(atPath: dir.path).sorted() } catch {
            throw VaultError.io("list \(dir.path): \(error)")
        }
    }

    /// `entries(dir)` that pass `include`, kept only if they are directories
    /// (`directories`) or only if they are not, following symbolic links as
    /// `isDirectory` does. Entry types come from `readdir(3)`; only symbolic
    /// links and entries of unknown type (some network or synced file
    /// systems report no type) cost a `stat`. Sorted; a missing `dir` is
    /// empty and any other failure to list it throws `VaultError.io`, as
    /// for `entries`.
    static func entries(_ dir: URL, directories: Bool, where include: (String) -> Bool) throws -> [String] {
        guard let d = dir.withUnsafeFileSystemRepresentation({ $0.flatMap { opendir($0) } }) else {
            let code = errno
            if code == ENOENT { return [] }
            throw VaultError.io("list \(dir.path): \(errnoText(code))")
        }
        defer { closedir(d) }
        var out: [String] = []
        while true {
            errno = 0
            guard let e = readdir(d) else {
                if errno != 0 { throw VaultError.io("list \(dir.path): \(errnoText(errno))") }
                break
            }
            let name = withUnsafePointer(to: &e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: e.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", include(name) else { continue }
            let isDir: Bool
            switch Int32(e.pointee.d_type) {
            case Int32(DT_DIR): isDir = true
            case Int32(DT_LNK), Int32(DT_UNKNOWN): isDir = isDirectory(dir.appendingPathComponent(name))
            default: isDir = false
            }
            if isDir == directories { out.append(name) }
        }
        return out.sorted()
    }

    package static func createDirectory(_ url: URL) throws {
        do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch {
            throw VaultError.io("mkdir \(url.path): \(error)")
        }
    }

    /// Removes a file and flushes its directory.
    package static func remove(_ url: URL) throws {
        do { try fm.removeItem(at: url) } catch { throw VaultError.io("remove \(url.path): \(error)") }
        try syncDirectory(url.deletingLastPathComponent())
    }
}

/// Runs `body` in its own autorelease pool on Apple platforms, where
/// `FileHandle` reads and writes autorelease their buffers: in a loop over a
/// large blob they would otherwise pile up until the caller's pool drains (a
/// whole file's worth of memory). A no-op elsewhere.
package func autoreleasing<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool { try body() }
    #else
    return try body()
    #endif
}

/// Reading files that may come from a sync server or a shared folder: only
/// regular files (a FIFO would block the open forever, a device never end),
/// and never more than a stated size, checked before the bytes are held.
public enum BoundedRead {
    /// The largest revision file a reader opens (the WebDAV client's download limit too).
    public static let maxRevisionBytes = 256 << 20
    /// The largest `vault.json` or `rewrap-journal.json` a reader opens.
    public static let maxManifestBytes = 16 << 20
    /// The largest identity file (`keys/*.key.age`) or device-state file a reader opens.
    public static let maxSmallFileBytes = 1 << 20
    /// The largest attachment blob file a reader opens: 1 GiB of content
    /// (format.md §8.4) plus 64 MiB for its framing and age overhead (padme of
    /// a 1 GiB blob adds up to 32 MiB, age's chunk tags 264 KiB, its header at
    /// most 2 MiB).
    public static let maxBlobFileBytes = (1 << 30) + (64 << 20)
    /// The largest `backup.json` a reader opens (one entry per backed-up file).
    public static let maxBackupManifestBytes = 256 << 20

    /// Opens `url` for reading if it is a regular file (following symlinks),
    /// without blocking on a FIFO.
    ///
    /// - Throws: `VaultError.io` if it cannot be opened or is not a regular file.
    public static func openRegularFile(_ url: URL) throws -> FileHandle {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NONBLOCK)
        }
        guard fd >= 0 else { throw VaultError.io("open \(url.path): \(FileIO.errnoText(errno))") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            _ = close(fd)
            throw VaultError.io("\(url.path) is not a regular file")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Opens the regular file at `path` (relative, `/`-separated) under the
    /// folder `root` without following a symbolic link anywhere below `root`
    /// (`root` itself may be one): each folder is opened with `openat(2)` and
    /// `O_NOFOLLOW | O_DIRECTORY`, the file with `O_NOFOLLOW`, so a link
    /// planted in a backup folder on shared storage can never make the
    /// reader copy a file from outside it (security review S3). Never blocks
    /// on a FIFO.
    ///
    /// - Throws: `VaultError.io` if a component is a symbolic link, cannot be
    ///   opened, or the file is not a regular file.
    public static func openRegularFile(under root: URL, _ path: String) throws -> FileHandle {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw VaultError.io("\(path): not a path inside \(root.path)")
        }
        var dir = root.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return -1 }
            return open(p, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard dir >= 0 else { throw VaultError.io("open \(root.path): \(FileIO.errnoText(errno))") }
        defer { if dir >= 0 { _ = close(dir) } }
        /// Why opening `name` in `at` failed: a symbolic link says so.
        func failure(_ name: String, _ code: Int32, _ at: Int32, _ shown: String) -> VaultError {
            var st = stat()
            if fstatat(at, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                return VaultError.io("\(shown) is a symbolic link; not followed")
            }
            return VaultError.io("open \(shown): \(FileIO.errnoText(code))")
        }
        for (i, name) in parts.dropLast().enumerated() {
            let next = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                throw failure(name, errno, dir, root.appendingPathComponent(parts[...i].joined(separator: "/")).path)
            }
            _ = close(dir)
            dir = next
        }
        let leaf = parts[parts.count - 1]
        let fd = openat(dir, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(leaf, errno, dir, root.appendingPathComponent(path).path) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            _ = close(fd)
            throw VaultError.io("\(root.appendingPathComponent(path).path) is not a regular file")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// The first component of `path` under `root` (as a `/`-separated prefix
    /// of `path`) that is a symbolic link, by `lstat(2)`; nil when there is
    /// none (missing components count as none).
    public static func firstLink(under root: URL, _ path: String) -> String? {
        var u = root
        var prefix: [Substring] = []
        for part in path.split(separator: "/") {
            u = u.appendingPathComponent(String(part))
            prefix.append(part)
            var st = stat()
            let rc = u.withUnsafeFileSystemRepresentation { p -> Int32 in
                guard let p else { return -1 }
                return lstat(p, &st)
            }
            guard rc == 0 else { return nil }
            if (st.st_mode & S_IFMT) == S_IFLNK { return prefix.joined(separator: "/") }
        }
        return nil
    }

    /// The whole file, or `VaultError.fileTooLarge` if it holds more than
    /// `maxBytes` (decided without reading more than `maxBytes + 1`).
    public static func contents(of url: URL, maxBytes: Int) throws -> Data {
        let h = try openRegularFile(url)
        defer { try? h.close() }
        let data: Data
        do { data = try h.read(upToCount: max(maxBytes, 0) + 1) ?? Data() } catch {
            throw VaultError.io("read \(url.path): \(error)")
        }
        guard data.count <= maxBytes else { throw VaultError.fileTooLarge(url.path, limit: maxBytes) }
        return data
    }
}

extension URL {
    /// The path with `.`, `..` and symbolic links resolved: two locations
    /// compare by it.
    public var canonicalPath: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether this location and `other` are the same or one is inside the other.
    public func overlaps(_ other: URL) -> Bool {
        let a = canonicalPath, b = other.canonicalPath
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// Whether this location is `root` or inside it.
    public func isSameOrInside(_ root: URL) -> Bool {
        let p = canonicalPath, r = root.canonicalPath
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}
