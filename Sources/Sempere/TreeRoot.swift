import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A path inside a `TreeRoot` that was left alone: a link on the way, or a leaf that is not a regular file.
package struct SkippedPath: Error, CustomStringConvertible {
    package var path: String
    package var reason: String
    package var description: String { "skipped \(path): \(reason)" }
}

/// A folder tree that this process writes into although others may write there too (an export folder on
/// shared storage). The root is resolved once and held open; every later operation goes through
/// `openat(2)` and friends relative to folders opened with `O_NOFOLLOW`, so a symbolic link made by someone else
/// anywhere below the root is never followed, and files are put in place with `rename(2)`.
package final class TreeRoot: Sendable {
    /// The resolved root.
    package let url: URL
    private let fd: Int32

    package init(_ root: URL) throws {
        let resolved = root.resolvingSymlinksInPath()
        let fd = resolved.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return -1 }
            return open(p, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else { throw VaultError.io("open \(root.path): \(FileIO.errnoText(errno))") }
        self.fd = fd
        self.url = resolved
    }

    deinit { _ = close(fd) }

    private func parts(_ rel: String) throws -> [String] {
        let p = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !p.isEmpty, p.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") }) else {
            throw SkippedPath(path: rel, reason: "not a path inside the folder")
        }
        return p
    }

    /// The folder `names` below the root, as a descriptor the caller closes; nil when it does not exist and
    /// is not created. A link or a non-folder on the way is `SkippedPath`.
    private func openFolder(_ names: ArraySlice<String>, create: Bool, shown: String) throws -> Int32? {
        var dir = dup(fd)
        guard dir >= 0 else { throw VaultError.io("open \(url.path): \(FileIO.errnoText(errno))") }
        for name in names {
            var next = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                if mkdirat(dir, name, 0o700) != 0, errno != EEXIST {
                    let code = errno
                    _ = close(dir)
                    throw VaultError.io("mkdir \(shown): \(FileIO.errnoText(code))")
                }
                next = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let code = errno
            _ = close(dir)
            guard next >= 0 else {
                if code == ENOENT { return nil }
                if code == ELOOP || code == ENOTDIR {
                    throw SkippedPath(path: shown, reason: "a folder on the way is a link or not a folder")
                }
                throw VaultError.io("open \(shown): \(FileIO.errnoText(code))")
            }
            dir = next
        }
        return dir
    }

    /// Throws `SkippedPath` when `name` in `parent` exists and is not a regular file (a link included).
    private func checkLeaf(_ parent: Int32, _ name: String, shown: String) throws {
        var st = stat()
        if fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw SkippedPath(path: shown, reason: "not a regular file")
        }
    }

    private func openRegular(_ parent: Int32, _ name: String) -> Int32? {
        let f = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard f >= 0 else { return nil }
        var st = stat()
        guard fstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { _ = close(f); return nil }
        return f
    }

    /// Whether the folder for `rel` can be used (created if missing) and its leaf is not a link or
    /// something other than a regular file. Throws `SkippedPath` otherwise.
    package func prepare(_ rel: String) throws {
        let p = try parts(rel)
        guard let leaf = p.last, let parent = try openFolder(p.dropLast(), create: true, shown: rel) else { return }
        defer { _ = close(parent) }
        try checkLeaf(parent, leaf, shown: rel)
    }

    /// The regular file at `rel`, read whole (at most `maxBytes`); no link below the root is followed.
    package func read(_ rel: String, maxBytes: Int) throws -> Data {
        try BoundedRead.contents(under: url, rel, maxBytes: maxBytes)
    }

    /// SHA-256 and size of the regular file at `rel`, or nil when it is not one (or a link is in the way).
    package func digest(_ rel: String) -> (sha256: String, size: Int64)? {
        guard let d = try? FileDigest.sha256(under: url, rel) else { return nil }
        return (d.hex, d.size)
    }

    /// Writes `data` to `rel` (private, mode 0600): a temporary file in the verified folder is written,
    /// flushed and renamed over the leaf. A leaf that is not a regular file is `SkippedPath`, unless
    /// `anyLeaf`: `rename(2)` replaces a link or a FIFO itself and never follows it (for the export's own
    /// manifest, which a stray file of that name must not block).
    package func replace(_ rel: String, with data: Data, anyLeaf: Bool = false) throws {
        let p = try parts(rel)
        guard let leaf = p.last, let parent = try openFolder(p.dropLast(), create: true, shown: rel) else {
            throw VaultError.io("mkdir \(rel)")
        }
        defer { _ = close(parent) }
        if !anyLeaf { try checkLeaf(parent, leaf, shown: rel) }
        let tmp = FileIO.tempPrefix + UUID().uuidString.lowercased()
        let f = openat(parent, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { throw VaultError.io("create \(rel): \(FileIO.errnoText(errno))") }
        let handle = FileHandle(fileDescriptor: f, closeOnDealloc: false)
        do {
            try autoreleasing { try handle.write(contentsOf: data) }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            _ = unlinkat(parent, tmp, 0)
            throw VaultError.io("write \(rel): \(error)")
        }
        guard renameat(parent, tmp, parent, leaf) == 0 else {
            let code = errno
            _ = unlinkat(parent, tmp, 0)
            throw VaultError.io("rename to \(rel): \(FileIO.errnoText(code))")
        }
        _ = fsync(parent)
    }

    /// Puts the file `render` makes at `rel`, unless the file there already holds exactly that. `render`
    /// writes a temporary file (mode 0600) at the URL it is given, in the verified folder; the result is
    /// compared and renamed over the leaf. Returns whether the file changed.
    package func place(_ rel: String, render: (URL) throws -> Void) throws -> Bool {
        let p = try parts(rel)
        guard let leaf = p.last, let parent = try openFolder(p.dropLast(), create: true, shown: rel) else {
            throw VaultError.io("mkdir \(rel)")
        }
        defer { _ = close(parent) }
        try checkLeaf(parent, leaf, shown: rel)
        let tmpName = ".\(leaf).\(UUID().uuidString).tmp"
        let folder = p.dropLast().reduce(url) { $0.appendingPathComponent($1) }
        defer { _ = unlinkat(parent, tmpName, 0) }
        try render(folder.appendingPathComponent(tmpName))
        guard let new = openRegular(parent, tmpName) else {
            throw VaultError.io("\(rel): the folder changed while the file was written")
        }
        defer { _ = close(new) }
        if let old = openRegular(parent, leaf) {
            defer { _ = close(old) }
            if Self.sameContents(old, new) { return false }
        }
        guard renameat(parent, tmpName, parent, leaf) == 0 else {
            throw VaultError.io("rename to \(rel): \(FileIO.errnoText(errno))")
        }
        _ = fsync(parent)
        return true
    }

    private static func sameContents(_ a: Int32, _ b: Int32) -> Bool {
        var sa = stat(), sb = stat()
        guard fstat(a, &sa) == 0, fstat(b, &sb) == 0, sa.st_size == sb.st_size else { return false }
        let ha = FileHandle(fileDescriptor: a, closeOnDealloc: false), hb = FileHandle(fileDescriptor: b, closeOnDealloc: false)
        while true {
            guard let x = try? autoreleasing({ try ha.read(upToCount: 1 << 20) }),
                  let y = try? autoreleasing({ try hb.read(upToCount: 1 << 20) }) else { return false }
            guard x == y else { return false }
            if x.isEmpty { return true }
        }
    }

    package enum Removal: Equatable {
        case removed, missing
        case skipped(String)
    }

    /// Deletes the regular file at `rel` only when its size and SHA-256 are the ones given (what an
    /// export wrote), then the folders that leaves empty (never the root). A link on the way, a leaf
    /// that is not a regular file, or a changed file is left alone.
    package func remove(_ rel: String, size: Int64, sha256: String) -> Removal {
        remove(rel, size: size) { handle in
            guard let d = try? FileDigest.sha256(of: handle, path: rel, maxBytes: size) else { return false }
            return d.size == size && d.hex == sha256
        }
    }

    /// `remove(_:size:sha256:)` with the check in the caller's hands: `matches` reads the open file (of `size` bytes).
    package func remove(_ rel: String, size: Int64, matches: (FileHandle) -> Bool) -> Removal {
        do {
            let p = try parts(rel)
            guard let leaf = p.last, let parent = try openFolder(p.dropLast(), create: false, shown: rel) else { return .missing }
            defer { _ = close(parent) }
            var st = stat()
            guard fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return .missing }
            guard (st.st_mode & S_IFMT) == S_IFREG, let f = openRegular(parent, leaf) else { return .skipped("not a regular file") }
            let handle = FileHandle(fileDescriptor: f, closeOnDealloc: false)
            let same = matches(handle)
            _ = close(f)
            guard same else { return .skipped("it is not the file that was exported") }
            guard unlinkat(parent, leaf, 0) == 0 else { return .skipped(FileIO.errnoText(errno)) }
        } catch let e as SkippedPath {
            return .skipped(e.reason)
        } catch {
            return .skipped("\(error)")
        }
        var folders = (try? parts(rel).dropLast()) ?? []
        while let name = folders.popLast() {
            guard let up = try? openFolder(folders[...], create: false, shown: rel) else { break }
            let rc = unlinkat(up, name, AT_REMOVEDIR)
            _ = close(up)
            if rc != 0 { break }
        }
        return .removed
    }
}
